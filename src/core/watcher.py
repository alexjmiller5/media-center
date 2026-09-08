"""RSS/Atom feed parsing.

Plain Python, no Modal imports - feedparser does the format handling
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
