"""Public author feeds -> entries. No credentials or handle resolution."""

import re
from datetime import UTC, datetime

import httpx

from core.watcher import Entry

API = "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed"
_PROFILE = re.compile(r"https://bsky\.app/profile/(did:[a-z]+:[A-Za-z0-9._:%-]*[A-Za-z0-9._-])")
_RKEY = re.compile(r"[A-Za-z0-9._~:-]{1,512}")


def _entry(item: dict, actor: str, profile_url: str) -> Entry | None:
    if not isinstance(item, dict):
        raise ValueError("Bluesky feed item must be an object")
    reason = item.get("reason", {})
    if not isinstance(reason, dict):
        raise ValueError("Bluesky feed reason must be an object")
    if reason.get("$type") == "app.bsky.feed.defs#reasonRepost":
        return None
    post = item.get("post")
    if not isinstance(post, dict) or not isinstance(post.get("author"), dict):
        raise ValueError("Bluesky post must contain an author")
    if not isinstance(post["author"].get("did"), str):
        raise ValueError("Bluesky post author must contain a DID")
    if post["author"]["did"] != actor:
        return None
    record = post.get("record")
    if not isinstance(record, dict):
        raise ValueError("Bluesky post record must be an object")
    if "reply" in record or "reply" in item:
        return None
    uri = post.get("uri")
    prefix = f"at://{actor}/app.bsky.feed.post/"
    if not isinstance(uri, str) or not uri.startswith(prefix):
        raise ValueError("Bluesky post URI must identify the source author's post")
    key = uri.removeprefix(prefix)
    if not _RKEY.fullmatch(key) or key in {".", ".."}:
        raise ValueError("Bluesky post URI has an invalid record key")
    if record.get("$type") != "app.bsky.feed.post" or not isinstance(record.get("text"), str):
        raise ValueError("Bluesky post record must contain post text")
    try:
        published = datetime.fromisoformat(record["createdAt"])
        if published.tzinfo is None:
            raise ValueError
        published = published.astimezone(UTC)
    except (KeyError, TypeError, ValueError, OverflowError):
        raise ValueError("Bluesky post createdAt must be a timestamp with a timezone") from None
    text = record["text"].strip()
    title = " ".join(text.splitlines()[0].split()) if text else f"Bluesky post {key}"
    if len(title) > 160:
        title = title[:157].rstrip() + "..."
    content = {"uri": uri, "record": record}
    if "embed" in post:
        if not isinstance(post["embed"], dict):
            raise ValueError("Bluesky post embed must be an object")
        content["embed"] = post["embed"]
    return Entry(uri, title, f"{profile_url}/post/{key}", published, content)


def entries(profile_url: str, http: httpx.Client) -> list[Entry]:
    match = _PROFILE.fullmatch(profile_url)
    if not match or len(match[1]) > 2048:
        raise ValueError("Bluesky source must be a canonical HTTPS profile URL containing a DID")
    actor = match[1]
    params = {"actor": actor, "filter": "posts_no_replies", "limit": "100"}
    out, seen, cursors = [], set(), set()
    # ponytail: full history held in memory; stream/checkpoint if source size warrants it.
    while True:
        response = http.get(API, params=params, timeout=30)
        response.raise_for_status()
        try:
            page = response.json()
        except ValueError:
            raise ValueError("Bluesky author-feed page is not valid JSON") from None
        if not isinstance(page, dict) or not isinstance(page.get("feed"), list):
            raise ValueError("Bluesky author-feed page must contain a feed array")
        for item in page["feed"]:
            entry = _entry(item, actor, profile_url)
            if entry is not None and entry.guid not in seen:
                seen.add(entry.guid)
                out.append(entry)
        if "cursor" not in page:
            return out
        cursor = page["cursor"]
        if not isinstance(cursor, str) or not cursor.strip():
            raise ValueError("Bluesky author-feed cursor must be a nonempty string")
        if cursor in cursors:
            raise ValueError("Bluesky author-feed cursor repeated")
        cursors.add(cursor)
        params["cursor"] = cursor
