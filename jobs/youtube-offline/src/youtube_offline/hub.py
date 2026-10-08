"""Life Data hub client: durable-pull-v1 subscription, projected row pulls,
revision-checked patches and immutable checksummed files."""

from collections.abc import Callable

import httpx

USER_AGENT = "media-center-youtube-offline/0.1"


class HubError(Exception):
    def __init__(self, message: str, *, retry_after: float | None = None, credential=False):
        super().__init__(message)
        self.retry_after, self.credential = retry_after, credential


class RevisionConflict(Exception):
    pass


class Hub:
    def __init__(self, url: str, token: Callable[[], str], http: httpx.Client | None = None):
        self.url, self._read_token, self._token = url, token, None
        self.http = http or httpx.Client(timeout=httpx.Timeout(120, connect=10, write=900))

    def request(self, method: str, path: str, **kwargs) -> httpx.Response:
        # Read once, hold in memory, reread after a rejection (rotation needs no restart).
        self._token = self._token or self._read_token()
        headers = {
            "Authorization": f"Bearer {self._token}",
            "User-Agent": USER_AGENT,
            **kwargs.pop("headers", {}),
        }
        try:
            response = self.http.request(method, self.url + path, headers=headers, **kwargs)
        except httpx.HTTPError as error:
            raise HubError(f"{method} {path}: {type(error).__name__}") from None
        if response.status_code in (401, 403):
            self._token = None
            raise HubError(f"{method} {path}: {response.status_code}", credential=True)
        if response.status_code == 429 or response.status_code >= 500:
            retry = response.headers.get("Retry-After", "")
            raise HubError(
                f"{method} {path}: {response.status_code}",
                retry_after=float(retry) if retry.isdigit() else None,
            )
        return response

    def _json(self, method: str, path: str, body: dict) -> dict:
        response = self.request(method, path, json=body)
        if response.status_code == 409 and path == "/v1/rows/patch":
            raise RevisionConflict(body["id"])
        if response.status_code >= 400:
            raise HubError(f"{method} {path}: {response.status_code}")
        return response.json()

    # --- subscription -------------------------------------------------------

    def poll(self, subscription: str, wait: int) -> dict:
        response = self.request(
            "GET", f"/v1/subscriptions/{subscription}/events", params={"wait": wait}
        )
        if response.status_code >= 400:
            raise HubError(f"poll: {response.status_code}")
        body = response.json()
        if body.get("subscription_id") != subscription or not isinstance(body.get("events"), list):
            raise HubError("invalid delivery")
        return body

    def ack(self, subscription: str, delivery_id: str) -> None:
        response = self.request(
            "POST", f"/v1/subscriptions/{subscription}/ack", json={"delivery_id": delivery_id}
        )
        if response.status_code >= 400:  # 409: superseded; the next poll re-offers
            raise HubError(f"ack: {response.status_code}")

    # --- rows ---------------------------------------------------------------

    def rows(self, table: str, columns: list[str], where: dict) -> list[dict]:
        out, after = [], None
        while True:
            body = {"table": table, "columns": columns, "where": where, "limit": 200}
            if after:
                body["after"] = after
            page = self._json("POST", "/v1/rows/pull", body)
            out += page["rows"]
            after = page.get("next_cursor")
            if not after:
                return out

    def patch(self, table: str, row_id: str, values: dict, revision: dict) -> None:
        self._json(
            "POST",
            "/v1/rows/patch",
            {"table": table, "id": row_id, "values": values, "expected_revision": revision},
        )

    # --- files --------------------------------------------------------------

    def head_file(self, key: str) -> httpx.Response:
        return self.request("HEAD", f"/v1/files/{key}")

    def put_file(self, key: str, data: bytes, sha256: str, mime: str) -> httpx.Response:
        return self.request(
            "PUT",
            f"/v1/files/{key}",
            content=data,
            headers={"If-None-Match": "*", "Content-Type": mime, "X-Content-SHA256": sha256},
        )
