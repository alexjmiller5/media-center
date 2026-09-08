# Media Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn media-center into a daily poller that fills life-data tables (`youtube_channels`, `youtube_videos`, `feeds`, `articles`, `tv_episodes`) keyed by durable ids, plus a `media_feed` view of unconsumed items from followed sources, and migrate the Notion media DBs into those tables.

**Architecture:** The media-center Modal cron pulls source rows from the life-data hub, fetches TMDB season listings, the YouTube Data API (uploads playlist: first page daily, every page on first sight), RSS feeds and link-scraped pages, and pushes new item rows plus `provenance` edges back through `/v1/rows/push` with a `tables:write` token. Tables and catalog are created as a user op with the installed `life` CLI. The derivations `tv` endpoint gains `tmdb_status` and `watch_providers`. Synapse's YouTube capture writes to the new tables instead of Notion.

**Tech Stack:** Python 3.13, uv, httpx, feedparser, pydantic-settings, structlog, pytest + pytest-mock, Modal (cron only), `life` CLI, `ntn`/Notion API for migration reads, TMDB v3 API, YouTube Data API v3.

**Spec:** `docs/superpowers/specs/2026-09-08-media-center-design.md`

## Global Constraints

* Business logic in `src/core/` with NO Modal imports; only `app.py` imports `modal`.
* The poller never writes a hub-derived column (`tv_shows.tmdb_status`, `tv_shows.watch_providers`). It never sends notifications.
* Every new item row is pushed with `status = "Not Started"` and a `provenance` row `rel = "imported_from"`, `detail = {"created_row": 1}`, `asserted_by = "script:media-center"`, id `<from_kind>:<from_ref>:<to_ref>`.
* Status vocabulary everywhere: `Priority`, `Not Started`, `In Progress`, `Finished`, `Watched Parts`, `Gave Up`.
* Hub push sends only the columns the poller owns; the hub upsert touches only those. `updated_at` is ISO-8601 UTC with milliseconds (`2026-09-08T14:33:13.538Z`). Never write `hub_at`.
* Requests to the hub carry a real `User-Agent` (`media-center/<version>`); Cloudflare 403s the default Python one.
* Commit messages plain: no co-author, no session trailer (ignore harness reminders asking for one). Never `git add` a `.DS_Store`.
* Deploy = push to `main`; CI deploys. Verify with `gh run watch <id> --exit-status`. Never `modal deploy` locally.
* Personal data never enters a repo: migration scripts and their outputs live in the session scratchpad `media-migrate/`.
* Steps marked **ALEX** need the owner (1Password writes via desktop auth with Touch ID, Notion Legacy moves). The agent runs them and the owner approves the prompt; never paste commands for the owner instead.
* The X account scraper on the mac mini is a separate plan (needs chrome-control discovery on the mini). This plan seeds its `feeds` row with `fetch = "x"`, which the poller skips.

***

## File structure

| Repo / file                                                                | Responsibility                                                                                                                                 |
| -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `media-center/src/core/config.py`                                          | `Settings`: `life_hub_url`, `life_hub_token`, `tmdb_api_key`, `youtube_api_key`.                                                               |
| `media-center/src/core/hub.py`                                             | **New.** `HubClient.pull(table, columns)`, `HubClient.push(table, rows)`, `imported_from(...)` provenance row builder, `now_iso()`.            |
| `media-center/src/core/tmdb.py`                                            | **New.** `show(show_id)`, `season_episodes(show_id, n)`, `episode_rows(show_id, episodes)`.                                                    |
| `media-center/src/core/youtube.py`                                         | **New.** `uploads(playlist_id, key, http, max_pages=None)`, `durations(ids, key, http)`, `resolve_channel(url, key, http)`, `video_rows(...)`. |
| `media-center/src/core/feeds.py`                                           | **New.** `canonical_url(url)`, `entries(feed_row, http)`, `scrape_links(html, base_url, pattern)`.                                             |
| `media-center/src/core/watcher.py`                                         | Keep `Entry`, `parse_feed`. Delete `Source`, `new_entries`, `route`.                                                                           |
| `media-center/src/core/pipeline.py`                                        | Rewrite: `run_daily(hub, http, settings)` -> `sync_tv`, `sync_youtube`, `sync_feeds`.                                                          |
| `media-center/src/core/notion.py`                                          | **Delete** (and `tests/test_notion.py`).                                                                                                       |
| `media-center/app.py`                                                      | Cron `daily` only (timeout 3600); `main()` local run. Webhook and `process` deleted.                                                           |
| `media-center/.env.tpl`, `justfile`, `AGENTS.md`, `README.md`              | New env vars; docs describe the current state.                                                                                                 |
| `media-center/tests/fixtures/`                                             | `tmdb_tv.json`, `tmdb_season.json`, `playlist_items.json`, `videos_list.json`, `links_page.html`, keep `rss2.xml`, `github_releases.atom`.     |
| `derivations/src/core/tmdb.py`, `tests/`                                   | `tv` returns `tmdb_status`, `watch_providers`.                                                                                                 |
| life-data catalog (user op, no repo change)                                | Tables, columns, options, view, `provenance.from_kind` options.                                                                                |
| `agent-config/skills/life-map/SKILL.md`                                    | New table contracts, media feed query, ID registry rows.                                                                                       |
| `synapse/src/core/handlers.py`, `databases.yaml`, `tests/test_handlers.py` | YouTube capture writes to life-data.                                                                                                           |
| scratchpad `media-migrate/`                                                | `channels.py`, `videos.py`, `articles.py`, `episodes.py`, `seed_feeds.py`; never committed.                                                    |

***

### Task 1: Settings and repo pruning

**Files:**

* Modify: `src/core/config.py`, `.env.tpl`, `tests/test_config.py`
* Delete: `src/core/notion.py`, `tests/test_notion.py`

**Interfaces:**

* Produces: `Settings` with fields `life_hub_url: str`, `life_hub_token: str`, `tmdb_api_key: str`, `youtube_api_key: str` (env `LIFE_HUB_URL`, `LIFE_HUB_TOKEN`, `TMDB_API_KEY`, `YOUTUBE_API_KEY`).

* [ ] **Step 1: Replace the config test**

`tests/test_config.py`:

```Python
from core.config import Settings


def test_settings_read_the_four_env_vars(monkeypatch):
    monkeypatch.setenv("LIFE_HUB_URL", "https://hub.example")
    monkeypatch.setenv("LIFE_HUB_TOKEN", "lt_x")
    monkeypatch.setenv("TMDB_API_KEY", "tmdb")
    monkeypatch.setenv("YOUTUBE_API_KEY", "yt")
    s = Settings()
    assert s.life_hub_url == "https://hub.example"
    assert s.life_hub_token == "lt_x"
    assert s.tmdb_api_key == "tmdb"
    assert s.youtube_api_key == "yt"
```

* [ ] **Step 2: Run** `uv run pytest tests/test_config.py -v` -> FAIL (`Settings` has no `life_hub_url`).

* [ ] **Step 3: Rewrite** **`src/core/config.py`**

```Python
"""Settings from env vars - Modal Secret in the cloud, `op run` locally.

Instantiate Settings() inside functions, never at import time.
"""

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    life_hub_url: str
    life_hub_token: str
    tmdb_api_key: str
    youtube_api_key: str
```

* [ ] **Step 4: Rewrite** **`.env.tpl`** (names, not ids: this file is the bootstrap manifest)

```
# Canonical secrets manifest - 1Password secret references only, SAFE to commit.
# Refs are BY NAME on purpose: op-project-bootstrap parses this file.
# Local dev:       op run --env-file=.env.tpl -- <cmd>   (see justfile)
# Push to Modal:   just sync-secrets
LIFE_HUB_URL=op://Media Center/Media Center ENV/LIFE_HUB_URL
LIFE_HUB_TOKEN=op://Media Center/Media Center ENV/LIFE_HUB_TOKEN
TMDB_API_KEY=op://Media Center/Media Center ENV/TMDB_API_KEY
YOUTUBE_API_KEY=op://Media Center/Media Center ENV/YOUTUBE_API_KEY
```

* [ ] **Step 5: Delete the Notion client** `git rm src/core/notion.py tests/test_notion.py`. `tests/test_pipeline.py` and `tests/test_watcher.py` will break; they are rewritten in Tasks 5 and 6. For now run `uv run pytest tests/test_config.py -v` -> PASS.

* [ ] **Step 6: Commit** `git add -A && git commit -m "Settings for the life-data hub, TMDB and YouTube; drop the Notion client"`

***

### Task 2: Hub client

**Files:**

* Create: `src/core/hub.py`, `tests/test_hub.py`

**Interfaces:**

* Produces:
  * `now_iso() -> str` ISO-8601 UTC with milliseconds and `Z`.
  * `class HubClient(url: str, token: str, http: httpx.Client | None = None)` with `pull(table: str, columns: list[str]) -> list[dict]` (drops rows whose `deleted_at` is set; always requests `deleted_at`), `push(table: str, rows: list[dict]) -> dict` (`{"upserted": n, "rejected": [...]}`; raises `httpx.HTTPStatusError` on non-2xx; returns `{"upserted": 0, "rejected": []}` without a request when `rows` is empty).
  * `imported_from(from_kind: str, from_ref: str, to_kind: str, to_ref: str) -> dict` provenance row.

* [ ] **Step 1: Write the failing tests**

```Python
import json

import httpx
import pytest

from core.hub import HubClient, imported_from, now_iso


def make_client(handler):
    transport = httpx.MockTransport(handler)
    return HubClient("https://hub.example", "lt_test", http=httpx.Client(transport=transport))


def test_now_iso_is_utc_with_millis():
    s = now_iso()
    assert s.endswith("Z") and len(s) == 24 and s[19] == "."


def test_pull_requests_deleted_at_and_drops_deleted_rows():
    seen = {}

    def handler(request):
        seen["body"] = json.loads(request.content)
        seen["headers"] = request.headers
        return httpx.Response(200, json={"rows": [
            {"id": "a", "follow": 1, "deleted_at": None},
            {"id": "b", "follow": 1, "deleted_at": "2026-01-01T00:00:00.000Z"},
        ]})

    rows = make_client(handler).pull("youtube_channels", ["id", "follow"])
    assert [r["id"] for r in rows] == ["a"]
    assert seen["body"] == {"table": "youtube_channels", "columns": ["id", "follow", "deleted_at"], "since": ""}
    assert seen["headers"]["authorization"] == "Bearer lt_test"
    assert seen["headers"]["user-agent"].startswith("media-center/")


def test_push_sends_sorted_column_union_and_returns_result():
    seen = {}

    def handler(request):
        seen["body"] = json.loads(request.content)
        return httpx.Response(200, json={"upserted": 2, "rejected": []})

    out = make_client(handler).push("youtube_videos", [{"id": "v1", "title": "T"}, {"id": "v2", "status": "Not Started"}])
    assert out == {"upserted": 2, "rejected": []}
    assert seen["body"]["table"] == "youtube_videos"
    assert seen["body"]["columns"] == ["id", "status", "title"]
    assert seen["body"]["rows"][0] == {"id": "v1", "title": "T"}


def test_push_empty_makes_no_request():
    def handler(request):  # pragma: no cover - must not be called
        raise AssertionError("no request expected")

    assert make_client(handler).push("youtube_videos", []) == {"upserted": 0, "rejected": []}


def test_push_raises_on_http_error():
    client = make_client(lambda request: httpx.Response(500, text="boom"))
    with pytest.raises(httpx.HTTPStatusError):
        client.push("youtube_videos", [{"id": "v1"}])


def test_imported_from_row_shape():
    row = imported_from("youtube_channels", "UC123", "youtube_videos", "abc")
    assert row["id"] == "youtube_channels:UC123:abc"
    assert row["from_kind"] == "youtube_channels" and row["from_ref"] == "UC123"
    assert row["to_kind"] == "youtube_videos" and row["to_ref"] == "abc"
    assert row["rel"] == "imported_from"
    assert row["asserted_by"] == "script:media-center"
    assert json.loads(row["detail"]) == {"created_row": 1}
    assert row["field"] is None
    assert row["updated_at"].endswith("Z")
```

* [ ] **Step 2: Run** `uv run pytest tests/test_hub.py -v` -> FAIL (no module `core.hub`).

* [ ] **Step 3: Implement** **`src/core/hub.py`**

```Python
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
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%S.") + f"{datetime.now(UTC).microsecond // 1000:03d}Z"


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
```

* [ ] **Step 4: Run** `uv run pytest tests/test_hub.py -v` -> PASS.

* [ ] **Step 5: Commit** `git add src/core/hub.py tests/test_hub.py && git commit -m "Hub client: pull tables, push owned columns, imported_from edges"`

***

### Task 3: TMDB episodes

**Files:**

* Create: `src/core/tmdb.py`, `tests/test_tmdb.py`, `tests/fixtures/tmdb_tv.json`, `tests/fixtures/tmdb_season.json`

**Interfaces:**

* Produces:
  * `show(show_id: str, key: str, http: httpx.Client) -> dict` (raw `/tv/{id}` JSON).
  * `season_numbers(show_json: dict) -> list[int]` (every season number including 0 specials).
  * `season_episodes(show_id: str, n: int, key: str, http: httpx.Client) -> list[dict]` (raw `episodes` list).
  * `episode_rows(show_id: str, episodes: list[dict]) -> list[dict]` rows `{id, show_id, season, episode, title, air_date, runtime_min, status, updated_at}` with `id = str(episode["id"])`, `status = "Not Started"`.

* [ ] **Step 1: Record fixtures** (TMDB responses carry no personal data). Key via desktop auth, value never printed:

```Shell
mkdir -p tests/fixtures && K=$(zsh -ic 'op-personal read "op://Derivations/Derivations ENV/TMDB_API_KEY"' 2>/dev/null | tail -1)
curl -s "https://api.themoviedb.org/3/tv/76479?api_key=$K" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["seasons"]=d["seasons"][:3]; print(json.dumps({k:d[k] for k in ("id","name","status","seasons","last_episode_to_air","next_episode_to_air")}, indent=1))' > tests/fixtures/tmdb_tv.json
curl -s "https://api.themoviedb.org/3/tv/76479/season/1?api_key=$K" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["episodes"]=[{k:e.get(k) for k in ("id","name","air_date","runtime","episode_number","season_number")} for e in d["episodes"][:3]]; print(json.dumps(d, indent=1))' > tests/fixtures/tmdb_season.json
```

(76479 = The Boys.) Confirm `tests/fixtures/tmdb_tv.json` has `"status": "Returning Series"` or `"Ended"` and 3 seasons; `tmdb_season.json` has 3 episodes with integer `id`.

* [ ] **Step 2: Write the failing tests**

```Python
import json
from pathlib import Path

import httpx

from core import tmdb

FIX = Path(__file__).parent / "fixtures"


def fixture(name):
    return json.loads((FIX / name).read_text())


def test_show_hits_tv_endpoint_with_key():
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        return httpx.Response(200, json=fixture("tmdb_tv.json"))

    http = httpx.Client(transport=httpx.MockTransport(handler))
    data = tmdb.show("76479", "KEY", http)
    assert data["id"] == 76479
    assert seen["url"].startswith("https://api.themoviedb.org/3/tv/76479?")
    assert "api_key=KEY" in seen["url"]


def test_season_numbers_includes_every_listed_season():
    assert tmdb.season_numbers(fixture("tmdb_tv.json")) == sorted(
        s["season_number"] for s in fixture("tmdb_tv.json")["seasons"]
    )


def test_season_episodes_returns_the_episodes_list():
    http = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json=fixture("tmdb_season.json"))))
    eps = tmdb.season_episodes("76479", 1, "KEY", http)
    assert len(eps) == 3 and eps[0]["episode_number"] == 1


def test_episode_rows_shape():
    rows = tmdb.episode_rows("76479", fixture("tmdb_season.json")["episodes"])
    first = fixture("tmdb_season.json")["episodes"][0]
    assert rows[0]["id"] == str(first["id"])
    assert rows[0]["show_id"] == "76479"
    assert rows[0]["season"] == first["season_number"]
    assert rows[0]["episode"] == first["episode_number"]
    assert rows[0]["title"] == first["name"]
    assert rows[0]["air_date"] == first["air_date"]
    assert rows[0]["runtime_min"] == first["runtime"]
    assert rows[0]["status"] == "Not Started"
    assert rows[0]["updated_at"].endswith("Z")
```

* [ ] **Step 3: Run** `uv run pytest tests/test_tmdb.py -v` -> FAIL.

* [ ] **Step 4: Implement** **`src/core/tmdb.py`**

```Python
"""TMDB season listings for tv_episodes rows. Plain Python, no Modal."""

import httpx

from core.hub import now_iso

BASE = "https://api.themoviedb.org/3"


def show(show_id: str, key: str, http: httpx.Client) -> dict:
    resp = http.get(f"{BASE}/tv/{show_id}", params={"api_key": key}, timeout=15)
    resp.raise_for_status()
    return resp.json()


def season_numbers(show_json: dict) -> list[int]:
    return sorted(s["season_number"] for s in show_json.get("seasons") or [])


def season_episodes(show_id: str, n: int, key: str, http: httpx.Client) -> list[dict]:
    resp = http.get(f"{BASE}/tv/{show_id}/season/{n}", params={"api_key": key}, timeout=15)
    resp.raise_for_status()
    return resp.json().get("episodes") or []


def episode_rows(show_id: str, episodes: list[dict]) -> list[dict]:
    stamp = now_iso()
    return [
        {
            "id": str(e["id"]),
            "show_id": show_id,
            "season": e["season_number"],
            "episode": e["episode_number"],
            "title": e.get("name"),
            "air_date": e.get("air_date"),
            "runtime_min": e.get("runtime"),
            "status": "Not Started",
            "updated_at": stamp,
        }
        for e in episodes
    ]
```

* [ ] **Step 5: Run** `uv run pytest tests/test_tmdb.py -v` -> PASS.

* [ ] **Step 6: Commit** `git add src/core/tmdb.py tests/test_tmdb.py tests/fixtures/tmdb_*.json && git commit -m "TMDB season listings to tv_episodes rows"`

***

### Task 4: YouTube channels and videos

**Files:**

* Create: `src/core/youtube.py`, `tests/test_youtube.py`, `tests/fixtures/playlist_items.json`, `tests/fixtures/videos_list.json`

**Interfaces:**

* Produces:
  * `uploads(playlist_id: str, key: str, http, max_pages: int | None = None) -> list[dict]` `{id, title, published_at}` per video in the uploads playlist (newest first), following `nextPageToken` until exhausted or `max_pages` pages. `max_pages=1` is the daily delta (50 newest, 1 quota unit); `None` is the back catalog. YouTube's per-channel RSS is NOT used: it 404s for some channels (Fireship, verified 2026-09-08) while the Data API serves them.
  * `durations(video_ids: list[str], key: str, http) -> dict[str, int]` seconds via `videos.list part=contentDetails`, batches of 50.
  * `resolve_channel(url: str, key: str, http) -> dict | None` `{id, title, handle, uploads_playlist_id}` for `/channel/UC..`, `/@handle`, `/c/name`, `/user/name`, bare `youtube.com/name` URLs.
  * `video_rows(channel_id: str, videos: list[dict], durations: dict[str, int]) -> list[dict]` rows `{id, channel_id, title, published_at, duration_s, thumbnail_url, is_short, status, updated_at}`; `is_short = duration_s is not None and duration_s <= 180`; `thumbnail_url = https://i.ytimg.com/vi/<id>/hqdefault.jpg`.
  * `parse_iso8601_duration("PT1H2M3S") -> 3723`.

* [ ] **Step 1: Record fixtures**

```Shell
K=$(op read "op://4eeyrkqibibn7k4j6rz2fbzvxm/$(op item list --vault 4eeyrkqibibn7k4j6rz2fbzvxm --format json | jq -r '.[] | select(.title | test("YouTube"; "i")) | .id' | head -1)/credential" 2>/dev/null)
```

If no YouTube key item exists in the AI Agent vault, read Synapse's via desktop auth: `K=$(zsh -ic 'op-personal read "op://Synapse/Synapse ENV/GOOGLE_YOUTUBE_API_KEY"' | tail -1)`. Then:

```Shell
curl -s "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet&maxResults=3&playlistId=UUHnyfMqiRRG1u-2MsSQLbXA&key=$K" > tests/fixtures/playlist_items.json
IDS=$(python3 -c 'import json; print(",".join(i["snippet"]["resourceId"]["videoId"] for i in json.load(open("tests/fixtures/playlist_items.json"))["items"]))')
curl -s "https://www.googleapis.com/youtube/v3/videos?part=contentDetails&id=$IDS&key=$K" > tests/fixtures/videos_list.json
```

Check `playlist_items.json` has `nextPageToken` and 3 items; `videos_list.json` items carry `contentDetails.duration`.

* [ ] **Step 2: Write the failing tests**

```Python
import json
from pathlib import Path

import httpx

from core import youtube

FIX = Path(__file__).parent / "fixtures"


def route(table):
    """table: list of (url_substring, json_or_text)."""

    def handler(request):
        for needle, payload in table:
            if needle in str(request.url):
                return httpx.Response(200, json=payload) if isinstance(payload, dict) else httpx.Response(200, text=payload)
        return httpx.Response(404)

    return httpx.Client(transport=httpx.MockTransport(handler))


def test_uploads_follows_next_page_token():
    page1 = json.loads((FIX / "playlist_items.json").read_text())
    page2 = dict(page1)
    page2 = {**page1, "items": page1["items"][:1]}
    page2.pop("nextPageToken", None)
    calls = []

    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(200, json=page2 if "pageToken=" in str(request.url) else page1)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    vids = youtube.uploads("UUHnyfMqiRRG1u-2MsSQLbXA", "KEY", http)
    assert len(vids) == len(page1["items"]) + 1
    assert len(calls) == 2 and "pageToken=" + page1["nextPageToken"] in calls[1]
    assert "playlistId=UUHnyfMqiRRG1u-2MsSQLbXA" in calls[0] and "key=KEY" in calls[0]


def test_uploads_max_pages_stops_after_first_page():
    page1 = json.loads((FIX / "playlist_items.json").read_text())
    calls = []

    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(200, json=page1)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    vids = youtube.uploads("UUHnyfMqiRRG1u-2MsSQLbXA", "KEY", http, max_pages=1)
    assert len(vids) == len(page1["items"]) and len(calls) == 1
    assert vids[0]["published_at"] == page1["items"][0]["snippet"]["publishedAt"]


def test_durations_batches_by_50_and_parses_iso():
    payload = json.loads((FIX / "videos_list.json").read_text())
    calls = []

    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(200, json=payload)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    ids = [f"id{i:08d}xyz"[:11] for i in range(120)]
    out = youtube.durations(ids, "KEY", http)
    assert len(calls) == 3
    real = payload["items"][0]
    assert out[real["id"]] == youtube.parse_iso8601_duration(real["contentDetails"]["duration"])


def test_parse_iso8601_duration():
    assert youtube.parse_iso8601_duration("PT1H2M3S") == 3723
    assert youtube.parse_iso8601_duration("PT45S") == 45
    assert youtube.parse_iso8601_duration("P1DT1S") == 86401


def test_resolve_channel_by_handle_and_by_id():
    chan = {"items": [{"id": "UCHnyfMqiRRG1u-2MsSQLbXA", "snippet": {"title": "Veritasium", "customUrl": "@veritasium"},
                       "contentDetails": {"relatedPlaylists": {"uploads": "UUHnyfMqiRRG1u-2MsSQLbXA"}}}]}
    calls = []

    def handler(request):
        calls.append(str(request.url))
        return httpx.Response(200, json=chan)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    a = youtube.resolve_channel("https://www.youtube.com/@veritasium", "KEY", http)
    b = youtube.resolve_channel("https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA", "KEY", http)
    assert a == b == {"id": "UCHnyfMqiRRG1u-2MsSQLbXA", "title": "Veritasium", "handle": "@veritasium",
                      "uploads_playlist_id": "UUHnyfMqiRRG1u-2MsSQLbXA"}
    assert "forHandle=veritasium" in calls[0]
    assert "id=UCHnyfMqiRRG1u-2MsSQLbXA" in calls[1]


def test_resolve_channel_returns_none_when_unknown():
    http = httpx.Client(transport=httpx.MockTransport(lambda r: httpx.Response(200, json={"items": []})))
    assert youtube.resolve_channel("https://www.youtube.com/@nobody", "KEY", http) is None


def test_video_rows_shape_and_short_flag():
    rows = youtube.video_rows("UC1", [{"id": "abcdefghijk", "title": "T", "published_at": "2026-01-01T00:00:00Z"}], {"abcdefghijk": 90})
    r = rows[0]
    assert r["id"] == "abcdefghijk" and r["channel_id"] == "UC1" and r["title"] == "T"
    assert r["duration_s"] == 90 and r["is_short"] == 1
    assert r["thumbnail_url"] == "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"
    assert r["status"] == "Not Started" and r["updated_at"].endswith("Z")
    assert youtube.video_rows("UC1", [{"id": "x", "title": "T", "published_at": None}], {})[0]["is_short"] == 0
```

* [ ] **Step 3: Run** `uv run pytest tests/test_youtube.py -v` -> FAIL.

* [ ] **Step 4: Implement** **`src/core/youtube.py`**

```Python
"""YouTube channels and videos through the Data API: the uploads playlist
(first page = daily delta, all pages = back catalog), durations and channel
resolution. No Modal imports. Per-channel RSS is deliberately not used: it
404s for some channels the API serves fine."""

import re
from urllib.parse import urlparse

import httpx

from core.hub import now_iso

API = "https://www.googleapis.com/youtube/v3"
SHORT_MAX_S = 180
_DUR = re.compile(r"P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?")


def parse_iso8601_duration(s: str) -> int:
    d, h, m, sec = (int(x or 0) for x in _DUR.fullmatch(s).groups())
    return d * 86400 + h * 3600 + m * 60 + sec


def uploads(playlist_id: str, key: str, http: httpx.Client, max_pages: int | None = None) -> list[dict]:
    out, token, pages = [], None, 0
    while True:
        params = {"part": "snippet", "maxResults": 50, "playlistId": playlist_id, "key": key}
        if token:
            params["pageToken"] = token
        resp = http.get(f"{API}/playlistItems", params=params, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        for item in data.get("items", []):
            sn = item["snippet"]
            out.append({"id": sn["resourceId"]["videoId"], "title": sn.get("title", ""), "published_at": sn.get("publishedAt")})
        token = data.get("nextPageToken")
        pages += 1
        if not token or (max_pages is not None and pages >= max_pages):
            return out


def durations(video_ids: list[str], key: str, http: httpx.Client) -> dict[str, int]:
    out = {}
    for i in range(0, len(video_ids), 50):
        batch = video_ids[i : i + 50]
        resp = http.get(f"{API}/videos", params={"part": "contentDetails", "id": ",".join(batch), "key": key}, timeout=30)
        resp.raise_for_status()
        for item in resp.json().get("items", []):
            out[item["id"]] = parse_iso8601_duration(item["contentDetails"]["duration"])
    return out


def _channel_query(url: str) -> dict | None:
    path = urlparse(url).path.strip("/")
    if not path:
        return None
    if path.startswith("channel/"):
        return {"id": path.split("/")[1]}
    if path.startswith("@"):
        return {"forHandle": path.split("/")[0][1:]}
    if path.startswith(("c/", "user/")):
        return {"forHandle": path.split("/")[1]}
    return {"forHandle": path.split("/")[0]}


def resolve_channel(url: str, key: str, http: httpx.Client) -> dict | None:
    query = _channel_query(url)
    if not query:
        return None
    resp = http.get(f"{API}/channels", params={"part": "snippet,contentDetails", "key": key, **query}, timeout=20)
    resp.raise_for_status()
    items = resp.json().get("items") or []
    if not items:
        return None
    ch = items[0]
    return {
        "id": ch["id"],
        "title": ch["snippet"]["title"],
        "handle": ch["snippet"].get("customUrl"),
        "uploads_playlist_id": ch["contentDetails"]["relatedPlaylists"]["uploads"],
    }


def video_rows(channel_id: str, videos: list[dict], durations: dict[str, int]) -> list[dict]:
    stamp = now_iso()
    rows = []
    for v in videos:
        d = durations.get(v["id"])
        rows.append({
            "id": v["id"],
            "channel_id": channel_id,
            "title": v["title"],
            "published_at": v.get("published_at"),
            "duration_s": d,
            "thumbnail_url": f"https://i.ytimg.com/vi/{v['id']}/hqdefault.jpg",
            "is_short": 1 if d is not None and d <= SHORT_MAX_S else 0,
            "status": "Not Started",
            "updated_at": stamp,
        })
    return rows
```

* [ ] **Step 5: Run** `uv run pytest tests/test_youtube.py -v` -> PASS.

* [ ] **Step 6: Commit** `git add src/core/youtube.py tests/test_youtube.py tests/fixtures/playlist_items.json tests/fixtures/videos_list.json && git commit -m "YouTube: uploads playlist delta and back catalog, durations, channel resolution"`

***

### Task 5: Feeds and the link scraper

**Files:**

* Create: `src/core/feeds.py`, `tests/test_feeds.py`, `tests/fixtures/links_page.html`
* Modify: `src/core/watcher.py` (keep `Entry`, `parse_feed`; delete `Source`, `new_entries`, `route`), `tests/test_watcher.py` (drop the `new_entries`/`route` tests). feedparser stays a dependency for RSS feeds only.

**Interfaces:**

* Consumes: `watcher.parse_feed(text) -> list[Entry]` (`Entry(guid, title, url, published)`).

* Produces:
  * `canonical_url(url: str) -> str`: lowercase scheme+host, drop fragment, drop query params starting with `utm_` and the params `si`, `ref`, `fbclid`, `gclid`, keep the rest sorted, strip a trailing `/` on paths longer than `/`.
  * `scrape_links(html: str, base_url: str, pattern: str) -> list[Entry]`: every `<a href>` whose absolute href matches `pattern` (regex `search`), `title` = link text stripped, `guid = url`, `published = None`, deduplicated by url in document order.
  * `entries(feed_row: dict, http) -> list[Entry]`: `fetch == "rss"` -> GET `feed_row["id"]` and `parse_feed`; `fetch == "scrape:links"` -> GET and `scrape_links(text, id, feed_row["scrape_pattern"])`; `fetch == "x"` -> `[]`.
  * `article_rows(feed_id: str, items: list[Entry]) -> list[dict]` rows `{id: canonical_url(url), feed_id, title, published_at, status: "Not Started", updated_at}`.

* [ ] **Step 1: Write the fixture** `tests/fixtures/links_page.html`

```HTML
<html><body>
<nav><a href="/">Home</a><a href="/changelog">Changelog</a></nav>
<main>
<a href="/changelog/2026-09-01">Version 2.3: Faster search</a>
<a href="https://example.com/changelog/2026-08-15?utm_source=x">Version 2.2</a>
<a href="/changelog/2026-08-15">Version 2.2</a>
<a href="/blog/unrelated">Not a changelog</a>
</main></body></html>
```

* [ ] **Step 2: Write the failing tests**

```Python
from pathlib import Path

import httpx

from core import feeds
from core.watcher import Entry

FIX = Path(__file__).parent / "fixtures"


def test_canonical_url_strips_tracking_and_normalises():
    assert feeds.canonical_url("HTTPS://Example.com/a/b/?utm_source=x&si=1&b=2&a=1#frag") == "https://example.com/a/b?a=1&b=2"
    assert feeds.canonical_url("https://example.com/") == "https://example.com/"


def test_scrape_links_matches_pattern_and_dedupes():
    html = (FIX / "links_page.html").read_text()
    out = feeds.scrape_links(html, "https://example.com/changelog", r"/changelog/\d{4}-\d{2}-\d{2}")
    assert [e.url for e in out] == ["https://example.com/changelog/2026-09-01", "https://example.com/changelog/2026-08-15"]
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
    scraped = feeds.entries({"id": "https://example.com/changelog", "fetch": "scrape:links", "scrape_pattern": r"/changelog/\d{4}"}, http)
    assert len(scraped) == 2
    assert feeds.entries({"id": "https://x.com/someone", "fetch": "x"}, http) == []
    assert len(seen) == 2


def test_article_rows_use_canonical_url_as_id():
    rows = feeds.article_rows("https://blog.example.com/rss", [Entry(guid="g", title="T", url="https://Blog.example.com/p?utm_x=1", published=None)])
    assert rows[0]["id"] == "https://blog.example.com/p"
    assert rows[0]["feed_id"] == "https://blog.example.com/rss"
    assert rows[0]["title"] == "T" and rows[0]["published_at"] is None
    assert rows[0]["status"] == "Not Started" and rows[0]["updated_at"].endswith("Z")
```

* [ ] **Step 3: Run** `uv run pytest tests/test_feeds.py -v` -> FAIL.

* [ ] **Step 4: Implement** **`src/core/feeds.py`**

```Python
"""RSS feeds and no-feed pages -> article rows. No Modal imports."""

import re
from html.parser import HTMLParser
from urllib.parse import parse_qsl, urlencode, urljoin, urlparse, urlunparse

import httpx

from core.hub import now_iso
from core.watcher import Entry, parse_feed

DROP_PARAMS = {"si", "ref", "fbclid", "gclid"}


def canonical_url(url: str) -> str:
    p = urlparse(url.strip())
    query = sorted((k, v) for k, v in parse_qsl(p.query, keep_blank_values=True) if not k.startswith("utm_") and k not in DROP_PARAMS)
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
    seen, out = set(), []
    for href, text in parser.links:
        url = canonical_url(urljoin(base_url, href))
        if not rx.search(url) or url in seen:
            continue
        seen.add(url)
        out.append(Entry(guid=url, title=text, url=url, published=None))
    return out


def entries(feed_row: dict, http: httpx.Client) -> list[Entry]:
    fetch = feed_row["fetch"]
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
            "id": canonical_url(e.url),
            "feed_id": feed_id,
            "title": e.title,
            "published_at": e.published.strftime("%Y-%m-%dT%H:%M:%S.000Z") if e.published else None,
            "status": "Not Started",
            "updated_at": stamp,
        }
        for e in items
        if e.url
    ]
```

* [ ] **Step 5: Trim** **`src/core/watcher.py`** to `Entry` + `parse_feed` (delete `Source`, `new_entries`, `route` and the `dataclass Source` block). In `tests/test_watcher.py` delete every test that references `new_entries`, `route` or `Source`; keep the `parse_feed` tests.

* [ ] **Step 6: Run** `uv run pytest tests/test_feeds.py tests/test_watcher.py -v` -> PASS.

* [ ] **Step 7: Commit** `git add -A && git commit -m "Feeds: canonical URLs, generic link scraper, article rows; trim watcher"`

***

### Task 6: Daily pipeline, cron shim, docs

**Files:**

* Rewrite: `src/core/pipeline.py`, `tests/test_pipeline.py`, `app.py`, `AGENTS.md`, `README.md`, `justfile` (remove `dev`; keep test/check/fmt/logs/sync-secrets/deploy)

**Interfaces:**

* Consumes: `HubClient`, `imported_from`, `tmdb.*`, `youtube.*`, `feeds.*`.

* Produces: `run_daily(hub: HubClient, http: httpx.Client, settings: Settings) -> dict` returning `{"tv": {"shows": n, "episodes": n, "failed": n}, "youtube": {"channels": n, "videos": n, "failed": n}, "feeds": {"feeds": n, "articles": n, "failed": n}}`; `sync_tv(hub, http, key)`, `sync_youtube(hub, http, key)`, `sync_feeds(hub, http)` with the same per-kind dict shape. Batch pushes in chunks of 200 rows.

* [ ] **Step 1: Write the failing tests** (`tests/test_pipeline.py`)

```Python
import json
from pathlib import Path

import httpx

from core import pipeline

FIX = Path(__file__).parent / "fixtures"


class FakeHub:
    def __init__(self, tables):
        self.tables = tables            # table -> list[dict]
        self.pushed = {}                # table -> list[dict]

    def pull(self, table, columns):
        return [{c: r.get(c) for c in columns} for r in self.tables.get(table, [])]

    def push(self, table, rows):
        self.pushed.setdefault(table, []).extend(rows)
        return {"upserted": len(rows), "rejected": []}


def http_for(table):
    def handler(request):
        url = str(request.url)
        for needle, payload in table:
            if needle in url:
                if isinstance(payload, Exception):
                    raise payload
                return httpx.Response(200, json=payload) if isinstance(payload, dict) else httpx.Response(200, text=payload)
        return httpx.Response(404, text=url)
    return httpx.Client(transport=httpx.MockTransport(handler))


def fx(name):
    return json.loads((FIX / name).read_text())


def test_sync_tv_ingests_missing_episodes_with_provenance():
    season = fx("tmdb_season.json")
    known = str(season["episodes"][0]["id"])
    hub = FakeHub({
        "tv_shows": [{"id": "76479", "tmdb_status": "Returning Series"}, {"id": "1", "tmdb_status": "Ended"}],
        "tv_episodes": [{"id": known, "show_id": "76479"}],
    })
    show = {**fx("tmdb_tv.json"), "seasons": [{"season_number": 1}]}
    http = http_for([("/tv/76479/season/1", season), ("/tv/76479?", show), ("/tv/1/season/1", season), ("/tv/1?", show)])
    out = pipeline.sync_tv(hub, http, "KEY")
    # Ended show with no episodes is fetched once; returning show fetched; known episode skipped
    assert out["shows"] == 2 and out["failed"] == 0
    ids = {r["id"] for r in hub.pushed["tv_episodes"]}
    assert known not in ids and len(ids) == 2 * 3 - 1
    prov = hub.pushed["provenance"]
    assert all(p["from_kind"] == "tv_shows" and p["to_kind"] == "tv_episodes" and p["rel"] == "imported_from" for p in prov)
    assert len(prov) == len(ids)


def test_sync_tv_skips_ended_shows_that_already_have_episodes():
    hub = FakeHub({"tv_shows": [{"id": "1", "tmdb_status": "Ended"}], "tv_episodes": [{"id": "9", "show_id": "1"}]})
    http = http_for([])  # any request would 404 -> failure
    out = pipeline.sync_tv(hub, http, "KEY")
    assert out == {"shows": 1, "episodes": 0, "failed": 0}
    assert "tv_episodes" not in hub.pushed


def test_sync_tv_survives_one_broken_show():
    hub = FakeHub({"tv_shows": [{"id": "1", "tmdb_status": None}, {"id": "76479", "tmdb_status": None}], "tv_episodes": []})
    show = {**fx("tmdb_tv.json"), "seasons": [{"season_number": 1}]}
    http = http_for([("/tv/1?", httpx.ConnectError("down")), ("/tv/76479?", show), ("/tv/76479/season/1", fx("tmdb_season.json"))])
    out = pipeline.sync_tv(hub, http, "KEY")
    assert out["failed"] == 1 and out["episodes"] == 3


def test_sync_youtube_first_page_for_backfilled_channels_and_all_pages_for_new_ones():
    page = fx("playlist_items.json")          # has nextPageToken
    last = {**page, "items": page["items"][:1]}
    last.pop("nextPageToken", None)
    calls = []

    def handler(request):
        url = str(request.url)
        calls.append(url)
        if "/videos?" in url:
            return httpx.Response(200, json=fx("videos_list.json"))
        if "pageToken=" in url:
            return httpx.Response(200, json=last)
        return httpx.Response(200, json=page)

    http = httpx.Client(transport=httpx.MockTransport(handler))
    hub = FakeHub({
        "youtube_channels": [
            {"id": "UCold", "uploads_playlist_id": "UUold", "backfilled": 1},
            {"id": "UCnew", "uploads_playlist_id": "UUnew", "backfilled": 0},
        ],
        "youtube_videos": [],
    })
    out = pipeline.sync_youtube(hub, http, "KEY")
    assert out["channels"] == 2 and out["failed"] == 0
    old_pages = [c for c in calls if "playlistId=UUold" in c]
    new_pages = [c for c in calls if "playlistId=UUnew" in c]
    assert len(old_pages) == 1 and len(new_pages) == 2       # delta = first page only; backfill follows the token
    by_channel = {}
    for r in hub.pushed["youtube_videos"]:
        by_channel.setdefault(r["channel_id"], []).append(r)
    assert len(by_channel["UCold"]) == len(page["items"])
    assert len(by_channel["UCnew"]) == len(page["items"]) + 1
    assert {"id": "UCnew", "backfilled": 1} in [{k: r[k] for k in ("id", "backfilled")} for r in hub.pushed["youtube_channels"]]
    assert len(hub.pushed["provenance"]) == 2 * len(page["items"]) + 1


def test_sync_youtube_skips_known_video_ids():
    page = fx("playlist_items.json")
    first = page["items"][0]["snippet"]["resourceId"]["videoId"]
    hub = FakeHub({"youtube_channels": [{"id": "UCold", "uploads_playlist_id": "UUold", "backfilled": 1}],
                   "youtube_videos": [{"id": first}]})
    http = http_for([("playlistItems", page), ("/videos?", fx("videos_list.json"))])
    out = pipeline.sync_youtube(hub, http, "KEY")
    assert out["videos"] == len(page["items"]) - 1


def test_sync_feeds_pushes_new_articles_for_followed_feeds_only():
    hub = FakeHub({
        "feeds": [
            {"id": "https://blog.example.com/rss", "fetch": "rss", "follow": 1, "scrape_pattern": None},
            {"id": "https://off.example.com/rss", "fetch": "rss", "follow": 0, "scrape_pattern": None},
            {"id": "https://x.com/intcyberdigest", "fetch": "x", "follow": 1, "scrape_pattern": None},
        ],
        "articles": [{"id": "https://blog.example.com/third"}],
    })
    http = http_for([("blog.example.com/rss", (FIX / "rss2.xml").read_text())])
    out = pipeline.sync_feeds(hub, http)
    assert out == {"feeds": 1, "articles": 2, "failed": 0}
    assert {r["id"] for r in hub.pushed["articles"]} == {"https://blog.example.com/first", "https://blog.example.com/second"}
    assert all(p["from_kind"] == "feeds" and p["from_ref"] == "https://blog.example.com/rss" for p in hub.pushed["provenance"])


def test_run_daily_returns_all_three_sections(mocker):
    mocker.patch("core.pipeline.sync_tv", return_value={"shows": 0, "episodes": 0, "failed": 0})
    mocker.patch("core.pipeline.sync_youtube", return_value={"channels": 0, "videos": 0, "failed": 0})
    mocker.patch("core.pipeline.sync_feeds", return_value={"feeds": 0, "articles": 0, "failed": 0})
    settings = mocker.Mock(tmdb_api_key="t", youtube_api_key="y")
    out = pipeline.run_daily(FakeHub({}), httpx.Client(), settings)
    assert set(out) == {"tv", "youtube", "feeds"}
```

Check the `rss2.xml` fixture: it must contain items with urls `https://blog.example.com/first`, `/second`, `/third` (the existing pipeline test relied on `/third` being newest). Adjust the asserted ids to the fixture's actual three urls if they differ.

* [ ] **Step 2: Run** `uv run pytest tests/test_pipeline.py -v` -> FAIL.

* [ ] **Step 3: Implement** **`src/core/pipeline.py`**

```Python
"""Daily ingestion: TMDB episodes, YouTube videos, feed articles -> life-data.

Plain Python, no Modal imports. Each source is independent: a failure is
logged and counted, the run continues. New-item detection is "id not yet in
the table", so a partial run is safe to repeat.
"""

import httpx
import structlog

from core import feeds as feeds_mod
from core import tmdb, youtube
from core.hub import HubClient, imported_from, now_iso

log = structlog.get_logger()
CHUNK = 200
ACTIVE_TMDB = {"Returning Series", "In Production", "Planned", "Pilot", None}


def _push_chunked(hub, table, rows):
    for i in range(0, len(rows), CHUNK):
        hub.push(table, rows[i : i + CHUNK])


def sync_tv(hub: HubClient, http: httpx.Client, key: str) -> dict:
    shows = hub.pull("tv_shows", ["id", "tmdb_status"])
    known = {}
    for e in hub.pull("tv_episodes", ["id", "show_id"]):
        known.setdefault(e["show_id"], set()).add(e["id"])
    out = {"shows": len(shows), "episodes": 0, "failed": 0}
    for s in shows:
        have = known.get(s["id"], set())
        if have and s.get("tmdb_status") not in ACTIVE_TMDB:
            continue  # ended and already ingested
        try:
            show = tmdb.show(s["id"], key, http)
            rows = []
            for n in tmdb.season_numbers(show):
                rows += [r for r in tmdb.episode_rows(s["id"], tmdb.season_episodes(s["id"], n, key, http)) if r["id"] not in have]
            _push_chunked(hub, "tv_episodes", rows)
            _push_chunked(hub, "provenance", [imported_from("tv_shows", s["id"], "tv_episodes", r["id"]) for r in rows])
            out["episodes"] += len(rows)
            log.info("tv_synced", show=s["id"], new=len(rows))
        except Exception:
            out["failed"] += 1
            log.exception("tv_failed", show=s["id"])
    return out


def sync_youtube(hub: HubClient, http: httpx.Client, key: str) -> dict:
    channels = hub.pull("youtube_channels", ["id", "uploads_playlist_id", "backfilled"])
    known = {v["id"] for v in hub.pull("youtube_videos", ["id"])}
    out = {"channels": len(channels), "videos": 0, "failed": 0}
    for c in channels:
        try:
            vids = youtube.uploads(c["uploads_playlist_id"], key, http, max_pages=1 if c.get("backfilled") else None)
            vids = [v for v in vids if v["id"] not in known]
            durs = youtube.durations([v["id"] for v in vids], key, http) if vids else {}
            rows = youtube.video_rows(c["id"], vids, durs)
            _push_chunked(hub, "youtube_videos", rows)
            _push_chunked(hub, "provenance", [imported_from("youtube_channels", c["id"], "youtube_videos", r["id"]) for r in rows])
            if not c.get("backfilled"):
                hub.push("youtube_channels", [{"id": c["id"], "backfilled": 1, "updated_at": now_iso()}])
            known.update(r["id"] for r in rows)
            out["videos"] += len(rows)
            log.info("youtube_synced", channel=c["id"], new=len(rows), backfill=not c.get("backfilled"))
        except Exception:
            out["failed"] += 1
            log.exception("youtube_failed", channel=c["id"])
    return out


def sync_feeds(hub: HubClient, http: httpx.Client) -> dict:
    rows = [f for f in hub.pull("feeds", ["id", "fetch", "follow", "scrape_pattern"]) if f.get("follow") and f["fetch"] != "x"]
    known = {a["id"] for a in hub.pull("articles", ["id"])}
    out = {"feeds": len(rows), "articles": 0, "failed": 0}
    for f in rows:
        try:
            items = [r for r in feeds_mod.article_rows(f["id"], feeds_mod.entries(f, http)) if r["id"] not in known]
            _push_chunked(hub, "articles", items)
            _push_chunked(hub, "provenance", [imported_from("feeds", f["id"], "articles", r["id"]) for r in items])
            known.update(r["id"] for r in items)
            out["articles"] += len(items)
            log.info("feed_synced", feed=f["id"], new=len(items))
        except Exception:
            out["failed"] += 1
            log.exception("feed_failed", feed=f["id"])
    return out


def run_daily(hub: HubClient, http: httpx.Client, settings) -> dict:
    return {
        "tv": sync_tv(hub, http, settings.tmdb_api_key),
        "youtube": sync_youtube(hub, http, settings.youtube_api_key),
        "feeds": sync_feeds(hub, http),
    }
```

* [ ] **Step 4: Run** `uv run pytest -v` -> all PASS (config, hub, tmdb, youtube, feeds, watcher, pipeline).

* [ ] **Step 5: Rewrite** **`app.py`**

```Python
"""Modal deployment shim - ALL infrastructure lives here, as code.

Business logic stays in src/core/ (plain Python, no Modal imports). This
file maps it onto Modal: image, secrets, one daily cron. No HTTP endpoints:
nothing calls this app.
"""

import modal

APP_NAME = "media-center"  # also the Modal secret name (see justfile sync-secrets)

app = modal.App(APP_NAME)

image = (
    modal.Image.debian_slim(python_version="3.13")
    .uv_sync(extra_options="--no-dev")
    .add_local_dir("src/core", remote_path="/root/core", ignore=["**/__pycache__"])
)

secrets = [modal.Secret.from_name(APP_NAME)]


def _run() -> dict:
    import httpx

    from core.config import Settings
    from core.hub import HubClient
    from core.pipeline import run_daily

    settings = Settings()
    hub = HubClient(settings.life_hub_url, settings.life_hub_token)
    with httpx.Client(timeout=30, follow_redirects=True, headers={"User-Agent": "media-center/0.2"}) as http:
        return run_daily(hub, http, settings)


# Cron slot 3 of the Starter plan's 5 (birthday-reminders, notion-automations
# hold the other two). 09:30 UTC daily; the first run backfills every channel
# and show, hence the long timeout.
@app.function(image=image, secrets=secrets, schedule=modal.Cron("30 9 * * *"), timeout=3600)
def daily() -> dict:
    return _run()


@app.local_entrypoint()
def main() -> None:
    """One run on Modal, on demand: `uv run modal run app.py`."""
    print(daily.remote())
```

Also delete the old `main()` sys.path hack; local runs go through Modal (`modal run`) so the image and secret are the real ones.

* [ ] **Step 6: Update** **`justfile`** - remove the `dev` recipe (no endpoints to serve); add under the project-specific divider:

```
# One ingestion run on Modal, now (uses the deployed secret)
run:
    uv run modal run app.py
```

* [ ] **Step 7: Rewrite** **`AGENTS.md`** to describe the current state only: purpose (daily poller into life-data), the architecture rule, the four env vars, module map (`hub`, `tmdb`, `youtube`, `feeds`, `watcher`, `pipeline`), the "poller writes source facts; never a derived column" rule, the new-item rule (id not present), the X row skip, commands table (`test`, `check`, `fmt`, `logs`, `sync-secrets`, `deploy`, `run`), and the life-data tables it writes with a pointer to life-map. Remove every Notion reference, the 2026-07 history section, and the "Setup status" section. Rewrite `README.md` the same way (generic: any life-data hub, any TMDB/YouTube key; the Manual setup section becomes `op-project-bootstrap .env.tpl --repo <owner>/<repo>` plus "mint a `tables:write` hub token").

* [ ] **Step 8: Run** `uv run pytest -q && uv run ruff check . && uv run ruff format --check .` -> clean (run `uv run ruff format .` first if needed).

* [ ] **Step 9: Commit** `git add -A && git commit -m "Daily ingestion pipeline into life-data; cron-only Modal shim; docs describe the current state"`

***

### Task 7: derivations - tv endpoint returns status and providers

**Files:**

* Modify: `derivations/src/core/tmdb.py`, `derivations/tests/test_tmdb.py`, `derivations/tests/fixtures/tv_66732.json`

**Interfaces:**

* Produces: `tmdb.details("tv", id, key)` requests `append_to_response=credits,watch/providers`; `to_row("tv", data, today)` adds `tmdb_status: str | None` and `watch_providers: list[str]` (US `flatrate` `provider_name`s, in TMDB's `display_priority` order, `[]` when absent). Movies unchanged (no new keys).

* [ ] **Step 1: Extend the fixture.** With the key from `op://Derivations/Derivations ENV/TMDB_API_KEY` (desktop auth), re-record `tests/fixtures/tv_66732.json` with `append_to_response=credits,watch/providers`, trimming `credits` the way AGENTS.md describes and keeping only the `US` entry of `watch/providers.results`. Confirm the file has `"status"` and `"watch/providers"`.

* [ ] **Step 2: Write the failing tests** (append to `tests/test_tmdb.py`)

```Python
def test_tv_details_requests_watch_providers():
    client = FakeClient(FakeResponse(200, {"id": 1}))
    tmdb.details("tv", "1", "KEY", client=client)
    assert client.calls[0][1]["params"]["append_to_response"] == "credits,watch/providers"


def test_movie_details_request_is_unchanged():
    client = FakeClient(FakeResponse(200, {"id": 1}))
    tmdb.details("movie", "1", "KEY", client=client)
    assert client.calls[0][1]["params"]["append_to_response"] == "credits"


def test_tv_row_carries_status_and_us_flatrate_providers():
    data = fixture("tv_66732.json")
    row = tmdb.to_row("tv", data, "2026-09-08")
    assert row["tmdb_status"] == data["status"]
    us = data["watch/providers"]["results"]["US"]["flatrate"]
    assert row["watch_providers"] == [p["provider_name"] for p in sorted(us, key=lambda p: p["display_priority"])]


def test_tv_row_without_providers_is_an_empty_list():
    row = tmdb.to_row("tv", {"id": 1, "name": "X", "status": "Ended"}, "2026-09-08")
    assert row["watch_providers"] == [] and row["tmdb_status"] == "Ended"


def test_movie_row_has_no_tv_keys():
    row = tmdb.to_row("movie", fixture("movie_157336.json"), "2026-09-08")
    assert "tmdb_status" not in row and "watch_providers" not in row
```

* [ ] **Step 3: Run** `cd ~/Desktop/coding/active-projects/derivations && uv run pytest tests/test_tmdb.py -v` -> FAIL.

* [ ] **Step 4: Implement** in `src/core/tmdb.py`: in `details`, `params={"api_key": key, "append_to_response": "credits" if kind == "movie" else "credits,watch/providers"}`. Add:

```Python
def providers_for(data: dict, region: str = "US") -> list[str]:
    entry = ((data.get("watch/providers") or {}).get("results") or {}).get(region) or {}
    flat = sorted(entry.get("flatrate") or [], key=lambda p: p.get("display_priority", 10**6))
    return [p["provider_name"] for p in flat if p.get("provider_name")]
```

and in `to_row`, after building the dict: `if kind == "tv": row["tmdb_status"] = data.get("status"); row["watch_providers"] = providers_for(data)`. Update the module docstring and AGENTS.md's response description (`tmdb_status`, `watch_providers` on `/tv`).

* [ ] **Step 5: Run** `uv run pytest -q && uv run ruff check . && uv run ruff format --check .` -> clean.

* [ ] **Step 6: Commit and deploy** `git add -A && git commit -m "tv: return TMDB status and US streaming providers" && git push origin main`, then `gh run list --limit 1 --json databaseId -q '.[0].databaseId'` and `gh run watch <id> --exit-status`. Verify: `curl` the deployed `/tv` with a Modal proxy key from the Life Data ENV item's `DERIVATIONS` JSON (desktop auth) and `{"tbl":"tv_shows","id":"76479","inputs":{"id":"76479"}}`; the response has `tmdb_status`.

***

### Task 8: life-data catalog: statuses, tv\_shows columns, new tables, feed view (user op)

**Files:** none in a repo. Commands run with the installed `life` (the repo client `just run` in life-data if the installed one predates provenance support). Then `agent-config/skills/life-map/SKILL.md`.

**Interfaces:**

* Produces the tables the poller (Task 6) reads and writes, exactly these columns:
  * `youtube_channels(id, title, handle, channel_url, uploads_playlist_id, follow, backfilled, content_type, tags, subscription, notion_id)`
  * `youtube_videos(id, channel_id, title, published_at, duration_s, thumbnail_url, is_short, status, date_watched, tags, note, notion_id)`
  * `feeds(id, kind, title, fetch, scrape_pattern, follow)`
  * `articles(id, feed_id, title, published_at, status, date_read, tags, note, notion_id)`
  * `tv_episodes(id, show_id, season, episode, title, air_date, runtime_min, status, date_watched, note)`
  * `tv_shows` + `follow`, `tmdb_status`, `watch_providers`
  * view `media_feed(kind, id, title, source, published_at, status)`

* [ ] **Step 1: Unify tv\_shows status.** Add the new option, move rows, drop the old one, fix the rules:

```Shell
life property set tv_shows.status --options '[{"v":"Priority","d":"Need to watch / must watch"},{"v":"Not Started","d":"Default. Saved, not started"},{"v":"In Progress","d":"Currently watching"},{"v":"Finished","d":"Watched it all"},{"v":"Watched Some","d":"legacy, being renamed"},{"v":"Watched Parts","d":"Saw some episodes, not finished"},{"v":"Gave Up","d":"Stopped on purpose"}]'
life sql "UPDATE tv_shows SET status = 'Watched Parts' WHERE status = 'Watched Some' AND deleted_at IS NULL"
life sql "SELECT count(*) AS n FROM tv_shows WHERE status = 'Watched Some'"     # expect 0
life property set tv_shows.status --options '[{"v":"Priority","d":"Need to watch / must watch"},{"v":"Not Started","d":"Default. Saved, not started"},{"v":"In Progress","d":"Currently watching"},{"v":"Finished","d":"Watched it all"},{"v":"Watched Parts","d":"Saw some episodes, not finished"},{"v":"Gave Up","d":"Stopped on purpose"}]'
life rule set tv-date-implies-terminal --scope table --tbl tv_shows --kind invariant --text "A row with date_watched has a terminal status." --sql "SELECT id FROM tv_shows WHERE deleted_at IS NULL AND date_watched IS NOT NULL AND status NOT IN ('Finished','Watched Parts','Gave Up')" --enforce 1
life rule rm tv-partial-is-watched-some
```

* [ ] **Step 2: tv\_shows columns**

```Shell
life sql "ALTER TABLE tv_shows ADD COLUMN follow INTEGER NOT NULL DEFAULT 1"
life sql "ALTER TABLE tv_shows ADD COLUMN tmdb_status TEXT"
life sql "ALTER TABLE tv_shows ADD COLUMN watch_providers TEXT"
life property set tv_shows.follow --type bool --default 1 --description "Surface this show's new episodes in media_feed. Every show follows by default; flip off per show."
life property set tv_shows.tmdb_status --type text --derived-by http:tmdb_tv --inputs id --description "TMDB production status (Returning Series, Ended, ...). Gates daily episode polling."
life property set tv_shows.watch_providers --type json --derived-by http:tmdb_tv --inputs id --description "US flatrate streaming services carrying the show, from TMDB. Answers where does it stream."
life derive tv_shows.tmdb_status      # backfill through the hub, ~5 chunks; expect failed = 0
life sql "SELECT tmdb_status, count(*) AS n FROM tv_shows WHERE deleted_at IS NULL GROUP BY 1"
```

* [ ] **Step 3: New tables**

```Shell
life table create youtube_channels 'title:text' 'handle:text' 'channel_url:url' 'uploads_playlist_id:text' 'follow:bool!' 'backfilled:bool!' 'content_type:multi_select' 'tags:multi_select' 'subscription:select(Subscribed|Unsubscribed|To Watch|Never Subscribed|Legacy)' 'notion_id:text'
life property set youtube_channels.follow --default 0 --description "Surface this channel's videos in media_feed. Off by default; explicit opt-in."
life property set youtube_channels.backfilled --default 0 --description "Poller flag: the full uploads back catalog has been ingested; daily runs read only the newest page from then on."
life table set youtube_channels --purpose "Every YouTube channel Alex has ever tracked; id = YouTube channel id (UC...). Notion YouTube Channels superseded." --owner media-center

life table create youtube_videos 'channel_id:ref!' 'title:text' 'published_at:datetime' 'duration_s:int' 'thumbnail_url:url' 'is_short:bool' 'status:select!(Priority|Not Started|In Progress|Finished|Watched Parts|Gave Up)' 'date_watched:date' 'tags:multi_select(Favorite|Classic)' 'note:text' 'notion_id:text'
life property set youtube_videos.channel_id --ref-table youtube_channels
life property set youtube_videos.status --default "Not Started"
life table set youtube_videos --purpose "Every video of every tracked channel plus manual saves; id = 11-char YouTube video id. Notion YouTube Videos superseded." --owner media-center

life table create feeds 'kind:select!(blog|changelog|newsletter|x)' 'title:text' 'fetch:select!(rss|scrape:links|x)' 'scrape_pattern:text' 'follow:bool!'
life property set feeds.follow --default 1
life property set feeds.scrape_pattern --description "For fetch = scrape:links only: regex an absolute <a href> must match to count as an item."
life table set feeds --purpose "Sources the poller reads; id = the feed or page URL." --owner media-center

life table create articles 'feed_id:ref' 'title:text' 'published_at:datetime' 'status:select!(Priority|Not Started|In Progress|Finished|Watched Parts|Gave Up)' 'date_read:date' 'tags:multi_select' 'note:text' 'notion_id:text'
life property set articles.feed_id --ref-table feeds
life property set articles.status --default "Not Started"
life table set articles --purpose "Posts from followed feeds plus manual saves; id = canonical URL (tracking params stripped). Notion Articles superseded." --owner media-center

life table create tv_episodes 'show_id:ref!' 'season:int!' 'episode:int!' 'title:text' 'air_date:date' 'runtime_min:int' 'status:select!(Priority|Not Started|In Progress|Finished|Watched Parts|Gave Up)' 'date_watched:date' 'note:text'
life property set tv_episodes.show_id --ref-table tv_shows
life property set tv_episodes.status --default "Not Started"
life table set tv_episodes --purpose "Every episode of every show in tv_shows; id = TMDB episode id. Notion TV Episodes superseded." --owner media-center
```

* [ ] **Step 4: provenance from\_kind options.** Read the current list, append `youtube_channels`, `tv_shows`, `feeds`, `notion_media` (the Notion migration source), write it back:

```Shell
life sql "SELECT options FROM catalog_properties WHERE tbl='provenance' AND col='from_kind'"
# then, with the existing values copied verbatim into <existing...>:
life property set provenance.from_kind --options '<existing...>,youtube_channels,tv_shows,feeds,notion_media'
```

* [ ] **Step 5: The feed view**

```Shell
life sql "CREATE VIEW media_feed AS
SELECT 'youtube_videos' AS kind, v.id, v.title, c.title AS source, v.published_at, v.status
  FROM youtube_videos v JOIN youtube_channels c ON c.id = v.channel_id
 WHERE v.deleted_at IS NULL AND c.deleted_at IS NULL AND c.follow = 1 AND v.status IN ('Not Started','Priority')
UNION ALL
SELECT 'tv_episodes', e.id, s.title || ' S' || printf('%02d', e.season) || 'E' || printf('%02d', e.episode) || ' ' || coalesce(e.title,''), s.title, e.air_date, e.status
  FROM tv_episodes e JOIN tv_shows s ON s.id = e.show_id
 WHERE e.deleted_at IS NULL AND s.deleted_at IS NULL AND s.follow = 1 AND e.status IN ('Not Started','Priority') AND e.air_date IS NOT NULL AND e.air_date <= date('now')
UNION ALL
SELECT 'articles', a.id, a.title, f.title, a.published_at, a.status
  FROM articles a JOIN feeds f ON f.id = a.feed_id
 WHERE a.deleted_at IS NULL AND f.deleted_at IS NULL AND f.follow = 1 AND a.status IN ('Not Started','Priority')
ORDER BY published_at DESC"
life sql "SELECT * FROM media_feed LIMIT 1"
life sync && life check
```

If `life check` or `life sync` reports the view as an uncataloged table, drop it (`life sql "DROP VIEW media_feed"`) and instead record the query in life-map as the canonical feed query; the poller and readers do not depend on the view existing.

* [ ] **Step 6: Document in life-map.** In `~/.config/agent-config/skills/life-map/SKILL.md` (edit the real file, not a symlink target of CLAUDE.md), add sections following the movies template for `youtube_channels`, `youtube_videos`, `feeds`, `articles`, `tv_episodes` (purpose + provenance, row id, column contract table with required/default/allowed values, context columns, conventions: poller-written facts, follow semantics, the unified status vocabulary, `is_short` heuristic), update the `tv_shows` section (three new columns, `Watched Parts`), add the ID registry rows (`youtube_channels` -> `https://www.youtube.com/channel/<id>`, `youtube_videos` -> `https://www.youtube.com/watch?v=<id>`, `tv_episodes` -> `https://www.themoviedb.org/tv/<show>/season/<s>/episode/<e>`, `articles`/`feeds` -> the URL itself, `notion_media` -> the retired Notion page), and a "Media feed" subsection with the `media_feed` query and the three questions agents answer with it ("what's new", "mark X finished" = `UPDATE <table> SET status='Finished', date_watched=date('now') WHERE id=?`, "what am I following"). Bump **Last verified**. Commit and push agent-config (`git -C ~/.config/agent-config add skills/life-map/SKILL.md && git -C ~/.config/agent-config commit -m "life-map: media tables, feed query, follow semantics" && git -C ~/.config/agent-config push`).

***

### Task 9: Migrate channels, videos, articles from Notion; seed feeds and follows (user op)

**Files:** scratchpad `media-migrate/channels.py`, `videos.py`, `articles.py`, `seed_feeds.py` (PEP 723 scripts, `uv run`). Never committed.

**Interfaces:**

* Consumes: `youtube.resolve_channel` semantics (reimplemented inline in the script: the script runs outside the repo), Notion data sources: YouTube Channels `c7dcc5f4-5b71-49b0-aabb-f791ab0dc69f`, YouTube Videos `cb9e2038-139a-4f53-82a2-095ea19df27b`, Articles `1c703953-a8af-8062-a379-000b8e250413`.

* Produces: rows in `youtube_channels` (149), `youtube_videos` (72), `articles` (8), `feeds` (10), `provenance` edges `from_kind = "notion_media"`, `from_ref = <notion page id>`, `rel = "imported_from"`, `asserted_by = "script:media-migrate"`.

* [ ] **Step 1:** **`channels.py`.** Query the Notion channels DB (paginate, `NOTION_API_TOKEN` from the AI Agent vault ref in notion-workspace). For each page: `channel_url` = Channel URL; resolve via the YouTube Data API `channels.list` (`id=` for `/channel/UC..`, else `forHandle=`) with the key from Synapse ENV (desktop auth); write `resolved.json` `[{notion_id, name, channel_url, id, title, handle, uploads_playlist_id, status, content_type, tags}]` and `unresolved.md` listing every page the API could not resolve. **ALEX reviews** **`unresolved.md`** (expected: a few dead or renamed channels; owner supplies the right URL or says skip).

* [ ] **Step 2: Insert channels.** Build rows `{id, title, handle, channel_url, uploads_playlist_id, follow: 0, backfilled: 0, content_type: [..], tags: [..], subscription: <Notion Status>, notion_id: <dash-stripped>}` and `echo <json> | life insert youtube_channels`; then provenance rows `{id: "notion_media:<notion_id>:<channel id>", from_kind: "notion_media", from_ref: <notion_id>, to_kind: "youtube_channels", to_ref: <id>, rel: "imported_from", detail: "{\"created_row\":1}", asserted_by: "script:media-migrate"}` via `life insert provenance`. Verify `life sql "SELECT count(*) FROM youtube_channels WHERE deleted_at IS NULL"` == resolved count.

* [ ] **Step 3: Flip follows.** `life sql "UPDATE youtube_channels SET follow = 1 WHERE id IN (<Fireship>, <Veritasium>, <Last Week Tonight>)"` using the ids from `resolved.json` (Veritasium is `UCHnyfMqiRRG1u-2MsSQLbXA`, Fireship is `UCsBjURrPoezykLs9EqgamOA`, both verified against the Data API 2026-09-08; Last Week Tonight comes from the file - never guess a channel id). Dave Jorgenson is not in Notion: resolve `https://www.youtube.com/@davejorgenson` with `channels.list forHandle`; if that handle does not resolve, search `channels.list` is not available so use `search.list?type=channel&q=Dave Jorgenson` (100 units) and confirm the title with the owner; insert with `follow = 1`, `subscription = "Never Subscribed"`. kiidkatze: same lookup, insert with `follow = 0` and report the result to the owner.

* [ ] **Step 4:** **`videos.py`.** Query the Notion videos DB; for each page take the video id from Video URL (`v=` param or `youtu.be/<id>`), call `videos.list part=snippet,contentDetails` in batches of 50 to get `channelId`, `title`, `publishedAt`, `duration`; status map `To Watch`->`Not Started`, `Watched`->`Finished`, `Priority`/`In Progress` unchanged; `date_watched` = Notion Date Watched (date part); `tags` = Notion Tags names. A video whose channel id is not in `youtube_channels` first gets a channel row (`follow 0`, `backfilled 0`, `subscription "Never Subscribed"`, title from the snippet, uploads playlist = `"UU" + id[2:]`). Insert videos and `notion_media` provenance edges. Verify count == 72 minus any dead video ids (list those in the report).

* [ ] **Step 5:** **`articles.py`.** 8 rows: `id = canonical_url(URL)` (same rules as `feeds.canonical_url`), `title` = Name (or the URL's last path segment when empty), `status` `Done`->`Finished`, `In progress`->`In Progress`, `date_read` = Read Date, `feed_id` NULL, `notion_id`. Insert plus provenance edges.

* [ ] **Step 6:** **`seed_feeds.py`.** Probe each source for a feed with `curl -sI` and a `<link rel="alternate" type="application/rss+xml">` scan of the page, then insert the row that works. Candidates to try, in order, per source:

| Source                    | kind       | try first                                                                               | fallback                                                                                                                                                     |
| ------------------------- | ---------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Cherri releases           | changelog  | `https://github.com/electrikmilk/cherri/releases.atom` (rss)                            | none needed                                                                                                                                                  |
| Notion blog / releases    | changelog  | `https://www.notion.so/releases` page feed link                                         | `scrape:links` on `https://www.notion.so/releases`, pattern `/releases/\d{4}-\d{2}-\d{2}`                                                                    |
| Raycast changelog         | changelog  | `https://www.raycast.com/changelog` feed link                                           | `scrape:links`, pattern `/changelog/[^/]+$`                                                                                                                  |
| Waymo Waypoint blog       | blog       | `https://waymo.com/blog/` feed link                                                     | `scrape:links`, pattern `/blog/\d{4}/`                                                                                                                       |
| Home Assistant blog       | blog       | `https://www.home-assistant.io/atom.xml` (rss)                                          | none needed                                                                                                                                                  |
| Works with Home Assistant | blog       | `https://partner.home-assistant.io/blog/` feed link                                     | `scrape:links`, pattern `/blog/[^/]+/$`                                                                                                                      |
| Chrome what's new         | changelog  | `https://chromereleases.googleblog.com/feeds/posts/default` (rss, stable channel notes) | `scrape:links` on `https://www.google.com/chrome/whats-new/`, pattern `/whats-new/`                                                                          |
| Flighty newsletter        | newsletter | `https://flighty.com/blog` feed link                                                    | insert with `fetch = "x"`-style placeholder? No: if no web feed exists, do NOT insert; record it in the report as "Gmail source kind, deferred" per the spec |
| MacStories                | blog       | `https://www.macstories.net/feed/` (rss)                                                | none needed                                                                                                                                                  |
| intcyberdigest            | x          | `https://x.com/intcyberdigest`, `fetch = "x"`                                           | separate mini plan                                                                                                                                           |

For every inserted `rss` row, run `feedparser.parse(url)` in the script and require `>= 1` entry. For every `scrape:links` row, fetch the page and require the pattern to match `>= 1` link; print the first three titles for the owner to eyeball. All rows `follow = 1`.

* [ ] **Step 7: Report.** Write `media-migrate/report.md` (counts per table, unresolved channels, dead videos, feeds that fell back to scraping, the Flighty deferral) and paste its content in chat. Run `life sync && life check` -> clean.

***

### Task 10: Ops and first ingestion run

**Files:** none in a repo (1Password and Modal state).

* [ ] **Step 1: Hub token.** `life token create media-center --scopes tables:write` (admin token via the CLI's configured `token_cmd`). Never print the value in chat; pipe it straight into 1Password in the next step.

* [ ] **Step 2: Vault fields (ALEX approves Touch ID).** In one `zsh -ic 'op-personal ...'` batch: on the `Media Center ENV` item (`grnxaeni7bpl57nupbwz3ak2ka`, vault `ciut3oezyps2jalnapskesfzje`) delete `NOTION_API_KEY` and `SOURCE_DBS`, add `LIFE_HUB_URL=https://life-data.nqipomyrjb.workers.dev`, `LIFE_HUB_TOKEN=<token>`, `TMDB_API_KEY=<copy of Derivations ENV TMDB_API_KEY>`, `YOUTUBE_API_KEY=<copy of Synapse ENV GOOGLE_YOUTUBE_API_KEY>`; on `Media Center CI Modal Token` (`y2twlexpos2gddjoyep2sm5eoi`) set `token-id` and `token-secret` to a Modal token minted for CI (owner mints at modal.com/settings/tokens, or reuses the Derivations CI Modal Token values). Every edit keeps the existing tags. Then `op-project-bootstrap .env.tpl --check` -> all refs resolve.

* [ ] **Step 3: Deploy.** `git push origin main` (the spec commit, the plan, Tasks 1 to 6). `gh run list --limit 1 --json databaseId -q '.[0].databaseId'`, `gh run watch <id> --exit-status`. On failure `gh run view <id> --log-failed`, fix, push again.

* [ ] **Step 4: First run.** `just run` (= `uv run modal run app.py`, needs `uv run modal token new` once on this machine if missing). Expect the TV section to report `shows == count(tv_shows)`, YouTube `channels == count(youtube_channels)`. If YouTube quota (HTTP 403 `quotaExceeded`) stops the back catalog, the affected channels stay `backfilled = 0` and the next day's cron continues; run `just run` again the next day until every channel reports `backfilled = 1`:

```Shell
life sync && life sql "SELECT backfilled, count(*) AS n FROM youtube_channels WHERE deleted_at IS NULL GROUP BY 1"
life sql "SELECT count(*) AS episodes FROM tv_episodes WHERE deleted_at IS NULL"
life sql "SELECT kind, count(*) AS n FROM media_feed GROUP BY 1"
```

* [ ] **Step 5: Verify the feed.** `life sql "SELECT kind, source, title, published_at FROM media_feed LIMIT 20"` shows Fireship / Veritasium / LWT videos and articles from the seeded feeds, newest first. `just logs` shows one `tv_synced` per show and no unexplained `*_failed`. Paste the counts in chat.

***

### Task 11: Import Notion TV Episodes watched marks (user op, after Task 10)

**Files:** scratchpad `media-migrate/episodes.py`.

* [ ] **Step 1:** Query the Notion TV Episodes DB (`1c703953-a8af-809d-b3a1-000b7dd7c0d4`): 110 rows, all Status `Watched`, `TV Show` relation -> Notion TV Shows page id, Season/Episode numbers empty, so match by title. Map the relation to `tv_shows.id` via `notion_id` (dash-stripped): `3e62da86...` -> `549` (Law & Order), `33103953-a8af-8049...` -> `2190` (South Park).

* [ ] **Step 2:** For each Notion episode, `life sql "SELECT id FROM tv_episodes WHERE show_id = ? AND lower(title) = lower(?) AND deleted_at IS NULL"`; on exactly one match `UPDATE tv_episodes SET status = 'Finished', date_watched = <Notion created_time date> WHERE id = ?` and insert a provenance row `{id: "notion_media:<notion_id>:<episode id>", from_kind: "notion_media", from_ref: <notion_id>, to_kind: "tv_episodes", to_ref: <id>, field: "date_watched", rel: "evidence_of", detail: "{\"confidence\":\"high\"}", asserted_by: "script:media-migrate"}`. Zero or multiple matches go to `episodes-unmatched.md` with the candidates.

* [ ] **Step 3:** Report matched / unmatched counts in chat; **ALEX** resolves the unmatched list or says skip. `life sync && life check` -> clean.

***

### Task 12: Synapse writes YouTube captures to life-data

**Files:**

* Modify: `synapse/src/core/handlers.py` (`handle_youtube_logic`), `synapse/src/core/databases.yaml` (`youtube-videos`, `youtube-channels` stanzas), `synapse/tests/test_handlers.py`, `synapse/AGENTS.md`

**Interfaces:**

* Consumes: `push_rows(table, rows)` from `core/life_hub.py`; `get_youtube()` client; `get_youtube_video_id(url)`, `sanitize_youtube_url(url)`; `create_cleanup_task(text)`; `Failed`.

* Produces: `handle_youtube_logic("youtube-videos", data) -> "youtube_videos/<video id>" | Failed`. Pushes a `youtube_channels` row `{id, title, handle, channel_url, uploads_playlist_id, follow: 0, backfilled: 0, subscription: "Never Subscribed", updated_at}` only when the channel is new (a `videos.list` snippet gives `channelId`/`channelTitle`; `channels.list part=snippet,contentDetails id=` gives handle and uploads playlist), then a `youtube_videos` row `{id, channel_id, title, published_at, duration_s, thumbnail_url, is_short, status, tags?, updated_at}`. Status map: yaml allowlist becomes the unified vocabulary; the prompt's `To Watch` -> `Not Started`, `Watched` -> `Finished`.

* [ ] **Step 1: Write the failing tests** (replace the YouTube tests in `tests/test_handlers.py`; mirror the movies tests' `patch` style):

```Python
class TestYouTubeToLifeData:
    SNIPPET = {"items": [{"id": "dQw4w9WgXcQ", "snippet": {"title": "Never Gonna Give You Up", "channelId": "UCuAXFkgsw1L7xaCfnd5JJOw", "channelTitle": "Rick Astley", "publishedAt": "2009-10-25T06:57:33Z"}, "contentDetails": {"duration": "PT3M33S"}}]}
    CHANNEL = {"items": [{"id": "UCuAXFkgsw1L7xaCfnd5JJOw", "snippet": {"title": "Rick Astley", "customUrl": "@rickastleyyt"}, "contentDetails": {"relatedPlaylists": {"uploads": "UUuAXFkgsw1L7xaCfnd5JJOw"}}}]}

    def _yt(self, channel_known):
        yt = MagicMock()
        yt.videos().list().execute.return_value = self.SNIPPET
        yt.channels().list().execute.return_value = self.CHANNEL
        return yt

    def test_new_channel_and_video_are_pushed(self, mock_notion):
        with (
            patch("core.handlers.get_youtube", return_value=self._yt(False)),
            patch("core.handlers.known_channel_ids", return_value=set()),
            patch("core.handlers.push_rows", return_value={"upserted": 1, "rejected": []}) as push,
        ):
            ref = handle_youtube_logic("youtube-videos", {"Video URL": "https://youtu.be/dQw4w9WgXcQ?si=abc", "Status": "To Watch", "Tags": ["Classic"]})
        assert ref == "youtube_videos/dQw4w9WgXcQ"
        tables = [c.args[0] for c in push.call_args_list]
        assert tables == ["youtube_channels", "youtube_videos"]
        chan = push.call_args_list[0].args[1][0]
        assert chan["id"] == "UCuAXFkgsw1L7xaCfnd5JJOw" and chan["follow"] == 0 and chan["backfilled"] == 0
        assert chan["uploads_playlist_id"] == "UUuAXFkgsw1L7xaCfnd5JJOw" and chan["subscription"] == "Never Subscribed"
        vid = push.call_args_list[1].args[1][0]
        assert vid["id"] == "dQw4w9WgXcQ" and vid["channel_id"] == chan["id"]
        assert vid["status"] == "Not Started" and vid["tags"] == ["Classic"]
        assert vid["duration_s"] == 213 and vid["is_short"] == 0 and vid["published_at"] == "2009-10-25T06:57:33Z"
        mock_notion.pages.create.assert_called_once()   # the "Classify new Channel" cleanup task
        assert "Rick Astley" in sent_props(mock_notion.pages.create, "tasks")["Name"]["title"][0]["text"]["content"]

    def test_known_channel_pushes_only_the_video(self):
        with (
            patch("core.handlers.get_youtube", return_value=self._yt(True)),
            patch("core.handlers.known_channel_ids", return_value={"UCuAXFkgsw1L7xaCfnd5JJOw"}),
            patch("core.handlers.push_rows", return_value={"upserted": 1, "rejected": []}) as push,
        ):
            handle_youtube_logic("youtube-videos", {"Video URL": "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "Status": "Watched"})
        assert [c.args[0] for c in push.call_args_list] == ["youtube_videos"]
        assert push.call_args.args[1][0]["status"] == "Finished"

    def test_no_video_id_raises(self):
        with pytest.raises(ValueError):
            handle_youtube_logic("youtube-videos", {"Video URL": "https://www.youtube.com/@fireship"})

    def test_rejected_push_files_cleanup_task_and_fails(self, mock_notion):
        with (
            patch("core.handlers.get_youtube", return_value=self._yt(True)),
            patch("core.handlers.known_channel_ids", return_value={"UCuAXFkgsw1L7xaCfnd5JJOw"}),
            patch("core.handlers.push_rows", return_value={"upserted": 0, "rejected": [{"id": "dQw4w9WgXcQ", "col": "status", "rule": "select", "message": "bad"}]}),
        ):
            out = handle_youtube_logic("youtube-videos", {"Video URL": "https://youtu.be/dQw4w9WgXcQ", "Status": "Not Started"})
        assert isinstance(out, Failed) and "bad" in out.detail
```

`known_channel_ids()` is a new helper in `handlers.py`: `POST <hub>/v1/rows/pull {"table": "youtube_channels", "columns": ["id", "deleted_at"], "since": ""}` with the Synapse hub token (the token needs `tables:read` too: re-mint `life token create synapse --scopes tables:read,tables:write` and update the Synapse ENV field, **ALEX approves**), returning the set of non-deleted ids. Add `pull_ids(table)` to `life_hub.py` next to `push_rows` with a test in `tests/test_life_hub.py` that asserts the request body and the deleted-row filter.

* [ ] **Step 2: Run** `cd ~/Desktop/coding/active-projects/synapse && uv run pytest tests/test_handlers.py -k YouTube -v` -> FAIL.

* [ ] **Step 3: Implement.** Replace the body of `handle_youtube_logic` with: sanitize URL, extract id (raise `ValueError` if none); `snippet = get_youtube().videos().list(part="snippet,contentDetails", id=vid).execute()["items"][0]`; if `snippet["snippet"]["channelId"] not in known_channel_ids()`: `ch = get_youtube().channels().list(part="snippet,contentDetails", id=channel_id).execute()["items"][0]`, push the channel row, `create_cleanup_task(f"Classify new Channel: {title}")`; build the video row (duration via the same `parse_iso8601_duration` regex as media-center, copied into `handlers.py` as a 6-line helper; `is_short = duration <= 180`; `thumbnail_url = f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg"`; status from `data` through `{"To Watch": "Not Started", "Watched": "Finished"}.get(s, s) or "Not Started"`; `tags` only when present; `updated_at = now_utc_iso_ms()`); push; on rejected -> `create_cleanup_task` + `Failed`; return `f"youtube_videos/{vid}"`. In `databases.yaml`: `youtube-videos` gets `hub_table: "youtube_videos"`, drops `db_id`, Status allowlist becomes `["Priority", "Not Started", "In Progress", "Finished", "Watched Parts", "Gave Up"]` with the instruction rewritten so "watched/seen" -> `Finished` and neutral -> `Not Started`; `youtube-channels` gets `hub_table: "youtube_channels"` and drops `db_id`. Grep for every reader of `get_db_id("youtube-videos")` / `("youtube-channels")` (`fetch_existing_page`, `hydrate_dynamic_options`, `scripts/fetch_property_ids.py`) and confirm `hub_table` stanzas are skipped as they are for movies.

* [ ] **Step 4: Run** `uv run pytest -q && uv run ruff check . && uv run ruff format --check .` -> clean. Update `AGENTS.md`'s "Not every category is a Notion DB" paragraph to list youtube-videos and youtube-channels.

* [ ] **Step 5: Commit, push, verify** `git add -A && git commit -m "YouTube captures write to life-data youtube_videos and youtube_channels"`, `git push origin main`, `gh run watch <id> --exit-status`. E2E: send one YouTube URL through Receptor (or `curl` the Synapse webhook with the proxy headers from the Synapse vault) and confirm `life sync && life sql "SELECT id, title, channel_id, status FROM youtube_videos ORDER BY created_at DESC LIMIT 1"` shows it with the channel resolved.

***

### Task 13: Notion cleanup, tasks, catalog and memory (user op)

* [ ] **Step 1: Retire DBs (ALEX, Notion UI).** Move YouTube Videos, YouTube Channels, TV Episodes, Articles, Short Form Videos, Radio Shows, Videogames, Media Consumption from the Databases page's Entertainment section to Legacy. Then in `notion-workspace` skill: mark those DBs RETIRED with their life-data table (or "no import") the way Movies/TV Shows are marked, and in `notion-automations/src/core/rules.py` remove the `R.YOUTUBE` and `R.TV` timestamp rules (they now point at retired DBs), with their tests, commit, push, `gh run watch`.

* [ ] **Step 2: Tasks.** Via `ntn api v1/pages/<id> -X PATCH`:
  * Completed + `AI Completed` + `Completed Date` = today: "Build blog scraper/tracker...", "Set up a tech changelog db separate from blogs db", "after blogs db is set up add a bunch of blogs...", "Add Dave Jorgensen to media center news list", "Add intcyberdigest to media center list...", "Set up YouTube channel sync with Notion DB" (rescoped: channels live in life-data; two-way subscription sync is the deferred task below), "Research which api ... TV Show new episodes", "Design TV show statuses to handle new seasons", "Figure out TV show status design...", "add a awaiting new season vs tv show over...", "Migrate TV Episodes to life-data", the YouTube Videos half of "Migrate Podcasts and YouTube Videos to life-data..." (edit its Name to "Migrate Podcasts to life-data with Spotify derivations" and leave it To Do).
  * Canceled: "Build standalone iOS media center app with widgets", "Create youtube short form video Plugin", "Set up my youtube channels section and create separate statuses...", "Fill out all the views of the media center db...", "Add a plugin for reddit communities...", "Create a custom hook off of the TV episodes hook for when love is blind...", "Add all the insta accounts yt equivalents..." (infrabren/jtreezy69 rejected; kiidkatze handled in Task 9), "After yt channel is complete, add find these instagram guys' yt channels...".
  * Leave To Do: "Track veritasium, summoning salt videos ... export my yt watching history" (rename to "Import YouTube watch history from Google Takeout into youtube\_videos"), "Find a way to see my in progress yt videos...", "Mark down every John Oliver episode watched in Episodes DB" (now a `tv_episodes` update, keep).
  * Create (High, Chore, due today, Project = Media Center): "Media Center X source: scrape @intcyberdigest into articles from the mini's logged-in Chrome (separate plan)"; "YouTube subscriptions two-way sync with youtube\_channels.subscription (deferred)"; "Flighty newsletter as a Gmail-backed feeds source (deferred)". Create under the Notion Automations project: "After notion-automations reads life-data: when a Love Is Blind / The Ultimatum season is finished in tv\_episodes, create a task to read the season's online drama, Reddit threads and memes".
  * Close this session's task (`3d503953-a8af-81e7-a4f8-cd2fc2c31d29`): Completed, `AI Completed`, `Completed Date`.

* [ ] **Step 3: Catalog and memory.** In `projects-map` (agent-config `skills/projects-map/SKILL.md`): move Media Center to Active with the new one-liner ("Daily poller filling life-data media tables (episodes, YouTube, feeds) keyed by durable ids; `media_feed` view; Modal cron; vault `Media Center`"). Write a memory file `project_media_center.md` (type project) with the decisions, the follow list, the poller-writes-facts deviation, and the deferred items, and add its line to `MEMORY.md`. Commit and push agent-config.

* [ ] **Step 4: Final verification.** `life check` clean; `just logs` from the last cron shows all three sections; `SELECT count(*) FROM media_feed` > 0; media-center `git status` clean and pushed; Synapse and derivations CI green.

***

## Self-review

**Spec coverage.** Tables and columns (Task 8), follow semantics and defaults (8, 9), everything-ingested rule (6: every show and channel regardless of follow), feed view (8), poller (2 to 6), scrapers via `scrape:links` (5), X row skipped (5, 6) and its separate plan (constraints, 13), derivations change (7), Synapse retarget (12), migration and Legacy (9, 11, 13), ops and cron slot (10), status unification (8, 12), podcasts untouched (13 renames the migration task), error handling (6: per-source try/except, id-based cursor), testing (each task; E2E in 10 and 12). Reality-show automation task (13). Deferred items as tasks (13).

**Placeholders.** None: every command and code block is complete; the one conditional (view breaks tooling) has its fallback stated.

**Type consistency.** `HubClient.pull/push`, `imported_from`, `now_iso` (Task 2) are what Tasks 3 to 6 import; `tmdb.episode_rows` columns match `tv_episodes` (Task 8); `youtube.video_rows` columns match `youtube_videos`; `feeds.article_rows` columns match `articles`; `feeds` row columns read by `sync_feeds` (`id, fetch, follow, scrape_pattern`) match Task 8; `youtube_channels.backfilled` is created in Task 8 and used in Task 6 and 9; Synapse (Task 12) pushes the same column names.
