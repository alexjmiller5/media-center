import json
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
import structlog.testing

from core import pipeline

FIX = Path(__file__).parent / "fixtures"


class FakeHub:
    def __init__(self, tables, reject=None):
        self.tables = tables  # table -> list[dict]
        self.pushed = {}  # table -> list[dict]
        self.reject = reject  # optional (table, row) -> dict | None

    def pull(self, table, columns, *, include_deleted=False):
        return [
            {c: r.get(c) for c in columns}
            for r in self.tables.get(table, [])
            if include_deleted or not r.get("deleted_at")
        ]

    def push(self, table, rows):
        self.pushed.setdefault(table, []).extend(rows)
        rejected = [self.reject(table, r) for r in rows] if self.reject else []
        rejected = [r for r in rejected if r]
        bad_ids = {r["id"] for r in rejected}
        stored = {r["id"]: dict(r) for r in self.tables.get(table, [])}
        for row in rows:
            if row["id"] not in bad_ids:
                stored.setdefault(row["id"], {}).update(row)
        self.tables[table] = list(stored.values())
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
            (
                "/tv/1/season/1",
                {"episodes": [{**e, "id": f"other-{e['id']}"} for e in season["episodes"]]},
            ),
            ("/tv/1?", show),
        ]
    )
    out = pipeline.sync_tv(hub, http, "KEY")
    # Both shows are fetched; the known episode is skipped.
    assert out["shows"] == 2 and out["failed"] == 0
    rows = hub.pushed["tv_episodes"]
    # Distinct episode IDs per show; the first show already has one episode.
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
    assert len(prov) == len(rows) + 1
    assert json.loads(next(p for p in prov if p["to_ref"] == known)["detail"]) == {"created_row": 0}
    assert "tv_shows" not in hub.pushed  # EARS-7: the poller never writes the follow list


def test_sync_tv_retries_partial_ended_backfill_without_resetting_status():
    season = fx("tmdb_season.json")
    ids = [str(e["id"]) for e in season["episodes"]]
    watched = {"id": ids[0], "show_id": "1", "status": "Finished", "note": "Keep"}
    hub = FakeHub(
        {
            "tv_shows": [{"id": "1", "tmdb_status": "Ended", "follow": 0, "status": "Gave Up"}],
            "tv_episodes": [watched.copy()],
        },
        reject=lambda table, row: (
            {"id": row["id"]} if table == "tv_episodes" and row["id"] == ids[-1] else None
        ),
    )
    http = http_for(
        [
            ("/tv/1/season/1", season),
            ("/tv/1?", {"seasons": [{"season_number": 1}]}),
        ]
    )
    first = pipeline.sync_tv(hub, http, "KEY")
    assert first == {"shows": 1, "episodes": 1, "failed": 0, "rejected": 1}
    assert {p["to_ref"] for p in hub.tables["provenance"]} == {ids[0], ids[1]}
    hub.reject = None
    assert pipeline.sync_tv(hub, http, "KEY")["episodes"] == 1
    assert pipeline.sync_tv(hub, http, "KEY")["episodes"] == 0
    assert {r["id"] for r in hub.tables["tv_episodes"]} == set(ids)
    assert next(r for r in hub.tables["tv_episodes"] if r["id"] == ids[0]) == watched
    assert [r["id"] for r in hub.pushed["tv_episodes"]].count(ids[1]) == 1


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
    assert out["rejected"] == 1  # provenance rejection is part of the ingestion result
    warnings = [
        log for log in logs if log["log_level"] == "warning" and log["event"] == "rows_rejected"
    ]
    assert len(warnings) == 1
    assert warnings[0]["table"] == "provenance" and warnings[0]["n"] == 1


@pytest.mark.parametrize(
    "backfilled,failure", [(0, "reject"), (1, "reject"), (1, "interrupt"), (1, None)]
)
def test_sync_youtube_paged_runs_recover_gaps_and_preserve_user_fields(backfilled, failure):
    video_ids = [f"v{i:010d}" for i in range(301)]
    requests = []

    def handler(request):
        if request.url.path.endswith("/videos"):
            return httpx.Response(200, json={"items": []})
        offset = int(request.url.params.get("pageToken", "0"))
        requests.append(offset)
        items = [
            {"snippet": {"resourceId": {"videoId": vid}, "title": "Upload"}}
            for vid in video_ids[offset : offset + 50]
        ]
        data = {"items": items}
        if offset + 50 < len(video_ids):
            data["nextPageToken"] = str(offset + 50)
        return httpx.Response(200, json=data)

    def reject(table, row):
        if table == "youtube_videos" and row["id"] == "v0000000225":
            if failure == "interrupt":
                raise httpx.ConnectError("interrupted second chunk")
            if failure == "reject":
                return {"id": row["id"]}
        return None

    watched = {"id": video_ids[0], "status": "Finished", "note": "Keep"}
    channel = {
        "id": "UCtest",
        "uploads_playlist_id": "UUtest",
        "backfilled": backfilled,
        "follow": 0,
        "title": "Keep channel",
    }
    hub = FakeHub(
        {
            "youtube_channels": [channel.copy()],
            "youtube_videos": [watched.copy()] + [{"id": vid} for vid in video_ids[250:]],
        },
        reject=reject,
    )
    http = httpx.Client(transport=httpx.MockTransport(handler))
    first = pipeline.sync_youtube(hub, http, "KEY")
    assert first["failed"] == (1 if failure == "interrupt" else 0)
    assert first["rejected"] == (1 if failure == "reject" else 0)
    assert hub.tables["youtube_channels"][0]["backfilled"] == (0 if failure else 1)
    if not failure:
        assert first["videos"] == 249  # more than a single 50-item page
        assert requests == [0, 50, 100, 150, 200, 250]  # stop at a fully known page
    else:
        assert "v0000000225" not in {r["id"] for r in hub.tables["youtube_videos"]}
        assert "v0000000225" not in {r["to_ref"] for r in hub.tables.get("provenance", [])}

    # New uploads push the failed older item even farther behind accepted pages.
    video_ids[:0] = [f"n{i:010d}" for i in range(50)]
    hub.reject = None
    second = pipeline.sync_youtube(hub, http, "KEY")
    assert second["failed"] == 0 and second["rejected"] == 0
    assert {r["id"] for r in hub.tables["youtube_videos"]} == set(video_ids)
    assert hub.tables["youtube_channels"] == [
        {**channel, "backfilled": 1, "updated_at": hub.tables["youtube_channels"][0]["updated_at"]}
    ]
    assert next(r for r in hub.tables["youtube_videos"] if r["id"] == watched["id"]) == watched
    assert all(set(r) == {"id", "backfilled", "updated_at"} for r in hub.pushed["youtube_channels"])
    assert pipeline.sync_youtube(hub, http, "KEY")["videos"] == 0


def test_sync_youtube_empty_channel_is_successful_and_future_uploads_are_ingested():
    available = False
    old = {"id": "old", "channel_id": "UCempty", "status": "Watched"}
    hub = FakeHub(
        {
            "youtube_channels": [
                {"id": "UCempty", "uploads_playlist_id": "UUempty", "backfilled": 0}
            ],
            "youtube_videos": [old.copy()],
        }
    )

    def handler(request):
        if request.url.path.endswith("/playlistItems"):
            if not available:
                return httpx.Response(
                    404, json={"error": {"errors": [{"reason": "playlistNotFound"}]}}
                )
            return httpx.Response(
                200, json={"items": [{"snippet": {"resourceId": {"videoId": "new"}}}]}
            )
        if request.url.path.endswith("/channels"):
            assert request.url.params["id"] == "UCempty"
            return httpx.Response(
                200,
                json={
                    "items": [
                        {
                            "id": "UCempty",
                            "statistics": {"videoCount": "0"},
                            "contentDetails": {"relatedPlaylists": {"uploads": "UUempty"}},
                        }
                    ]
                },
            )
        assert request.url.path.endswith("/videos")
        return httpx.Response(200, json={"items": []})

    with httpx.Client(transport=httpx.MockTransport(handler)) as http:
        with structlog.testing.capture_logs() as logs:
            for _ in range(2):
                assert pipeline.sync_youtube(hub, http, "KEY") == {
                    "channels": 1,
                    "videos": 0,
                    "failed": 0,
                    "rejected": 0,
                }
        assert all(entry["log_level"] != "error" for entry in logs)
        assert hub.tables["youtube_videos"] == [old]
        available = True
        assert pipeline.sync_youtube(hub, http, "KEY")["videos"] == 1
        assert hub.tables["youtube_videos"][0] == old
        assert hub.tables["youtube_videos"][1]["id"] == "new"


def test_sync_youtube_skips_known_video_ids():
    page = fx("playlist_items.json")
    page.pop("nextPageToken")
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


def test_sync_youtube_all_rejected_stays_unfilled_and_no_provenance():
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
    assert hub.tables["youtube_channels"][0]["backfilled"] == 0
    assert "youtube_channels" not in hub.pushed


def test_sync_feeds_catalogs_unfollowed_sources_and_preserves_read_status():
    read = {"id": "https://blog.example.com/third", "status": "Finished", "note": "Keep"}
    hub = FakeHub(
        {
            "feeds": [
                {"id": "https://blog.example.com/rss", "fetch": "rss", "follow": 0},
                {
                    "id": "https://off.example.com",
                    "fetch": "scrape:links",
                    "follow": 0,
                    "scrape_pattern": "/post/",
                },
                {"id": "https://example.com/external", "fetch": "x", "follow": 1},
            ],
            "articles": [read.copy()],
        }
    )
    http = http_for(
        [
            ("blog.example.com/rss", (FIX / "rss2.xml").read_text()),
            ("off.example.com", '<a href="/post/1">New post</a>'),
        ]
    )
    assert pipeline.sync_feeds(hub, http) == {"feeds": 2, "articles": 3, "failed": 0, "rejected": 0}
    assert pipeline.sync_feeds(hub, http)["articles"] == 0
    assert {r["id"] for r in hub.pushed["articles"]} == {
        "https://blog.example.com/first",
        "https://blog.example.com/second",
        "https://off.example.com/post/1",
    }
    assert next(r for r in hub.tables["articles"] if r["id"] == read["id"]) == read
    assert len(hub.tables["provenance"]) == 3


def test_run_daily_returns_all_three_sections(mocker):
    mocker.patch("core.pipeline.sync_tv", return_value={"shows": 0, "episodes": 0, "failed": 0})
    mocker.patch(
        "core.pipeline.sync_youtube", return_value={"channels": 0, "videos": 0, "failed": 0}
    )
    mocker.patch("core.pipeline.sync_feeds", return_value={"feeds": 0, "articles": 0, "failed": 0})
    settings = mocker.Mock(tmdb_api_key="t", youtube_api_key="y")
    out = pipeline.run_daily(FakeHub({}), httpx.Client(), settings)
    assert set(out) == {"tv", "youtube", "feeds"}


@pytest.mark.parametrize("backfilled", [0, 1])
def test_sync_youtube_rejected_flag_push_is_logged(backfilled):
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
                {
                    "id": "UCnew",
                    "uploads_playlist_id": "UUnew",
                    "backfilled": backfilled,
                    "follow": 1,
                }
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
    if backfilled:
        assert not hub.tables["youtube_videos"]
        assert "youtube_videos" not in hub.pushed


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


def test_sync_feeds_retries_shared_article_after_another_source_rejected_it():
    hub = FakeHub(
        {
            "feeds": [
                {
                    "id": "https://one.example.com",
                    "fetch": "scrape:links",
                    "scrape_pattern": "/post",
                },
                {
                    "id": "https://two.example.com",
                    "fetch": "scrape:links",
                    "scrape_pattern": "/post",
                },
            ]
        },
        reject=lambda table, row: (
            {"id": row["id"]}
            if table == "articles" and row["feed_id"] == "https://one.example.com"
            else None
        ),
    )
    http = http_for(
        [
            (url, '<a href="https://example.com/post">Post</a>')
            for url in ("one.example.com", "two.example.com")
        ]
    )
    assert pipeline.sync_feeds(hub, http) == {"feeds": 2, "articles": 1, "failed": 0, "rejected": 1}
    assert hub.tables["articles"][0]["feed_id"] == "https://two.example.com"
    assert hub.tables["provenance"][0]["from_ref"] == "https://two.example.com"
    assert pipeline.sync_feeds(hub, http)["articles"] == 0


def test_sync_failures_log_safe_details_and_continue():
    secret = "TEST-QUERY-SECRET"
    body = "TEST-RESPONSE-SECRET"
    bad_feed = f"https://bad.example.com/rss?token={secret}#private"
    hub = FakeHub(
        {
            "tv_shows": [{"id": "1"}, {"id": "2"}],
            "youtube_channels": [
                {"id": "UCbad", "uploads_playlist_id": "UUbad", "backfilled": 0},
                {"id": "UCgood", "uploads_playlist_id": "UUgood", "backfilled": 0},
            ],
            "feeds": [
                {"id": bad_feed, "fetch": "rss"},
                {"id": "https://good.example.com/rss", "fetch": "rss"},
            ],
        }
    )

    def handler(request):
        if (
            request.url.path == "/3/tv/1"
            or request.url.params.get("playlistId") == "UUbad"
            or request.url.host == "bad.example.com"
        ):
            return httpx.Response(404, text=body)
        if request.url.host == "good.example.com":
            return httpx.Response(200, text='<rss version="2.0"><channel/></rss>')
        return httpx.Response(200, json={"seasons": [], "items": []})

    http = httpx.Client(transport=httpx.MockTransport(handler))
    with structlog.testing.capture_logs(processors=[structlog.processors.format_exc_info]) as logs:
        # Repeat the actual sync paths: inaccessible playlists stay failures and retry.
        for _ in range(2):
            assert pipeline.sync_tv(hub, http, secret) == {
                "shows": 2,
                "episodes": 0,
                "failed": 1,
                "rejected": 0,
            }
            assert pipeline.sync_youtube(hub, http, secret) == {
                "channels": 2,
                "videos": 0,
                "failed": 1,
                "rejected": 0,
            }
            assert pipeline.sync_feeds(hub, http) == {
                "feeds": 2,
                "articles": 0,
                "failed": 1,
                "rejected": 0,
            }
    rendered = json.dumps(logs)
    assert secret not in rendered and body not in rendered
    failures = [entry for entry in logs if entry["event"].endswith("_failed")]
    assert (
        failures
        == [
            {
                "event": event,
                **source,
                "error": "HTTPStatusError",
                "http_status": 404,
                "log_level": "error",
            }
            for event, source in [
                ("tv_failed", {"show": "1"}),
                ("youtube_failed", {"channel": "UCbad"}),
                (
                    "feed_failed",
                    {"feed": "b6364921ac5214032ae03612379c0b00b7ef781c8346a29dbb6fad2d0e432d38"},
                ),
            ]
        ]
        * 2
    )
    assert hub.tables["youtube_channels"][0]["backfilled"] == 0
    assert hub.tables["youtube_channels"][1]["backfilled"] == 1


@pytest.mark.parametrize("http_error", [True, False])
def test_kind_failures_log_safe_details_and_continue(http_error):
    secret, body, message = "TEST-QUERY-SECRET", "TEST-RESPONSE-SECRET", "TEST-MESSAGE-SECRET"
    request = httpx.Request("POST", f"https://hub.example.com/pull?key={secret}")
    error = (
        httpx.HTTPStatusError(
            message, request=request, response=httpx.Response(503, text=body, request=request)
        )
        if http_error
        else RuntimeError(message)
    )

    def handler(request):
        if json.loads(request.content)["table"] == "tv_shows":
            raise error
        return httpx.Response(200, json={"rows": []})

    http = httpx.Client(transport=httpx.MockTransport(handler))
    hub = pipeline.HubClient("https://hub.example.com", "test-token", http)
    settings = SimpleNamespace(tmdb_api_key=secret, youtube_api_key=secret)
    with structlog.testing.capture_logs(processors=[structlog.processors.format_exc_info]) as logs:
        result = pipeline.run_daily(hub, http, settings)
    assert all(value not in json.dumps(logs) for value in (secret, body, message))
    error_type = "HTTPStatusError" if http_error else "RuntimeError"
    expected = {"event": "kind_failed", "kind": "tv", "error": error_type, "log_level": "error"}
    if http_error:
        expected["http_status"] = 503
    assert logs == [expected]
    assert result["tv"] == {"failed": 1, "error": error_type}
    assert result["youtube"] == {"channels": 0, "videos": 0, "failed": 0, "rejected": 0}
    assert result["feeds"] == {"feeds": 0, "articles": 0, "failed": 0, "rejected": 0}


def test_sync_youtube_ingests_videos_with_unavailable_duration():
    ids = ["known000001", "missing0001", "empty000001"]
    page = {
        "items": [{"snippet": {"resourceId": {"videoId": vid}, "title": "Upload"}} for vid in ids]
    }
    http = http_for(
        [
            ("playlistItems", page),
            (
                "/videos?",
                {
                    "items": [
                        {"id": ids[0], "contentDetails": {"duration": "PT45S"}},
                        {"id": ids[1], "contentDetails": {"dimension": "2d", "definition": "hd"}},
                        {"id": ids[2], "contentDetails": {"duration": ""}},
                    ]
                },
            ),
        ]
    )
    hub = FakeHub(
        {"youtube_channels": [{"id": "UCtest", "uploads_playlist_id": "UUtest", "backfilled": 0}]}
    )
    assert pipeline.sync_youtube(hub, http, "KEY") == {
        "channels": 1,
        "videos": 3,
        "failed": 0,
        "rejected": 0,
    }
    assert [(r["duration_s"], r["is_short"]) for r in hub.tables["youtube_videos"]] == [
        (45, 1),
        (None, 0),
        (None, 0),
    ]
    assert hub.tables["youtube_channels"][0]["backfilled"] == 1
    assert len(hub.tables["provenance"]) == 3


def test_feed_logs_use_stable_opaque_source_ids():
    secrets = ["TEST-USER", "TEST-PASSWORD", "TEST-PATH", "TEST-QUERY", "TEST-FRAGMENT"]
    user, password, path, query, fragment = secrets
    urls = [
        f"https://{user}:{password}@feeds.example.com/{path}/{name}?token={query}#{fragment}"
        for name in ("first", "second")
    ]
    hub = FakeHub({"feeds": [{"id": url, "fetch": "rss"} for url in urls]})
    fail_first = True

    def handler(request):
        name = request.url.path.rsplit("/", 1)[-1]
        if fail_first and name == "first":
            return httpx.Response(403)
        return httpx.Response(
            200,
            text=f'<rss version="2.0"><channel><item>'
            f"<title>Post</title><link>https://articles.example.com/{name}</link>"
            "</item></channel></rss>",
        )

    http = httpx.Client(transport=httpx.MockTransport(handler))
    with structlog.testing.capture_logs(processors=[structlog.processors.format_exc_info]) as logs:
        assert pipeline.sync_feeds(hub, http) == {
            "feeds": 2,
            "articles": 1,
            "failed": 1,
            "rejected": 0,
        }
        fail_first = False
        assert pipeline.sync_feeds(hub, http) == {
            "feeds": 2,
            "articles": 1,
            "failed": 0,
            "rejected": 0,
        }
    rendered = json.dumps(logs)
    assert all(secret not in rendered for secret in secrets)
    first, second = logs[0]["feed"], logs[1]["feed"]
    assert first != second
    assert all(
        len(value) == 64 and set(value) <= set("0123456789abcdef") for value in (first, second)
    )
    assert logs == [
        {
            "event": "feed_failed",
            "feed": first,
            "error": "HTTPStatusError",
            "http_status": 403,
            "log_level": "error",
        },
        {"event": "feed_synced", "feed": second, "new": 1, "log_level": "info"},
        {"event": "feed_synced", "feed": first, "new": 1, "log_level": "info"},
        {"event": "feed_synced", "feed": second, "new": 0, "log_level": "info"},
    ]
