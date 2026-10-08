# AGENTS.md

Media Center: native iPhone and Mac clients plus a daily poller that ingests TV episodes (TMDB), YouTube
uploads (YouTube Data API) and articles (RSS, link scraping, public Bluesky
and Chrome consumer feature updates) into a Life Data hub.
The Python service runs on Modal as a single cron job.
`packages/MediaKit` contains native client models, feed rules, scoped HTTP
transport, canonical enrollment policy, bounded content cache and draft state.
Device enrollment uses browser approval and a device-local Keychain credential.
`apps/ios` and `apps/macos` are XcodeGen platform shells; `apps/Shared`
contains SwiftUI navigation, enrollment, feed/library/history, direct capture,
source follows and explicit consumption controls. Synthetic launch data is
Debug-only and uses an isolated test directory. Release clients obtain role
bindings, catalog metadata and status choices through their scoped Life Data
consumer connection. They never hold poller or operator credentials.

## Architecture rule (the one that matters)

**Business logic lives in `src/core/` as plain Python with NO Modal imports.**
Only `app.py` imports `modal` - it is the deployment shim (image, secrets,
cron schedule). This keeps the logic portable: the same `core` package runs
in tests or on any future platform.

- The poller has no HTTP endpoints; its only trigger is the daily
  cron (`app.py`'s `daily` function), plus `just run` for an on-demand run.
- Cron: Modal is the PREFERRED home for schedules - but the Starter plan
  allows **5 deployed crons across ALL apps**, so track the budget. Overflow
  goes to GHA cron or CF Cron Triggers (see the `infra` skill).

## Stack

uv · pydantic-settings (env config) · httpx · structlog · pytest · ruff.
Config comes from env vars only: Modal Secret in the cloud, `op run` locally.
`.env.tpl` is the canonical secrets manifest (op:// refs, committed).
Instantiate `Settings()` inside functions, never at import time.

Native clients use Swift 6, SwiftUI, Foundation, Security/Keychain and
JavaScriptCore, with no external Swift dependencies. Application Support
holds bounded content pages, validated nonsecret connection snapshots and
independent unsent drafts. Browser approval enrolls one revocable device
credential; replacement devices enroll again. Consumer field edits use
revision-checked sparse patches. Capture submission uses the Life Data
adapter and displays Saved only after its resolved saved receipt.
Catalog-permitted notes, tags and consumption dates are edited through explicit
revision-checked patches. Feed filters persist in device-local defaults, scoped
to the validated connection. Opening media and dismissing a review never changes
consumption state. The Drafts screen recovers locally preserved captures with
stable request IDs and offers read-only receipt/current-value checks; it never
replays them automatically. Full TV-show details are read independently from
episode cards. Source feed starts use explicit conditional catalog edits and
never change item consumption state. Catalog date-only values are Gregorian;
calendar comparisons retain the device time zone. A revoked credential or changed enrollment profile on any
read, edit or capture path clears visible content and cached pages while
preserving unsent drafts for later validated recovery.
Mac lists support native keyboard selection. Explicit Save/Unsave on selected
items applies independent revision-checked patches and reports each rejected
item; it never changes consumption or source follows. Unconfigured media types
remain visibly unavailable in filters.
There is no analytics SDK or mobile notification permission.

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
- Podcasts have no polling or
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
| `just gen` | XcodeGen for `apps/ios` and `apps/macos` |
| `just test` | pytest + MediaKit `swift test`; `just test ios` / `just test macos` run that app's synthetic XCUITests |
| `just check` / `just fmt` | ruff, signing/workflow script tests, unsigned iPhone Simulator and Mac builds / ruff fix |
| `just run [ios\|macos\|poller] [args]` | Debug app on a simulator or the Mac (`--synthetic --test-id <uuid>` for isolated fixtures), or one ingestion on Modal |
| `just install <ipa>` / `just ota <ipa>` | Install a verified Ad Hoc IPA on `IOS_DEVICE_ID` (optionally via `IOS_INSTALL_HOST`) / serve a tailnet install page |
| `just logs` / `just sync-secrets` / `just deploy` | Poller logs / push `.env.tpl` into Modal / fallback poller deploy |

`run poller` and `logs` call bare `modal` so the installed authentication wrapper
is used; `uv run modal` bypasses it. Derived data defaults to
`~/Library/Developer/Xcode/DerivedData/MediaCenter` (`IOS_DERIVED_DATA`).

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

## YouTube offline job (mac mini)

`jobs/youtube-offline/` is a separate uv project and sub-flake
(`github:alexjmiller5/media-center?dir=jobs/youtube-offline`): package plus
`darwinModules.default` (`services.media-center.youtube-offline`), installed on
the mac mini as a kept-alive launchd user agent. It follows the mini-job
template's outbound long-poll architecture: it consumes a Life Data
`durable-pull-v1` subscription on `youtube_videos.offline_requested`, treats
events as wake-ups, reconciles from the rows (also at startup), and ACKs a batch
only after its pass succeeds. For each requested row that is not `ready` it
downloads with nixpkgs yt-dlp/ffmpeg (H.264 mp4 at <= 720p first, so AVFoundation
can play it anywhere), uploads content-addressed immutable parts
(`youtube/<id>/<sha256>`, at most `part_bytes` = 90 MiB each, under Cloudflare's
100 MB request body limit) and patches `offline_status`/`offline_file`/
`offline_bytes`/`offline_error` against the row's current revision. Retries
5 min/30 min/2 h/12 h then give up; budgets persist in the state dir before
each attempt and reset when the request toggles. A storage cap refuses new
downloads with `storage_full`; retained files cannot be deleted through the hub,
so every `ready` row counts. Its credential is its own (grants in the job
README), read from the mini's login Keychain via `credentialCommand`; the
operator copy is `Media Center YouTube Offline Life Data Token` in the project
vault. Tests use an in-process fake hub and a fake yt-dlp (`just test` in the
job directory; CI `youtube-offline.yml`). The job writes no other column and
never touches the poller's tables.

Native playback: `packages/MediaKit/Sources/MediaKit/OfflineVideo.swift` parses
`offline_file` (only content-addressed `youtube/<id>/<sha256>` parts of that
video), and `OfflineVideoCache` (behind `OfflineVideoStore`) downloads each part
through `HubClient.downloadFile` (`files:read:youtube/`), verifies size and
SHA-256, and joins them into `Application Support/MediaCenter/Offline`.
`apps/Shared/OfflineVideoView.swift` shows Download / Play offline on a YouTube
detail when the connection binds the `offlineFile` role to a `json` column. The
`media-center` enrollment profile must carry `tables:read`/`catalog:read` for
`youtube_videos.offline_file`, `files:read:youtube/` and the `offlineFile`
binding before release clients see it; until then the controls stay hidden.
Debug synthetic data publishes one offline part; the UI test
`testOfflineCopyDownloadsThenPlaysWithoutWriting` covers the flow.

## Native delivery

- iPhone: manual `build-ios.yml` (workflow_dispatch, public age recipient input).
  It downloads the app's `IOS_APP_ADHOC` profile by repository variable
  `IOS_PROVISIONING_PROFILE_ID` through the App Store Connect API, checks the
  `IOS_DEVICE_ID` ENV field against it, signs in a temporary keychain
  (`scripts/sign-ios.py`), verifies the run-stamped build and uploads only the
  age-encrypted IPA for one day. Install with `just install` or `just ota`.
- Mac: `release-macos.yml` runs only for stable `vX.Y.Z` tags. It downloads the
  app-owned `MAC_APP_DIRECT` profile (`MACOS_PROVISIONING_PROFILE_ID`), archives
  a universal Release with `Signing/MediaCenter.entitlements` (application
  identifier for the Data Protection Keychain; Debug/test builds stay ad hoc and
  omit it), exports with Developer ID, verifies both architectures
  (`scripts/verify-macos-signing.py`), notarizes, staples, then publishes the
  zip plus `SHA256SUMS`. A separate job updates the cask in
  `HOMEBREW_TAP_REPOSITORY` via checkout credentials, never a token URL. The
  signing job restores the runner's keychain search list in an `always()` step.
- Signing CI reads the documented shared Apple Signing vault exception (P12s,
  ASC key, tap token) through the project CI service account; the apps never
  receive these credentials. CI never creates certificates or profiles.
- `flake.nix` exports `packages.<darwin>.media-center` (the published zip,
  unmodified) and `homeModules.default` (`programs.media-center.enable`).
  `nix/package.nix` pins the latest release's version and hash.
- Ordinary changes never bump `MARKETING_VERSION` or push a release tag.

## Native domain library

`packages/MediaKit` is a dependency-free Swift package for iOS 17+ and macOS 14+.
It uses compound media identity, runtime record/source bindings and runtime
consumption-state mappings. Filter preferences never mutate catalog records.
Run `swift test --package-path packages/MediaKit --jobs 2` with a private
`--scratch-path` outside cloud-synced folders. Tests contain only synthetic data.
Cross-service capture checks and their explicit dependency paths are documented
in `tests/contracts/README.md`; they run entirely against temporary synthetic state.

Native policy and codecs are generated from a pinned Life Data revision with
`bun scripts/build-enrollment-policy.ts <life-data-checkout>`. Add `--check` to
verify reproducibility; do not edit files under `Generated/` or the policy JS.
The JSC adapter calls canonical policy without importing replica or SQL code.
Content cache is bounded to 50 pages/50 MiB, partitioned by endpoint, profile
revision and credential fingerprint. Drafts live separately, keyed by endpoint
and enrollment profile so they survive revision changes and re-enrollment; they
are never automatically submitted or erased on disconnect. A confirmed edit or
saved capture removes its draft; conflicting, uncertain or refused ones stay. Write receipts and readback
control success; uncertain or conflicting patches cannot be silently replayed.
Enrollment uses the `media-center` service profile and configuration namespace.
Installation-specific table/field/status mappings and duration units come from
that profile. Canonical policy rejects broad grants, and native binding checks
reject grants to unrelated fields. Status mappings must equal the catalog's
status options exactly. Reconnect checks the stored exact scope set
and profile revision. One device credential is active per installation: a new
enrollment revokes earlier ones, and a credential that can no longer connect is
revoked (or dropped once the service answers 401). A failed read during a session
switches to cached pages; the next successful read on the validated session ends
the outage, while snapshot browsing revalidates through "Try again". Cancelled
reads never count as outages. Cancelled or expired candidates remain in Keychain only
for revocation retries until the hub confirms revocation; they cannot connect.
Nonsecret connection snapshots allow previously viewed offline pages without
enabling writes or recovering drafts until session revalidation succeeds.
