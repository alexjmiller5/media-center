# my-media-center

Headless pollers that watch media sources — RSS blogs, tech changelogs, later
Trakt (TV) and YouTube — and push updates into Notion. Notion is the UI; this
service has no frontend. Runs on [Modal](https://modal.com) (webhook +
background workers + cron).

## Layout

```
app.py            Modal shim — image, secrets, endpoints, schedules
src/core/         business logic (plain Python, portable)
tests/            pytest
.env.tpl          secrets manifest (1Password op:// refs, committed)
justfile          dev / test / sync-secrets / deploy
```

## Commands

`just dev` / `just test` / `just check` / `just fmt` / `just logs` /
`just sync-secrets` / `just deploy` — see CLAUDE.md.

## Manual setup

Run these once from a desktop-authenticated `op` terminal (a CI service
account cannot create vaults):

```bash
# 1. Project vault + read-only CI service account
op vault create "MediaCenter"
OUT=$(op service-account create "my-media-center-ci" --vault "MediaCenter:read_items" --format json </dev/null)
op item create --category "API Credential" --title "MediaCenter CI op Service Account Token" --vault "<your vault>" "token[concealed]=$(echo "$OUT" | jq -r .token)" </dev/null

# 2. Credentials the app consumes (items referenced by .env.tpl / deploy.yml)
op item create --category "API Credential" --title "MediaCenter Notion API Key" --vault MediaCenter \
    "credential[concealed]=<your Notion integration secret>" \
    "source dbs[text]=<comma-separated data_source IDs of your source DBs>"
op item create --category "API Credential" --title "MediaCenter CI Modal Token" --vault MediaCenter "token-id[concealed]=<id>" "token-secret[concealed]=<secret>"

# 3. CI bootstrap (the single GH secret)
gh secret set OP_SERVICE_ACCOUNT_TOKEN --repo <owner>/<repo> --body "$(op read 'op://<your vault>/MediaCenter CI op Service Account Token/token')"
```

Other one-time steps that cannot be codified:

- `uv run modal token new` — authenticate this machine with Modal
- Mint a Proxy Auth Token in the Modal dashboard for HTTP callers

## Bring your own Notion

Create one or more Notion databases to act as source DBs and list their
`data_source_id`s (comma-separated) in the `SOURCE_DBS` env var. Each source
DB needs these properties (exact names):

| Property | Type | Used for |
|---|---|---|
| `Name` | title | source name / created entry title |
| `Site URL` | url | dedup key for created entries |
| `Feed URL` | url | the RSS/Atom feed to poll |
| `Status` | select | only rows with `Tracked` are polled |
| `Last Checked` | date | poll cursor, advanced by the service |

New entries are written back into the same DB the source row came from, so
target and source share this schema.
