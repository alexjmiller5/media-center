# AGENTS.md

media-center: a daily poller that ingests TV episodes (TMDB), YouTube
uploads (YouTube Data API) and blog/feed articles (RSS + link scraping)
into Alex's life-data hub. No frontend, no webhook - life-data (and
whatever reads it) is the UI. Python service deployed on Modal as a single
cron job.

## Architecture rule (the one that matters)

**Business logic lives in `src/core/` as plain Python with NO Modal imports.**
Only `app.py` imports `modal` - it is the deployment shim (image, secrets,
cron schedule). This keeps the logic portable: the same `core` package runs
in tests or on any future platform.

- No HTTP endpoints - nothing calls this app; the only trigger is the daily
  cron (`app.py`'s `daily` function), plus `just run` for an on-demand run.
- Cron: Modal is the PREFERRED home for schedules - but the Starter plan
  allows **5 deployed crons across ALL apps**, so track the budget. Overflow
  goes to GHA cron or CF Cron Triggers (see the `infra` skill).

## Stack

uv · pydantic-settings (env config) · httpx · structlog · pytest · ruff.
Config comes from env vars only: Modal Secret in the cloud, `op run` locally.
`.env.tpl` is the canonical secrets manifest (op:// refs, committed).
Instantiate `Settings()` inside functions, never at import time.

### Env vars

| Var | Purpose |
|---|---|
| `LIFE_HUB_URL` | Base URL of the life-data hub API |
| `LIFE_HUB_TOKEN` | Bearer token, scoped `tables:read,tables:write` on the tables below (a write-only token cannot pull) |
| `TMDB_API_KEY` | TMDB v3 API key (show/season lookups) - account-level key, shared with the derivations project since TMDB issues only one v3 key per account |
| `YOUTUBE_API_KEY` | YouTube Data API v3 key (uploads playlist, video details) - this project's own dedicated key, minted for media-center |

## Module map

| Module | Purpose |
|---|---|
| `core/config.py` | `Settings` - the four env vars above |
| `core/hub.py` | `HubClient` (`pull`/`push` against the life-data hub), `imported_from` (provenance edge), `now_iso` |
| `core/tmdb.py` | TMDB show/season lookups -> `tv_episodes` rows |
| `core/youtube.py` | Uploads-playlist paging, video durations, channel resolution -> `youtube_videos` rows; the row normalizers (`parse_iso8601_duration`, `to_hub_datetime`, `is_short`, `thumbnail_url`) come from the shared `media_fields` package, never a local copy |
| `core/feeds.py` | RSS parsing + generic link scraping -> `articles` rows |
| `core/watcher.py` | `Entry` + `parse_feed` (feedparser wrapper), shared by `feeds.py` |
| `core/pipeline.py` | `sync_tv`, `sync_youtube`, `sync_feeds`, `run_daily` - wires the above into one ingestion pass |

## Rules the poller follows

- **The poller writes source facts; never a derived column.** Anything the
  hub or a downstream consumer computes (e.g. `tv_shows.tmdb_status`,
  `tv_shows.watch_providers`) is out of scope - this service only pushes the
  columns it owns (episode/video/article rows) and never touches those.
- **New-item detection is "id not yet in the table"**, checked against the
  hub's actual pulled state at the start of each sync - not an in-run
  accumulator. A partial or repeated run is always safe.
- Every pushed row gets `status = "Not Started"`; every new item also gets a
  `provenance` row (`rel = "imported_from"`) via `core.hub.imported_from`.
- A `feeds` row with `fetch = "x"` is skipped - X/Twitter scraping is a
  separate mac-mini job, not this poller's job.
- It never sends notifications.
- Datetimes pushed to the hub are millisecond ISO-8601 (`to_hub_datetime`
  from `media_fields`), and a rejected row (the hub's `push` `rejected` list)
  is counted, logged and never marked as ingested.

## Commands

Standard verb set (see global AGENTS.md) - the justfile is the interface,
not a script catalog; one-offs go in `scripts/` and run directly.

| Command | Purpose |
|---|---|
| `just test` / `just check` / `just fmt` | pytest / ruff read-only / ruff fix |
| `just logs` | Stream deployed-app logs |
| `just sync-secrets` | Push `.env.tpl` → Modal secret store |
| `just deploy` | test + sync-secrets + `modal deploy` |
| `just run` | One ingestion run on Modal, on demand (`modal run app.py`) |

## TDD

Write the test in `tests/` first, then the `src/core/` code. `app.py` shim
functions stay thin enough to not need tests.

## life-data tables

This service reads `tv_shows`, `youtube_channels` and `feeds` (the
follow/tracking lists) and writes `tv_episodes`, `youtube_videos`,
`articles` and `provenance`, plus the one flag it owns on a follow list:
`youtube_channels.backfilled`. Table schemas and conventions are documented in
the `life-map` skill - read it before adding a column or a new source table.
