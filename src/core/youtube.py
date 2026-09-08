"""YouTube channels and videos through the Data API: the uploads playlist
(first page = daily delta, all pages = back catalog), durations and channel
resolution. No Modal imports. Per-channel RSS is deliberately not used: it
404s for some channels the API serves fine."""

import re
from datetime import UTC, datetime
from urllib.parse import urlparse

import httpx

from core.hub import now_iso

API = "https://www.googleapis.com/youtube/v3"
SHORT_MAX_S = 180
_DUR = re.compile(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?")


def parse_iso8601_duration(s: str) -> int:
    d, h, m, sec = (int(x or 0) for x in _DUR.fullmatch(s).groups())
    return d * 86400 + h * 3600 + m * 60 + sec


def to_hub_datetime(value: str | None) -> str | None:
    """Normalize any ISO-8601 UTC timestamp YouTube emits (seconds-only,
    fractional, or +00:00 offset) into the hub's millisecond ISO-8601 form."""
    if not value:
        return None
    dt = datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + f"{dt.microsecond // 1000:03d}Z"


def uploads(
    playlist_id: str, key: str, http: httpx.Client, max_pages: int | None = None
) -> list[dict]:
    out, token, pages = [], None, 0
    while True:
        params = {"part": "snippet", "maxResults": 50, "playlistId": playlist_id, "key": key}
        if token:
            params["pageToken"] = token
        resp = http.get(f"{API}/playlistItems", params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        for item in data.get("items", []):
            sn = item["snippet"]
            out.append(
                {
                    "id": sn["resourceId"]["videoId"],
                    "title": sn.get("title", ""),
                    "published_at": sn.get("publishedAt"),
                }
            )
        token = data.get("nextPageToken")
        pages += 1
        if not token or (max_pages is not None and pages >= max_pages):
            return out


def durations(video_ids: list[str], key: str, http: httpx.Client) -> dict[str, int]:
    out = {}
    for i in range(0, len(video_ids), 50):
        batch = video_ids[i : i + 50]
        resp = http.get(
            f"{API}/videos",
            params={"part": "contentDetails", "id": ",".join(batch), "key": key},
            timeout=30,
        )
        resp.raise_for_status()
        for item in resp.json().get("items", []):
            out[item["id"]] = parse_iso8601_duration(item["contentDetails"]["duration"])
    return out


def _channel_query(url: str) -> dict | None:
    path = urlparse(url).path.strip("/")
    if not path:
        return None
    if path.startswith("channel/"):
        return {"id": path.split("/")[1]}
    if path.startswith("@"):
        return {"forHandle": path.split("/")[0][1:]}
    if path.startswith(("c/", "user/")):
        return {"forHandle": path.split("/")[1]}
    return {"forHandle": path.split("/")[0]}


def resolve_channel(url: str, key: str, http: httpx.Client) -> dict | None:
    query = _channel_query(url)
    if not query:
        return None
    resp = http.get(
        f"{API}/channels",
        params={"part": "snippet,contentDetails", "key": key, **query},
        timeout=20,
    )
    resp.raise_for_status()
    items = resp.json().get("items") or []
    if not items:
        return None
    ch = items[0]
    return {
        "id": ch["id"],
        "title": ch["snippet"]["title"],
        "handle": ch["snippet"].get("customUrl"),
        "uploads_playlist_id": ch["contentDetails"]["relatedPlaylists"]["uploads"],
    }


def video_rows(channel_id: str, videos: list[dict], durations: dict[str, int]) -> list[dict]:
    stamp = now_iso()
    rows = []
    for v in videos:
        d = durations.get(v["id"])
        rows.append(
            {
                "id": v["id"],
                "channel_id": channel_id,
                "title": v["title"],
                "published_at": to_hub_datetime(v.get("published_at")),
                "duration_s": d,
                "thumbnail_url": f"https://i.ytimg.com/vi/{v['id']}/hqdefault.jpg",
                "is_short": 1 if d is not None and d <= SHORT_MAX_S else 0,
                "status": "Not Started",
                "updated_at": stamp,
            }
        )
    return rows
