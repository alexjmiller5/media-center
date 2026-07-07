from datetime import UTC, datetime
from pathlib import Path

from core.watcher import Entry, Source, new_entries, parse_feed, route

FIXTURES = Path(__file__).parent / "fixtures"


def entry(guid: str, published: datetime | None) -> Entry:
    return Entry(guid=guid, title=guid, url=f"https://x.example/{guid}", published=published)


def test_parse_rss2():
    entries = parse_feed((FIXTURES / "rss2.xml").read_text())
    assert len(entries) == 3
    e = entries[0]
    assert e.title == "Third post"
    assert e.url == "https://blog.example.com/third"
    assert e.guid == "https://blog.example.com/third"
    assert e.published == datetime(2026, 7, 5, 12, 0, tzinfo=UTC)


def test_parse_atom_github_releases():
    entries = parse_feed((FIXTURES / "github_releases.atom").read_text())
    assert len(entries) == 2
    e = entries[0]
    assert e.guid == "tag:github.com,2008:Repository/570893536/v2.4.1"
    assert e.title == "v2.4.1"
    assert e.url == "https://github.com/electrikmilk/cherri/releases/tag/v2.4.1"
    assert e.published == datetime(2026, 6, 20, 18, 30, tzinfo=UTC)


def test_new_entries_no_cursor_returns_all():
    entries = [entry("a", datetime(2026, 7, 1, tzinfo=UTC))]
    assert new_entries(entries) == entries


def test_new_entries_filters_by_timestamp():
    old = entry("old", datetime(2026, 6, 1, tzinfo=UTC))
    new = entry("new", datetime(2026, 7, 1, tzinfo=UTC))
    cursor = datetime(2026, 6, 15, tzinfo=UTC)
    assert new_entries([new, old], last_checked=cursor) == [new]


def test_new_entries_excludes_entry_at_exactly_the_cursor():
    cursor = datetime(2026, 6, 15, tzinfo=UTC)
    at_cursor = entry("at-cursor", cursor)
    assert new_entries([at_cursor], last_checked=cursor) == []


def test_new_entries_drops_last_seen_guid():
    a = entry("a", datetime(2026, 7, 1, tzinfo=UTC))
    b = entry("b", datetime(2026, 7, 2, tzinfo=UTC))
    assert new_entries([b, a], last_guid="a") == [b]


def test_new_entries_undated_entry_is_new_unless_guid_seen():
    undated = entry("undated", None)
    cursor = datetime(2026, 6, 15, tzinfo=UTC)
    assert new_entries([undated], last_checked=cursor) == [undated]
    assert new_entries([undated], last_checked=cursor, last_guid="undated") == []


def test_route_targets_the_db_the_source_came_from():
    source = Source(
        page_id="p1",
        name="Cherri",
        feed_url="https://github.com/electrikmilk/cherri/releases.atom",
        data_source_id="db-changelogs",
        last_checked=None,
    )
    assert route(source) == "db-changelogs"
