"""Daily ingestion: TMDB episodes, YouTube videos, feed articles -> life-data.

Plain Python, no Modal imports. Each source is independent: a failure is
logged and counted, the run continues. New-item detection is "id not yet in
the table", so a partial run is safe to repeat.
"""

import httpx
import structlog

from core import feeds as feeds_mod
from core import tmdb, youtube
from core.hub import HubClient, imported_from, now_iso

log = structlog.get_logger()
CHUNK = 200


def _push_chunked(hub, table, rows) -> list[dict]:
    rejected = []
    for i in range(0, len(rows), CHUNK):
        rejected += hub.push(table, rows[i : i + CHUNK])["rejected"]
    if rejected:
        log.warning("rows_rejected", table=table, n=len(rejected), first=rejected[0])
    return rejected


def sync_tv(hub: HubClient, http: httpx.Client, key: str) -> dict:
    shows = hub.pull("tv_shows", ["id"])
    known = {}
    for e in hub.pull("tv_episodes", ["id", "show_id"]):
        known.setdefault(e["show_id"], set()).add(e["id"])
    out = {"shows": len(shows), "episodes": 0, "failed": 0, "rejected": 0}
    for s in shows:
        have = known.get(s["id"], set())
        try:
            show = tmdb.show(s["id"], key, http)
            rows = []
            for n in tmdb.season_numbers(show):
                rows += [
                    r
                    for r in tmdb.episode_rows(s["id"], tmdb.season_episodes(s["id"], n, key, http))
                    if r["id"] not in have
                ]
            rejected = _push_chunked(hub, "tv_episodes", rows)
            bad_ids = {r["id"] for r in rejected}
            accepted = [r for r in rows if r["id"] not in bad_ids]
            _push_chunked(
                hub,
                "provenance",
                [imported_from("tv_shows", s["id"], "tv_episodes", r["id"]) for r in accepted],
            )
            out["episodes"] += len(accepted)
            out["rejected"] += len(rejected)
            log.info("tv_synced", show=s["id"], new=len(accepted))
        except Exception:
            out["failed"] += 1
            log.exception("tv_failed", show=s["id"])
    return out


def sync_youtube(hub: HubClient, http: httpx.Client, key: str) -> dict:
    channels = hub.pull("youtube_channels", ["id", "uploads_playlist_id", "backfilled"])
    known = {v["id"] for v in hub.pull("youtube_videos", ["id"])}
    out = {"channels": len(channels), "videos": 0, "failed": 0, "rejected": 0}
    for c in channels:
        try:
            vids = youtube.uploads(
                c["uploads_playlist_id"],
                key,
                http,
                known_ids=known if c.get("backfilled") else None,
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
            _push_chunked(
                hub,
                "provenance",
                [
                    imported_from("youtube_channels", c["id"], "youtube_videos", r["id"])
                    for r in accepted
                ],
            )
            if not rejected and (rows or not c.get("backfilled")):
                # Only a fully accepted walk may enable the known-page boundary.
                _push_chunked(
                    hub,
                    "youtube_channels",
                    [{"id": c["id"], "backfilled": 1, "updated_at": now_iso()}],
                )
            out["videos"] += len(accepted)
            out["rejected"] += len(rejected)
            log.info(
                "youtube_synced",
                channel=c["id"],
                new=len(accepted),
                backfill=not c.get("backfilled"),
            )
        except Exception:
            out["failed"] += 1
            log.exception("youtube_failed", channel=c["id"])
    return out


def sync_feeds(hub: HubClient, http: httpx.Client) -> dict:
    rows = [f for f in hub.pull("feeds", ["id", "fetch", "scrape_pattern"]) if f["fetch"] != "x"]
    known = {a["id"] for a in hub.pull("articles", ["id"])}
    out = {"feeds": len(rows), "articles": 0, "failed": 0, "rejected": 0}
    for f in rows:
        try:
            items = [
                r
                for r in feeds_mod.article_rows(f["id"], feeds_mod.entries(f, http))
                if r["id"] not in known
            ]
            rejected = _push_chunked(hub, "articles", items)
            bad_ids = {r["id"] for r in rejected}
            accepted = [r for r in items if r["id"] not in bad_ids]
            _push_chunked(
                hub,
                "provenance",
                [imported_from("feeds", f["id"], "articles", r["id"]) for r in accepted],
            )
            known.update(r["id"] for r in accepted)
            out["articles"] += len(accepted)
            out["rejected"] += len(rejected)
            log.info("feed_synced", feed=f["id"], new=len(accepted))
        except Exception:
            out["failed"] += 1
            log.exception("feed_failed", feed=f["id"])
    return out


def _safe(kind: str, fn, *args) -> dict:
    """One kind's failure (e.g. a hub 5xx on its first pull) never aborts the run."""
    try:
        return fn(*args)
    except Exception as exc:
        log.exception("kind_failed", kind=kind)
        return {"failed": 1, "error": type(exc).__name__}


def run_daily(hub: HubClient, http: httpx.Client, settings) -> dict:
    return {
        "tv": _safe("tv", sync_tv, hub, http, settings.tmdb_api_key),
        "youtube": _safe("youtube", sync_youtube, hub, http, settings.youtube_api_key),
        "feeds": _safe("feeds", sync_feeds, hub, http),
    }
