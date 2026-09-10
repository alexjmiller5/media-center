"""Daily ingestion: TMDB episodes, YouTube videos, feed articles -> life-data.

Plain Python, no Modal imports. Each source is independent: a failure is
logged and counted, the run continues. New-item detection is "id not yet in
the table", so a partial run is safe to repeat.
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


def _push_chunked(hub, table, rows) -> list[dict]:
    rejected = []
    for i in range(0, len(rows), CHUNK):
        rejected += hub.push(table, rows[i : i + CHUNK])["rejected"]
    if rejected:
        log.warning("rows_rejected", table=table, n=len(rejected))
    return rejected


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
            out["rejected"] += len(_push_chunked(hub, "provenance", missing[i : i + CHUNK]))
    except Exception as exc:
        out["failed"] += 1
        _log_failure("provenance_failed", exc, kind=item_table)


def sync_tv(hub: HubClient, http: httpx.Client, key: str) -> dict:
    shows = hub.pull("tv_shows", ["id"])
    known = {e["id"] for e in hub.pull("tv_episodes", ["id"], include_deleted=True)}
    new_ids = set()
    out = {"shows": len(shows), "episodes": 0, "failed": 0, "rejected": 0}
    for s in shows:
        try:
            show = tmdb.show(s["id"], key, http)
            rows = []
            for n in tmdb.season_numbers(show):
                rows += [
                    r
                    for r in tmdb.episode_rows(s["id"], tmdb.season_episodes(s["id"], n, key, http))
                    if r["id"] not in known
                ]
            rejected = _push_chunked(hub, "tv_episodes", rows)
            bad_ids = {r["id"] for r in rejected}
            accepted = [r for r in rows if r["id"] not in bad_ids]
            known.update(r["id"] for r in accepted)
            new_ids.update(r["id"] for r in accepted)
            out["episodes"] += len(accepted)
            out["rejected"] += len(rejected)
            log.info("tv_synced", show=s["id"], new=len(accepted))
        except Exception as exc:
            out["failed"] += 1
            _log_failure("tv_failed", exc, show=s["id"])
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
                if _push_chunked(
                    hub,
                    "youtube_channels",
                    [{"id": c["id"], "backfilled": 0, "updated_at": now_iso()}],
                ):
                    raise RuntimeError("could not mark channel for retry")
            rejected = _push_chunked(hub, "youtube_videos", rows)
            bad_ids = {r["id"] for r in rejected}
            accepted = [r for r in rows if r["id"] not in bad_ids]
            known.update(r["id"] for r in accepted)
            new_ids.update(r["id"] for r in accepted)
            out["videos"] += len(accepted)
            out["rejected"] += len(rejected)
            if not rejected and (rows or not c.get("backfilled")):
                # Only a fully accepted walk may enable the known-page boundary.
                _push_chunked(
                    hub,
                    "youtube_channels",
                    [{"id": c["id"], "backfilled": 1, "updated_at": now_iso()}],
                )
            log.info(
                "youtube_synced",
                channel=c["id"],
                new=len(accepted),
                backfill=not c.get("backfilled"),
            )
        except Exception as exc:
            out["failed"] += 1
            _log_failure("youtube_failed", exc, channel=c["id"])
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
            rejected = _push_chunked(hub, "articles", items)
            bad_ids = {r["id"] for r in rejected}
            accepted = [r for r in items if r["id"] not in bad_ids]
            new_ids.update(r["id"] for r in accepted)
            known.update(r["id"] for r in accepted)
            out["articles"] += len(accepted)
            out["rejected"] += len(rejected)
            log.info("feed_synced", feed=source_id, new=len(accepted))
        except Exception as exc:
            out["failed"] += 1
            _log_failure("feed_failed", exc, feed=source_id)
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
