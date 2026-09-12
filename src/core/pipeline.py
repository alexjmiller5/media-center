"""Daily ingestion: TMDB episodes, YouTube videos, feed articles -> life-data.

Plain Python, no Modal imports. Each source is independent: a failure is
logged and counted, the run continues after recovery. New items and provenance
use atomic insert-if-absent writes; snapshots only avoid redundant requests.
"""

from hashlib import sha256

import httpx
import structlog

from core import feeds as feeds_mod
from core import tmdb, youtube
from core.hub import HubClient, imported_from, now_iso

log = structlog.get_logger()
CHUNK = 200


def _log_failure(event: str, exc: Exception, **context) -> None:
    """Log only safe diagnostics; exception messages and tracebacks can contain keys."""
    if isinstance(exc, httpx.HTTPStatusError):
        context["http_status"] = exc.response.status_code
    log.error(event, error=type(exc).__name__, **context)


def _count_rejected(table, rejected, out) -> set[str]:
    out["rejected"] += len(rejected)
    if rejected:
        log.warning("rows_rejected", table=table, n=len(rejected))
    return {row["id"] for row in rejected}


def _push(hub, table, rows, out) -> set[str]:
    return _count_rejected(table, hub.push(table, rows)["rejected"], out)


def _insert(hub, table, rows, out) -> dict:
    result = hub.insert(table, rows)
    _count_rejected(table, result["rejected"], out)
    return result


def _ingest(hub, table, rows, known, new_ids, out, counter) -> tuple[int, int]:
    before, rejected_before = out[counter], out["rejected"]
    rows = list({row["id"]: row for row in rows}.values())
    for i in range(0, len(rows), CHUNK):
        chunk = rows[i : i + CHUNK]
        result = _insert(hub, table, chunk, out)
        added = set(result["inserted"])
        # Acknowledge each chunk before a later request can fail.
        known.update(added)
        known.update(result["existing"])
        new_ids.update(added)
        out[counter] += len(added)
    return out[counter] - before, out["rejected"] - rejected_before


def _recover_known(hub, table, known, out) -> bool:
    """A failed write may have committed. Stop this kind if its state cannot be read."""
    try:
        known.update(row["id"] for row in hub.pull(table, ["id"], include_deleted=True))
        return True
    except Exception as exc:
        out["failed"] += 1
        _log_failure("recovery_failed", exc, kind=table)
        return False


def _sync_provenance(hub, source_table, item_table, parent, new_ids, out) -> None:
    """Repair from persisted relationships, even after an interrupted ingestion run."""
    try:
        known = {p["id"] for p in hub.pull("provenance", ["id"], include_deleted=True)}
        edges = [
            imported_from(
                source_table, row[parent], item_table, row["id"], created_row=row["id"] in new_ids
            )
            for row in hub.pull(item_table, ["id", parent])
            if row.get(parent)
        ]
        missing = [edge for edge in edges if edge["id"] not in known]
        for i in range(0, len(missing), CHUNK):
            # Account per chunk so a later HTTP failure cannot hide earlier rejections.
            _insert(hub, "provenance", missing[i : i + CHUNK], out)
    except Exception as exc:
        out["failed"] += 1
        _log_failure("provenance_failed", exc, kind=item_table)


def sync_tv(hub: HubClient, http: httpx.Client, key: str) -> dict:
    shows = hub.pull("tv_shows", ["id"])
    stored = {
        e["id"]: e
        for e in hub.pull(
            "tv_episodes",
            ["id", "show_id", "air_date", "title", "runtime_min", "deleted_at"],
            include_deleted=True,
        )
    }
    known = set(stored)
    new_ids = set()
    out = {"shows": len(shows), "episodes": 0, "failed": 0, "rejected": 0}
    for s in shows:
        try:
            show = tmdb.show(s["id"], key, http)
            rows = []
            updates = []
            for n in tmdb.season_numbers(show):
                for row in tmdb.episode_rows(s["id"], tmdb.season_episodes(s["id"], n, key, http)):
                    if row["id"] not in known:
                        rows.append(row)
                    elif old := stored.get(row["id"]):
                        if old.get("deleted_at") or old.get("show_id") != s["id"]:
                            continue
                        facts = {
                            col: row[col]
                            for col in ("air_date", "title", "runtime_min")
                            if row[col] not in (None, "")
                            and row[col] != old.get(col)
                            and (col != "runtime_min" or row[col] > 0)
                        }
                        if facts:
                            updates.append(
                                {"id": row["id"], **facts, "updated_at": row["updated_at"]}
                            )
            added, _ = _ingest(hub, "tv_episodes", rows, known, new_ids, out, "episodes")
            updates = list({row["id"]: row for row in updates}.values())
            for i in range(0, len(updates), CHUNK):
                _push(hub, "tv_episodes", updates[i : i + CHUNK], out)
            log.info("tv_synced", show=s["id"], new=added)
        except Exception as exc:
            out["failed"] += 1
            _log_failure("tv_failed", exc, show=s["id"])
            if not _recover_known(hub, "tv_episodes", known, out):
                break
    _sync_provenance(hub, "tv_shows", "tv_episodes", "show_id", new_ids, out)
    return out


def sync_youtube(hub: HubClient, http: httpx.Client, key: str) -> dict:
    channels = hub.pull("youtube_channels", ["id", "uploads_playlist_id", "backfilled"])
    known = {v["id"] for v in hub.pull("youtube_videos", ["id"], include_deleted=True)}
    new_ids = set()
    out = {"channels": len(channels), "videos": 0, "failed": 0, "rejected": 0}
    for c in channels:
        try:
            vids = youtube.uploads(
                c["uploads_playlist_id"],
                key,
                http,
                known_ids=known if c.get("backfilled") else None,
                channel_id=c["id"],
            )
            vids = [v for v in vids if v["id"] not in known]
            durs = youtube.durations([v["id"] for v in vids], key, http) if vids else {}
            rows = youtube.video_rows(c["id"], vids, durs)
            if rows and c.get("backfilled"):
                # Persist retry intent before any chunk can be partially accepted.
                if _push(
                    hub,
                    "youtube_channels",
                    [{"id": c["id"], "backfilled": 0, "updated_at": now_iso()}],
                    out,
                ):
                    raise RuntimeError("could not mark channel for retry")
            added, rejected = _ingest(hub, "youtube_videos", rows, known, new_ids, out, "videos")
            if not rejected and (rows or not c.get("backfilled")):
                # Only a fully accepted walk may enable the known-page boundary.
                if _push(
                    hub,
                    "youtube_channels",
                    [{"id": c["id"], "backfilled": 1, "updated_at": now_iso()}],
                    out,
                ):
                    raise RuntimeError("could not mark channel backfilled")
            log.info(
                "youtube_synced",
                channel=c["id"],
                new=added,
                backfill=not c.get("backfilled"),
            )
        except Exception as exc:
            out["failed"] += 1
            _log_failure("youtube_failed", exc, channel=c["id"])
            if not _recover_known(hub, "youtube_videos", known, out):
                break
    _sync_provenance(hub, "youtube_channels", "youtube_videos", "channel_id", new_ids, out)
    return out


def sync_feeds(hub: HubClient, http: httpx.Client) -> dict:
    rows = [f for f in hub.pull("feeds", ["id", "fetch", "scrape_pattern"]) if f["fetch"] != "x"]
    known = {a["id"] for a in hub.pull("articles", ["id"], include_deleted=True)}
    new_ids = set()
    out = {"feeds": len(rows), "articles": 0, "failed": 0, "rejected": 0}
    for f in rows:
        # Feed URLs can carry credentials in any component; log only an opaque id.
        source_id = sha256(f["id"].encode()).hexdigest()
        try:
            items = [
                r
                for r in feeds_mod.article_rows(f["id"], feeds_mod.entries(f, http))
                if r["id"] not in known
            ]
            added, _ = _ingest(hub, "articles", items, known, new_ids, out, "articles")
            log.info("feed_synced", feed=source_id, new=added)
        except Exception as exc:
            out["failed"] += 1
            _log_failure("feed_failed", exc, feed=source_id)
            if not _recover_known(hub, "articles", known, out):
                break
    _sync_provenance(hub, "feeds", "articles", "feed_id", new_ids, out)
    return out


def _safe(kind: str, fn, *args) -> dict:
    """One kind's failure (e.g. a hub 5xx on its first pull) never aborts the run."""
    try:
        return fn(*args)
    except Exception as exc:
        _log_failure("kind_failed", exc, kind=kind)
        return {"failed": 1, "error": type(exc).__name__}


def run_daily(hub: HubClient, http: httpx.Client, settings) -> dict:
    return {
        "tv": _safe("tv", sync_tv, hub, http, settings.tmdb_api_key),
        "youtube": _safe("youtube", sync_youtube, hub, http, settings.youtube_api_key),
        "feeds": _safe("feeds", sync_feeds, hub, http),
    }
