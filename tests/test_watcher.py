from datetime import UTC, datetime
from pathlib import Path

from core.watcher import parse_feed

FIXTURES = Path(__file__).parent / "fixtures"


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
