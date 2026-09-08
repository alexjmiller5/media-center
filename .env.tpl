# Canonical secrets manifest - 1Password secret references only, SAFE to commit.
# Refs are BY NAME on purpose: op-project-bootstrap parses this file.
# Local dev:       op run --env-file=.env.tpl -- <cmd>   (see justfile)
# Push to Modal:   just sync-secrets
LIFE_HUB_URL=op://Media Center/Media Center ENV/LIFE_HUB_URL
LIFE_HUB_TOKEN=op://Media Center/Media Center ENV/LIFE_HUB_TOKEN
TMDB_API_KEY=op://Media Center/Media Center ENV/TMDB_API_KEY
YOUTUBE_API_KEY=op://Media Center/Media Center ENV/YOUTUBE_API_KEY
