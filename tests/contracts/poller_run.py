"""One poller ingestion against a contract hub, with synthetic upstream sources.

Usage: poller_run.py <hub url> <token> <state file> <new item suffix>
Prints the run result as JSON on stdout; logs go to stderr.
"""

import json
import sys
from pathlib import Path
from types import SimpleNamespace

import httpx
import structlog

from core.hub import CachedHub, HubClient, load_state, save_state
from core.pipeline import run_daily

hub_url, token, state_path, new = sys.argv[1:5]
structlog.configure(logger_factory=structlog.PrintLoggerFactory(sys.stderr))
state = Path(state_path)
RSS = """<?xml version="1.0"?><rss version="2.0"><channel><title>Feed</title>{}</channel></rss>"""


def upstream(request: httpx.Request) -> httpx.Response:
    host, path = request.url.host, request.url.path
    if host == "api.themoviedb.org":
        if "/season/" not in path:
            return httpx.Response(200, json={"seasons": [{"season_number": 1}]})
        ids = ["ep-linked", "ep-unlinked", f"ep-{new}"]
        episodes = [
            {"id": e, "season_number": 1, "episode_number": n, "name": f"Episode {n}"}
            for n, e in enumerate(ids, 1)
        ]
        return httpx.Response(200, json={"episodes": episodes})
    if host == "www.googleapis.com" and path.endswith("/playlistItems"):
        ids = [f"vid-{new}", "vid-linked", "vid-unlinked"]
        items = [{"snippet": {"resourceId": {"videoId": v}, "title": v}} for v in ids]
        return httpx.Response(200, json={"items": items})
    if host == "www.googleapis.com" and path.endswith("/videos"):
        ids = request.url.params["id"].split(",")
        return httpx.Response(
            200, json={"items": [{"id": v, "contentDetails": {"duration": "PT9M"}} for v in ids]}
        )
    if host == "feed.test":
        links = ["a-linked", "a-unlinked", f"a-{new}"]
        items = "".join(
            f"<item><title>{a}</title><link>https://feed.test/{a}</link></item>" for a in links
        )
        return httpx.Response(200, text=RSS.format(items))
    return httpx.Response(404)


hub = CachedHub(HubClient(hub_url, token), load_state(state))
settings = SimpleNamespace(tmdb_api_key="synthetic", youtube_api_key="synthetic")
with httpx.Client(transport=httpx.MockTransport(upstream)) as http:
    out = run_daily(hub, http, settings, lambda cache: save_state(state, cache))
print(json.dumps(out))
