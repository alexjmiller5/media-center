import json
from pathlib import Path

import httpx

from core import pipeline

FIX = Path(__file__).parent / "fixtures"


class FakeHub:
    def __init__(self, tables):
        self.tables = tables  # table -> list[dict]
        self.pushed = {}  # table -> list[dict]

    def pull(self, table, columns):
        return [{c: r.get(c) for c in columns} for r in self.tables.get(table, [])]

    def push(self, table, rows):
        self.pushed.setdefault(table, []).extend(rows)
        return {"upserted": len(rows), "rejected": []}


def http_for(table):
    def handler(request):
        url = str(request.url)
        for needle, payload in table:
            if needle in url:
                if isinstance(payload, Exception):
                    raise payload
                return (
                    httpx.Response(200, json=payload)
                    if isinstance(payload, dict)
                    else httpx.Response(200, text=payload)
                )
        return httpx.Response(404, text=url)

    return httpx.Client(transport=httpx.MockTransport(handler))


def fx(name):
    return json.loads((FIX / name).read_text())


def test_sync_tv_ingests_missing_episodes_with_provenance():
    season = fx("tmdb_season.json")
    known = str(season["episodes"][0]["id"])
    hub = FakeHub(
        {
            "tv_shows": [
                {"id": "76479", "tmdb_status": "Returning Series"},
                {"id": "1", "tmdb_status": "Ended"},
            ],
            "tv_episodes": [{"id": known, "show_id": "76479"}],
        }
    )
    show = {**fx("tmdb_tv.json"), "seasons": [{"season_number": 1}]}
    http = http_for(
        [
            ("/tv/76479/season/1", season),
            ("/tv/76479?", show),
            ("/tv/1/season/1", season),
            ("/tv/1?", show),
        ]
    )
    out = pipeline.sync_tv(hub, http, "KEY")
    # Ended show with no episodes is fetched once; returning show fetched; known episode skipped
    assert out["shows"] == 2 and out["failed"] == 0
    rows = hub.pushed["tv_episodes"]
    # both shows share the season fixture (3 episodes); show 76479 already has 1 -> 5 new rows total
    assert len(rows) == 2 * 3 - 1
    by_show = {}
    for r in rows:
        by_show.setdefault(r["show_id"], set()).add(r["id"])
    assert known not in by_show["76479"]
    prov = hub.pushed["provenance"]
    assert all(
        p["from_kind"] == "tv_shows"
        and p["to_kind"] == "tv_episodes"
        and p["rel"] == "imported_from"
        for p in prov
    )
    assert len(prov) == len(rows)


def test_sync_tv_skips_ended_shows_that_already_have_episodes():
    hub = FakeHub(
        {
            "tv_shows": [{"id": "1", "tmdb_status": "Ended"}],
            "tv_episodes": [{"id": "9", "show_id": "1"}],
        }
    )
    http = http_for([])  # any request would 404 -> failure
    out = pipeline.sync_tv(hub, http, "KEY")
    assert out == {"shows": 1, "episodes": 0, "failed": 0}
    assert "tv_episodes" not in hub.pushed


def test_sync_tv_survives_one_broken_show():
    hub = FakeHub(
        {
            "tv_shows": [{"id": "1", "tmdb_status": None}, {"id": "76479", "tmdb_status": None}],
            "tv_episodes": [],
        }
    )
    show = {**fx("tmdb_tv.json"), "seasons": [{"season_number": 1}]}
    http = http_for(
        [
            ("/tv/1?", httpx.ConnectError("down")),
            ("/tv/76479?", show),
            ("/tv/76479/season/1", fx("tmdb_season.json")),
        ]
    )
    out = pipeline.sync_tv(hub, http, "KEY")
    assert out["failed"] == 1 and out["episodes"] == 3


def test_sync_youtube_first_page_for_backfilled_channels_and_all_pages_for_new_ones():
    page = fx("playlist_items.json")  # has nextPageToken
    last = {**page, "items": page["items"][:1]}
    last.pop("nextPageToken", None)
    calls = []

    def handler(request):
        url = str(request.url)
        calls.append(url)
        if "/videos?" in url:
            return httpx.Response(200, json=fx("videos_list.json"))
        if "pageToken=" in url:
            return httpx.Response(200, json=last)
        return httpx.Response(200, json=page)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    hub = FakeHub(
        {
            "youtube_channels": [
                {"id": "UCold", "uploads_playlist_id": "UUold", "backfilled": 1},
                {"id": "UCnew", "uploads_playlist_id": "UUnew", "backfilled": 0},
            ],
            "youtube_videos": [],
        }
    )
    out = pipeline.sync_youtube(hub, http, "KEY")
    assert out["channels"] == 2 and out["failed"] == 0
    old_pages = [c for c in calls if "playlistId=UUold" in c]
    new_pages = [c for c in calls if "playlistId=UUnew" in c]
    assert (
        len(old_pages) == 1 and len(new_pages) == 2
    )  # delta = first page only; backfill follows the token
    by_channel = {}
    for r in hub.pushed["youtube_videos"]:
        by_channel.setdefault(r["channel_id"], []).append(r)
    assert len(by_channel["UCold"]) == len(page["items"])
    assert len(by_channel["UCnew"]) == len(page["items"]) + 1
    assert {"id": "UCnew", "backfilled": 1} in [
        {k: r[k] for k in ("id", "backfilled")} for r in hub.pushed["youtube_channels"]
    ]
    assert len(hub.pushed["provenance"]) == 2 * len(page["items"]) + 1


def test_sync_youtube_skips_known_video_ids():
    page = fx("playlist_items.json")
    first = page["items"][0]["snippet"]["resourceId"]["videoId"]
    hub = FakeHub(
        {
            "youtube_channels": [{"id": "UCold", "uploads_playlist_id": "UUold", "backfilled": 1}],
            "youtube_videos": [{"id": first}],
        }
    )
    http = http_for([("playlistItems", page), ("/videos?", fx("videos_list.json"))])
    out = pipeline.sync_youtube(hub, http, "KEY")
    assert out["videos"] == len(page["items"]) - 1


def test_sync_feeds_pushes_new_articles_for_followed_feeds_only():
    hub = FakeHub(
        {
            "feeds": [
                {
                    "id": "https://blog.example.com/rss",
                    "fetch": "rss",
                    "follow": 1,
                    "scrape_pattern": None,
                },
                {
                    "id": "https://off.example.com/rss",
                    "fetch": "rss",
                    "follow": 0,
                    "scrape_pattern": None,
                },
                {
                    "id": "https://x.com/intcyberdigest",
                    "fetch": "x",
                    "follow": 1,
                    "scrape_pattern": None,
                },
            ],
            "articles": [{"id": "https://blog.example.com/third"}],
        }
    )
    http = http_for([("blog.example.com/rss", (FIX / "rss2.xml").read_text())])
    out = pipeline.sync_feeds(hub, http)
    assert out == {"feeds": 1, "articles": 2, "failed": 0}
    assert {r["id"] for r in hub.pushed["articles"]} == {
        "https://blog.example.com/first",
        "https://blog.example.com/second",
    }
    assert all(
        p["from_kind"] == "feeds" and p["from_ref"] == "https://blog.example.com/rss"
        for p in hub.pushed["provenance"]
    )


def test_run_daily_returns_all_three_sections(mocker):
    mocker.patch("core.pipeline.sync_tv", return_value={"shows": 0, "episodes": 0, "failed": 0})
    mocker.patch(
        "core.pipeline.sync_youtube", return_value={"channels": 0, "videos": 0, "failed": 0}
    )
    mocker.patch("core.pipeline.sync_feeds", return_value={"feeds": 0, "articles": 0, "failed": 0})
    settings = mocker.Mock(tmdb_api_key="t", youtube_api_key="y")
    out = pipeline.run_daily(FakeHub({}), httpx.Client(), settings)
    assert set(out) == {"tv", "youtube", "feeds"}
