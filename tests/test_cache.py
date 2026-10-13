"""CachedHub: the poller's reads come from its own copy, kept current incrementally."""

import copy
import json
from pathlib import Path

import httpx
import pytest
from fakehub import hub_reads
from test_provenance_retry import transport

from core import hub as hub_mod
from core import pipeline
from core.hub import READS, CachedHub, HubClient, load_state, save_state

URL = "https://hub.example"


def fake(state, log):
    """One synthetic hub; `connect(saved)` starts a poller process on it with a saved cache.

    Writes insert absent IDs, except the IDs in `control["reject"]`.
    """
    reads, control = hub_reads(state, log), {"reject": set()}

    def handler(request):
        if (read := reads(request)) is not None:
            return read
        body = json.loads(request.content)
        log.append((request.url.path, body))
        stored = state.setdefault(body["table"], [])
        ids = {r["id"] for r in stored}
        new = [r for r in body["rows"] if r["id"] not in ids | control["reject"]]
        stored.extend(new)
        return httpx.Response(
            200,
            json={
                "inserted": [r["id"] for r in new],
                "existing": [r["id"] for r in body["rows"] if r["id"] in ids],
                "rejected": [
                    {"id": r["id"]} for r in body["rows"] if r["id"] in control["reject"] - ids
                ],
            },
        )

    def connect(saved=None):
        http = httpx.Client(transport=httpx.MockTransport(handler))
        return CachedHub(HubClient(URL, "synthetic-token", http), saved)

    return connect, control


def tables():
    return {
        "tv_shows": [{"id": "show", "follow": 1, "updated_at": "2026-10-01T00:00:00.000Z"}],
        "youtube_channels": [{"id": "UC1", "uploads_playlist_id": "UU1", "backfilled": 1}],
        "feeds": [{"id": "https://feed.example", "fetch": "rss"}],
        "tv_episodes": [{"id": "e1", "show_id": "show", "title": "Pilot", "status": "Finished"}],
        "youtube_videos": [
            {"id": "v1", "channel_id": "UC1"},
            {"id": "v2", "channel_id": "UC1", "deleted_at": "2026-10-02T00:00:00.000Z"},
        ],
        "articles": [{"id": "https://feed.example/a", "feed_id": "https://feed.example"}],
    }


def test_warm_quiet_round_is_one_cursor_request_and_serves_the_cached_rows():
    state, log = tables(), []
    connect, _ = fake(state, log)
    hub = connect()
    hub.refresh()
    assert [path for path, _ in log] == ["/v1/cursor", "/v1/rows/pull"]
    assert log[0][1] == {"tables": list(READS)}
    assert hub.reads == {"requests": 2, "rows": 7}
    log.clear()
    warm = connect(json.loads(json.dumps(hub.state)))
    warm.refresh()
    assert [path for path, _ in log] == ["/v1/cursor"]
    assert warm.reads == {"requests": 1, "rows": 0}
    assert warm.pull("youtube_videos", ["id", "channel_id"]) == [{"id": "v1", "channel_id": "UC1"}]
    assert [r["id"] for r in warm.pull("youtube_videos", ["id"], include_deleted=True)] == [
        "v1",
        "v2",
    ]
    assert len(log) == 1  # served from the copy


def test_only_changed_rows_are_pulled_and_merged_into_the_copy():
    state, log = tables(), []
    connect, _ = fake(state, log)
    hub = connect()
    hub.refresh()
    state["youtube_videos"].append({"id": "v3", "channel_id": "UC1"})
    state["tv_episodes"][0]["title"] = "Renamed"
    state["articles"][0]["deleted_at"] = "2026-10-03T00:00:00.000Z"
    log.clear()
    warm = connect(hub.state)
    warm.refresh()
    # Inclusive cursors re-read the rows at the held mark (v2), never the rest.
    assert warm.reads == {"requests": 2, "rows": 4}
    pulled = {item["table"] for item in log[1][1]["batch"]}
    assert pulled == {"youtube_videos", "tv_episodes", "articles"}
    assert all(item["since"] for item in log[1][1]["batch"])
    assert {r["id"] for r in warm.pull("youtube_videos", ["id"])} == {"v1", "v3"}
    assert warm.pull("tv_episodes", ["id", "title"]) == [{"id": "e1", "title": "Renamed"}]
    assert warm.pull("articles", ["id"]) == []
    gone = warm.pull("articles", ["id", "deleted_at"], include_deleted=True)
    assert gone == [{"id": "https://feed.example/a", "deleted_at": "2026-10-03T00:00:00.000Z"}]


def test_a_mark_behind_the_cursor_rereads_the_table_and_forgets_missing_rows():
    state, log = tables(), []
    connect, _ = fake(state, log)
    hub = connect()
    hub.refresh()
    state["youtube_videos"].pop()  # the newest row is purged
    warm = connect(hub.state)
    warm.refresh()
    assert [r["id"] for r in warm.pull("youtube_videos", ["id"], include_deleted=True)] == ["v1"]


def test_a_write_makes_only_that_table_read_again_before_its_next_use():
    state, log = tables(), []
    hub = fake(state, log)[0]()
    hub.refresh()
    log.clear()
    hub.insert("tv_episodes", [{"id": "e2", "show_id": "show", "updated_at": "x"}])
    assert hub.pull("tv_shows", ["id"]) == [{"id": "show"}]
    assert [path for path, _ in log] == ["/v1/rows/insert"]
    assert {r["id"] for r in hub.pull("tv_episodes", ["id", "show_id"])} == {"e1", "e2"}
    assert log[1] == ("/v1/cursor", {"tables": ["tv_episodes"]})
    assert log[2][1]["batch"][0]["table"] == "tv_episodes"


def test_reads_outside_the_cached_columns_are_refused():
    hub = fake(tables(), [])[0]()
    with pytest.raises(ValueError):
        hub.pull("tv_episodes", ["id", "status"])


def test_saved_state_for_another_hub_is_ignored():
    state, log = tables(), []
    connect, _ = fake(state, log)
    hub = connect()
    hub.refresh()
    other = {**hub.state, "endpoint": "https://other.example"}
    log.clear()
    cold = connect(other)
    cold.refresh()
    assert all(item["since"] == "" for item in log[1][1]["batch"])


def edges(kind, n, deleted=()):
    return [
        {
            "id": f"{kind}:src:item{i}",
            "from_kind": kind,
            "deleted_at": "x" if i in deleted else None,
        }
        for i in range(n)
    ]


def test_edge_ids_walk_only_the_poller_edge_range_and_persist(monkeypatch):
    monkeypatch.setattr(hub_mod, "SLICE_PAGE", 2)
    state = {
        "provenance": [
            {"id": "takeout:x:songs:1", "from_kind": "takeout"},
            *edges("tv_shows", 3, deleted={1}),
            {"id": "tv_shows_extra:y", "from_kind": "tv_shows"},
            *edges("youtube_channels", 4),
        ]
    }
    log = []
    connect, _ = fake(state, log)
    hub = connect()
    assert hub.edge_ids("tv_shows") == {f"tv_shows:src:item{i}" for i in range(3)}
    walks = [body["batch"][0] for _, body in log]
    assert [w["after"] for w in walks] == ["tv_shows:", "tv_shows:src:item1"]
    assert all(w["table"] == "provenance" and w["columns"] == ["id"] for w in walks)
    assert hub.edge_ids("tv_shows") is hub.edge_ids("tv_shows") and len(log) == 2
    log.clear()
    warm = connect(hub.state)
    assert len(warm.edge_ids("tv_shows")) == 3 and log == []


def test_edge_acknowledgments_extend_the_known_slice_and_rejections_retry():
    state = {"provenance": edges("feeds", 1)}
    log = []
    connect, control = fake(state, log)
    hub = connect()
    assert hub.edge_ids("feeds") == {"feeds:src:item0"}
    control["reject"] = {"feeds:src:item2"}
    new = edges("feeds", 3) + edges("tv_shows", 1)
    result = hub.insert("provenance", new)
    assert result["existing"] == ["feeds:src:item0"]
    assert result["inserted"] == ["feeds:src:item1", "tv_shows:src:item0"]
    assert hub.edge_ids("feeds") == {"feeds:src:item0", "feeds:src:item1"}
    assert "tv_shows" not in hub.state["edges"]  # an unread slice is never assumed complete


def test_edge_walk_refuses_a_cursor_that_does_not_advance():
    calls = []

    def handler(request):
        calls.append(request)
        assert len(calls) < 5, "walk did not stop"
        page = {"rows": [{"id": "feeds:a"}], "next_cursor": "feeds:"}
        return httpx.Response(200, json={"batch": [page]})

    http = httpx.Client(transport=httpx.MockTransport(handler))
    with pytest.raises(ValueError):
        CachedHub(HubClient(URL, "t", http)).edge_ids("feeds")


def test_state_round_trips_through_a_compressed_file(tmp_path):
    path = tmp_path / "hub-cache.json.gz"
    assert load_state(path) == {}
    save_state(path, {"v": 1, "rows": {"t": {"a": {"id": "a"}}}})
    assert load_state(path) == {"v": 1, "rows": {"t": {"a": {"id": "a"}}}}
    assert [p.name for p in tmp_path.iterdir()] == ["hub-cache.json.gz"]
    path.write_bytes(b"not gzip")
    assert load_state(path) == {}


def test_warm_youtube_run_reads_no_provenance_and_never_recreates_a_tombstoned_video():
    state = {"youtube_channels": [{"id": "source", "uploads_playlist_id": "u", "backfilled": 0}]}
    calls = []
    base = transport(state, "item", lambda *_: None, [])

    def handler(request):
        if request.url.host == "hub.example":
            calls.append((request.url.path, json.loads(request.content)))
        return base.handle_request(request)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    first = CachedHub(HubClient(URL, "t", http))
    assert pipeline.sync_youtube(first, http, "key")["videos"] == 1
    assert len(state["provenance"]) == 1
    state["youtube_videos"][0]["deleted_at"] = "2026-10-05T00:00:00.000Z"
    calls.clear()
    warm = CachedHub(HubClient(URL, "t", http), copy.deepcopy(first.state))
    out = pipeline.sync_youtube(warm, http, "key")
    assert out == {"channels": 1, "videos": 0, "failed": 0, "rejected": 0}
    assert not any(
        item["table"] == "provenance"
        for path, body in calls
        if path == "/v1/rows/pull"
        for item in body["batch"]
    )
    assert not any(path == "/v1/rows/insert" for path, _ in calls)
    assert len(state["youtube_videos"]) == 1 and len(state["provenance"]) == 1


def test_run_daily_prefetches_every_read_once_and_saves_after_each_kind(mocker):
    for name in ("sync_feed_boundaries", "sync_tv", "sync_youtube", "sync_feeds"):
        mocker.patch(f"core.pipeline.{name}", return_value={"failed": 0})
    state, log, saves = tables(), [], []
    hub = fake(state, log)[0]()
    settings = mocker.Mock(tmdb_api_key="t", youtube_api_key="y")
    out = pipeline.run_daily(hub, httpx.Client(), settings, saves.append)
    assert log[0] == ("/v1/cursor", {"tables": list(READS)})
    assert out["reads"] == {"requests": 2, "rows": 7}
    assert len(saves) == 4 and saves[-1]["rows"]["tv_shows"]["show"]["follow"] == 1


def test_poller_profile_reads_exactly_the_cached_columns():
    """A new READS column needs its grant in the Soma profile, or narrow pulls are refused."""
    path = Path(__file__).parent.parent / "docs" / "poller-profile.json"
    ((_, profile),) = json.loads(path.read_text()).items()
    reads = {s for s in profile["scopes"] if s.startswith("tables:read:")}
    assert reads == {
        f"tables:read:{table}:{column}"
        for table, columns in READS.items()
        for column in ["id", "hub_at", "deleted_at", *columns]
    }
