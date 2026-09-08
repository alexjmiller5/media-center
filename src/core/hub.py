"""life-data hub client - the one place media-center reads and writes rows.

Pull whole tables (`/v1/rows/pull`), push only the columns we own
(`/v1/rows/push`; the hub's upsert touches exactly those). Provenance edges
are ordinary rows in the `provenance` table.
"""

import json
from datetime import UTC, datetime

import httpx

VERSION = "0.2"
ASSERTED_BY = "script:media-center"


def now_iso() -> str:
    now = datetime.now(UTC)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


class HubClient:
    def __init__(self, url: str, token: str, http: httpx.Client | None = None):
        self._url = url.rstrip("/")
        self._http = http or httpx.Client(timeout=120)
        self._headers = {
            "Authorization": f"Bearer {token}",
            "User-Agent": f"media-center/{VERSION}",
            "Content-Type": "application/json",
        }

    def pull(self, table: str, columns: list[str]) -> list[dict]:
        cols = list(columns) + (["deleted_at"] if "deleted_at" not in columns else [])
        resp = self._http.post(
            f"{self._url}/v1/rows/pull",
            json={"table": table, "columns": cols, "since": ""},
            headers=self._headers,
        )
        resp.raise_for_status()
        return [r for r in resp.json()["rows"] if not r.get("deleted_at")]

    def push(self, table: str, rows: list[dict]) -> dict:
        if not rows:
            return {"upserted": 0, "rejected": []}
        resp = self._http.post(
            f"{self._url}/v1/rows/push",
            json={"table": table, "columns": sorted({k for r in rows for k in r}), "rows": rows},
            headers=self._headers,
        )
        resp.raise_for_status()
        return resp.json()


def imported_from(from_kind: str, from_ref: str, to_kind: str, to_ref: str) -> dict:
    """The provenance edge that records which source row created an item row."""
    return {
        "id": f"{from_kind}:{from_ref}:{to_ref}",
        "from_kind": from_kind,
        "from_ref": from_ref,
        "to_kind": to_kind,
        "to_ref": to_ref,
        "rel": "imported_from",
        "field": None,
        "detail": json.dumps({"created_row": 1}),
        "asserted_by": ASSERTED_BY,
        "updated_at": now_iso(),
    }
