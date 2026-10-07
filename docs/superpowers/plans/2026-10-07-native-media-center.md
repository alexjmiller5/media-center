# Native Media Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement the linked plans task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Deliver native phone and desktop media discovery with shared saves and truthful consumption tracking.

**Architecture:** Native apps read and conditionally edit scoped Life Data records. A bounded Life Data capture gateway forwards to Synapse's existing resolution pipeline with a dedicated service credential; the existing Media Center Modal poller remains the only scheduled updater. Runtime profile configuration supplies logical media bindings, so personal schemas and source preferences never enter public source.

**Tech Stack:** SwiftUI, Foundation/URLSession/Keychain, JavaScriptCore for canonical enrollment policy; existing Life Data Worker/core; existing Python/uv Synapse and Media Center services; template-based XcodeGen and CI signing.

**Spec:** ../specs/2026-10-07-native-media-center-design.md (approved).

## Global Constraints

- Native iPhone and Mac targets live in the existing public Media Center repository.
- Single combined feed; one TV card per show; no mobile media pushes.
- Existing-record saves preserve unrequested fields and use current revisions.
- Follow affects future feed inclusion, never catalog retention or ingestion.
- No personal schema/source lists, credentials, artifacts containing device IDs or migration receipts in Git.
- No broader credential fallback, Life UI internals, direct infrastructure bindings or duplicated validators.
- Tests precede code; exercise rejected mutations and real user-visible paths before acceptance.
- Deployment is through reviewed commits and CI; new live integration wiring requires the concrete contract below to be approved.
- Source work, test state and credentials are isolated from normal app launches and the enrolled personal estate.

## Review Focus

1. A delayed capture reply after a retry cannot reset watched state or create another item. Service plan task 3 and migration plan task 1 cover this.
2. A changing source catalog between pages cannot make the UI claim a complete snapshot. Service plan task 2 and native plan task 1 cover cursor reset and refresh semantics.
3. A server changes the binding for an existing profile without changing scopes. Service plan task 1 tests configuration-revision binding and reenrollment.
4. Following a source with missing or date-only release facts must not invent precision. Native plan task 1 covers undated and midnight/timezone cases.
5. Bulk episode edits can partially succeed or lose their reply. Native plan task 3 tests per-row receipts, retained drafts and uncertain outcomes.

## Execution order and deliverables

1. [Service contracts](2026-10-07-media-service-contracts.md): profile metadata, bounded queries, capture receipts and gateway. Each is independently testable in synthetic contexts before deployment.
2. [Capture and migration](2026-10-07-media-capture-migration.md): preserve user state, remove subscription writers, then migrate through installed interfaces with private receipts.
3. [Native clients](2026-10-07-media-native-clients.md): shared feed/model tests, platform apps, integrated capture/edit flows, accessibility/runtime acceptance and installation.

Dependency order: service tasks 1-2, capture/migration task 1, service task 3, capture/migration tasks 2-3, then native transport/UI/release. Native model tests can run against frozen synthetic contracts while service work is reviewed. Real enrollment, personal-data migration and releases stay behind the contract and acceptance prerequisites. Do not declare the whole application complete after one plan. Original tracking tasks remain open until their actual scope passes acceptance.

## Proposed shared-service contract requiring approval before wiring

| Owner | Consumer | Exact interface/access | Rotation/deletion effect |
|---|---|---|---|
| Life Data | Media Center device | Scoped profile configuration, projected metadata/query, conditional field edits, capture submit and own receipt read | Device revocation disconnects that device; poller and other devices retain their credentials |
| Synapse | Life Data capture gateway | Dedicated workspace-bound gateway credential, submit structured capture and read only that gateway caller's receipts | Revocation stops new/receipt capture operations through this gateway; browsing and ordinary record edits remain available |
| Life Data | Synapse | Existing supported hub interface, with dedicated Synapse credential; save/create and conditional edits on configured media roles | Revocation stops Synapse media writes; native browsing and the independent poller remain available |

Reason: direct Add needs server-side provider resolution and an eventual saved-item receipt while native setup remains one service URL and enrollment. The gateway is a fixed configured adapter, not arbitrary URL forwarding. The device token never reaches Synapse. Provider credentials remain with their owning resolver. Gateway configuration and credentials are service-side runtime state, documented in both owning projects' AGENTS.md only after approval.

No new database, bucket, queue or schedule is assumed. Synapse uses its existing owned durable state for capture receipts. Life Data's gateway is stateless. New resource needs discovered during implementation require a concrete ownership decision before provisioning.

## Release sequencing and completion

- [ ] Complete synthetic contract tests and independent review; publish compatible Life Data/Synapse capabilities and verify exact released revisions.
- [ ] Complete the public-repository privacy scrub with private backup and rewritten-ref receipts before creating release artifacts. Keep a mapping for the design/plan links affected by rewritten hashes.
- [ ] Complete the approved data migration and prove every source/item identity, consumption field, tombstone and unrelated provenance remains intact.
- [ ] Complete native unit, preview, simulator and Mac runtime checks, including two-client readback and capture failure cases.
- [ ] Scope CI so native/docs changes do not redeploy the poller; watch every triggered verification/deployment run.
- [ ] Sign/install via the platform templates, verifying artifacts and installation separately. Do not substitute a simulator pass for actual installation.
- [ ] Record accepted behavior, remaining human-only checks and exact resume commands in the existing private handoff/tasks. Close tasks only when their promised behavior is delivered.

Analytics: explicitly declined. Remove template analytics wiring; no analytics project, SDK or events.

## Plan review result

Spec requirements 1-10 map respectively to native tasks 1/3, migration task 2, capture task 1, native task 1, native task 3, native task 3, native task 3, service tasks 1/3 and release checks, service tasks 1/2 and migration task 2, and migration task 3. Scope limits, query scale and capture creation are explicit service work, not assumed existing capabilities. Proposed endpoint names and types below are new contract designs and must be released before clients depend on them.
