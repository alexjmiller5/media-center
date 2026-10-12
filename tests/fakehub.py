"""The hub's read protocol over a dict-of-lists test state: `/v1/cursor` and batched pulls.

A row's `hub_at` advances whenever its content changes, as an arrival would on the
real hub, so tests that edit `state` directly stay visible to incremental reads
without the stored rows gaining a key.
"""

import json
from datetime import UTC, datetime, timedelta

import httpx

EPOCH = datetime(2026, 10, 11, tzinfo=UTC)


def hub_reads(state, log=None):
    """`reads(request)` answers a hub read, or returns None for anything else."""
    seen = {}  # (table, id) -> (content, hub_at)
    tick = 0

    def stamped(table):
        nonlocal tick
        out = []
        for row in state.get(table, []):
            key, content = (table, row["id"]), json.dumps(row, sort_keys=True, default=str)
            if seen.get(key, ("",))[0] != content:
                tick += 1
                at = EPOCH + timedelta(milliseconds=tick)
                seen[key] = (content, at.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z")
            out.append({**row, "hub_at": seen[key][1]})
        return out

    def reads(request):
        if request.url.path not in ("/v1/cursor", "/v1/rows/pull"):
            return None
        body = json.loads(request.content)
        if log is not None:
            log.append((request.url.path, body))
        if request.url.path == "/v1/cursor":
            marks, at_mark = {}, {}
            for table in body["tables"]:
                rows = stamped(table)
                marks[table] = max((r["hub_at"] for r in rows), default="")
                at_mark[table] = sum(r["hub_at"] == marks[table] for r in rows)
            return httpx.Response(
                200,
                json={
                    "tables": marks,
                    "at_mark": at_mark,
                    "pull_batch": {"items": 50, "rows": 5000},
                },
            )
        pages = []
        for item in body["batch"]:
            rows = sorted(
                (
                    r
                    for r in stamped(item["table"])
                    if r["hub_at"] >= item["since"]
                    and r["id"] > item.get("after", "")
                    and all(r.get(k) == v for k, v in item.get("where", {}).items())
                ),
                key=lambda r: r["id"],
            )[: item["limit"]]
            pages.append(
                {
                    "rows": [{c: r.get(c) for c in item["columns"]} for r in rows],
                    "next_cursor": rows[-1]["id"] if len(rows) == item["limit"] else None,
                }
            )
        return httpx.Response(200, json={"batch": pages})

    return reads
