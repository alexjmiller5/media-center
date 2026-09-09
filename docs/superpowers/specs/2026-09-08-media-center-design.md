# Media Center - design (2026-09-08)

## What this is

A release radar you pull from, not a push. Every show, channel and feed the
user cares about is ingested in full into life-data tables keyed by durable
external ids. New items keep arriving daily. A **feed** is a query over
those tables: unconsumed items from sources the user has flagged `follow`,
newest first. Consumption is recorded on the rows themselves (status plus a
date). No notifications, ever.

The reader is whatever exists: an agent running `life sql` today, Life UI
later. Nothing in this design depends on a UI.

Reframed from the 2026-02 scope (Notion pollers, Trakt, push notifications)
after the life-data migration made Notion the wrong destination and the user
decided against mobile notifications.

## Decisions (settled with the user, 2026-09-07/08)

* Tables hold **every available item** from every known show, channel and
  feed. Shows and channels include their back catalogs; RSS/scrape sources
  contribute items exposed by their feed or page. A source followed later
  already has its catalogued history browsable. `follow` only decides what
  surfaces in the feed.
* **TV**: every show in `tv_shows` gets its episodes, Gave Up included, so
  watched/unwatched is logged per episode. All shows start `follow = 1`.
* **YouTube**: all 149 channels from the Notion YouTube Channels DB are
  ingested with `follow = 0`. Follow on for: Fireship, Dave Jorgenson,
  Veritasium, Last Week Tonight. kiidkatze's channel to be looked up. Rejected:
  ThePrimeagen, Dwarkesh Patel, Summoning Salt, infrabren, jtreezy69.
* **Feeds** (all follow on): Cherri GitHub releases, Notion blog, Raycast
  blog, Waymo Waypoint blog, Home Assistant blog, Works with Home Assistant
  blog, Chrome what's-new, Flighty newsletter, MacStories, and the X account
  intcyberdigest.
* **Podcasts**: no polling, no follows. Rows are captured manually (Synapse,
  Spotify ids per the existing 2026-09-04 migration task). Life UI note: a
  podcast row in `Not Started` belongs in the to-watch section.
* **Reddit** as a source: no.
* **Reality-show wrap-up** (Love Is Blind, The Ultimatum): not here. Becomes a
  notion-automations spec once that app reads life-data: finishing a season
  creates a task to read the season's online drama, Reddit threads and memes.
* **Status vocabulary** unified across all media tables, taken from movies:
  `Priority`, `Not Started`, `In Progress`, `Finished`, `Watched Parts`,
  `Gave Up`. tv\_shows' `Watched Some` (6 rows) renames to `Watched Parts`.
* Out of scope, permanently: push notifications, an iOS media app, short-form
  video from TikTok/Instagram, Trakt, Apify.
* Deferred, separate tasks: YouTube subscription two-way sync; watch-history
  imports (Google Takeout, Netflix, HBO); newsletters via Gmail as a source
  kind if the Flighty newsletter has no web feed.

## Architecture

```
                         life-data hub (D1 + catalog + derivations sweep)
                                   ^ rows/push (tables:write token)
                                   |
  media-center (Modal, daily cron) -+-- TMDB       (episodes, air dates)
                                    +-- YouTube    (Data API uploads playlist: page to known boundary daily, all pages for backfill)
                                    +-- RSS/Atom   (feeds table)
                                    +-- scrapers   (pages with no feed)
  media-center-x (mac mini launchd) ---- x.com via logged-in Chrome  -> same articles table

  derivations (Modal): the tv endpoint also returns tmdb_status + watch_providers
  Synapse: youtube-videos and youtube-channels categories retarget to life-data
  Readers: `life sql` (agents) now; Life UI later. The feed is a SQL view.
```

Business logic stays in `src/core/` as plain Python with no Modal imports,
as the repo already does. `app.py` keeps only the cron function; the webhook
endpoint is deleted (no caller exists).

## Data model (life-data)

All tables are created through `life table create` with typed catalog
properties and documented in life-map before any row lands (the table
authoring standard). Row id = the source system's stable id. Row origin is a
`provenance` edge, never a column.

**Facts the poller already holds are written by the poller** (video title,
duration, published time; episode title, air date, runtime; article title
from the feed entry). They are source facts captured at ingest, recorded
under the row's `imported_from` edge. Hub derivation is reserved for
`tv_shows` (status and streaming providers), because the hub's sweep derives
50 rows per property per 15 minutes and a 100k-row YouTube back catalog would
take weeks to fill that way. Synapse-captured videos get the same columns
from the YouTube API call Synapse already makes.

### Shared columns

Every media item table has: `status` (select, required, the unified
vocabulary, default `Not Started`), `date_watched` (date, nullable, meaning
"finished on"; `date_read` for articles), `note` (text), `published_at`
(datetime, poller-written, the item's release time) plus the sync columns
life-data adds. `tags` (JSON array, user-curated) is on `youtube_videos`
and `articles` only - `tv_episodes` has none by design.

### youtube\_channels - id = YouTube channel id (`UC...`)

| col                   | type            | notes                                                                                                                                         |
| --------------------- | --------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| follow                | bool, default 0 | surfaces the channel's videos in the feed                                                                                                     |
| backfilled            | bool, default 0 | poller flag: full back catalog accepted; deltas page to a nonempty fully known page; incomplete writes clear the flag                                                      |
| title                 | text            | from the YouTube API at seed / first sight                                                                                                    |
| handle                | text            | `@fireship`                                                                                                                                   |
| uploads\_playlist\_id | text            | `UU...`, the Data API back-catalog handle                                                                                                     |
| channel\_url          | url             | the URL as originally saved                                                                                                                   |
| content\_type, tags   | JSON arrays     | migrated from Notion Content Type / Tags                                                                                                      |
| subscription          | select          | migrated Notion Status: `Subscribed`, `Unsubscribed`, `To Watch`, `Never Subscribed`, `Legacy`. Informational until the deferred two-way sync |
| notion\_id            | text            | former Notion page id, dash-stripped                                                                                                          |

### youtube\_videos - id = 11-char YouTube video id

| col                                               | type                     | notes                                                                                           |
| ------------------------------------------------- | ------------------------ | ----------------------------------------------------------------------------------------------- |
| channel\_id                                       | ref -> youtube\_channels | required                                                                                        |
| title, duration\_s, published\_at, thumbnail\_url | poller / Synapse written | from `playlistItems.list` / `videos.list`                                                       |
| is\_short                                         | bool                     | duration <= 180s heuristic; feed filter only                                                    |
| status, date\_watched, tags, note                 | shared                   | Notion `To Watch` -> `Not Started`, `Watched` -> `Finished`, `Priority`/`In Progress` unchanged |
| notion\_id                                        | text                     | migrated rows only                                                                              |

### feeds - id = the canonical feed or page URL

| col             | type             | notes                                                                  |
| --------------- | ---------------- | ---------------------------------------------------------------------- |
| kind            | select, required | `blog`, `changelog`, `newsletter`, `x`                                 |
| follow          | bool, default 1  |                                                                        |
| title           | text             | user-typed at seed time                                                |
| fetch           | select, required | `rss`, `scrape:links`, `x` - how the poller reads it                   |
| scrape\_pattern | text, nullable   | for `scrape:links`: regex an `<a href>` must match to count as an item |

### articles - id = canonical item URL (tracking params stripped, host lowercased)

| col                            | type                   | notes                                                                |
| ------------------------------ | ---------------------- | -------------------------------------------------------------------- |
| feed\_id                       | ref -> feeds, nullable | null for manual saves                                                |
| title, published\_at           | text / datetime        | from the feed entry or scraped link text                             |
| status, date\_read, tags, note | shared                 | Notion Articles `Done` -> `Finished`, `In progress` -> `In Progress` |

### tv\_shows - existing table, three additions

| col              | type                                 | notes                                                   |
| ---------------- | ------------------------------------ | ------------------------------------------------------- |
| follow           | bool, default 1                      | feed surfacing; user flips off per show                 |
| tmdb\_status     | text, derived `http:tmdb_tv`         | `Returning Series`, `Ended`, ... - informational; all shows are polled        |
| watch\_providers | JSON, derived `http:tmdb_tv` from id | US flatrate services, the "where does it stream" answer |

`Watched Some` -> `Watched Parts` on the 6 rows; catalog option list updated.

### tv\_episodes - id = TMDB episode id

| col                            | type                                        | notes                                              |
| ------------------------------ | ------------------------------------------- | -------------------------------------------------- |
| show\_id                       | ref -> tv\_shows, required                  |                                                    |
| season, episode                | int, required                               | inputs for derivation                              |
| title, air\_date, runtime\_min | poller-written from the TMDB season listing |                                                    |
| status, date\_watched, note    | shared                                      | Notion TV Episodes rows import their watched marks |

Ingest rule: every episode of every show in `tv_shows`, regardless of the
show's status.

### The feed

A SQL view, `media_feed`, unioning `(kind, id, title, source, published_at,
status)` from youtube\_videos (channel follow = 1), tv\_episodes (show follow =
1\), articles (feed follow = 1), and (once the podcasts table exists) podcast rows in `Not Started`, restricted
to `status IN ('Not Started', 'Priority')`, ordered by `published_at DESC`.
Life UI's to-watch section is this view; an agent answers "what's new" with
`SELECT * FROM media_feed LIMIT 50`.

## Ingestion service (media-center)

Daily Modal cron, one function, sequential over source kinds; per-source
failures are logged and skipped so one dead feed never blocks the run.

1. **TV**: pull `tv_shows` (`/v1/rows/pull`). For every show, list all
   seasons and push episode ids not yet present. Follow and show status do
   not gate ingestion. Ended shows are checked on every run, so an accepted
   subset never strands the remainder of a partial backfill.
2. **YouTube**: pull every `youtube_channels` row. Backfill: walk every
   uploads-playlist page. Delta: walk pages until a nonempty page contains
   only ids present in the hub at the start of this sync, or the playlist
   ends. Process mixed known/new pages in full; more than 50 new uploads
   between runs must not be lost. Before writing a delta's new videos,
   persist `backfilled = 0`; if that flag write is rejected, skip the channel
   without writing videos. Set `backfilled = 1` only after every video row
   is accepted. Rejections and interrupted writes leave a full walk due on
   the next run. Both flag writes contain only `{id, backfilled, updated_at}`.
   Per-channel RSS is not used; videos and durations come from the Data API.
3. **Feeds**: pull every `feeds` row regardless of follow, excluding
   `fetch = "x"` (handled by the separate job). `rss` uses feedparser;
   `scrape:links` fetches the page and takes every `<a href>` matching the
   row's `scrape_pattern`, with link text as the title. Feed URLs and scrape
   patterns are source data supplied by the user.
4. Each new item is pushed with `status = 'Not Started'` and a `provenance`
   edge `rel = 'imported_from'`, `from_kind` = the source kind, `from_ref`
   \= the source row id, `detail.created_row = 1`.
5. Pushing an item that already exists touches nothing: the push sends only
   the columns the poller owns, and existing rows are skipped by id.

The X account runs separately on the mac mini as a launchd job driving the
logged-in Chrome session (residential IP, no X API): read the account's
recent posts, push each as an `articles` row with `feed_id` = the
intcyberdigest feeds row. Same nix-darwin module pattern as the other mini
jobs.

## Derivations (derivations repo)

One change: the existing `tv` endpoint requests
`append_to_response=credits,watch/providers` and returns two more keys,
`tmdb_status` (TMDB's `status`, e.g. `Returning Series`, `Ended`) and
`watch_providers` (US `flatrate` provider names). Both are cataloged on
`tv_shows` as derived by `http:tmdb_tv` from `id`, so the hub fills them
with no new endpoint and no new secret.

## Migration and cutover

1. Create the tables, add the tv\_shows columns, rename the 6 statuses,
   document all of it in life-map.
2. Import Notion YouTube Channels (149) -> youtube\_channels, YouTube Videos
   -> youtube\_videos (channel resolved from the Notion relation or the video
   itself), TV Episodes -> tv\_episodes watched marks (the 2 linked shows),
   Articles (8) -> articles. Podcasts stay with their own task.
3. Seed `feeds` with the ten decided sources and flip the four channel
   follows on.
4. Retarget Synapse's `youtube-videos` (hub\_table) and `youtube-channels`
   categories to life-data, same pattern as movies.
5. First ingestion run: full TV episode backfill, full YouTube back catalog.
   Then the daily cron.
6. Move the Notion YouTube Videos, YouTube Channels, TV Episodes and Articles
   DBs to Legacy. Short Form Videos, Radio Shows, Videogames and Media
   Consumption go to Legacy too with no import.
7. Close or cancel the 17 Media Center tasks per the decisions above; create
   the notion-automations reality-show task and the kiidkatze lookup task.

## Ops

* media-center: fill the two `CHANGEME` fields in the Media Center vault
  (Modal token id and secret), replace `NOTION_API_KEY`/`SOURCE_DBS` in the
  ENV item with `LIFE_HUB_URL`, `LIFE_HUB_TOKEN` (a `tables:write` token
  minted for this app), `TMDB_API_KEY`, `YOUTUBE_API_KEY`. Deploy = push to
  main, CI runs. Modal cron slot 3 of 5.
* derivations: no new secret; deploy the tv endpoint change via its CI.
* mini job: nix-config module for the X scraper, enabled after switch-mini.

## Error handling

* A source that fails is logged with its id and skipped; the run still
  completes and reports counts per kind.
* A `tv_shows` derivation failure leaves the row underived; the hub retries
  on its sweep. The poller never writes a derived column.
* Duplicate pushes are idempotent by id. A re-run after a partial failure
  is safe.
* TMDB or YouTube quota exhaustion aborts that kind for the day, logged, and
  the next run catches up because the cursor is "ids not yet present", not a
  timestamp.

## Testing

* Unit: parsers against recorded fixtures (YouTube playlist items, TMDB season and
  providers responses, each scraper's saved HTML, feed samples). New-item
  detection given an existing-id set. URL canonicalisation cases.
* Pipeline regressions: repeated runs with partial acceptance, older YouTube
  rejections, interrupted chunk writes, more than 50 new uploads, mixed
  known/new pages, unfollowed RSS/scrape sources, and preserved user fields.
* Integration (marked, skipped in CI): one real fetch per source kind
  against a live endpoint.
* Migration: row counts and a sampled diff between each Notion DB and its
  table; `life check` clean after import.
* End to end: first cron run on Modal produces episode and video rows;
  `SELECT count(*) FROM media_feed` is non-zero; a Synapse YouTube capture
  lands in `youtube_videos` with its channel resolved.

## Requirements (EARS)

1. The system shall store every media item keyed by its source system's stable id (TMDB episode id, YouTube video id, canonical URL) and never by a generated id where an external one exists.
2. The system shall ingest all episodes of every row in `tv_shows` and all videos of every row in `youtube_channels`, and available articles from every supported row in `feeds`, independent of follow or status.
3. When the daily run finds an item whose id is not present, the system shall insert it with status `Not Started` and a provenance edge naming the source row.
4. While a source has `follow = 0`, its items shall not appear in `media_feed`.
5. The system shall never send a notification of any kind.
6. If a source fetch fails, the system shall log the failure and continue with the remaining sources.
7. The system shall never write a hub-derived column (`tv_shows.tmdb_status`, `tv_shows.watch_providers`) from the poller.
8. Where a page has no feed, the system shall use the generic link scraper with the row's `scrape_pattern`, tested against a recorded fixture.
9. The feed view shall order items by `published_at` descending and include only rows in `Not Started` or `Priority`.

