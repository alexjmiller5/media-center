# Cross-service contracts

## Capture

Run with tested Soma and Synapse development checkouts and a Python
interpreter containing Synapse's locked dependencies:

```sh
CONTRACT_SOMA=/path/to/soma \
CONTRACT_SYNAPSE=/path/to/synapse \
CONTRACT_PYTHON=/path/to/synapse/.venv/bin/python \
bun test tests/contracts/capture_gateway.test.ts
```

The test starts an ephemeral loopback hub over in-memory SQLite and a synthetic
Synapse process. It exercises the real gateway, resolver, receipt lifecycle,
insert-only creation and conditional patches. Only AI extraction is replaced
with deterministic content. No personal configuration, installed state, provider
credentials or external network service is used. Both processes exit afterward.

Assertions cover saving new/existing items, a competing poller insert, duplicate
and conflicting request IDs, caller isolation, tombstones, non-media classifier
output, and a lost write reply reconciled without repeating the mutation.

## Poller grants

Run with a tested Soma development checkout and a Python interpreter holding the
poller's locked dependencies (`uv sync`, then `.venv/bin/python` or the
`UV_PROJECT_ENVIRONMENT` interpreter):

```sh
CONTRACT_SOMA=/path/to/soma \
CONTRACT_PYTHON=/path/to/venv/bin/python \
bun test tests/contracts/poller_grants.test.ts
```

The test checks `docs/poller-profile.json` with Soma's profile validator, then
runs the poller three times against an ephemeral loopback hub over in-memory
SQLite, with synthetic TMDB, YouTube and RSS sources: with exactly the
profile's grants and no saved state, with broad reads, and with the profile
again on the saved state. Assertions cover feed-boundary patches, item inserts,
TV refresh and channel-flag pushes, canonical edge IDs, stored three-part edges
left unduplicated, and refusals of provenance reads, three-part edge IDs and
source-row pushes. Dropping any single grant fails it.
