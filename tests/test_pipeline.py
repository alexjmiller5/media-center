import json
from pathlib import Path

import httpx
import structlog.testing

from core import pipeline

FIX = Path(__file__).parent / "fixtures"


class FakeHub:
    def __init__(self, tables, reject=None):
        self.tables = tables  # table -> list[dict]
        self.pushed = {}  # table -> list[dict]
        self.reject = reject  # optional (table, row) -> dict | None

    def pull(self, table, columns):
        return [{c: r.get(c) for c in columns} for r in self.tables.get(table, [])]

    def push(self, table, rows):
        self.pushed.setdefault(table, []).extend(rows)
        rejected = [self.reject(table, r) for r in rows] if self.reject else []
        rejected = [r for r in rejected if r]
        return {"upserted": len(rows) - len(rejected), "rejected": rejected}


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
    assert "tv_shows" not in hub.pushed  # EARS-7: the poller never writes the follow list


def test_sync_tv_skips_ended_shows_that_already_have_episodes():
    hub = FakeHub(
        {
            "tv_shows": [{"id": "1", "tmdb_status": "Ended"}],
            "tv_episodes": [{"id": "9", "show_id": "1"}],
        }
    )
    http = http_for([])  # any request would 404 -> failure
    out = pipeline.sync_tv(hub, http, "KEY")
    assert out == {"shows": 1, "episodes": 0, "failed": 0, "rejected": 0}
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


def test_sync_tv_rejected_episode_excluded_from_count_and_provenance():
    season = fx("tmdb_season.json")
    bad_id = str(season["episodes"][0]["id"])

    def reject(table, row):
        if table == "tv_episodes" and row["id"] == bad_id:
            return {"id": bad_id, "col": "air_date", "rule": "iso8601_ms", "message": "bad"}
        return None

    hub = FakeHub(
        {
            "tv_shows": [{"id": "76479", "tmdb_status": "Returning Series"}],
            "tv_episodes": [],
        },
        reject=reject,
    )
    show = {**fx("tmdb_tv.json"), "seasons": [{"season_number": 1}]}
    http = http_for([("/tv/76479/season/1", season), ("/tv/76479?", show)])
    out = pipeline.sync_tv(hub, http, "KEY")
    assert out["episodes"] == len(season["episodes"]) - 1
    assert out["rejected"] == 1
    prov_refs = {p["to_ref"] for p in hub.pushed["provenance"]}
    assert bad_id not in prov_refs


def test_sync_tv_rejected_provenance_row_is_warned_but_episode_still_accepted():
    season = fx("tmdb_season.json")
    ep_id = str(season["episodes"][0]["id"])

    def reject(table, row):
        if table == "provenance" and row["to_ref"] == ep_id:
            return {"id": row["id"], "col": "detail", "rule": "json", "message": "bad"}
        return None

    hub = FakeHub(
        {
            "tv_shows": [{"id": "76479", "tmdb_status": "Returning Series"}],
            "tv_episodes": [],
        },
        reject=reject,
    )
    show = {**fx("tmdb_tv.json"), "seasons": [{"season_number": 1}]}
    http = http_for([("/tv/76479/season/1", season), ("/tv/76479?", show)])
    with structlog.testing.capture_logs() as logs:
        out = pipeline.sync_tv(hub, http, "KEY")
    assert out["episodes"] == len(season["episodes"])  # provenance rejection doesn't uncount it
    assert out["rejected"] == 0  # scoped to the primary table, not provenance
    warnings = [
        log for log in logs if log["log_level"] == "warning" and log["event"] == "rows_rejected"
    ]
    assert len(warnings) == 1
    assert warnings[0]["table"] == "provenance" and warnings[0]["n"] == 1


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
                {"id": "UCold", "uploads_playlist_id": "UUold", "backfilled": 1, "follow": 1},
                {"id": "UCnew", "uploads_playlist_id": "UUnew", "backfilled": 0, "follow": 1},
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
            "youtube_channels": [
                {"id": "UCold", "uploads_playlist_id": "UUold", "backfilled": 1, "follow": 1}
            ],
            "youtube_videos": [{"id": first}],
        }
    )
    http = http_for([("playlistItems", page), ("/videos?", fx("videos_list.json"))])
    out = pipeline.sync_youtube(hub, http, "KEY")
    assert out["videos"] == len(page["items"]) - 1


def test_sync_youtube_all_rejected_still_marked_backfilled_and_no_provenance():
    page = fx("playlist_items.json")
    last = {**page, "items": page["items"][:1]}
    last.pop("nextPageToken", None)

    def handler(request):
        url = str(request.url)
        if "/videos?" in url:
            return httpx.Response(200, json=fx("videos_list.json"))
        if "pageToken=" in url:
            return httpx.Response(200, json=last)
        return httpx.Response(200, json=page)

    http = httpx.Client(transport=httpx.MockTransport(handler))

    def reject(table, row):
        if table == "youtube_videos":
            return {"id": row["id"], "col": "published_at", "rule": "iso8601_ms", "message": "bad"}
        return None

    hub = FakeHub(
        {
            "youtube_channels": [
                {"id": "UCnew", "uploads_playlist_id": "UUnew", "backfilled": 0, "follow": 1}
            ],
            "youtube_videos": [],
        },
        reject=reject,
    )
    out = pipeline.sync_youtube(hub, http, "KEY")
    assert out["videos"] == 0
    assert out["rejected"] == len(page["items"]) + 1
    assert hub.pushed.get("provenance", []) == []
    # rejected ids are retried next run (detection is "id not present"), so the completed
    # walk still flips the flag
    assert any(r.get("backfilled") for r in hub.pushed["youtube_channels"])


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
    assert out == {"feeds": 1, "articles": 2, "failed": 0, "rejected": 0}
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


def test_sync_youtube_flag_push_is_a_partial_row_even_when_a_video_was_rejected():
    page = fx("playlist_items.json")
    last = {**page, "items": page["items"][:1]}
    last.pop("nextPageToken", None)
    bad_id = page["items"][0]["snippet"]["resourceId"]["videoId"]

    def handler(request):
        url = str(request.url)
        if "/videos?" in url:
            return httpx.Response(200, json=fx("videos_list.json"))
        if "pageToken=" in url:
            return httpx.Response(200, json=last)
        return httpx.Response(200, json=page)

    def reject(table, row):
        if table == "youtube_videos" and row["id"] == bad_id:
            return {"id": bad_id, "col": "published_at", "rule": "iso8601_ms", "message": "bad"}
        return None

    http = httpx.Client(transport=httpx.MockTransport(handler))
    hub = FakeHub(
        {
            "youtube_channels": [
                {"id": "UCnew", "uploads_playlist_id": "UUnew", "backfilled": 0, "follow": 1}
            ],
            "youtube_videos": [],
        },
        reject=reject,
    )
    out = pipeline.sync_youtube(hub, http, "KEY")
    assert out["rejected"] == 2  # the fixture repeats its first item on the last page
    flag = hub.pushed["youtube_channels"][0]
    # the hub checks required columns against the merged row, so the flag push
    # carries only the flag - never an echo of the channel's other columns
    assert set(flag) == {"id", "backfilled", "updated_at"}
    assert flag["id"] == "UCnew" and flag["backfilled"] == 1


def test_sync_youtube_rejected_flag_push_is_logged():
    page = fx("playlist_items.json")
    last = {**page, "items": page["items"][:1]}
    last.pop("nextPageToken", None)

    def handler(request):
        url = str(request.url)
        if "/videos?" in url:
            return httpx.Response(200, json=fx("videos_list.json"))
        if "pageToken=" in url:
            return httpx.Response(200, json=last)
        return httpx.Response(200, json=page)

    def reject(table, row):
        if table == "youtube_channels":
            return {"id": row["id"], "col": "backfilled", "rule": "type", "message": "bad"}
        return None

    http = httpx.Client(transport=httpx.MockTransport(handler))
    hub = FakeHub(
        {
            "youtube_channels": [
                {"id": "UCnew", "uploads_playlist_id": "UUnew", "backfilled": 0, "follow": 1}
            ],
            "youtube_videos": [],
        },
        reject=reject,
    )
    with structlog.testing.capture_logs() as logs:
        pipeline.sync_youtube(hub, http, "KEY")
    warnings = [
        log
        for log in logs
        if log["event"] == "rows_rejected" and log["table"] == "youtube_channels"
    ]
    assert len(warnings) == 1 and warnings[0]["n"] == 1


def test_run_daily_isolates_a_failing_kind(mocker):
    mocker.patch("core.pipeline.sync_tv", side_effect=RuntimeError("hub down"))
    mocker.patch(
        "core.pipeline.sync_youtube", return_value={"channels": 0, "videos": 0, "failed": 0}
    )
    mocker.patch("core.pipeline.sync_feeds", return_value={"feeds": 0, "articles": 0, "failed": 0})
    settings = mocker.Mock(tmdb_api_key="t", youtube_api_key="y")
    out = pipeline.run_daily(FakeHub({}), httpx.Client(), settings)
    assert out["tv"] == {"failed": 1, "error": "RuntimeError"}
    assert out["youtube"]["channels"] == 0 and out["feeds"]["feeds"] == 0
