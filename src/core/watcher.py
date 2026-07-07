"""RSS/Atom feed parsing, new-entry detection, and routing.

Plain Python, no Modal/Notion imports — feedparser does the format handling
(RSS 2.0, Atom, GitHub releases.atom all come out the same shape).
"""

from calendar import timegm
from dataclasses import dataclass
from datetime import UTC, datetime

import feedparser


@dataclass
class Entry:
    guid: str
    title: str
    url: str
    published: datetime | None


@dataclass
class Source:
    """A tracked feed row from one of the Notion source DBs."""

    page_id: str
    name: str
    feed_url: str
    data_source_id: str  # the DB the row lives in
    last_checked: datetime | None


def parse_feed(content: str | bytes) -> list[Entry]:
    """Parse RSS/Atom text into Entries, feed order preserved (newest first)."""
    parsed = feedparser.parse(content)
    entries = []
    for e in parsed.entries:
        struct = e.get("published_parsed") or e.get("updated_parsed")
        published = datetime.fromtimestamp(timegm(struct), tz=UTC) if struct else None
        link = e.get("link", "")
        entries.append(
            Entry(guid=e.get("id") or link, title=e.get("title", ""), url=link, published=published)
        )
    return entries


def new_entries(
    entries: list[Entry],
    last_checked: datetime | None = None,
    last_guid: str | None = None,
) -> list[Entry]:
    """Entries newer than the cursor (the Notion row's Last Checked / last GUID).

    Undated entries count as new unless their guid was the last one seen.
    No cursor at all -> everything is new (first poll seeds the DB).
    """
    return [
        e
        for e in entries
        if e.guid != last_guid
        and (last_checked is None or e.published is None or e.published > last_checked)
    ]


def route(source: Source) -> str:
    """Target DB for a source's new entries: the DB the source row came from.

    ponytail: deliberately no rules engine — add a routing-rules layer here
    if one feed ever needs to split across DBs.
    """
    return source.data_source_id
