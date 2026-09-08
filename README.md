# media-center

A daily poller that ingests TV episodes (TMDB), YouTube uploads (YouTube
Data API) and blog/feed articles (RSS + generic link scraping) into a
life-data hub. No frontend - the hub (and whatever reads it) is the UI.
Runs on [Modal](https://modal.com) as a single daily cron job.

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
implementing `/v1/rows/pull` and `/v1/rows/push` (see `src/core/hub.py`)
works, as long as it has these tables:

| Table | Role |
|---|---|
| `tv_shows` | source list - rows this service reads to know which shows to poll |
| `tv_episodes` | written - TMDB episode rows |
| `youtube_channels` | source list - channels to poll, tracks per-channel backfill state |
| `youtube_videos` | written - uploaded video rows |
| `feeds` | source list - RSS/scrape sources; `fetch = "x"` rows are skipped |
| `articles` | written - feed/scrape article rows |
| `provenance` | written - one row per created item, linking it back to its source |
