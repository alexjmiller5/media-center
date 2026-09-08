from pathlib import Path

import httpx

from core import feeds
from core.watcher import Entry

FIX = Path(__file__).parent / "fixtures"


def test_canonical_url_strips_tracking_and_normalises():
    assert (
        feeds.canonical_url("HTTPS://Example.com/a/b/?utm_source=x&si=1&b=2&a=1#frag")
        == "https://example.com/a/b?a=1&b=2"
    )
    assert feeds.canonical_url("https://example.com/") == "https://example.com/"


def test_scrape_links_matches_pattern_and_dedupes():
    html = (FIX / "links_page.html").read_text()
    out = feeds.scrape_links(html, "https://example.com/changelog", r"/changelog/\d{4}-\d{2}-\d{2}")
    assert [e.url for e in out] == [
        "https://example.com/changelog/2026-09-01",
        "https://example.com/changelog/2026-08-15",
    ]
    assert out[0].title == "Version 2.3: Faster search"
    assert out[0].guid == out[0].url and out[0].published is None


def test_entries_dispatches_on_fetch():
    seen = []

    def handler(request):
        seen.append(str(request.url))
        if "rss" in str(request.url):
            return httpx.Response(200, text=(FIX / "rss2.xml").read_text())
        return httpx.Response(200, text=(FIX / "links_page.html").read_text())

    http = httpx.Client(transport=httpx.MockTransport(handler))
    rss = feeds.entries({"id": "https://blog.example.com/rss", "fetch": "rss"}, http)
    assert len(rss) == 3
    scraped = feeds.entries(
        {
            "id": "https://example.com/changelog",
            "fetch": "scrape:links",
            "scrape_pattern": r"/changelog/\d{4}",
        },
        http,
    )
    assert len(scraped) == 2
    assert feeds.entries({"id": "https://x.com/someone", "fetch": "x"}, http) == []
    assert len(seen) == 2


def test_article_rows_use_canonical_url_as_id():
    rows = feeds.article_rows(
        "https://blog.example.com/rss",
        [Entry(guid="g", title="T", url="https://Blog.example.com/p?utm_x=1", published=None)],
    )
    assert rows[0]["id"] == "https://blog.example.com/p"
    assert rows[0]["feed_id"] == "https://blog.example.com/rss"
    assert rows[0]["title"] == "T" and rows[0]["published_at"] is None
    assert rows[0]["status"] == "Not Started" and rows[0]["updated_at"].endswith("Z")
