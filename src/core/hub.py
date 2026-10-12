"""soma hub client - the one place media-center reads and writes rows.

`CachedHub` serves every read from the poller's own copy of the tables it
reads, kept current by soma's table-pull helper, and passes writes through:
atomic creation of missing rows (`/v1/rows/insert`), owned-column updates
(`/v1/rows/push`) and revision-guarded single-row edits (`/v1/rows/patch`).
Provenance edges use the same insert-only contract as new items.
"""

import gzip
import json
import os
from datetime import UTC, datetime
from pathlib import Path

import httpx

from core.table_pull import pull_tables

VERSION = "0.2"
ASSERTED_BY = "script:media-center"
STATE_VERSION = 1
SLICE_PAGE = 5000  # the hub's per-request row ceiling for batched pulls
# Every column a poller read uses, per table (the helper adds id, hub_at, deleted_at).
READS = {
    "tv_shows": ["follow", "feed_since", "updated_at"],
    "youtube_channels": ["uploads_playlist_id", "backfilled", "follow", "feed_since", "updated_at"],
    "feeds": ["fetch", "scrape_pattern", "follow", "feed_since", "updated_at"],
    "tv_episodes": ["show_id", "air_date", "title", "runtime_min"],
    "youtube_videos": ["channel_id"],
    "articles": ["feed_id"],
}


def now_iso() -> str:
    now = datetime.now(UTC)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


class HubClient:
    def __init__(self, url: str, token: str, http: httpx.Client | None = None):
        self.url = url.rstrip("/")
        self._http = http or httpx.Client(timeout=120)
        self._headers = {
            "Authorization": f"Bearer {token}",
            "User-Agent": f"media-center/{VERSION}",
            "Content-Type": "application/json",
        }

    def post(self, route: str, body: dict) -> dict:
        resp = self._http.post(f"{self.url}{route}", json=body, headers=self._headers)
        resp.raise_for_status()
        return resp.json()

    def push(self, table: str, rows: list[dict]) -> dict:
        if not rows:
            return {"upserted": 0, "rejected": []}
        columns = sorted({k for r in rows for k in r})
        return self.post("/v1/rows/push", {"table": table, "columns": columns, "rows": rows})

    def patch(self, table: str, id: str, values: dict, expected_revision: dict) -> dict:
        """Edit one live row only if it still has the revision we read; 409 otherwise."""
        return self.post(
            "/v1/rows/patch",
            {"table": table, "id": id, "values": values, "expected_revision": expected_revision},
        )

    def insert(self, table: str, rows: list[dict]) -> dict:
        """Create absent IDs, preserving existing rows including tombstones. No fallback."""
        if not rows:
            return {"inserted": [], "existing": [], "rejected": []}
        columns = sorted({k for r in rows for k in r})
        result = self.post("/v1/rows/insert", {"table": table, "columns": columns, "rows": rows})
        # A missing/ambiguous acknowledgment is uncertain, never proof of creation.
        try:
            if any(
                not isinstance(result[key], list) for key in ("inserted", "existing", "rejected")
            ):
                raise ValueError
            inserted, existing = set(result["inserted"]), set(result["existing"])
            rejected = {row["id"] for row in result["rejected"]}
            if (
                inserted & existing
                or inserted & rejected
                or existing & rejected
                or inserted | existing | rejected != {row["id"] for row in rows}
            ):
                raise ValueError
        except (KeyError, TypeError, ValueError):
            raise ValueError("Invalid insert acknowledgment") from None
        return result


class CachedHub:
    """The poller's reads, served from its own copy of the hub tables it reads.

    soma's table-pull helper keeps the copy current: one `/v1/cursor` request
    when nothing moved, otherwise only rows that arrived since the held cursor.
    A table the poller writes to is read again before its next use, so recovery
    and provenance repair see every committed write. `state` is the JSON the
    caller saves between runs; losing it costs one full read.
    """

    def __init__(self, hub: HubClient, state: dict | None = None):
        self._hub = hub
        if (state or {}).get("v") != STATE_VERSION or state.get("endpoint") != hub.url:
            state = {}
        self._pull = state.get("pull") or {"v": 1, "endpoint": hub.url, "tables": {}}
        self._rows = state.get("rows") or {}  # table -> {id: row}, tombstones included
        self._edges = {kind: set(ids) for kind, ids in (state.get("edges") or {}).items()}
        self._fresh = set()
        self.reads = {"requests": 0, "rows": 0}

    @property
    def state(self) -> dict:
        edges = {kind: sorted(ids) for kind, ids in self._edges.items()}
        return {
            "v": STATE_VERSION,
            "endpoint": self._hub.url,
            "pull": self._pull,
            "rows": self._rows,
            "edges": edges,
        }

    def _post(self, route: str, body: dict) -> dict:
        self.reads["requests"] += 1
        return self._hub.post(route, body)

    def refresh(self, tables=READS) -> None:
        """Bring stale tables up to date in one cursor round; errors leave the copy as it was."""
        stale = [t for t in tables if t not in self._fresh]
        if not stale:
            return
        out = pull_tables(
            self._hub.url, None, {t: READS[t] for t in stale}, self._pull, post=self._post
        )
        for table, change in out["changes"].items():
            rows = {} if change["full"] else self._rows.get(table, {})
            for row in change["rows"] + change["tombstones"]:
                rows[row["id"]] = row
            self._rows[table] = rows
            self.reads["rows"] += len(change["rows"]) + len(change["tombstones"])
        self._pull = {**out["state"], "tables": {**self._pull["tables"], **out["state"]["tables"]}}
        self._fresh.update(stale)

    def pull(self, table: str, columns: list[str], *, include_deleted: bool = False) -> list[dict]:
        if unknown := set(columns) - {"id", "hub_at", "deleted_at", *READS[table]}:
            raise ValueError(f"the {table} copy holds no {sorted(unknown)}")
        self.refresh([table])
        return [
            {c: row.get(c) for c in columns}
            for row in self._rows[table].values()
            if include_deleted or not row.get("deleted_at")
        ]

    def edge_ids(self, from_kind: str) -> set[str]:
        """Stored provenance IDs (tombstones included) that this kind's edges can collide with.

        Read once per kind, then kept current from insert acknowledgments. The
        read needs broad `tables:read`: soma has no narrow provenance read.
        """
        if from_kind not in self._edges:
            self._edges[from_kind] = self._edge_range(f"{from_kind}:")
        return self._edges[from_kind]

    def _edge_range(self, prefix: str) -> set[str]:
        # Edge IDs start with their source kind, so the slice is one primary-key range.
        ids, after = set(), prefix
        while True:
            pull = {"table": "provenance", "columns": ["id"], "since": "", "limit": SLICE_PAGE}
            page = self._post("/v1/rows/pull", {"batch": [{**pull, "after": after}]})["batch"][0]
            inside = [row["id"] for row in page["rows"] if row["id"].startswith(prefix)]
            ids.update(inside)
            self.reads["rows"] += len(page["rows"])
            if len(inside) < len(page["rows"]) or not page["next_cursor"]:
                return ids
            if page["next_cursor"] <= after:
                raise ValueError("provenance walk did not advance")
            after = page["next_cursor"]

    def insert(self, table: str, rows: list[dict]) -> dict:
        self._fresh.discard(table)
        result = self._hub.insert(table, rows)
        if table == "provenance":
            stored = set(result["inserted"]) | set(result["existing"])
            for row in rows:
                if row["id"] in stored and (known := self._edges.get(row["from_kind"])) is not None:
                    known.add(row["id"])
        return result

    def push(self, table: str, rows: list[dict]) -> dict:
        self._fresh.discard(table)
        return self._hub.push(table, rows)

    def patch(self, table: str, id: str, values: dict, expected_revision: dict) -> dict:
        self._fresh.discard(table)
        return self._hub.patch(table, id, values, expected_revision)


def load_state(path: Path) -> dict:
    """The previous run's cache; a missing or unreadable file means one full read."""
    try:
        return json.loads(gzip.decompress(path.read_bytes()))
    except (OSError, EOFError, ValueError):
        return {}


def save_state(path: Path, state: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_bytes(gzip.compress(json.dumps(state, separators=(",", ":")).encode()))
    os.replace(tmp, path)


def imported_from(
    from_kind: str, from_ref: str, to_kind: str, to_ref: str, *, created_row: bool = True
) -> dict:
    """Record the stored source relationship, distinguishing creation from repair.

    The id is soma's canonical `<from_kind>:<from_ref>:<to_kind>:<to_ref>`, which
    `provenance:create:<to_kind>` requires. Older edges omit `to_kind` (`legacy_edge_id`).
    """
    return {
        "id": f"{from_kind}:{from_ref}:{to_kind}:{to_ref}",
        "from_kind": from_kind,
        "from_ref": from_ref,
        "to_kind": to_kind,
        "to_ref": to_ref,
        "rel": "imported_from",
        "field": None,
        "detail": json.dumps({"created_row": int(created_row)}),
        "asserted_by": ASSERTED_BY,
        "updated_at": now_iso(),
    }


def legacy_edge_id(edge: dict) -> str:
    """The poller's older `<from_kind>:<from_ref>:<to_ref>` edge id; stored ones count as existing."""
    return f"{edge['from_kind']}:{edge['from_ref']}:{edge['to_ref']}"
