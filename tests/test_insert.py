"""Insert contract regressions at the hub HTTP boundary, with synthetic state."""

import copy
import json

import httpx
import pytest

from core import pipeline
from core.hub import HubClient
from test_hub import make_client
from test_provenance_retry import CASES, setup_source, sync, transport


def test_insert_uses_distinct_route_and_returns_exact_acknowledgments():
    rows = [{"id": "new", "title": "New"}, {"id": "saved"}, {"id": "invalid"}]
    result = {"inserted": ["new"], "existing": ["saved"], "rejected": [{"id": "invalid"}]}

    def handler(request):
        assert request.url.path == "/v1/rows/insert"
        assert request.headers["authorization"] == "Bearer lt_test"
        assert json.loads(request.content) == {
            "table": "articles",
            "columns": ["id", "title"],
            "rows": rows,
        }
        return httpx.Response(200, json=result)

    assert make_client(handler).insert("articles", rows) == result


def test_empty_insert_makes_no_request():
    def handler(request):
        pytest.fail("empty insert made a request")

    assert make_client(handler).insert("articles", []) == {
        "inserted": [],
        "existing": [],
        "rejected": [],
    }


@pytest.mark.parametrize("status", [404, 405, 500])
def test_insert_http_failure_never_falls_back_to_push(status):
    paths = []

    def handler(request):
        paths.append(request.url.path)
        return httpx.Response(status)

    with pytest.raises(httpx.HTTPStatusError):
        make_client(handler).insert("articles", [{"id": "new"}])
    assert paths == ["/v1/rows/insert"]


@pytest.mark.parametrize(
    "result",
    [
        {"upserted": 1, "rejected": []},
        {"inserted": [], "existing": [], "rejected": []},
        {"inserted": ["foreign"], "existing": [], "rejected": []},
        {"inserted": ["new"], "existing": ["new"], "rejected": []},
    ],
)
def test_incomplete_or_ambiguous_insert_acknowledgment_fails_closed(result):
    with pytest.raises(ValueError, match="insert acknowledgment"):
        make_client(lambda _: httpx.Response(200, json=result)).insert("articles", [{"id": "new"}])


@pytest.mark.parametrize(("source_table", "item_table", "parent", "counter"), CASES)
@pytest.mark.parametrize("deleted", [False, True])
def test_concurrent_capture_after_read_never_overwrites_item_or_tombstone(
    source_table, item_table, parent, counter, deleted
):
    source, item_id = setup_source(source_table)
    saved = {
        "id": item_id,
        parent: "stored-owner",
        "status": "Finished",
        "note": "Keep",
        "title": "Saved title",
        "updated_at": "2026-09-01T00:00:00.000Z",
        "deleted_at": "2026-09-01T00:00:00.000Z" if deleted else None,
    }
    state, writes, paths = {source_table: [source]}, [], []

    def intercept(body, persisted):
        if body["table"] == item_table and not persisted:
            state[item_table] = [copy.deepcopy(saved)]

    with httpx.Client(transport=transport(state, item_id, intercept, writes, paths)) as http:
        result = sync(source_table, http)
    assert result[counter] == result["failed"] == result["rejected"] == 0
    assert state[item_table] == [saved]
    assert ("/v1/rows/insert", item_table) in paths
    assert ("/v1/rows/push", item_table) not in paths
    if deleted:
        assert not state.get("provenance")
    else:
        (edge,) = state["provenance"]
        assert edge["from_ref"] == saved[parent]
        assert json.loads(edge["detail"]) == {"created_row": 0}


@pytest.mark.parametrize(("source_table", "item_table", "parent", "counter"), CASES)
@pytest.mark.parametrize("deleted", [False, True])
def test_concurrent_provenance_insert_preserves_existing_edge_or_tombstone(
    source_table, item_table, parent, counter, deleted
):
    source, item_id = setup_source(source_table)
    state, writes = {source_table: [source]}, []
    saved = {}

    def intercept(body, persisted):
        if body["table"] == "provenance" and not persisted:
            saved.update(body["rows"][0], detail='{"keep":true}', asserted_by="manual")
            if deleted:
                saved["deleted_at"] = "2026-09-01T00:00:00.000Z"
            state["provenance"] = [copy.deepcopy(saved)]

    with httpx.Client(transport=transport(state, item_id, intercept, writes)) as http:
        result = sync(source_table, http)
    assert result[counter] == 1
    assert result["failed"] == result["rejected"] == 0
    assert state["provenance"] == [saved]


@pytest.mark.parametrize(("source_table", "item_table", "parent", "counter"), CASES)
def test_lost_insert_ack_then_retry_does_not_invent_creation_or_reset_user_state(
    source_table, item_table, parent, counter
):
    source, item_id = setup_source(source_table)
    state, writes = {source_table: [source]}, []

    def intercept(body, persisted):
        if body["table"] == item_table and persisted:
            state[item_table][0].update(status="Finished", note="Keep")
            raise httpx.ReadTimeout("ack dropped after commit")

    with httpx.Client(transport=transport(state, item_id, intercept, writes)) as http:
        first = sync(source_table, http)
        saved = copy.deepcopy(state[item_table])
        second = sync(source_table, http)
    assert first[counter] == second[counter] == 0
    assert first["failed"] == 1 and second["failed"] == 0
    assert state[item_table] == saved
    assert len([w for w in writes if w["table"] == item_table]) == 1
    assert json.loads(state["provenance"][0]["detail"]) == {"created_row": 0}


@pytest.mark.parametrize(("source_table", "item_table", "parent", "counter"), CASES)
def test_older_hub_fails_closed_for_new_items_and_missing_edges(
    source_table, item_table, parent, counter
):
    source, item_id = setup_source(source_table)
    state = {source_table: [source], item_table: [{"id": "older", parent: source["id"]}]}
    writes, paths = [], []

    def intercept(body, persisted):
        if body["table"] != "youtube_channels":
            return httpx.Response(404)

    with httpx.Client(transport=transport(state, item_id, intercept, writes, paths)) as http:
        result = sync(source_table, http)
    assert result[counter] == 0 and result["failed"] == 2
    assert len(state[item_table]) == 1
    assert not state.get("provenance")
    assert ("/v1/rows/insert", item_table) in paths
    assert ("/v1/rows/insert", "provenance") in paths
    assert all(path == "/v1/rows/insert" or table == "youtube_channels" for path, table in paths)


@pytest.mark.parametrize("violations", [1, 2])
def test_mixed_insert_acknowledgments_and_duplicate_source_ids_use_only_inserted_counts(violations):
    a, b = "https://a.example/feed", "https://b.example/feed"
    ids = [f"https://items.example/{key}" for key in ("new", "existing", "bad")]
    state = {
        "feeds": [
            {"id": source, "fetch": "scrape:links", "scrape_pattern": "."} for source in (a, b)
        ]
    }
    batches = []

    def handler(request):
        if request.url.host != "hub.example":
            return httpx.Response(200, text="".join(f'<a href="{id_}">Item</a>' for id_ in ids * 2))
        body = json.loads(request.content)
        table = body["table"]
        if request.url.path.endswith("pull"):
            return httpx.Response(200, json={"rows": state.get(table, [])})
        assert request.url.path == "/v1/rows/insert"
        rows = body["rows"]
        if table == "articles":
            batches.append([r["id"] for r in rows])
            if len(batches) == 1:
                state[table] = [rows[0], {"id": ids[1], "feed_id": b, "status": "Finished"}]
                return httpx.Response(
                    200,
                    json={
                        "inserted": [ids[0]],
                        "existing": [ids[1]],
                        "rejected": [{"id": ids[2], "col": str(i)} for i in range(violations)],
                    },
                )
        state.setdefault(table, []).extend(rows)
        return httpx.Response(
            200, json={"inserted": [r["id"] for r in rows], "existing": [], "rejected": []}
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as http:
        result = pipeline.sync_feeds(HubClient("https://hub.example", "synthetic", http), http)
    assert result == {"feeds": 2, "articles": 2, "failed": 0, "rejected": violations}
    assert batches == [ids, [ids[2]]]
    edges = {r["to_ref"]: r for r in state["provenance"]}
    assert [json.loads(edges[id_]["detail"])["created_row"] for id_ in ids] == [1, 0, 1]
    assert edges[ids[1]]["from_ref"] == b


@pytest.mark.parametrize("deleted", [False, True])
def test_request_committing_after_recovery_read_cannot_overwrite_on_overlapping_source(deleted):
    a, b, item_id = "https://a.example/feed", "https://b.example/feed", "https://items.example/post"
    state = {
        "feeds": [
            {"id": source, "fetch": "scrape:links", "scrape_pattern": "."} for source in (a, b)
        ]
    }
    pending, saved, calls = {}, {}, 0

    def handler(request):
        nonlocal calls
        if request.url.host != "hub.example":
            if str(request.url) == b:
                # The previous insert commits after recovery returned no rows.
                saved.update(pending, status="Finished", note="Keep")
                if deleted:
                    saved["deleted_at"] = "2026-09-01T00:00:00.000Z"
                state["articles"] = [copy.deepcopy(saved)]
            return httpx.Response(200, text=f'<a href="{item_id}">Post</a>')
        body = json.loads(request.content)
        table, rows = body["table"], body.get("rows", [])
        if request.url.path.endswith("pull"):
            return httpx.Response(200, json={"rows": state.get(table, [])})
        assert request.url.path == "/v1/rows/insert"
        if table == "articles":
            calls += 1
            if calls == 1:
                pending.update(rows[0])
                raise httpx.ReadTimeout("request still in flight", request=request)
            return httpx.Response(200, json={"inserted": [], "existing": [item_id], "rejected": []})
        state[table] = rows
        return httpx.Response(
            200, json={"inserted": [r["id"] for r in rows], "existing": [], "rejected": []}
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as http:
        result = pipeline.sync_feeds(HubClient("https://hub.example", "synthetic", http), http)
    assert result == {"feeds": 2, "articles": 0, "failed": 1, "rejected": 0}
    assert calls == 2 and state["articles"] == [saved]
    if deleted:
        assert not state.get("provenance")
    else:
        assert state["provenance"][0]["from_ref"] == a
        assert json.loads(state["provenance"][0]["detail"]) == {"created_row": 0}


def test_tv_mixed_new_duplicate_and_refresh_rows_use_separate_write_contracts():
    state = {
        "tv_shows": [{"id": "source"}],
        "tv_episodes": [{"id": "old", "show_id": "source", "title": "TBA", "status": "Finished"}],
    }
    writes = []

    def handler(request):
        if request.url.host == "api.themoviedb.org":
            if "/season/" in request.url.path:
                return httpx.Response(
                    200,
                    json={
                        "episodes": [
                            {
                                "id": id_,
                                "season_number": 1,
                                "episode_number": 1,
                                "name": title,
                                "runtime": 42,
                                "air_date": "2026-09-01",
                            }
                            for id_, title in [
                                ("old", "Released"),
                                ("new", "First"),
                                ("new", "Last"),
                            ]
                        ]
                    },
                )
            return httpx.Response(200, json={"seasons": [{"season_number": 1}]})
        body = json.loads(request.content)
        table, rows = body["table"], body.get("rows", [])
        if request.url.path.endswith("pull"):
            return httpx.Response(200, json={"rows": state.get(table, [])})
        writes.append((request.url.path, table, copy.deepcopy(rows)))
        if request.url.path.endswith("push"):
            assert table == "tv_episodes" and len(rows) == 1
            assert set(rows[0]) == {"id", "air_date", "title", "runtime_min", "updated_at"}
            assert rows[0]["id"] == "old"
            state[table][0].update(rows[0])
            return httpx.Response(200, json={"upserted": 1, "rejected": []})
        assert request.url.path == "/v1/rows/insert"
        assert all(r["id"] != "old" for r in rows)
        state.setdefault(table, []).extend(rows)
        return httpx.Response(
            200, json={"inserted": [r["id"] for r in rows], "existing": [], "rejected": []}
        )

    with httpx.Client(transport=httpx.MockTransport(handler)) as http:
        result = pipeline.sync_tv(HubClient("https://hub.example", "synthetic", http), http, "key")
    assert result == {"shows": 1, "episodes": 1, "failed": 0, "rejected": 0}
    assert state["tv_episodes"][0]["status"] == "Finished"
    assert len(state["tv_episodes"]) == 2 and state["tv_episodes"][1]["title"] == "Last"
    assert [(path, table) for path, table, _ in writes] == [
        ("/v1/rows/insert", "tv_episodes"),
        ("/v1/rows/push", "tv_episodes"),
        ("/v1/rows/insert", "provenance"),
    ]
