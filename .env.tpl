# Canonical secrets manifest — 1Password secret references only, SAFE to commit.
# Local dev:       op run --env-file=.env.tpl -- <cmd>   (see justfile)
# Push to Modal:   just sync-secrets
#
# One line per secret. Reference syntax (no spaces):
#   VAR_NAME=op :// vault / item / field   <- remove the spaces; spelled out
#   because a literal reference in a comment breaks `op inject`.
NOTION_API_KEY=op://MediaCenter/MediaCenter Notion API Key/credential
SOURCE_DBS=op://MediaCenter/MediaCenter Notion API Key/source dbs
