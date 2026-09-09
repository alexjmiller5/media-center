# Public Bluesky ingestion

The poller shall dispatch `feeds.fetch = bluesky` from a canonical
`https://bsky.app/profile/<DID>` source ID. Source identity is state.

The adapter shall request the public author-feed endpoint with the DID,
`filter=posts_no_replies`, `limit=100`, and each returned cursor. It shall
walk every available page every run regardless of follow state. It shall
retain original top-level authored posts, quote posts and media-only posts,
skip reposts, replies and other authors, and deduplicate native AT URIs.
Article IDs shall be `https://bsky.app/profile/<DID>/post/<record-key>` and
shall not depend on returned handles.

Each new article shall have a readable first-line preview (at most 160
characters, with `...` on truncation), or `Bluesky post <record-key>` when
text is empty. Optional `articles.content` shall hold JSON text containing
`uri`, the unmodified `record`, and `embed` when available on the post view.
Full text, facets, quote references and media/link payloads shall survive.
Ordinary RSS and scraped rows shall omit content. Published times shall be
normalized to UTC milliseconds.

Invalid source IDs, post URIs, pages, records, dates, or cursors shall fail
the source. Repeated cursors shall fail rather than loop. API/transport
errors shall propagate to the existing safe failure counter. A failed walk
shall write no partial source history. Logs shall not contain payloads,
source URLs, cursors or remote exception text.

Ingestion shall insert only missing article IDs, including tombstones in
the known-ID set. Existing state and soft deletes shall remain unchanged.
Only accepted new articles shall receive imported_from provenance;
rejected rows shall remain eligible for retry.

No credentials, dependencies, checkpoints, live account identifiers,
production data access, catalog mutations or deployment are required here.
The controller shall add `bluesky` to feeds.fetch/kind and optional JSON
articles.content through the installed Life interface before activation.

Protocol references: [author-feed lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/getAuthorFeed.json),
[post-view lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/defs.json),
[record-key syntax](https://atproto.com/specs/record-key).
