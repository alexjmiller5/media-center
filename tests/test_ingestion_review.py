"""Regression reproductions using synthetic sources and persisted hub responses."""

import copy
import json

import httpx
import pytest
import structlog.testing

from core import pipeline
from core.hub import HubClient
from test_pipeline import FakeHub, http_for


@pytest.mark.parametrize(
    "committed,recovery_fails,tombstone",
    [(False, False, False), (True, False, False), (True, False, True), (True, True, False)],
)
def test_failed_article_chunk_recovers_before_overlapping_source(
    monkeypatch, committed, recovery_fails, tombstone
):
    a, b = "https://a.example/feed", "https://b.example/feed"
    ids = [f"https://items.example/post/{i}" for i in range(201)]
    state = {
        "feeds": [
            {"id": source, "fetch": "scrape:links", "scrape_pattern": "/post/"} for source in (a, b)
        ]
    }
    calls, fetched, writes = 0, [], []
    saved = {}
    monkeypatch.setattr(
        "core.feeds.now_iso",
        iter(["2026-09-01T00:00:00.000Z", "2026-09-01T00:00:02.000Z"]).__next__,
    )

    def handler(request):
        nonlocal calls
        if request.url.host != "hub.example":
            fetched.append(str(request.url))
            selected = range(201) if str(request.url) == a else (0, 199, 200)
            return httpx.Response(
                200, text="".join(f'<a href="{ids[i]}">Post {i}</a>' for i in selected)
            )
        body = json.loads(request.content)
        table = body["table"]
        if request.url.path.endswith("/pull"):
            if (
                recovery_fails
                and calls == 2
                and table == "articles"
                and "feed_id" not in body["columns"]
            ):
                return httpx.Response(503)
            return httpx.Response(
                200,
                json={
                    "rows": [{c: r.get(c) for c in body["columns"]} for r in state.get(table, [])]
                },
            )
        assert request.url.path.endswith("/insert")
        writes.append(copy.deepcopy(body))
        rows, rejected = body["rows"], []
        if table == "articles":
            calls += 1
            if calls == 1:
                rejected, rows = [{"id": ids[199]}], rows[:-1]
            elif calls == 2 and not committed:
                return httpx.Response(503)
        stored = {r["id"]: r for r in state.get(table, [])}
        inserted, existing = [], []
        for row in rows:
            if row["id"] not in stored:
                stored[row["id"]] = row
                inserted.append(row["id"])
            else:
                existing.append(row["id"])
        state[table] = list(stored.values())
        if table == "articles" and calls in (1, 2):
            # A user edits a durably accepted row before the next source is read.
            row = stored[ids[0] if calls == 1 else ids[200]]
            row.update(
                status="Finished",
                note="Keep",
                date_read="2026-09-01",
                tags='["saved"]',
                updated_at="2026-09-01T00:00:01.000Z",
            )
            if calls == 2 and tombstone:
                row["deleted_at"] = "2026-09-01T00:00:01.000Z"
            saved[row["id"]] = copy.deepcopy(row)
            if calls == 2:
                raise httpx.ReadTimeout("lost committed response", request=request)
        return httpx.Response(
            200, json={"inserted": inserted, "existing": existing, "rejected": rejected}
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as http:
        result = pipeline.sync_feeds(HubClient("https://hub.example", "synthetic", http), http)
    assert result == {
        "feeds": 2,
        "articles": 199 if recovery_fails else 201 - int(committed),
        "failed": 2 if recovery_fails else 1,
        "rejected": 1,
    }
    stored = {r["id"]: r for r in state["articles"]}
    assert all(stored[key] == row for key, row in saved.items())
    assert fetched == ([a] if recovery_fails else [a, b])
    assert len(stored) == (200 if recovery_fails else 201)
    edges = {edge["to_ref"]: edge for edge in state["provenance"]}
    assert edges[ids[0]]["from_ref"] == a
    assert json.loads(edges[ids[0]]["detail"]) == {"created_row": 1}
    if committed and not tombstone:
        assert edges[ids[200]]["from_ref"] == a
        assert json.loads(edges[ids[200]]["detail"]) == {"created_row": 0}
    if tombstone:
        assert ids[200] not in edges
    for key in saved:
        assert (
            sum(row["id"] == key for w in writes if w["table"] == "articles" for row in w["rows"])
            == 1
        )


@pytest.mark.parametrize("kind", ["tv", "youtube"])
def test_primary_chunk_acknowledgments_survive_later_failure(kind):
    item_table, counter = (
        ("tv_episodes", "episodes") if kind == "tv" else ("youtube_videos", "videos")
    )
    ids = [f"v{i:010d}" for i in range(201)]

    def reject(table, row):
        if table == item_table and row["id"] == ids[199]:
            return {"id": row["id"]}
        if table == item_table and row["id"] == ids[200]:
            raise httpx.ReadTimeout("second chunk failed")
        return None

    hub = FakeHub(
        {
            "tv_shows": [{"id": "1"}],
            "youtube_channels": [{"id": "UC1", "uploads_playlist_id": "UU1", "backfilled": 1}],
        },
        reject=reject,
    )
    with http_for(
        [
            (
                "/season/1",
                {
                    "episodes": [
                        {"id": id_, "season_number": 1, "episode_number": i + 1}
                        for i, id_ in enumerate(ids)
                    ]
                },
            ),
            ("/tv/1?", {"seasons": [{"season_number": 1}]}),
            (
                "/playlistItems",
                {"items": [{"snippet": {"resourceId": {"videoId": id_}}} for id_ in ids]},
            ),
            ("/videos?", {"items": []}),
        ]
    ) as http:
        result = getattr(pipeline, f"sync_{kind}")(hub, http, "synthetic")
    assert result[counter] == 199
    assert result["rejected"] == 1 and result["failed"] == 1
    assert len(hub.tables[item_table]) == 199
    assert len(hub.tables["provenance"]) == 199
    assert all(json.loads(edge["detail"])["created_row"] == 1 for edge in hub.tables["provenance"])
    if kind == "youtube":
        assert hub.tables["youtube_channels"][0]["backfilled"] == 0


def test_tv_refreshes_source_facts_without_reinitializing_history_or_ownership():
    user = {"status": "Finished", "note": "Keep", "date_watched": "2026-08-01"}
    existing = [
        {
            "id": "same",
            "show_id": "1",
            "air_date": None,
            "title": "TBA",
            "runtime_min": None,
            "season": 0,
            "episode": 9,
            **user,
        },
        {"id": "other", "show_id": "2", "title": "Other owner", **user},
        {"id": "manual", "show_id": None, "title": "Manual", **user},
        {"id": "deleted", "show_id": "1", "deleted_at": "2026-08-01T00:00:00.000Z", **user},
    ]
    hub = FakeHub(
        {
            "tv_shows": [{"id": "1", "follow": 0, "status": "Gave Up"}],
            "tv_episodes": copy.deepcopy(existing),
        }
    )

    def upstream(date, title, runtime):
        return http_for(
            [
                (
                    "/season/1",
                    {
                        "episodes": [
                            {
                                "id": r["id"],
                                "season_number": 1,
                                "episode_number": 1,
                                "name": title,
                                "air_date": date,
                                "runtime": runtime,
                            }
                            for r in existing
                        ]
                    },
                ),
                ("/tv/1?", {"seasons": [{"season_number": 1}]}),
            ]
        )

    for date, title, runtime in [("2026-09-01", "Released", 42), ("2026-09-02", "Corrected", 43)]:
        with upstream(date, title, runtime) as http:
            assert pipeline.sync_tv(hub, http, "synthetic")["episodes"] == 0
        row = hub.tables["tv_episodes"][0]
        assert {key: row[key] for key in user} == user
        assert (row["show_id"], row["season"], row["episode"]) == ("1", 0, 9)
        assert (row["air_date"], row["title"], row["runtime_min"]) == (date, title, runtime)
        assert hub.tables["tv_episodes"][1:] == existing[1:]
    assert len(hub.pushed["tv_episodes"]) == 2
    assert all(
        set(row) == {"id", "air_date", "title", "runtime_min", "updated_at"}
        for row in hub.pushed["tv_episodes"]
    )
    saved = copy.deepcopy(hub.tables["tv_episodes"])
    for values in [("2026-09-02", "Corrected", 43), (None, "", 0)]:
        with upstream(*values) as http:
            pipeline.sync_tv(hub, http, "synthetic")
    assert hub.tables["tv_episodes"] == saved
    assert len(hub.pushed["tv_episodes"]) == 2
    assert all(json.loads(edge["detail"])["created_row"] == 0 for edge in hub.tables["provenance"])


@pytest.mark.parametrize("backfilled", [0, 1])
def test_rejected_youtube_flags_appear_in_result(backfilled):
    hub = FakeHub(
        {
            "youtube_channels": [
                {"id": "UC1", "uploads_playlist_id": "UU1", "backfilled": backfilled}
            ]
        },
        reject=lambda table, row: {"id": row["id"]} if table == "youtube_channels" else None,
    )
    with http_for(
        [
            ("/playlistItems", {"items": [{"snippet": {"resourceId": {"videoId": "new"}}}]}),
            ("/videos?", {"items": []}),
        ]
    ) as http:
        result = pipeline.sync_youtube(hub, http, "synthetic")
    assert result == {"channels": 1, "videos": 1 - backfilled, "failed": 1, "rejected": 1}
    assert hub.tables["youtube_channels"][0]["backfilled"] == backfilled


def test_unrecognized_rss_fails_safely_and_next_source_continues():
    hub = FakeHub(
        {
            "feeds": [
                {"id": f"https://{name}.example/feed", "fetch": "rss"} for name in ("bad", "good")
            ]
        }
    )
    with (
        http_for(
            [
                ("bad.example", "<html><body>PRIVATE upstream error</body></html>"),
                (
                    "good.example",
                    '<rss version="2.0"><channel><item><title>Good</title><link>https://good.example/post</link></item></channel></rss>',
                ),
            ]
        ) as http,
        structlog.testing.capture_logs() as logs,
    ):
        result = pipeline.sync_feeds(hub, http)
    assert result == {"feeds": 2, "articles": 1, "failed": 1, "rejected": 0}
    assert "PRIVATE" not in json.dumps(logs)


def test_tv_unscheduled_episode_refresh_retries_rejection_without_new_item_or_edge():
    hub = FakeHub({"tv_shows": [{"id": "1"}]})
    episode = {
        "id": "episode",
        "season_number": 1,
        "episode_number": 1,
        "name": "TBA",
        "air_date": None,
        "runtime": None,
    }

    def run():
        with http_for(
            [
                ("/season/1", {"episodes": [episode.copy()]}),
                ("/tv/1?", {"seasons": [{"season_number": 1}]}),
            ]
        ) as http:
            return pipeline.sync_tv(hub, http, "synthetic")

    assert run()["episodes"] == 1
    hub.tables["tv_episodes"][0].update(status="Priority", note="Keep", date_watched="2026-08-01")
    saved = copy.deepcopy(hub.tables["tv_episodes"])
    edges = copy.deepcopy(hub.tables["provenance"])
    episode.update(air_date="2026-09-01", name="Released", runtime=42)
    hub.reject = lambda table, row: {"id": row["id"]} if table == "tv_episodes" else None
    assert run() == {"shows": 1, "episodes": 0, "failed": 0, "rejected": 1}
    assert hub.tables["tv_episodes"] == saved
    hub.reject = None
    assert run() == {"shows": 1, "episodes": 0, "failed": 0, "rejected": 0}
    row = hub.tables["tv_episodes"][0]
    assert (row["air_date"], row["title"], row["runtime_min"]) == ("2026-09-01", "Released", 42)
    assert (row["status"], row["note"], row["date_watched"]) == ("Priority", "Keep", "2026-08-01")
    assert hub.tables["provenance"] == edges
    writes = copy.deepcopy(hub.pushed)
    assert run()["episodes"] == 0
    assert hub.pushed == writes
