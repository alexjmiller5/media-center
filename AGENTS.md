# AGENTS.md

my-media-center: headless pollers (RSS blog/changelog watcher now; Trakt +
YouTube sync later) that push updates into Alex's Notion DBs. Notion is the
UI — no frontend here. Python service deployed on Modal: HTTP webhook +
spawned background workers + cron.

## Architecture rule (the one that matters)

**Business logic lives in `src/core/` as plain Python with NO Modal imports.**
Only `app.py` imports `modal` — it is the deployment shim (image, secrets,
endpoints, schedules). This keeps the logic portable: the same `core` package
runs in tests, on the mac mini via launchd, or on any future platform.

- Webhook → worker handoff is `process.spawn(payload)` — Modal's spawn IS the
  queue. Do not add Pub/Sub/Redis/celery.
- Endpoints use `requires_proxy_auth=True` — callers send `Modal-Key` +
  `Modal-Secret` headers (mint tokens in the Modal dashboard → Settings →
  Proxy Auth Tokens). Never expose an unauthenticated endpoint.
- Cron: Modal is the PREFERRED home for schedules — but the Starter plan
  allows **5 deployed crons across ALL apps**, so track the budget. Overflow
  goes to GHA cron or CF Cron Triggers (see the `infra` skill).

## Stack

uv · pydantic-settings (env config) · httpx · structlog · pytest · ruff.
Config comes from env vars only: Modal Secret in the cloud, `op run` locally.
`.env.tpl` is the canonical secrets manifest (op:// refs, committed).
Instantiate `Settings()` inside functions, never at import time.

## Commands

Standard verb set (see global AGENTS.md) — the justfile is the interface,
not a script catalog; one-offs go in `scripts/` and run directly.

| Command | Purpose |
|---|---|
| `just dev` | Live-reload dev against real Modal infra (`modal serve`) |
| `just test` / `just check` / `just fmt` | pytest / ruff read-only / ruff fix |
| `just logs` | Stream deployed-app logs |
| `just sync-secrets` | Push `.env.tpl` → Modal secret store |
| `just deploy` | test + sync-secrets + `modal deploy` |

## TDD

Write the test in `tests/` first, then the `src/core/` code. `app.py` shim
functions stay thin enough to not need tests.

## What exists (2026-07-07 overnight)

RSS watcher vertical slice — all unit-tested, no live calls in tests:

- `src/core/watcher.py` — `parse_feed` (feedparser; RSS 2.0 + GitHub
  releases.atom fixtures in `tests/fixtures/`), `new_entries` (cursor = the
  source row's Last Checked timestamp / optional last GUID), `route` (new
  entries go back to the DB the source row came from; a routing-rules layer
  is the upgrade path if one feed ever needs to split)
- `src/core/notion.py` — thin httpx `NotionClient`: `list_sources` (keeps
  Status=Tracked rows with a Feed URL), `upsert_entry` (dedup by Site URL),
  `mark_checked` (advances the cursor)
- `src/core/pipeline.py` — `poll_all_sources()` over the `SOURCE_DBS` env
  var (comma-separated data_source IDs, see `core/config.py`);
  per-source failures are logged and skipped, cursor advances only on success
- `app.py` `main()` — one local poll run:
  `op run --env-file=.env.tpl -- uv run python app.py`

NOT deployed yet: the Modal cron slot (5 total across all apps) needs Alex's
sign-off — see the ASSUMPTION comment in `app.py`.

## Setup status

1Password vault (`MediaCenter`) + CI service account do not exist yet — see
"Manual setup" in README.md. Until then `just sync-secrets`,
`just deploy`, and CI deploys will fail on the op:// references.

## Notion IDs (source-of-truth DBs for pollers)

Created 2026-07-06 (overnight sprint). Use `data_source_id` for all API calls
(`Notion-Version: 2026-03-11`).

| DB | data_source_id | Purpose |
|---|---|---|
| Tech Changelogs | `0296e086-a630-4a78-9dd9-c935f00a67f4` | Tracked changelog sources (Name, Site URL, Feed URL, Status Tracked/Paused, Last Checked, Notes) |
| Blogs | `6cbb5c8a-30b7-4332-8f06-36a706c7c646` | Tracked blog sources (same schema) |
| Blog Posts | `31203953-a8af-8021-91bb-000b1468b912` | Pre-existing stub (title only) — where scraped posts land |
| YouTube Posts | `31203953-a8af-80e0-96f1-000b140d566a` | Pre-existing stub |

Rows with an empty Feed URL need special handling (no RSS exists) — see each
row's Notes property.
