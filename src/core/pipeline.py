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
ACTIVE_TMDB = {"Returning Series", "In Production", "Planned", "Pilot", None}


def _push_chunked(hub, table, rows):
    for i in range(0, len(rows), CHUNK):
        hub.push(table, rows[i : i + CHUNK])


def sync_tv(hub: HubClient, http: httpx.Client, key: str) -> dict:
    shows = hub.pull("tv_shows", ["id", "tmdb_status"])
    known = {}
    for e in hub.pull("tv_episodes", ["id", "show_id"]):
        known.setdefault(e["show_id"], set()).add(e["id"])
    out = {"shows": len(shows), "episodes": 0, "failed": 0}
    for s in shows:
        have = known.get(s["id"], set())
        if have and s.get("tmdb_status") not in ACTIVE_TMDB:
            continue  # ended and already ingested
        try:
            show = tmdb.show(s["id"], key, http)
            rows = []
            for n in tmdb.season_numbers(show):
                rows += [
                    r
                    for r in tmdb.episode_rows(s["id"], tmdb.season_episodes(s["id"], n, key, http))
                    if r["id"] not in have
                ]
            _push_chunked(hub, "tv_episodes", rows)
            _push_chunked(
                hub,
                "provenance",
                [imported_from("tv_shows", s["id"], "tv_episodes", r["id"]) for r in rows],
            )
            out["episodes"] += len(rows)
            log.info("tv_synced", show=s["id"], new=len(rows))
        except Exception:
            out["failed"] += 1
            log.exception("tv_failed", show=s["id"])
    return out


def sync_youtube(hub: HubClient, http: httpx.Client, key: str) -> dict:
    channels = hub.pull("youtube_channels", ["id", "uploads_playlist_id", "backfilled"])
    known = {v["id"] for v in hub.pull("youtube_videos", ["id"])}
    out = {"channels": len(channels), "videos": 0, "failed": 0}
    for c in channels:
        try:
            vids = youtube.uploads(
                c["uploads_playlist_id"], key, http, max_pages=1 if c.get("backfilled") else None
            )
            vids = [v for v in vids if v["id"] not in known]
            durs = youtube.durations([v["id"] for v in vids], key, http) if vids else {}
            rows = youtube.video_rows(c["id"], vids, durs)
            _push_chunked(hub, "youtube_videos", rows)
            _push_chunked(
                hub,
                "provenance",
                [
                    imported_from("youtube_channels", c["id"], "youtube_videos", r["id"])
                    for r in rows
                ],
            )
            if not c.get("backfilled"):
                hub.push(
                    "youtube_channels", [{"id": c["id"], "backfilled": 1, "updated_at": now_iso()}]
                )
            out["videos"] += len(rows)
            log.info(
                "youtube_synced", channel=c["id"], new=len(rows), backfill=not c.get("backfilled")
            )
        except Exception:
            out["failed"] += 1
            log.exception("youtube_failed", channel=c["id"])
    return out


def sync_feeds(hub: HubClient, http: httpx.Client) -> dict:
    rows = [
        f
        for f in hub.pull("feeds", ["id", "fetch", "follow", "scrape_pattern"])
        if f.get("follow") and f["fetch"] != "x"
    ]
    known = {a["id"] for a in hub.pull("articles", ["id"])}
    out = {"feeds": len(rows), "articles": 0, "failed": 0}
    for f in rows:
        try:
            items = [
                r
                for r in feeds_mod.article_rows(f["id"], feeds_mod.entries(f, http))
                if r["id"] not in known
            ]
            _push_chunked(hub, "articles", items)
            _push_chunked(
                hub,
                "provenance",
                [imported_from("feeds", f["id"], "articles", r["id"]) for r in items],
            )
            known.update(r["id"] for r in items)
            out["articles"] += len(items)
            log.info("feed_synced", feed=f["id"], new=len(items))
        except Exception:
            out["failed"] += 1
            log.exception("feed_failed", feed=f["id"])
    return out


def run_daily(hub: HubClient, http: httpx.Client, settings) -> dict:
    return {
        "tv": sync_tv(hub, http, settings.tmdb_api_key),
        "youtube": sync_youtube(hub, http, settings.youtube_api_key),
        "feeds": sync_feeds(hub, http),
    }
