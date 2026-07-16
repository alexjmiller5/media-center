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


def run(payload: dict) -> dict:
    log.info("run", payload=payload)
    return poll_all_sources()


def poll_all_sources(
    notion: NotionClient | None = None,
    http: httpx.Client | None = None,
    source_dbs: tuple[str, ...] | None = None,
) -> dict:
    if notion is None or source_dbs is None:
        settings = Settings()
        notion = notion or NotionClient(settings.notion_api_key)
        source_dbs = source_dbs or settings.source_dbs
    http = http or httpx.Client(
        timeout=30, follow_redirects=True, headers={"User-Agent": "my-media-center/0.1"}
    )
    checked = created = 0
    for db in source_dbs:
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
