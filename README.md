# media-center

A daily poller that ingests TV episodes (TMDB), YouTube uploads (YouTube
Data API) and articles (RSS, generic link scraping, public Bluesky and Chrome
consumer feature updates) into a life-data hub. No frontend - the hub (and
whatever reads it) is the UI.
Runs on [Modal](https://modal.com) as a single daily cron job.

Every tracked show, channel and supported feed is catalogued regardless of
`follow`; follow only controls what a reader surfaces. Existing items keep
their user statuses, dates, notes and tags. Ended shows are checked on every
run to fill missing episodes and refresh changed air dates, titles and
positive runtimes on live episodes with matching stored ownership. Missing
source facts never erase existing values; refreshes leave user fields,
parent IDs, episode numbering and tombstones alone. YouTube deltas page until a nonempty page
is entirely known (or the playlist ends); incomplete writes leave the channel
eligible for a full backfill on the next run.

New items and provenance edges use the hub's atomic `/v1/rows/insert` route.
Existing rows, including tombstones created after our read, remain unchanged.
Primary writes count only the response's `inserted` IDs as new, record
`existing` IDs as known, and account for rejections after each chunk.
After a source failure, the poller re-reads stored IDs before processing
another source. If that recovery fails, it stops that kind while preserving
acknowledged progress. Provenance repair reads stored parent relationships
and creates missing edges even when upstream no longer lists an item.
Existing edges and tombstones are preserved; repairs never reset item state.

Bluesky uses canonical DID-based source URLs and public author feeds. It
retains original posts, quotes and media-only posts, excludes replies and
reposts, and preserves full records plus available embed payloads in optional
JSON `articles.content`. Source handles are not stable IDs. Unrecognized RSS
responses fail safely; recognized empty feeds and recoverable parse warnings
are allowed. Scraped links keep canonical order and the first nonempty title
among duplicate anchors; a wholly untitled link remains untitled.

Chrome consumer feature updates use `fetch = "chrome"` with the exact source
ID `https://www.google.com/chrome/whats-new/archive/`. Each feature card's
stable article ID retains the provider's feature-dialog URL fragment.
JSON `articles.content` stores `{feature_id, text}` with the original feature
instructions. `published_at` is null; no publication timestamp is invented.
Only new IDs are submitted, and the pipeline's atomic insert preserves
existing rows, user state and tombstones.

No notifications are sent. X is skipped by this poller. Flighty Gmail
ingestion is canceled; podcasts have no polling or subscriptions here.

## Durability limits

Creation counts and `detail.created_row=1` require an explicit `inserted`
acknowledgment. A dropped response can leave durable rows uncounted;
reconciliation repairs their missing edges with `created_row=0`. Retrying
insertion cannot overwrite a concurrent capture or tombstone. Existing
provenance edges are also protected by insert-only writes, but the parent
read and edge insert are separate operations, not one transaction.

Sparse TV refreshes and channel flags still use last-write-wins `push`.
They preserve omitted user fields, parents and deletion markers, but their
read-time eligibility checks are not compare-and-set conditions. A TV episode
moved or tombstoned after the read can still receive source metadata changes;
its user fields, parent and deletion marker remain unchanged. Stale/equal
timestamp pushes may be accepted no-ops, so a successful flag response does
not prove the flag changed.

Source walks finish in memory before item writes. YouTube's known-page
boundary assumes no missing older item lies behind that page; an incorrect
`backfilled=1` flag needs a full backfill. RSS/scrape history is limited to
items exposed by the source. Empty uploads playlists are accepted after an
initial 404 only if the channel API confirms the exact playlist and zero
public videos. Later-page failures remain errors, and empty channels keep
being polled for future uploads.

## Layout

```
app.py            Modal shim - image, secrets, cron schedule
src/core/         business logic (plain Python, portable)
tests/            pytest
.env.tpl          secrets manifest (1Password op:// refs, committed)
justfile          test / check / fmt / logs / sync-secrets / deploy / run
```

## Commands

`just test` / `just check` / `just fmt` / `just logs` / `just sync-secrets` /
`just deploy` / `just run` - see AGENTS.md.

Normal releases use the GitHub deploy workflow on a main-branch push or an
approved manual dispatch. Verify the workflow SHA and successful completion;
`[skip ci]` suppresses push deployment. The September 8 implementation plan
is obsolete as an executable runbook; current operating behavior is here
and in AGENTS.md.

## Manual setup

```bash
op-project-bootstrap .env.tpl --repo <owner>/<repo>
```

Then mint a hub token scoped `tables:read,tables:write` on
`tv_episodes`, `youtube_videos`, `articles`, `provenance` and
`youtube_channels` (a `tables:write`-only token cannot pull), plus read on
`tv_shows` and `feeds`, and put it in the
`LIFE_HUB_TOKEN` field of the project's `<Project> ENV` item alongside
`LIFE_HUB_URL`, `TMDB_API_KEY` and `YOUTUBE_API_KEY`.

Other one-time steps that cannot be codified:

- `uv run modal token new` - authenticate this machine with Modal

## Bring your own hub

This service is agnostic to which life-data hub it talks to - any endpoint
implementing `/v1/rows/pull`, `/v1/rows/insert` and `/v1/rows/push` (see `src/core/hub.py`)
works, as long as it has these tables:

| Table | Role |
|---|---|
| `tv_shows` | source list - rows this service reads to know which shows to poll |
| `tv_episodes` | written - new TMDB episodes and sparse refreshes of mutable source facts |
| `youtube_channels` | source list - channels to poll, tracks per-channel backfill state |
| `youtube_videos` | written - uploaded video rows |
| `feeds` | source list - RSS/scrape/Bluesky/Chrome sources; `fetch = "x"` rows are skipped |
| `articles` | written - feed/scrape/Bluesky articles and Chrome consumer feature cards |
| `provenance` | read and written - missing source relationships repaired from live stored items |

`POST /v1/rows/insert` accepts the same `{table, columns, rows}` envelope
as push, atomically leaves existing IDs (including tombstones) untouched,
and returns `{inserted: [ids], existing: [ids], rejected: [...]}`. The
acknowledgment must account for every submitted ID with disjoint outcomes.
An unsupported route or invalid acknowledgment fails safely; there is no
upsert fallback. Deploy the compatible hub before releasing this poller.

Before activating Bluesky, catalog `bluesky` in both `feeds.fetch` and
`feeds.kind`, and optional JSON `articles.content`. Chrome requires `chrome`
in `feeds.fetch` and the same optional JSON content field. Activate a Chrome
source only after the compatible hub and poller are deployed.
The hub must validate partial updates against the merged stored row and
preserve omitted columns.
Channel flag writes contain only `id`, `backfilled` and `updated_at`; they
never echo the required user-owned `follow` field.
