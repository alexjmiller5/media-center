import json
from pathlib import Path

import httpx
import pytest

from core import youtube

FIX = Path(__file__).parent / "fixtures"


def route(table):
    """table: list of (url_substring, json_or_text)."""

    def handler(request):
        for needle, payload in table:
            if needle in str(request.url):
                return (
                    httpx.Response(200, json=payload)
                    if isinstance(payload, dict)
                    else httpx.Response(200, text=payload)
                )
        return httpx.Response(404)

    return httpx.Client(transport=httpx.MockTransport(handler))


def test_uploads_follows_next_page_token():
    page1 = json.loads((FIX / "playlist_items.json").read_text())
    page2 = dict(page1)
    page2 = {**page1, "items": page1["items"][:1]}
    page2.pop("nextPageToken", None)
    calls = []

    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(200, json=page2 if "pageToken=" in str(request.url) else page1)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    vids = youtube.uploads("UUHnyfMqiRRG1u-2MsSQLbXA", "KEY", http)
    assert len(vids) == len(page1["items"]) + 1
    assert len(calls) == 2 and "pageToken=" + page1["nextPageToken"] in calls[1]
    assert "playlistId=UUHnyfMqiRRG1u-2MsSQLbXA" in calls[0] and "key=KEY" in calls[0]


@pytest.mark.parametrize("known_ids,expected_pages", [({"known"}, 3), (None, 4)])
def test_uploads_stops_at_nonempty_fully_known_page(known_ids, expected_pages):
    pages = [[], ["known", "new"], ["known"], ["old"]]
    calls = []

    def handler(request):
        offset = int(request.url.params.get("pageToken", "0"))
        calls.append(offset)
        data = {"items": [{"snippet": {"resourceId": {"videoId": vid}}} for vid in pages[offset]]}
        if offset < 3:
            data["nextPageToken"] = str(offset + 1)
        return httpx.Response(200, json=data)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    vids = youtube.uploads("UUtest", "KEY", http, known_ids=known_ids)
    assert calls == list(range(expected_pages))
    assert {v["id"] for v in vids} == ({"known", "new"} if known_ids else {"known", "new", "old"})


def test_durations_batches_by_50_and_parses_iso():
    payload = json.loads((FIX / "videos_list.json").read_text())
    calls = []

    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(200, json=payload)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    ids = [f"id{i:08d}xyz"[:11] for i in range(120)]
    out = youtube.durations(ids, "KEY", http)
    assert len(calls) == 3
    real = payload["items"][0]
    assert out[real["id"]] == youtube.parse_iso8601_duration(real["contentDetails"]["duration"])


def test_parse_iso8601_duration():
    assert youtube.parse_iso8601_duration("PT1H2M3S") == 3723
    assert youtube.parse_iso8601_duration("PT45S") == 45
    assert youtube.parse_iso8601_duration("P1DT1S") == 86401


def test_parse_iso8601_duration_raises_on_unparseable():
    with pytest.raises(ValueError):
        youtube.parse_iso8601_duration("P1W")


def test_resolve_channel_by_handle_and_by_id():
    chan = {
        "items": [
            {
                "id": "UCHnyfMqiRRG1u-2MsSQLbXA",
                "snippet": {"title": "Veritasium", "customUrl": "@veritasium"},
                "contentDetails": {"relatedPlaylists": {"uploads": "UUHnyfMqiRRG1u-2MsSQLbXA"}},
            }
        ]
    }
    calls = []

    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(200, json=chan)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    a = youtube.resolve_channel("https://www.youtube.com/@veritasium", "KEY", http)
    b = youtube.resolve_channel(
        "https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA", "KEY", http
    )
    assert (
        a
        == b
        == {
            "id": "UCHnyfMqiRRG1u-2MsSQLbXA",
            "title": "Veritasium",
            "handle": "@veritasium",
            "uploads_playlist_id": "UUHnyfMqiRRG1u-2MsSQLbXA",
        }
    )
    assert "forHandle=veritasium" in calls[0]
    assert "id=UCHnyfMqiRRG1u-2MsSQLbXA" in calls[1]


def test_resolve_channel_returns_none_when_unknown():
    http = httpx.Client(
        transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"items": []}))
    )
    assert youtube.resolve_channel("https://www.youtube.com/@nobody", "KEY", http) is None


def test_video_rows_shape_and_short_flag():
    rows = youtube.video_rows(
        "UC1",
        [{"id": "abcdefghijk", "title": "T", "published_at": "2026-01-01T00:00:00Z"}],
        {"abcdefghijk": 90},
    )
    r = rows[0]
    assert r["id"] == "abcdefghijk" and r["channel_id"] == "UC1" and r["title"] == "T"
    assert r["duration_s"] == 90 and r["is_short"] == 1
    assert r["thumbnail_url"] == "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"
    assert r["status"] == "Not Started" and r["updated_at"].endswith("Z")
    assert r["published_at"] == "2026-01-01T00:00:00.000Z"
    assert (
        youtube.video_rows("UC1", [{"id": "x", "title": "T", "published_at": None}], {})[0][
            "is_short"
        ]
        == 0
    )


def test_to_hub_datetime_normalizes_youtube_timestamps():
    assert youtube.to_hub_datetime("2009-10-25T06:57:33Z") == "2009-10-25T06:57:33.000Z"
    assert youtube.to_hub_datetime("2026-09-07T17:24:51.5Z") == "2026-09-07T17:24:51.500Z"
    assert youtube.to_hub_datetime("2026-09-07T17:24:51+00:00") == "2026-09-07T17:24:51.000Z"
    assert youtube.to_hub_datetime("2026-09-07T17:24:51+05:00") == "2026-09-07T12:24:51.000Z"
    assert youtube.to_hub_datetime(None) is None
    assert youtube.to_hub_datetime("") is None
