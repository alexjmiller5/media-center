# Cross-service capture contract

Run with tested Life Data and Synapse development checkouts and a Python
interpreter containing Synapse's locked dependencies:

```sh
CONTRACT_LIFE_DATA=/path/to/life-data \
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
