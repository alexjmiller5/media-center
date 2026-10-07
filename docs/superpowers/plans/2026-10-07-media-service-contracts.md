# Media Service Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans task-by-task.

**Goal:** Provide bounded, narrowly authorized native reads, edits and capture resolution without exposing operator credentials.

**Architecture:** Extend generic Life Data consumer profiles and query contracts, not its personal schema. Synapse owns capture job state and resolution; a fixed Life Data adapter forwards authorized requests without forwarding device credentials.

**Tech Stack:** Existing Worker JavaScript, core TypeScript, Python/uv/httpx/pytest and synthetic Worker tests.

**Spec:** ../specs/2026-10-07-native-media-center-design.md

## Global Constraints

All constraints and the shared-service approval boundary in 2026-10-07-native-media-center.md apply. Work in isolated checkouts of each owning repo at freshly verified main revisions. Pin released library revisions; never modify a sibling agent's checkout. Use each repo's current test scripts and AGENTS.md before editing.

## Review Focus

Profile config changing under a stored credential (task 1); forbidden columns in filter/sort expressions (task 2); nullable/collated IDs at paging boundaries (task 2); wrong-caller receipt reads (task 3); lost submit replies and repeated UUIDs (task 3).

### Task 1: Profile-bound configuration and narrow metadata

**Files (Life Data):** Modify worker/src/enrollment-profile.js, worker/src/scopes.js, worker/src/login.js, worker/src/index.js, core/src/enrollment-scopes.ts, core/src/enrollment.ts and core/contract/core.json; regenerate existing generated codecs. Create worker/src/consumer-config.js and worker/test/consumer-config.test.js. Extend worker/test/enrollment-profile.test.js, core/test/enrollment.test.ts, fixtures/enrollment policy and docs/scoped-enrollment.md in their existing locations.

**Interfaces:** Extend the profile with optional config `{version:1, namespace:string, bindings:object}` bounded to 16 KiB. Config contains no credentials or URLs to backing infrastructure. `GET /v1/consumer/config` returns `{profile:{id,revision},config}` only to its exact enrolled profile. Profile revision binds canonical config bytes as well as label/scopes; profiles without config retain their current revision algorithm. New metadata grants are `catalog:read:TABLE:COLUMN`; `POST /v1/catalog/projection` accepts `{table,columns}` and returns only those properties' type, static options, description, required and read-only flags. Dynamic option SQL is never disclosed/executed for this caller.

- [ ] Add failing Worker/core tests with these assertions:

```javascript
expect(configFromOtherProfile.status).toBe(403);
expect(configAfterBindingChange.status).toBe(409);
expect(legacyProfileRevisionAfterUpgrade).toBe(legacyProfileRevisionBefore);
expect(metadataForUngrantedColumn.status).toBe(403);
expect(JSON.stringify(projectedMetadata)).not.toContain('SELECT');
```

- [ ] Raise the validated maximum from 64 to 256 distinct grants in every canonical parser and fixture. Test 256 accepted, 257 rejected, duplicates rejected, old receipts still valid and old profiles gaining no new authority. Keep existing total configuration/body limits.
- [ ] Implement config retrieval with a current profile-revision check and no cacheable response. Extend canonical enrollment policy/codecs once; native clients must consume this policy rather than reimplement it.
- [ ] Add synthetic media binding conformance: required logical roles, granted identity/revision/deletion fields, field-type compatibility, missing optional role behavior and no personal mappings in fixtures.
- [ ] Run the owning Worker/core focused tests, generated-contract check and full relevant suites via their existing Bun scripts. Expected: all pass, and removing revision binding or a metadata grant check makes its named test fail. Restore code and rerun.
- [ ] Commit all safe changes, push the review branch, and record the exact candidate contract revision. Deploy only after integration review and existing deployment authorization applies.

### Task 2: Scoped bounded record queries

**Files (Life Data):** Create worker/src/rows-query.js, worker/test/rows-query.test.js, tests/fixtures/hub-query-contract.json and core/src/query.ts; extend worker/src/index.js, worker/src/scopes.js, capability fixtures, canonical contract/generated codecs and core tests. Reuse checkedReads/queryBudget and existing catalog/type/identity helpers.

**Interfaces:** `POST /v1/rows/query` accepts `{table,columns,filter?,order?,limit?,cursor?}`. `filter` is a bounded AST: `and/or` groups and leaves `{column,op,value}` with eq/in/gte/lte/contains/is_null. No SQL strings. `order` contains at most three `{column,direction}` pairs; primary identity is the final tie-breaker. Page limit 1-200, default 50; max 64 leaves, depth 4, IN lists at most 200 values. Reply `{rows,next_cursor}`. Cursors bind normalized request, schema/identity semantics and last sort values; changing filters/order/config invalidates the cursor. Both returned and predicate/sort columns require existing read grants. A new session capability advertises this endpoint.

- [ ] Add failing tests:

```javascript
expect(await pageIds({limit:2})).toEqual(['a','b']);
expect(await remainingPageIds()).toEqual(['c','d']);
expect(queryWithForbiddenSort.status).toBe(403);
expect(queryWithRawSql.status).toBe(400);
expect(queryWithChangedFilterCursor.status).toBe(409);
expect(queryWithoutCapabilityFallback).toBe(false);
```

- [ ] Implement parameterized query compilation and authorization before row access. Use native SQLite affinity/collation for cursor comparisons; reject unsupported identity shapes rather than applying JavaScript equality. Null sort values follow known values in either direction. Catalog changes during checked reads fail safely.
- [ ] Add equal-date, null-date, NOCASE identity, tombstone, multi-page OR-filter and oversized-expression tests. Do not claim snapshot consistency across separate requests: clients refresh/restart on relevant source/config changes and deduplicate identities.
- [ ] Add an isolated 250,000-record fixture benchmark with a bounded result size and query-plan check for configured indexes. The data migration owns actual index creation; do not add personal table/index literals to Life Data. Record request sizes and time, not personal values. No full-catalog app-start fetch is acceptable.
- [ ] Run focused Worker/core tests and normal full checks. Expected: all pass; mutations removing column authorization, cursor binding and identity tie-breaking fail named tests. Commit/push review branch and pin the contract before native transport implementation.

### Task 3: Typed capture receipts and stateless gateway

Prerequisite: capture/migration task 1 provides the tested `save_media` helper. This task adds transport/receipt lifecycle and reuses that helper; it does not implement a second save path.

**Files (Synapse):** Create src/core/media_capture.py, tests/test_media_capture.py and scripts/media-capture.py; modify src/core/capture_clients.py, src/core/pipeline.py, src/core/handlers.py, app.py, store.py only where needed, and their existing tests. Keep Modal imports in app.py. **Files (Life Data):** Create worker/src/capture-gateway.js, worker/test/capture-gateway.test.js and tests/fixtures/hub-capture-contract.json; extend routing, capabilities, scopes and canonical contract/codecs.

**Interfaces:** `POST /v1/captures/ADAPTER` accepts `{request_id,input:{text?,url?},intent:'save'|'record_consumption',fields?}`; exactly one text/url. `GET /v1/captures/ADAPTER/REQUEST_ID` reads only this caller's receipt. Scope grants are `captures:submit:ADAPTER` and `captures:read:ADAPTER`. Gateway adapters are fixed HTTPS endpoints with independently minted credentials in owning service secrets; the caller cannot supply endpoint/workspace/credential. Never follow adapter redirects or return raw upstream exceptions.

Synapse implements `submit_capture(store, caller, request) -> CaptureReceipt`, `process_capture(store, caller, request_id) -> CaptureReceipt` and `get_capture(store, caller, request_id) -> CaptureReceipt`. Receipt states: received, processing, saved, needs_review, failed, uncertain. A saved receipt includes `{kind,id}` only after a verified committed result. Duplicate caller/request_id with identical input returns the same receipt; a different input returns conflict. The gateway sends an opaque caller subject, never the device token. Synapse only accepts delegated subjects from its separately scoped gateway credential, and keys every receipt by gateway-client plus subject plus request_id.

- [ ] Add failing assertions:

```python
assert repeat_same_request().request_id == first.request_id
assert different_payload_same_id().status_code == 409
assert another_caller_read().status_code == 404
assert queued_reply().state == 'received'
assert lost_write_reply().state == 'uncertain'
assert explicit_save_existing_finished().status == 'Finished'
```

- [ ] Persist requests/receipts in Synapse's existing owned durable store; retain current serialized worker execution. Replay dedupe must use request identity and intent, not only the existing raw-text window. Establish committed receipt/state transitions before retrying a mutation. An uncertain external write is reconciled through supported hub reads before another edit.
- [ ] Add fixed-route gateway authorization, bounded request/reply bodies (64 KiB each), explicit timeouts, per-caller receipt isolation, revocation tests and denial of arbitrary endpoint/workspace inputs. A device authorized only for reads cannot submit captures.
- [ ] Add complete transport tests from synthetic native-shaped request through gateway, Synapse resolver and real synthetic hub insert/patch behavior. Test racing poller insertion, tombstone, ambiguous resolution, duplicate submission and service outage without creating a second queue/database/schedule.
- [ ] Run both repos' focused and full relevant checks; mutate caller isolation and saved-before-commit behavior to prove detection. Commit/push independently reviewable changes and update both AGENTS.md files with the approved shared interface only when approval exists.
- [ ] After exact contract review, mint the gateway's dedicated Synapse credential, configure it server-side, deploy through each owner's CI and verify allowed and denied operations with synthetic records. Retain no plaintext credential files and give no token to the native app other than its Life Data device session.
