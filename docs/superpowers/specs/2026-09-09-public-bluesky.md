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
Feeds, TV and YouTube shall reconcile missing imported_from edges using
stored live item parent relationships and existing provenance IDs. Existing
edges and tombstones shall not be overwritten. Null parents shall not gain
guessed source ownership. Rejected primary rows shall not gain an edge.

Edge rejection or an interrupted/lost response after item acceptance shall
remain repairable after restart, even if upstream no longer lists the item.
Rejections shall count, including earlier rejected chunks when a later chunk
fails. Repair shall not increment new-item counts or rewrite item state.
Only items accepted as new in the current run shall receive created_row=1;
older-item repairs shall receive created_row=0. No queue or new endpoint
shall be required.

No credentials, dependencies, checkpoints, live account identifiers,
production data access, catalog mutations or deployment are required here.
The controller shall add `bluesky` to feeds.fetch/kind and optional JSON
articles.content through the installed Life interface before activation.

Protocol references: [author-feed lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/getAuthorFeed.json),
[post-view lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/defs.json),
[record-key syntax](https://atproto.com/specs/record-key).
