"""Poll all tracked RSS/Atom sources and push new entries into Notion.

Business logic — plain Python, no Modal imports. Runs anywhere.
The cursor is the Notion source row itself (Last Checked), per the
Notion-as-datastore cache+refresh pattern.
"""

from datetime import UTC, datetime

import httpx
import structlog

from core.config import Settings
from core.notion import NotionClient
from core.watcher import new_entries, parse_feed, route

log = structlog.get_logger()

# The two source DBs (see CLAUDE.md): Tech Changelogs, Blogs.
SOURCE_DBS = (
    "0296e086-a630-4a78-9dd9-c935f00a67f4",
    "6cbb5c8a-30b7-4332-8f06-36a706c7c646",
)


def run(payload: dict) -> dict:
    log.info("run", payload=payload)
    return poll_all_sources()


def poll_all_sources(notion: NotionClient | None = None, http: httpx.Client | None = None) -> dict:
    notion = notion or NotionClient(Settings().notion_api_key)
    http = http or httpx.Client(
        timeout=30, follow_redirects=True, headers={"User-Agent": "my-media-center/0.1"}
    )
    checked = created = 0
    for db in SOURCE_DBS:
        for source in notion.list_sources(db):
            try:
                resp = http.get(source.feed_url)
                resp.raise_for_status()
                fresh = new_entries(parse_feed(resp.text), last_checked=source.last_checked)
                for entry in fresh:
                    created += notion.upsert_entry(route(source), entry)
                # cursor only advances after a successful poll
                notion.mark_checked(source.page_id, datetime.now(UTC))
                checked += 1
                log.info("polled", source=source.name, new=len(fresh))
            except Exception:
                log.exception("source_failed", source=source.name, feed_url=source.feed_url)
    return {"ok": True, "sources_checked": checked, "entries_created": created}
