"""Synthetic protocol fixtures; network and hub boundaries use MockTransport."""

import copy
import json

import httpx
import pytest
import structlog.testing

from core import feeds, pipeline
from core.hub import HubClient

DID = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_DID = "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"
PROFILE = f"https://bsky.app/profile/{DID}"
SOURCE = {"id": PROFILE, "fetch": "bluesky", "kind": "bluesky", "follow": 0}


def post(key, text="First line\nFull second line", *, actor=DID, handle="before.invalid"):
    return {
        "post": {
            "uri": f"at://{actor}/app.bsky.feed.post/{key}",
            "cid": "synthetic-cid",
            "author": {"did": actor, "handle": handle},
            "record": {
                "$type": "app.bsky.feed.post",
                "text": text,
                "createdAt": "2026-09-01T02:30:00.123456+02:30",
                "langs": ["en"],
            },
            "indexedAt": "2026-09-01T00:00:01Z",
        }
    }


def test_bluesky_paginates_filters_and_preserves_content():
    original = post("original", "  First   line\n" + "Long full text " * 50)
    original["post"]["record"]["facets"] = [{"index": {"byteStart": 0, "byteEnd": 4}}]
    quote = post("quote", "Q" * 200)
    quote["post"]["record"]["embed"] = {
        "$type": "app.bsky.embed.record",
        "record": {"uri": f"at://{OTHER_DID}/app.bsky.feed.post/quoted", "cid": "quote-cid"},
    }
    quote["post"]["embed"] = {
        "$type": "app.bsky.embed.record#view",
        "record": {"$type": "app.bsky.embed.record#viewNotFound", "notFound": True},
    }
    media = post("media", " \n ")
    media["post"]["record"]["embed"] = {
        "$type": "app.bsky.embed.images",
        "images": [{"alt": "Synthetic image", "image": {"ref": {"$link": "synthetic-blob"}}}],
    }
    media["post"]["embed"] = {
        "$type": "app.bsky.embed.images#view",
        "images": [{"alt": "Synthetic image", "fullsize": "https://media.example/image"}],
    }
    reply = post("reply")
    reply["post"]["record"]["reply"] = {"parent": {}, "root": {}}
    view_reply = {**post("view-reply"), "reply": {"parent": {}, "root": {}}}
    repost = {**post("self-repost"), "reason": {"$type": "app.bsky.feed.defs#reasonRepost"}}
    pinned = {**post("pin"), "reason": {"$type": "app.bsky.feed.defs#reasonPin"}}
    pages = [
        {"feed": [original, repost, post("other", actor=OTHER_DID), reply, view_reply]},
        {"feed": []},
        {"feed": [post("original", handle="after.invalid"), quote, media, pinned]},
    ]
    cursors = []

    def handler(request):
        assert request.url.host == "public.api.bsky.app"
        assert request.url.path == "/xrpc/app.bsky.feed.getAuthorFeed"
        assert request.url.params["actor"] == DID
        assert request.url.params["filter"] == "posts_no_replies"
        assert request.url.params["limit"] == "100"
        assert "authorization" not in request.headers
        cursor = request.url.params.get("cursor")
        cursors.append(cursor)
        index = {None: 0, "page-2": 1, "page-3": 2}[cursor]
        page = copy.deepcopy(pages[index])
        if index < 2:
            page["cursor"] = f"page-{index + 2}"
        return httpx.Response(200, json=page)

    with httpx.Client(transport=httpx.MockTransport(handler)) as http:
        entries = feeds.entries(SOURCE, http)
    assert cursors == [None, "page-2", "page-3"]
    assert [e.guid for e in entries] == [
        f"at://{DID}/app.bsky.feed.post/{key}" for key in ("original", "quote", "media", "pin")
    ]
    rows = feeds.article_rows(PROFILE, entries)
    assert [r["id"] for r in rows] == [
        f"{PROFILE}/post/{key}" for key in ("original", "quote", "media", "pin")
    ]
    assert [r["title"] for r in rows] == [
        "First line",
        "Q" * 157 + "...",
        "Bluesky post media",
        "First line",
    ]
    assert all(r["published_at"] == "2026-09-01T00:00:00.123Z" for r in rows)
    for row, native in zip(rows, [original, quote, media, pinned], strict=True):
        content = json.loads(row["content"])
        assert content["uri"] == native["post"]["uri"]
        assert content["record"] == native["post"]["record"]
        assert content.get("embed") == native["post"].get("embed")
        assert row["status"] == "Not Started"


@pytest.mark.parametrize("reject_first", [False, True])
def test_bluesky_sync_preserves_user_state_tombstones_and_retries(reject_first):
    existing = [
        {
            "id": f"{PROFILE}/post/read",
            "status": "Finished",
            "note": "Keep",
            "date_read": "2026-09-02",
            "tags": '["saved"]',
            "updated_at": "2026-09-02T00:00:00.000Z",
        },
        {
            "id": f"{PROFILE}/post/deleted",
            "status": "Gave Up",
            "deleted_at": "2026-09-02T00:00:00.000Z",
            "note": "Keep deleted",
        },
    ]
    state = {
        "feeds": [
            SOURCE,
            {
                **SOURCE,
                "id": f"https://bsky.app/profile/{OTHER_DID}",
                "deleted_at": "2026-09-02T00:00:00.000Z",
            },
        ],
        "articles": copy.deepcopy(existing),
    }
    pushed = []
    handle = "before.invalid"
    reject = reject_first

    def handler(request):
        if request.url.host == "public.api.bsky.app":
            assert request.url.params["actor"] == DID
            return httpx.Response(
                200,
                json={
                    "feed": [post(key, handle=handle) for key in ("read", "deleted", "new", "new")]
                },
            )
        body = json.loads(request.content)
        table = body["table"]
        if request.url.path == "/v1/rows/pull":
            return httpx.Response(
                200,
                json={
                    "rows": [
                        {col: row.get(col) for col in body["columns"]}
                        for row in state.get(table, [])
                    ]
                },
            )
        assert request.url.path == "/v1/rows/push"
        pushed.append(body)
        rejected = []
        for row in body["rows"]:
            if table == "articles" and reject:
                rejected.append(
                    {"id": row["id"], "col": "content", "message": "synthetic rejection"}
                )
            else:
                state.setdefault(table, []).append(row)
        return httpx.Response(
            200, json={"upserted": len(body["rows"]) - len(rejected), "rejected": rejected}
        )

    with (
        httpx.Client(transport=httpx.MockTransport(handler)) as http,
        structlog.testing.capture_logs() as logs,
    ):
        hub = HubClient("https://hub.example", "test-token", http)
        assert pipeline.sync_feeds(hub, http) == {
            "feeds": 1,
            "articles": 0 if reject else 1,
            "failed": 0,
            "rejected": int(reject),
        }
        assert len(state.get("provenance", [])) == (0 if reject else 1)
        reject = False
        handle = "after.invalid"
        assert pipeline.sync_feeds(hub, http)["articles"] == int(reject_first)
        assert pipeline.sync_feeds(hub, http)["articles"] == 0
    assert "synthetic rejection" not in json.dumps(logs)
    assert DID not in json.dumps(logs)
    assert state["articles"][:2] == existing
    assert len(state["articles"]) == 3
    assert state["articles"][2]["id"] == f"{PROFILE}/post/new"
    assert (
        json.loads(state["articles"][2]["content"])["record"]["text"]
        == "First line\nFull second line"
    )
    assert len(state["provenance"]) == 1
    assert state["provenance"][0]["from_ref"] == PROFILE
    assert state["provenance"][0]["to_ref"] == f"{PROFILE}/post/new"
    assert state["provenance"][0]["rel"] == "imported_from"
    assert all(body["table"] != "feeds" for body in pushed)
    assert all(
        row["id"] == f"{PROFILE}/post/new"
        for body in pushed
        if body["table"] == "articles"
        for row in body["rows"]
    )


@pytest.mark.parametrize(
    "profile",
    [
        "https://bsky.app/profile/handle.invalid",
        PROFILE + "/",
        PROFILE + "?token=private",
        PROFILE + "/post/key",
        PROFILE.replace("https:", "http:"),
        PROFILE.replace("bsky.app", "evil.example"),
        PROFILE + "#private",
        "https://bsky.app/profile/did:",
        PROFILE + ":",
        PROFILE + "%",
        "https://bsky.app/profile/did:plc:" + "a" * 2048,
    ],
)
def test_bluesky_rejects_noncanonical_profile_without_fetching(profile):
    def handler(request):
        pytest.fail("invalid source must be rejected before network access")

    with httpx.Client(transport=httpx.MockTransport(handler)) as http:
        with pytest.raises(ValueError, match="Bluesky.*profile"):
            feeds.entries({**SOURCE, "id": profile}, http)


@pytest.mark.parametrize(
    "uri",
    [
        "https://example.com/post",
        f"at://{DID}/app.bsky.feed.like/key",
        f"at://{OTHER_DID}/app.bsky.feed.post/key",
        f"at://{DID}/app.bsky.feed.post/",
        f"at://{DID}/app.bsky.feed.post/..",
        f"at://{DID}/app.bsky.feed.post/a/b",
        f"at://{DID}/app.bsky.feed.post/key?private",
        f"at://{DID}/app.bsky.feed.post/" + "a" * 513,
        None,
    ],
)
def test_bluesky_rejects_malformed_post_uri(uri):
    item = post("bad")
    item["post"]["uri"] = uri
    with httpx.Client(
        transport=httpx.MockTransport(lambda request: httpx.Response(200, json={"feed": [item]}))
    ) as http:
        with pytest.raises(ValueError, match="Bluesky.*URI"):
            feeds.entries(SOURCE, http)


@pytest.mark.parametrize(
    "problem",
    [
        "http",
        "timeout",
        "json",
        "page",
        "feed",
        "item",
        "record",
        "date",
        "naive-date",
        "cursor-type",
        "cursor-null",
        "cursor-empty",
        "cursor-repeat",
        "cursor-cycle",
    ],
)
def test_bluesky_failed_walk_is_counted_safe_and_writes_no_partial_history(problem):
    pushes = []
    requests = 0
    private = "SYNTHETIC-PRIVATE-PAYLOAD"

    def handler(request):
        nonlocal requests
        if request.url.host == "hub.example":
            body = json.loads(request.content)
            if request.url.path.endswith("pull"):
                return httpx.Response(
                    200,
                    json={
                        "rows": [SOURCE, {"id": "https://rss.example/feed", "fetch": "rss"}]
                        if body["table"] == "feeds"
                        else []
                    },
                )
            pushes.append(body)
            return httpx.Response(200, json={"upserted": len(body["rows"]), "rejected": []})
        if request.url.host == "rss.example":
            return httpx.Response(
                200,
                text='<rss version="2.0"><channel><item><title>RSS</title><link>https://rss.example/post</link></item></channel></rss>',
            )
        requests += 1
        assert requests <= 4, "pagination loop did not terminate"
        if requests == 1:
            return httpx.Response(200, json={"feed": [post("first")], "cursor": private})
        if problem == "http":
            return httpx.Response(503, text=private)
        if problem == "timeout":
            raise httpx.ReadTimeout(private, request=request)
        if problem == "json":
            return httpx.Response(200, text=private)
        item = post("second")
        if problem == "record":
            item["post"]["record"]["text"] = None
        if problem in ("date", "naive-date"):
            item["post"]["record"]["createdAt"] = (
                private if problem == "date" else "2026-09-01T00:00:00"
            )
        payload = {"feed": [item]}
        if problem == "page":
            payload = []
        elif problem == "feed":
            payload = {"feed": {}}
        elif problem == "item":
            payload = {"feed": [None]}
        elif problem.startswith("cursor-"):
            payload["cursor"] = {
                "cursor-type": [],
                "cursor-null": None,
                "cursor-empty": "",
                "cursor-repeat": private,
                "cursor-cycle": "second-cursor" if requests == 2 else private,
            }[problem]
        return httpx.Response(200, json=payload)

    with httpx.Client(transport=httpx.MockTransport(handler)) as http:
        with structlog.testing.capture_logs() as logs:
            result = pipeline.sync_feeds(HubClient("https://hub.example", "test-token", http), http)
    assert requests == (3 if problem == "cursor-cycle" else 2)
    assert result == {"feeds": 2, "articles": 1, "failed": 1, "rejected": 0}
    assert len(pushes) == 2  # Only the independent RSS source and its provenance.
    assert pushes[0]["rows"][0]["id"] == "https://rss.example/post"
    assert "content" not in pushes[0]["rows"][0]
    assert private not in json.dumps(logs) and DID not in json.dumps(logs)
    assert logs[0]["event"] == "feed_failed"


@pytest.mark.parametrize(
    ("path", "value", "message"),
    [
        (("reason",), [], "reason"),
        (("post",), None, "author"),
        (("post", "author", "did"), None, "DID"),
        (("post", "record"), [], "record"),
        (("post", "embed"), [], "embed"),
    ],
)
def test_bluesky_malformed_objects_have_safe_diagnostics(path, value, message):
    item = post("bad", "SYNTHETIC-PRIVATE-PAYLOAD")
    obj = item
    for key in path[:-1]:
        obj = obj[key]
    obj[path[-1]] = value
    with httpx.Client(
        transport=httpx.MockTransport(lambda request: httpx.Response(200, json={"feed": [item]}))
    ) as http:
        with pytest.raises(ValueError, match=f"Bluesky.*{message}") as error:
            feeds.entries(SOURCE, http)
    assert "SYNTHETIC-PRIVATE-PAYLOAD" not in str(error.value)
