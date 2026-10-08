"""In-process fake of the Life Data hub routes the job uses (durable-pull-v1,
projected pull, revision-checked patch, immutable checksummed files)."""

import hashlib
import json
from datetime import UTC, datetime, timedelta

import httpx

SUB = "0f6c2f9e-1d2b-4c3a-9e8f-0123456789ab"
URL = "https://hub.example"
TABLE = "youtube_videos"
_clock = datetime(2026, 10, 8, tzinfo=UTC)


def stamp() -> str:
    global _clock
    _clock += timedelta(milliseconds=1)
    return _clock.strftime("%Y-%m-%dT%H:%M:%S.") + f"{_clock.microsecond // 1000:03d}Z"


class FakeHub:
    def __init__(self, rows=(), *, max_body=None):
        self.rows = {r["id"]: self.row(**r) for r in rows}
        self.files: dict[str, tuple[bytes, str]] = {}
        self.batches: list[dict] = []
        self.acks: list[str] = []
        self.patches: list[dict] = []
        self.fail_patch_conflicts = 0
        self.max_body = max_body
        self.status = None
        self.on_poll = None  # called once before the next events response

    @staticmethod
    def row(**values):
        base = {
            "deleted_at": None,
            "offline_requested": None,
            "offline_status": None,
            "offline_file": None,
            "offline_bytes": None,
            "offline_error": None,
        }
        t = stamp()
        return {**base, "updated_at": t, "hub_at": t, **values}

    def request_offline(self, video_id, value=1):
        """A user edit plus the subscription event it records."""
        self.edit(video_id, offline_requested=value)
        seq = str(len(self.acks) + len(self.batches) + 1)
        event = {
            "id": f"e{seq}",
            "seq": seq,
            "operation": "update",
            "source": {"table": TABLE, "row_id": video_id},
            "changes": [{"column": "offline_requested", "new_value": value}],
        }
        self.batches.append(
            {
                "subscription_id": SUB,
                "delivery_id": f"d{seq}",
                "through_seq": seq,
                "events": [event],
            }
        )

    def edit(self, video_id, **values):
        t = stamp()
        self.rows[video_id].update(values, updated_at=t, hub_at=t)

    def __call__(self, request: httpx.Request) -> httpx.Response:
        assert request.headers["authorization"] == "Bearer fixture-token"
        if self.status:
            return httpx.Response(self.status, json={"error": "x"})
        path, method = request.url.path, request.method
        if path == f"/v1/subscriptions/{SUB}/events":
            if self.on_poll:
                hook, self.on_poll = self.on_poll, None
                hook()
            if not self.batches:
                return httpx.Response(
                    200,
                    json={
                        "subscription_id": SUB,
                        "delivery_id": None,
                        "through_seq": "0",
                        "events": [],
                    },
                )
            return httpx.Response(200, json=self.batches[0])
        if path == f"/v1/subscriptions/{SUB}/ack":
            delivery = json.loads(request.content)["delivery_id"]
            assert self.batches and self.batches[0]["delivery_id"] == delivery
            self.acks.append(self.batches.pop(0)["delivery_id"])
            return httpx.Response(200, json={"acked_seq": "1"})
        if path == "/v1/rows/pull":
            return self.pull(json.loads(request.content))
        if path == "/v1/rows/patch":
            return self.patch(json.loads(request.content))
        if path.startswith("/v1/files/"):
            return self.file(method, path.removeprefix("/v1/files/"), request)
        return httpx.Response(404)

    def pull(self, body):
        assert body["table"] == TABLE and 1 <= body["limit"] <= 200
        rows = sorted(self.rows.values(), key=lambda r: r["id"])
        rows = [r for r in rows if all(r.get(k) == v for k, v in body.get("where", {}).items())]
        rows = [r for r in rows if r["id"] > body.get("after", "")][: body["limit"]]
        out = [{c: r.get(c) for c in body["columns"]} for r in rows]
        cursor = rows[-1]["id"] if len(rows) == body["limit"] else None
        return httpx.Response(200, json={"rows": out, "next_cursor": cursor})

    def patch(self, body):
        row = self.rows.get(body["id"])
        revision = body["expected_revision"]
        if self.fail_patch_conflicts:
            self.fail_patch_conflicts -= 1
            self.edit(body["id"], note="concurrent edit")
            return httpx.Response(409, json={"error": "revision_conflict"})
        if (
            row is None
            or row["deleted_at"]
            or (row["updated_at"], row["hub_at"]) != (revision["updated_at"], revision["hub_at"])
        ):
            return httpx.Response(409, json={"error": "revision_conflict"})
        assert set(body["values"]) <= {
            "offline_status",
            "offline_file",
            "offline_bytes",
            "offline_error",
        }
        self.patches.append({"id": body["id"], **body["values"]})
        self.edit(body["id"], **body["values"])
        return httpx.Response(200, json={"id": row["id"], "revision": {}})

    def file(self, method, key, request):
        assert key.startswith("youtube/")
        if method == "HEAD":
            if key not in self.files:
                return httpx.Response(404)
            data, mime = self.files[key]
            return httpx.Response(
                200,
                headers={
                    "Content-Length": str(len(data)),
                    "Content-Type": mime,
                    "X-Content-SHA256": hashlib.sha256(data).hexdigest(),
                },
            )
        assert method == "PUT" and request.headers["if-none-match"] == "*"
        data = request.content
        assert int(request.headers["content-length"]) == len(data)
        if self.max_body is not None and len(data) > self.max_body:
            return httpx.Response(413, json={"error": "too large"})
        digest = request.headers["x-content-sha256"]
        if hashlib.sha256(data).hexdigest() != digest:
            return httpx.Response(400, json={"error": "checksum_mismatch"})
        if key in self.files:
            return httpx.Response(412, json={"error": "file_exists"})
        self.files[key] = (data, request.headers["content-type"])
        return httpx.Response(
            201,
            json={
                "key": key,
                "mime": request.headers["content-type"],
                "bytes": len(data),
                "sha256": digest,
            },
        )
