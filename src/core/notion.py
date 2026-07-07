"""Thin Notion API client (httpx) — list tracked sources, upsert entries.

API version 2026-03-11: query via /data_sources/{id}/query, pages created
with a data_source_id parent.
"""

from datetime import UTC, datetime

import httpx

from core.watcher import Entry, Source

API = "https://api.notion.com/v1"


class NotionClient:
    def __init__(self, api_key: str, http: httpx.Client | None = None):
        self._http = http or httpx.Client(
            base_url=API,
            headers={
                "Authorization": f"Bearer {api_key}",
                "Notion-Version": "2026-03-11",
                "Content-Type": "application/json",
            },
            timeout=30,
        )

    def list_sources(self, data_source_id: str) -> list[Source]:
        """Tracked sources with a feed URL from one source DB.

        ponytail: no pagination — source DBs are ~10 rows; add start_cursor
        handling if a source DB ever passes 100 rows.
        """
        resp = self._http.post(f"/data_sources/{data_source_id}/query", json={})
        resp.raise_for_status()
        sources = []
        for page in resp.json()["results"]:
            props = page["properties"]
            status = (props["Status"].get("select") or {}).get("name")
            feed_url = props["Feed URL"].get("url")
            if status != "Tracked" or not feed_url:
                continue
            date = props["Last Checked"].get("date") or {}
            last_checked = _parse_notion_date(date.get("start"))
            title = props["Name"].get("title", [])
            sources.append(
                Source(
                    page_id=page["id"],
                    name=title[0]["plain_text"] if title else "",
                    feed_url=feed_url,
                    data_source_id=data_source_id,
                    last_checked=last_checked,
                )
            )
        return sources

    def upsert_entry(self, data_source_id: str, entry: Entry) -> bool:
        """Create the entry as a page in the target DB unless its URL is already there.

        Returns True if a page was created.
        """
        query = self._http.post(
            f"/data_sources/{data_source_id}/query",
            json={"filter": {"property": "Site URL", "url": {"equals": entry.url}}},
        )
        query.raise_for_status()
        if query.json()["results"]:
            return False
        # ponytail: entry rows carry title + URL only (target DBs share the source
        # schema; Notion's created_time records arrival, published date not stored)
        properties: dict = {
            "Name": {"title": [{"text": {"content": entry.title}}]},
            "Site URL": {"url": entry.url},
        }
        create = self._http.post(
            "/pages",
            json={
                "parent": {"type": "data_source_id", "data_source_id": data_source_id},
                "properties": properties,
            },
        )
        create.raise_for_status()
        return True

    def mark_checked(self, page_id: str, when: datetime) -> None:
        """Advance the source row's cursor (Last Checked)."""
        resp = self._http.patch(
            f"/pages/{page_id}",
            json={"properties": {"Last Checked": {"date": {"start": when.isoformat()}}}},
        )
        resp.raise_for_status()


def _parse_notion_date(start: str | None) -> datetime | None:
    if not start:
        return None
    dt = datetime.fromisoformat(start)
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)
