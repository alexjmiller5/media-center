"""life-data hub client - the one place media-center reads and writes rows.

Pull whole tables (`/v1/rows/pull`), atomically create missing rows
(`/v1/rows/insert`), and update only owned columns (`/v1/rows/push`).
Provenance edges use the same insert-only contract as new items.
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

    def pull(self, table: str, columns: list[str], *, include_deleted: bool = False) -> list[dict]:
        cols = list(columns) + (["deleted_at"] if "deleted_at" not in columns else [])
        resp = self._http.post(
            f"{self._url}/v1/rows/pull",
            json={"table": table, "columns": cols, "since": ""},
            headers=self._headers,
        )
        resp.raise_for_status()
        return [r for r in resp.json()["rows"] if include_deleted or not r.get("deleted_at")]

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

    def insert(self, table: str, rows: list[dict]) -> dict:
        """Create absent IDs, preserving existing rows including tombstones. No fallback."""
        if not rows:
            return {"inserted": [], "existing": [], "rejected": []}
        resp = self._http.post(
            f"{self._url}/v1/rows/insert",
            json={"table": table, "columns": sorted({k for r in rows for k in r}), "rows": rows},
            headers=self._headers,
        )
        resp.raise_for_status()
        result = resp.json()
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


def imported_from(
    from_kind: str, from_ref: str, to_kind: str, to_ref: str, *, created_row: bool = True
) -> dict:
    """Record the stored source relationship, distinguishing creation from repair."""
    return {
        "id": f"{from_kind}:{from_ref}:{to_ref}",
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
