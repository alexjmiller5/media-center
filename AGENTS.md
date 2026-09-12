# AGENTS.md

media-center: a daily poller that ingests TV episodes (TMDB), YouTube
uploads (YouTube Data API) and articles (RSS, link scraping, public Bluesky
and Chrome consumer feature updates) into Alex's life-data hub.
No frontend, no webhook - life-data (and
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
| `YOUTUBE_API_KEY` | YouTube Data API v3 key (uploads playlist, video details) |

## Module map

| Module | Purpose |
|---|---|
| `core/config.py` | `Settings` - the four env vars above |
| `core/hub.py` | `HubClient` (`pull`/`insert`/`push` against the life-data hub), `imported_from` (provenance edge), `now_iso` |
| `core/tmdb.py` | TMDB show/season lookups -> `tv_episodes` rows |
| `core/youtube.py` | Uploads-playlist paging, video durations, channel resolution -> `youtube_videos` rows |
| `core/feeds.py` | RSS, link scraping, Bluesky and Chrome dispatch -> `articles` rows |
| `core/bluesky.py` | Public author-feed pagination, DID-based post IDs and original content |
| `core/chrome.py` | Chrome What's New archive consumer feature cards, provider IDs and original instructions |
| `core/watcher.py` | `Entry` + `parse_feed` (feedparser wrapper), shared by `feeds.py` |
| `core/pipeline.py` | `sync_tv`, `sync_youtube`, `sync_feeds`, `run_daily` - wires the above into one ingestion pass |

## Rules the poller follows

- **Catalog every tracked source regardless of follow or user status.**
  `follow` only gates the reader's feed. Known items are never reinitialized;
  ingestion preserves user status, watched/read dates, notes and tags.
- TV always checks every show's seasons, including ended shows, so partial
  backfills are retried without a separate completion flag. For known live
  episodes whose pulled `show_id` matches, it refreshes changed `air_date`,
  `title` and positive `runtime_min` values. Null/empty facts and zero/negative
  runtimes never clear existing values. These sparse patches contain only
  changed source facts plus `id`/`updated_at`, never parent, season/episode,
  user fields or `deleted_at`. Refreshes do not count as new episodes.
- YouTube walks all pages until `backfilled = 1`; deltas then continue through
  mixed pages until a nonempty page contains only ids already in the hub, or
  the playlist ends. Before delta writes, it clears `backfilled`; it restores
  the flag only after every video ID is acknowledged as inserted or existing.
  Rejections or interrupted writes leave a full walk due. Flag writes contain only
  `{id, backfilled, updated_at}`. Rejected clear/completion flags increment
  both `rejected` and `failed`; a rejected clear prevents video writes.
- An initial YouTube uploads-playlist 404 counts as an empty successful sync
  only when the channel API confirms that channel owns the playlist and has
  zero public videos. The channel is still polled daily; saved videos are
  preserved. Missing later pages and other failures remain errors.
- **The poller writes source facts; never a derived column.** Anything the
  hub or a downstream consumer computes (e.g. `tv_shows.tmdb_status`,
  `tv_shows.watch_providers`) is out of scope - this service only pushes the
  columns it owns (episode/video/article rows) and never touches those.
- **New items and provenance edges require `/v1/rows/insert`.** The hub
  atomically inserts absent IDs and preserves existing rows, including
  tombstones, even when another writer commits after our snapshot. Snapshot
  ID lookups include tombstones to avoid redundant requests. Primary rows
  are deduplicated by ID. Each chunk's `inserted` IDs alone determine
  new-item counts and creation detail; `existing` IDs also become known,
  without being counted as new. Rejections are counted before the next write.
  After a source failure, stored item IDs (including tombstones) are re-read
  before continuing to another source. If that read fails, this kind stops
  with its acknowledged counts intact; provenance repair and other kinds
  can still run. Unacknowledged writes found by recovery are not counted as
  confirmed creations; missing edges use `created_row = 0`. Rejected IDs
  remain eligible unless a subsequent read finds them stored.
- The insert response must partition submitted IDs into `inserted`,
  `existing` and `rejected`; malformed/incomplete acknowledgments fail the
  source and trigger recovery. Unsupported hubs fail with no fallback to
  `push`. Release the compatible hub before deploying this poller.
- Sparse TV refreshes and channel flags still use `push`. Stale/equal
  timestamp pushes can be accepted no-ops; a flag response alone does not
  prove a flag changed. Refresh ownership is checked at the read, without
  a compare-and-set condition: a concurrently moved or tombstoned episode
  can still receive source-fact changes. Its user fields, parent and deletion
  marker remain unchanged. Insert-only writes do not make the separate
  item-parent read and provenance insertion a single transaction.
- Every new item gets `status = "Not Started"`. After each kind's ingestion,
  shared provenance reconciliation reads live stored items and their parent
  columns (`feed_id`, `show_id`, `channel_id`) and inserts missing
  `imported_from` edges. It does not infer ownership from the current source
  response. Missing/null parents are left alone; manual rows are not assigned
  a source. Existing edge IDs, including tombstones, are never rewritten.
- Provenance repairs run independently of upstream listings and retry after
  rejection, HTTP failure or process interruption. `rejected` includes edge
  rejections, counted per chunk; reconciliation failure increments `failed`.
  Repair never changes item state or increments new-item counts. Edge detail
  uses `created_row = 1` only for item IDs acknowledged in `inserted` in the
  current run; older-item repairs use `created_row = 0`. No durable queue is needed.
- RSS/Atom responses must be recognized by feedparser. Valid empty feeds
  and recoverable parser warnings are allowed; unrecognized documents fail
  with a safe error. Link scraping keeps canonical URL order and the first
  nonempty title across duplicate anchors; all-empty titles remain empty.
- A `feeds` row with `fetch = "chrome"` requires the exact source ID
  `https://www.google.com/chrome/whats-new/archive/`. It ingests consumer
  feature cards from that archive. Stable article IDs retain the provider's
  feature-dialog URL fragment; do not strip it through ordinary URL
  canonicalization. `articles.content` is JSON text `{feature_id, text}`
  preserving the original feature instructions. `published_at` is null;
  the adapter does not invent publication timestamps. Only new IDs are
  submitted, and the pipeline's insert-only write preserves any existing
  row, including user state and tombstones.
- A `feeds` row with `fetch = "x"` is skipped. Any X adapter is a separate
  concern, not part of this poller.
- A `feeds` row with `fetch = "bluesky"` uses a canonical
  `https://bsky.app/profile/<DID>` ID. Every run walks the public author feed
  in full, without credentials, regardless of follow state. Only original
  top-level posts, quotes and media-only posts are ingested; replies,
  reposts and other authors are skipped. Native AT URIs deduplicate posts;
  article URLs contain the DID, never a mutable handle.
- Bluesky `articles.content` is optional JSON text: `{uri, record, embed?}`.
  The record retains full text, facets and original embed data; `embed`
  preserves the post-view payload when supplied. Ordinary feed rows omit
  content. Titles use a bounded first-line preview or a record-key fallback.
  Invalid pages, records, URIs, dates or cursors fail the source before any
  of its articles are written; repeated cursors fail rather than loop.
- Feed logs use hashed source IDs, error classes/HTTP statuses and counts;
  remote messages, content and rejection payloads are never logged.
- It never sends notifications.
- Flighty Gmail ingestion is canceled. Podcasts have no polling or
  subscriptions here. Source identities and feed choices remain data;
  blog feeds, changelogs and technical release feeds are not interchangeable.
- Datetimes sent to the hub are millisecond ISO-8601 (`to_hub_datetime`),
  and rejected entries (from `insert` or `push`) are counted and logged.
  Multiple validation violations for one ID count as multiple rejections;
  rejected IDs are never marked as ingested by that acknowledgment.

## Commands

Standard verb set (see global AGENTS.md) - the justfile is the interface,
not a script catalog; one-offs go in `scripts/` and run directly.

| Command | Purpose |
|---|---|
| `just test` / `just check` / `just fmt` | pytest / ruff read-only / ruff fix |
| `just logs` | Stream deployed-app logs via the installed `modal` command |
| `just sync-secrets` | Push `.env.tpl` → Modal secret store |
| `just deploy` | test + sync-secrets + `modal deploy` |
| `just run` | One ingestion run on Modal, on demand (`modal run app.py`) |

`run` and `logs` call bare `modal` so the installed authentication wrapper
is used; `uv run modal` bypasses it.

## TDD

Write the test in `tests/` first, then the `src/core/` code. `app.py` shim
functions stay thin enough to not need tests.

## life-data tables

This service reads `tv_shows`, `youtube_channels` and `feeds` (the
follow/tracking lists) and writes `tv_episodes`, `youtube_videos`,
`articles` and `provenance`, plus the one flag it owns on a follow list:
`youtube_channels.backfilled` - pushed as a partial row (`{id, backfilled,
updated_at}`), since the hub checks required columns against the merged row.
All new items and provenance edges use `POST /v1/rows/insert`, with the same
`{table, columns, rows}` request envelope as push and an
`{inserted: [ids], existing: [ids], rejected: [...]}` response. Existing IDs
must remain entirely unchanged, including deleted rows. This route requires
the same table write scope; unsupported-route errors never fall back to upsert.
Bluesky ingestion requires `bluesky` options on `feeds.fetch` and
`feeds.kind`, plus optional JSON `articles.content` owned by the poller.
Chrome ingestion requires `chrome` on `feeds.fetch` and the same optional
JSON `articles.content` field.
Provision these catalog properties through the installed Life interface
before activating a source.
Provenance reconciliation additionally reads `provenance` IDs and live
item parent relationships, using the same hub pull endpoint and scoped token.
Table schemas and conventions are documented in
the `life-map` skill - read it before adding a column or a new source table.

## Credential provisioning

`op-project-bootstrap` calls `scripts/provision.py --batch modal-token` to
mint one dedicated CI token pair. Open its stderr URL in the configured
remote browser session and approve the displayed code. Both verified fields
are saved together in the project vault through JSON stdin; no plaintext
credential cache is written. Individual Modal field minting is refused.
