# Media Capture and Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans task-by-task.

**Goal:** Make explicit saves lossless across capture and ingestion, then retire subscription tracking and activate the new feed fields.

**Architecture:** Change existing Synapse handlers before any physical column retirement. Use insert-only creation plus revision-checked sparse edits; the daily Media Center poller keeps its existing ownership. Personal migration is an installed-interface operation with private receipts, never committed seed code.

**Tech Stack:** Existing Python/uv/httpx/pytest services and installed Life Data CLI/API.

**Spec:** ../specs/2026-10-07-native-media-center-design.md

## Global Constraints

The index plan's constraints apply. No existing statuses, dates, tags, notes, IDs, tombstones or provenance may be reset by Save or ingestion. No private data migration starts before the exact compatible writer/API releases are verified. The subscription removal is approved; it does not authorize loss of unrelated data or an unverified schema rollout.

## Review Focus

Existing Finished rows recaptured with no status (task 1); concurrent poller insertion (task 1); old writers after column removal (task 2); ambiguous historical saves (task 2); undated feed entries and existing-follow boundaries (task 2).

### Task 1: Preserve state and express capture intent

**Files (Synapse):** Modify src/core/handlers.py, src/core/life_hub.py, src/core/template/databases.yaml and applicable extraction/business-logic code discovered from current pipeline; extend tests/test_handlers.py and tests/test_life_hub.py. Create src/core/media_save.py and tests/test_media_save.py only if shared creation/patch logic cannot fit the existing hub client cleanly. Keep actual table mappings and chosen options in the workspace overlay.

**Interfaces:** `save_media(hub, binding, identity, initializer, requested_values, expected_revision=None) -> SaveReceipt` returns saved identity/revision, needs_review, conflict or uncertain. `intent='save'` supplies only the explicit saved flag on an existing item unless other fields were explicitly requested. `intent='record_consumption'` does not set the saved flag by default. Expose insert/conditional-patch/read operations through the existing hub client rather than writing a second HTTP stack. Gateway processing in service task 3 consumes this helper.

- [ ] Reproduce through the existing capture pipeline before editing: a synthetic Finished video recaptured without explicit status currently receives Not Started. Assert the desired behavior fails:

```python
assert capture_existing(status='Finished', intent='save').status == 'Finished'
assert capture_existing(status='In Progress', intent='save').saved is True
assert capture_existing(note='keep', tags=['Favorite'], intent='save').note == 'keep'
assert capture_past_tense().saved is False
assert new_channel_payload().get('subscription') is None
```

- [ ] Preserve intent explicitly during extraction. Missing Status is not a requested edit. New-item initialization may default to Not Started; existing rows may not. Remove subscription initialization/extraction assumptions and update related cleanup wording.
- [ ] Implement insert-only creation, reread-on-existing and sparse conditional patch. Never replace another writer's row with initializer metadata. A rejection or uncertain response cannot return saved. Tombstones require review; no alternate IDs or implicit restore.
- [ ] Add stable-identity duplicate tests for all supported resolver kinds, blank/ambiguous source resolution, lost insert acknowledgment, user edit racing Save, clock skew, and explicit status/date edits validated together. Preserve source fact/user field ownership.
- [ ] Run focused tests using `uv run pytest tests/test_handlers.py tests/test_life_hub.py tests/test_media_save.py` if the new test file exists; otherwise use the two existing paths. Run `just check` and the full existing nonintegration suite. Expected: green. Mutate the default-status assignment and insert-to-push fallback; named tests must fail, then pass after restoration.
- [ ] Commit/push the review branch. Release compatible code through CI before migration task 2; verify exact source SHA and an isolated end-to-end capture receipt. No personal test record is inserted.

### Task 2: Catalog and schema migration with conservation checks

**Files:** No personal schema/data files in any repository. Use a private session migration directory for backup, intended operations, before/after receipts and unresolved historical-save candidates. After successful migration refresh the owning life-map generated schema through `life doc`, and update only current consumer ownership descriptions. The generic application profile's bindings are service runtime state.

**Interfaces:** Logical item roles gain `saved:bool` default false; logical source roles gain `feed_since:datetime` as a user-adjustable release boundary. Existing follow fields retain their boolean values. Changes use installed `life` operations and supported hub schema/config interfaces. Do not hardcode table bindings in a public migration script.

- [ ] Capture a private supported export and hash it. Inventory active source/item schema, views, rules, field references, writers and grants. Check subscription references in Synapse workspace overlays and all known consumers, not only checked-in template text.
- [ ] Rehearse the exact logged-DDL/catalog operation sequence in an isolated synthetic Life Data context with representative triggers, derived columns, rules and old/new clients. Expected: compatible replication succeeds; unsupported schema changes fail before any live mutation.
- [ ] Verify released Synapse has stopped sending subscription, and the poller never sends it. Retire its catalog property and physical column with the tested supported operation sequence. Preserve prior history unless the installed lifecycle contract explicitly requires a reviewed alternative; never manually rewrite plumbing tables.
- [ ] Add/catalog saved and feed_since, explicit writer ownership and needed query indexes. Existing follows receive the approved activation boundary, not a fabricated historical timestamp. Existing unfollowed sources retain follow=false. Source follow action sets boundary and follow in one conditional row patch.
- [ ] Reconcile explicit saves from positive capture/import evidence only. Preserve proof and exact IDs privately. Ambiguous cases stay unclassified and visible for review; no Not Started-to-saved bulk rule and no assumption that missing provenance proves manual intent. Confirmed In Progress and Priority already surface without guessing saved intent.
- [ ] Sync through the supported credential path, inspect rejections, re-read authoritative schema and sample/aggregate receipts, run `life check` and distinguish pre-existing findings from new regressions. Compare all IDs, statuses/dates, tags/notes, tombstones and provenance with the before snapshot; only intended subscription removal and new fields may differ.
- [ ] Refresh generated life-map docs and current project instructions after successful readback. Stop before claiming migration completion if hub delivery or another installed replica's compatibility remains unverified. Do not bypass auth failures or edit replica internals.

### Task 3: Poller regression and public-release hygiene

**Files (Media Center):** Extend tests/test_pipeline.py, tests/test_insert.py and tests/test_provenance_retry.py as needed; modify production code only for a reproduced regression. Update AGENTS.md/README.md to describe current supported behavior when code ships. Existing app.py remains the sole scheduled updater.

**Interfaces:** Existing `run_daily(hub,http,settings)` preserves saved, feed_since and consumption fields. Source-only refresh patches do not mention either new user field.

- [ ] Add repeat-run assertions:

```python
assert after_second_run['saved'] == before['saved']
assert after_second_run['status'] == before['status']
assert channel_after['feed_since'] == channel_before['feed_since']
assert tombstone_after == tombstone_before
assert len(imported_from_edges) == len(set(edge_ids))
```

- [ ] Run `uv run pytest -m 'not integration'` and `just check`. Expected: green without broadening poller writes. Mutate one sparse refresh to send saved=false; its regression must fail, then restore and rerun.
- [ ] Preserve existing private planning in the owning private Note. Make the compliance backup bundle, scrub personal planning from every published branch/tag using the prescribed history procedure, verify the rewritten histories and coordinate stale-clone recovery. Do not lose concurrent commits or push rewritten refs from an unverified clone. Handle the resulting main push as a deployment-triggering operation under existing approval rules, and watch the actual CI run.
- [ ] Publish current generic docs and update old spec/plan links to their surviving rewritten revisions. Verify remote refs and clean trees. No secret was identified by the planning audit; if one is found, follow secret rotation in addition to history removal.
- [ ] Verify the existing single Modal schedule and a successful run after integration. Check authoritative sampled user-state readbacks after ingestion; execution success alone does not prove each upstream source succeeded.
