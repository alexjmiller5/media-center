# my-media-center

Headless pollers that watch media sources — RSS blogs, tech changelogs, later
Trakt (TV) and YouTube — and push updates into Notion. Notion is the UI; this
service has no frontend. Runs on [Modal](https://modal.com) (webhook +
background workers + cron).

Notion project: [My Media Center](https://www.notion.so/31103953a8af8132ba7ff2f1a3759b81)

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

## Manual setup (Alex)

The overnight agent's 1Password service account cannot create vaults or write
to Personal, so run these once from your own terminal (desktop-authenticated
`op`):

```bash
# 1. Project vault + read-only CI service account
op vault create "MediaCenter"
OUT=$(op service-account create "my-media-center-ci" --vault "MediaCenter:read_items" --format json </dev/null)
op item create --category "API Credential" --title "my-media-center-ci SA Token" --vault Personal "token[concealed]=$(echo "$OUT" | jq -r .token)" </dev/null

# 2. Credentials the app consumes (items referenced by .env.tpl / deploy.yml)
op item create --category "API Credential" --title "Notion API Key" --vault MediaCenter "credential[concealed]=<your Notion integration secret>"
op item create --category "API Credential" --title "Modal my-media-center" --vault MediaCenter "token-id[concealed]=<id>" "token-secret[concealed]=<secret>"

# 3. CI bootstrap (the single GH secret)
gh secret set OP_SERVICE_ACCOUNT_TOKEN --repo alexjmiller5/my-media-center --body "$(op read 'op://Personal/my-media-center-ci SA Token/token')"
```

Other one-time steps that cannot be codified:

- `uv run modal token new` — authenticate this machine with Modal
- Mint a Proxy Auth Token in the Modal dashboard for HTTP callers
