import json

import httpx
import pytest

from core.hub import HubClient, imported_from, now_iso


def make_client(handler):
    transport = httpx.MockTransport(handler)
    return HubClient("https://hub.example", "lt_test", http=httpx.Client(transport=transport))


def test_now_iso_is_utc_with_millis():
    s = now_iso()
    assert s.endswith("Z") and len(s) == 24 and s[19] == "."


def test_pull_requests_deleted_at_and_drops_deleted_rows():
    seen = {}

    def handler(request):
        seen["body"] = json.loads(request.content)
        seen["headers"] = request.headers
        return httpx.Response(
            200,
            json={
                "rows": [
                    {"id": "a", "follow": 1, "deleted_at": None},
                    {"id": "b", "follow": 1, "deleted_at": "2026-01-01T00:00:00.000Z"},
                ]
            },
        )

    rows = make_client(handler).pull("youtube_channels", ["id", "follow"])
    assert [r["id"] for r in rows] == ["a"]
    assert seen["body"] == {
        "table": "youtube_channels",
        "columns": ["id", "follow", "deleted_at"],
        "since": "",
    }
    assert seen["headers"]["authorization"] == "Bearer lt_test"
    assert seen["headers"]["user-agent"].startswith("media-center/")


def test_push_sends_sorted_column_union_and_returns_result():
    seen = {}

    def handler(request):
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, json={"upserted": 2, "rejected": []})

    out = make_client(handler).push(
        "youtube_videos", [{"id": "v1", "title": "T"}, {"id": "v2", "status": "Not Started"}]
    )
    assert out == {"upserted": 2, "rejected": []}
    assert seen["body"]["table"] == "youtube_videos"
    assert seen["body"]["columns"] == ["id", "status", "title"]
    assert seen["body"]["rows"][0] == {"id": "v1", "title": "T"}


def test_push_empty_makes_no_request():
    def handler(request):  # pragma: no cover - must not be called
        raise AssertionError("no request expected")

    assert make_client(handler).push("youtube_videos", []) == {"upserted": 0, "rejected": []}


def test_push_raises_on_http_error():
    client = make_client(lambda request: httpx.Response(500, text="boom"))
    with pytest.raises(httpx.HTTPStatusError):
        client.push("youtube_videos", [{"id": "v1"}])


def test_imported_from_row_shape():
    row = imported_from("youtube_channels", "UC123", "youtube_videos", "abc")
    assert row["id"] == "youtube_channels:UC123:abc"
    assert row["from_kind"] == "youtube_channels" and row["from_ref"] == "UC123"
    assert row["to_kind"] == "youtube_videos" and row["to_ref"] == "abc"
    assert row["rel"] == "imported_from"
    assert row["asserted_by"] == "script:media-center"
    assert json.loads(row["detail"]) == {"created_row": 1}
    assert row["field"] is None
    assert row["updated_at"].endswith("Z")
