"""RSS, scraped links and public Bluesky feeds -> article rows. No Modal imports."""

import json
import re
from datetime import UTC
from html.parser import HTMLParser
from urllib.parse import parse_qsl, urlencode, urljoin, urlparse, urlunparse

import httpx

from core import bluesky, chrome
from core.hub import now_iso
from core.watcher import Entry, parse_feed

DROP_PARAMS = {"si", "ref", "fbclid", "gclid"}


def canonical_url(url: str) -> str:
    p = urlparse(url.strip())
    query = sorted(
        (k, v)
        for k, v in parse_qsl(p.query, keep_blank_values=True)
        if not k.startswith("utm_") and k not in DROP_PARAMS
    )
    path = p.path.rstrip("/") if len(p.path) > 1 else p.path
    return urlunparse((p.scheme.lower(), p.netloc.lower(), path, "", urlencode(query), ""))


class _Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links: list[tuple[str, str]] = []
        self._href = None
        self._text: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            self._href = dict(attrs).get("href")
            self._text = []

    def handle_data(self, data):
        if self._href is not None:
            self._text.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._href is not None:
            self.links.append((self._href, " ".join("".join(self._text).split())))
            self._href = None


def scrape_links(html: str, base_url: str, pattern: str) -> list[Entry]:
    parser = _Links()
    parser.feed(html)
    rx = re.compile(pattern)
    out = {}
    for href, text in parser.links:
        url = canonical_url(urljoin(base_url, href))
        if not rx.search(url):
            continue
        if url not in out:
            out[url] = Entry(guid=url, title=text, url=url, published=None)
        elif not out[url].title:
            out[url].title = text
    return list(out.values())


def entries(feed_row: dict, http: httpx.Client) -> list[Entry]:
    fetch = feed_row["fetch"]
    if fetch == "bluesky":
        return bluesky.entries(feed_row["id"], http)
    if fetch == "chrome":
        return chrome.entries(feed_row["id"], http)
    if fetch == "x":
        return []
    resp = http.get(feed_row["id"], timeout=30, follow_redirects=True)
    resp.raise_for_status()
    if fetch == "rss":
        return parse_feed(resp.text)
    if fetch == "scrape:links":
        return scrape_links(resp.text, feed_row["id"], feed_row["scrape_pattern"])
    raise ValueError(f"unknown fetch kind {fetch!r}")


def article_rows(feed_id: str, items: list[Entry]) -> list[dict]:
    stamp = now_iso()
    return [
        {
            "id": e.row_id if e.row_id is not None else canonical_url(e.url),
            "feed_id": feed_id,
            "title": e.title,
            "published_at": (
                e.published.astimezone(UTC)
                .isoformat(timespec="milliseconds")
                .replace("+00:00", "Z")
                if e.published
                else None
            ),
            "status": "Not Started",
            "updated_at": stamp,
            **(
                {"content": json.dumps(e.content, ensure_ascii=False)}
                if e.content is not None
                else {}
            ),
        }
        for e in items
        if e.url
    ]
