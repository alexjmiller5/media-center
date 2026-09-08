# Canonical secrets manifest — 1Password secret references only, SAFE to commit.
# Refs are BY NAME on purpose: op-project-bootstrap parses this file.
# Local dev:       op run --env-file=.env.tpl -- <cmd>   (see justfile)
# Push to Modal:   just sync-secrets
NOTION_API_KEY=op://Media Center/Media Center ENV/NOTION_API_KEY
SOURCE_DBS=op://Media Center/Media Center ENV/SOURCE_DBS
