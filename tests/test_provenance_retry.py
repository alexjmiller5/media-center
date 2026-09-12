"""Retry behavior at the actual hub HTTP boundary, with durable synthetic state."""

import copy
import json

import httpx
import pytest

from core import pipeline
from core.hub import HubClient

CASES = [
    ("feeds", "articles", "feed_id", "articles"),
    ("tv_shows", "tv_episodes", "show_id", "episodes"),
    ("youtube_channels", "youtube_videos", "channel_id", "videos"),
]
PROFILE = "https://bsky.app/profile/did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"


def setup_source(source_table):
    if source_table == "feeds":
        return {"id": PROFILE, "fetch": "bluesky", "follow": 0}, PROFILE + "/post/item"
    if source_table == "tv_shows":
        return {"id": "source", "follow": 0}, "item"
    return {"id": "source", "uploads_playlist_id": "uploads", "backfilled": 1}, "item"


def upstream(request, item_id):
    if request.url.host == "public.api.bsky.app":
        return {
            "feed": [
                {
                    "post": {
                        "uri": "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/app.bsky.feed.post/item",
                        "author": {"did": "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"},
                        "record": {
                            "$type": "app.bsky.feed.post",
                            "text": "Post",
                            "createdAt": "2026-09-01T00:00:00Z",
                        },
                    }
                }
            ]
        }
    if request.url.host == "api.themoviedb.org":
        if "/season/" in request.url.path:
            return {"episodes": [{"id": item_id, "season_number": 1, "episode_number": 1}]}
        return {"seasons": [{"season_number": 1}]}
    if request.url.path.endswith("playlistItems"):
        return {"items": [{"snippet": {"resourceId": {"videoId": item_id}, "title": "Video"}}]}
    return {"items": [{"id": item_id, "contentDetails": {"duration": "PT45S"}}]}


def sync(source_table, http):
    # A fresh client every time simulates a new process using only persisted state.
    hub = HubClient("https://hub.example", "synthetic-token", http)
    if source_table == "feeds":
        return pipeline.sync_feeds(hub, http)
    fn = pipeline.sync_tv if source_table == "tv_shows" else pipeline.sync_youtube
    return fn(hub, http, "synthetic-key")


def transport(state, item_id, intercept, pushes, paths=None):
    def handler(request):
        if request.url.host != "hub.example":
            return httpx.Response(200, json=upstream(request, item_id))
        body = json.loads(request.content)
        table = body["table"]
        if request.url.path.endswith("pull"):
            return httpx.Response(
                200,
                json={
                    "rows": [
                        {col: row.get(col) for col in body["columns"]}
                        for row in state.get(table, [])
                    ]
                },
            )
        path = request.url.path
        assert path in ("/v1/rows/push", "/v1/rows/insert")
        if paths is not None:
            paths.append((path, table))
        if path.endswith("push"):
            assert table == "youtube_channels" or (
                table == "tv_episodes"
                and all(
                    set(r) <= {"id", "updated_at", "air_date", "title", "runtime_min"}
                    for r in body["rows"]
                )
            ), "new items and edges must use insert"

        pushes.append(copy.deepcopy(body))
        response = intercept(body, False)
        if response is not None:
            return response
        stored = {row["id"]: row for row in state.get(table, [])}
        inserted, existing = [], []
        for row in body["rows"]:
            if path.endswith("push"):
                stored.setdefault(row["id"], {}).update(row)
            elif row["id"] in stored:
                existing.append(row["id"])
            else:
                stored[row["id"]] = dict(row)
                inserted.append(row["id"])
        state[table] = list(stored.values())
        response = intercept(body, True)
        result = (
            {"upserted": len(body["rows"]), "rejected": []}
            if path.endswith("push")
            else {"inserted": inserted, "existing": existing, "rejected": []}
        )
        return response if response is not None else httpx.Response(200, json=result)

    return httpx.MockTransport(handler)


@pytest.mark.parametrize(("source_table", "item_table", "parent", "counter"), CASES)
@pytest.mark.parametrize("failure", ["rejected", "edge-http", "edge-accepted-http", "restart"])
def test_missing_provenance_retries_from_stored_items_after_failure(
    source_table, item_table, parent, counter, failure
):
    source, item_id = setup_source(source_table)
    state = {source_table: [source]}
    pushes = []
    failing = True

    def intercept(body, persisted):
        if not failing:
            return None
        if failure == "restart" and body["table"] == item_table and persisted:
            raise SystemExit("synthetic process interruption")
        if body["table"] == "provenance":
            if failure == "rejected" and not persisted:
                return httpx.Response(
                    200,
                    json={
                        "inserted": [],
                        "existing": [],
                        "rejected": [{"id": row["id"]} for row in body["rows"]],
                    },
                )
            if (failure == "edge-http" and not persisted) or (
                failure == "edge-accepted-http" and persisted
            ):
                return httpx.Response(503)
        return None

    with httpx.Client(transport=transport(state, item_id, intercept, pushes)) as http:
        if failure == "restart":
            with pytest.raises(SystemExit):
                sync(source_table, http)
        else:
            first = sync(source_table, http)
            assert first[counter] == 1
            assert first["rejected"] == int(failure == "rejected")
            assert first["failed"] == int(failure != "rejected")
        assert len(state[item_table]) == 1
        # The source disappears; a retry must use stored relationships, not upstream.
        state[source_table] = []
        state[item_table][0].update(status="Finished", note="Keep edited note")
        saved = copy.deepcopy(state[item_table])
        existing_edges = copy.deepcopy(state.get("provenance", []))
        failing = False
        second = sync(source_table, http)
        assert second[counter] == 0 and second["rejected"] == 0 and second["failed"] == 0
        assert state[item_table] == saved
        edges = state.get("provenance", [])
        assert len(edges) == 1
        assert edges[0]["id"] == f"{source_table}:{source['id']}:{item_id}"
        assert edges[0]["from_ref"] == saved[0][parent]
        assert edges[0]["to_ref"] == item_id
        assert edges[0]["rel"] == "imported_from"
        assert json.loads(edges[0]["detail"]) == {
            "created_row": int(failure == "edge-accepted-http")
        }
        if existing_edges:
            assert edges == existing_edges
        before = copy.deepcopy(pushes)
        assert sync(source_table, http)[counter] == 0
        assert pushes == before
    assert len([p for p in pushes if p["table"] == item_table]) == 1


@pytest.mark.parametrize(("source_table", "item_table", "parent", "counter"), CASES)
@pytest.mark.parametrize("deleted", [False, True])
def test_repair_uses_stored_parent_and_preserves_items_and_existing_edges(
    source_table, item_table, parent, counter, deleted
):
    source, item_id = setup_source(source_table)
    owner = "https://owner.example/feed" if source_table == "feeds" else "stored-owner"
    items = [
        {"id": item_id, parent: owner, "status": "Finished", "note": "keep"},
        {"id": "manual", parent: None, "status": "Priority"},
        {"id": "deleted-item", parent: owner, "deleted_at": "2026-09-01T00:00:00.000Z"},
        {"id": "valid-edge", parent: owner, "status": "Finished"},
        {"id": "deleted-edge", parent: owner, "status": "Finished"},
    ]
    if deleted:
        items[0]["deleted_at"] = "2026-09-01T00:00:00.000Z"
    edges = [
        {
            "id": f"{source_table}:{owner}:{key}",
            "from_kind": source_table,
            "from_ref": owner,
            "to_kind": item_table,
            "to_ref": key,
            "rel": "imported_from",
            "detail": '{"keep":true}',
            "updated_at": "2026-09-01T00:00:00.000Z",
            "deleted_at": deleted,
        }
        for key, deleted in [("valid-edge", None), ("deleted-edge", "2026-09-02T00:00:00.000Z")]
    ]
    state = {
        source_table: [source],
        item_table: copy.deepcopy(items),
        "provenance": copy.deepcopy(edges),
    }
    pushes = []
    with httpx.Client(transport=transport(state, item_id, lambda *_: None, pushes)) as http:
        result = sync(source_table, http)
    assert result[counter] == 0
    assert result["failed"] == result["rejected"] == 0
    assert state[item_table] == items
    assert state["provenance"][:2] == edges
    if deleted:
        assert state["provenance"] == edges
        assert pushes == []
        return
    assert len(state["provenance"]) == 3
    repair = state["provenance"][-1]
    assert repair["from_ref"] == owner
    assert repair["to_ref"] == item_id
    assert json.loads(repair["detail"]) == {"created_row": 0}
    assert [p["table"] for p in pushes] == ["provenance"]


def test_repair_counts_rejection_before_later_chunk_http_failure_and_retries():
    items = [
        {"id": f"https://items.example/{i}", "feed_id": "https://owner.example/feed"}
        for i in range(201)
    ]
    state = {"feeds": [], "articles": copy.deepcopy(items)}
    pushes = []
    calls = 0

    def intercept(body, persisted):
        nonlocal calls
        assert body["table"] == "provenance"
        if persisted:
            return None
        calls += 1
        if calls == 1:
            state["provenance"] = copy.deepcopy(body["rows"][1:])
            return httpx.Response(
                200,
                json={
                    "inserted": [r["id"] for r in body["rows"][1:]],
                    "existing": [],
                    "rejected": [{"id": body["rows"][0]["id"]}],
                },
            )
        if calls == 2:
            return httpx.Response(503)
        return None

    with httpx.Client(transport=transport(state, "", intercept, pushes)) as http:
        assert sync("feeds", http) == {"feeds": 0, "articles": 0, "failed": 1, "rejected": 1}
        accepted = copy.deepcopy(state["provenance"])
        assert len(accepted) == 199
        assert sync("feeds", http) == {"feeds": 0, "articles": 0, "failed": 0, "rejected": 0}
    assert state["articles"] == items
    assert state["provenance"][:199] == accepted
    assert len(state["provenance"]) == 201
    assert len(pushes[-1]["rows"]) == 2
    assert all(json.loads(edge["detail"]) == {"created_row": 0} for edge in state["provenance"])
