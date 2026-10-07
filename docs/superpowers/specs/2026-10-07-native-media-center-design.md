# Native Media Center design

Status: written design for review. No implementation or live migration is implied.

## Purpose and accepted behavior

Media Center provides native iPhone and Mac apps for choosing something to
watch, read or listen to, and recording consumption. Both apps and the existing
daily ingestion job belong to this public project. Shared media records remain
in Life Data; Life UI is the general client for that service.

The main feed combines new releases from followed sources, explicit individual
saves, and in-progress media. Following a source contributes future releases;
its older catalog remains browsable and individually saveable. TV appears as
one card per show, with episode-level tracking inside. Saving is available
through the apps and through Receptor/Synapse. External YouTube subscription
tracking is removed. No mobile media pushes are introduced.

Public code contains product behavior and synthetic fixtures only. Personal
source choices, mappings, schemas, credentials and migration receipts remain
private runtime state. Repository visibility does not publish catalog data.

## Boundaries and ownership

- Media Center owns native presentation, feed composition, save semantics,
  source ingestion and its existing single daily schedule.
- Life Data owns durable records, catalog validation, history, revisions,
  tombstones, authorization and supported record APIs.
- Synapse owns natural-language classification and capture resolution;
  Receptor remains its input client. Capture integration must preserve the
  same item identity and field ownership as a direct save.
- Native clients never receive the poller's provider keys or hub credential.
  Each caller/service pair has its own scoped credential. Native sessions use
  supported enrollment and device Keychain storage.
- No Life UI private models, UI scraping, backing database bindings or shared
  project infrastructure are dependencies. Reusable Life Data core policy is
  consumed through its supported, versioned library entry points.

## Native presentation

One shared Swift package contains media identity, presentation models, feed
composition and transport interfaces. Separate iPhone and Mac targets supply
navigation, platform interactions and app lifecycle. All content lists use
stable compound identity: logical media kind plus the source record ID.

Primary destinations are Feed, Library and History. iPhone uses native tab
navigation; Mac uses a sidebar and detail pane. A content row/card shows its
title, source, kind, release date when known, duration when known and status.
It states why it is present: new release, saved or in progress. Overlapping
reasons do not duplicate the item. Mac supports keyboard navigation and
multi-selection; phone actions remain accessible without swipe gestures.

The visual direction is a quiet native media library: system typography,
platform surfaces and content imagery, with a restrained accent for selection
and progress. Feed controls remain visible without dashboard metrics or a
marketing header. Dynamic Type, VoiceOver, contrast, keyboard focus and reduced
motion are acceptance requirements.

Filters select media type, source, status and YouTube Shorts. Newest, oldest
and duration sorts are available; missing values are labeled and sort after
known values. Search matches title and source. Filter choices are runtime
preferences, not compiled-in source lists. Changing a filter never edits an
item's status, follow state or save intent.

Proposed first-release defaults, subject to review:

- Open content in its original app/site; no embedded player or full article
  renderer in the first release.
- Explicit status/date editing is always available. Returning after opening
  an item makes it eligible for a nonblocking in-app confirmation review.
  Opening only records an interaction, never consumption. Dismissal means
  leave unchanged. There is no mobile notification or weekly schedule.
- Cached content can be browsed offline. Edits require connectivity initially;
  the UI retains an unsent draft and never reports it as saved. Durable offline
  mutation queues are a separate feature, not an implicit promise.
- Filter preferences are local to each device initially. Shared source follow,
  item save and consumption fields synchronize through Life Data.

## Record semantics

The names below describe logical fields. Installation-specific table and column
bindings are runtime configuration accessed through a supported service
contract, never personal schema literals embedded in the app. Cataloged user
fields remain editable elsewhere through Life Data without going through this
app. Provider facts and ingestion bookkeeping remain read-only in the UI.

| Concept | Meaning | Writer |
|---|---|---|
| Source follow | Include eligible future releases from this source | Explicit user action |
| Feed start boundary | Earliest release eligible through this follow period | Explicit follow action or user adjustment |
| Item saved | Explicit queue intent independent of status and source follow | Direct save or explicit capture intent |
| Item status | Existing consumption vocabulary, including Priority | Explicit user action or separately authorized import |
| Consumption date | Existing watched/read/listened date for the kind | Explicit consumption action |
| Tags and notes | User classification and context | Explicit user action/capture |
| Source facts | Provider title, release, duration, image, parent identity | Existing ingestion/derivation owners |

The existing status vocabulary remains intact. Priority continues to express
want-next intent; this version does not migrate all status values into another
model. Saved is independent: an in-progress item can remain saved, and unsaving
cannot mark it finished. Finished, Gave Up and Watched Parts remain browsable
in Library/History; they are excluded from the default active feed. Requeueing
an already consumed item requires an explicit status change, never an automatic
reset caused by Save.

A feed start boundary is a user-adjustable feed eligibility setting, not a
replacement for the history of follow changes. It is stored on the source so
both devices use the same boundary without granting access to unrestricted
history. A fresh off-to-on follow starts a new boundary; source items still
saved or in progress remain eligible independently. Follow off never deletes
records or stops the existing ingestion contract.

Timestamped releases compare their actual release instant against the boundary.
Date-only TV releases compare calendar dates in the configured user timezone;
the UI cannot claim a more precise release time. Unknown publication dates are
not presented as newly released by inference from ingestion time. They remain
available in Library and can enter the feed by explicit save/progress. A product
choice to surface newly discovered undated items must be represented separately.

## Feed eligibility and ordering

An item is eligible when it is live, passes the selected filters, has an active
consumption state, and at least one of these holds:

1. Its source is followed and its known release is on/after the source boundary
   and not in the future.
2. The item is explicitly saved, including saves from unfollowed sources.
3. The item is In Progress or Priority.

Source deletion suppresses automatic source-follow inclusion. An independently
saved item remains accessible if the item itself is still live; missing source
metadata is shown explicitly. Tombstoned items never reappear through a feed
union or save retry. A known future item can be saved and viewed as upcoming,
but it is not described as available to consume.

Default display places Priority items first, then In Progress, then other
eligible items newest first. This is a proposed ranking default. The user may
select a chronological sort instead. Unknown durations never become zero and
unknown dates never become today's date.

The existing narrow SQL media_feed view is not the app's complete feed and is
never a write target. The client combines bounded projections of canonical
records and navigates back to those records for editing.

## TV behavior

A show's feed card groups all its qualifying episode reasons and shows a next
unwatched aired episode. Within the show, episodes are ordered by season and
episode, and show individual statuses and dates. Specials are a separate group
so season zero does not become an accidental prerequisite.

A new season can surface a followed show even when its series status is Finished.
Its next-episode suggestion may be older than the new release, helping the user
resume in sequence. Series status is not automatically overwritten. An explicitly
saved or In Progress series may also surface the next available episode even
when follow is off. Shows with no known eligible aired episode display that fact
rather than inventing an episode.

Marking one episode Finished affects that episode only. A season completion
command previews the exact aired episodes it will change and needs explicit
confirmation. It never marks unaired episodes watched. Series-level status stays
independent; no season or series completion is inferred from navigation or an
external viewing launch. Partially completed bulk writes report exact receipts
and remaining episodes; the UI never claims a cross-row atomic operation unless
the service actually supplies it.

## Capture and save behavior

The public save operation has explicit intent and returns a typed result:
resolved item identity, outcome, and any required user review. The transport
must distinguish received/queued, resolved/saved and failed. HTTP acceptance
alone cannot render Saved.

- Direct Add accepts a link or a supported media lookup and resolves a durable
  source identity. A title-only ambiguous match asks for selection.
- An existing live row receives only the explicit saved intent and any other
  fields the user requested. It keeps consumption state, notes, tags and dates.
- An absent row is created through a supported insert/create operation with
  the same identity scheme as ingestion. A concurrent insertion is reread and
  conditionally edited; it is never overwritten with initializer values.
- A tombstone requires explicit restore handling through its owning service;
  Save cannot silently resurrect it or create a duplicate alternate ID.
- Synapse treats save-for-later separately from a past-tense consumption report.
  Unspecified consumption state never generates a default status update to an
  existing row. An explicit save does not automatically follow its source.
- Poller-created records do not acquire explicit save intent. Manual sources
  and ingestion can discover the same item without creating two copies.
- Failed or uncertain capture retains the submitted input and an honest
  outcome, with retry tied to stable identity and receipt semantics.

The existing Synapse YouTube handler sends a default Not Started on every
capture and still initializes channel subscription. Those behaviors must be
changed and regression-tested before activating the new save contract or
removing the column. Receptor does not gain catalog-specific schema knowledge.

## Service contract work required

Current Life Data supports projected base-table reads and conditional field
patches with expected row revisions, plus canonical scoped device enrollment.
These are suitable foundations for existing-record edits, but they do not yet
constitute the complete consumer contract:

- A browser enrollment profile currently has a 64-grant limit. Complete
  multi-kind projections plus field patches may exceed it. Enumerate the exact
  minimal grants and test a bounded policy extension where required; do not
  replace the design with a broad token or multiple concealed enrollments.
- Projected reads currently provide bounded keyset pages and scalar equality,
  not the complete filter/sort/query surface needed for a large mixed feed.
  Benchmark the actual catalog size using value-free counts. Add a generic,
  scoped bounded query capability if needed; never fetch an unbounded estate
  on app launch or pretend one page is complete.
- Runtime bindings, permitted option metadata and consumer-specific settings
  need a supported scoped configuration/metadata contract. Existing narrow
  profiles do not grant general catalog access. That capability must be
  explicit and tested against unrelated-table disclosure.
- Current device patch enrollment cannot create new rows. Direct Add therefore
  needs a supported capture/create contract, including a resolution receipt and
  its own caller authorization. Reuse Synapse's capture/resolution capability
  with a dedicated consumer contract where it fits; do not copy its provider
  credentials into native apps or treat Receptor's credential as reusable.
- History here initially means consumed items plus their recorded dates. A full
  cell-edit audit timeline requires an independently supported scoped history
  contract and is not implied by the History screen.

These are planned dependency work, not claims that endpoints already exist.
The implementation plan must pin released contracts and record ownership in
both affected projects. Any newly shared service interface or broader provider
scope must be presented concretely before live wiring. The apps' user setup
must remain a service URL plus supported enrollment, not provider facts or
operator tokens. If the required direct capture contract cannot meet that
onboarding boundary, settle its service placement before native implementation.

All row edits use current revision checks. On conflict, keep the user's draft,
show the current row and let them choose the intended edit. On timeout, reconcile
before retrying; an uncertain response is not proof of failure. Catalog rejection
is presented honestly without weakening server validation. Retrying never falls
back to unconditional upsert.

## Migration and rollout

1. Preserve a private backup and inspect every active subscription reader/writer,
   including Synapse templates/overlays, generic views and ingestion/import paths.
2. Ship and verify removal of subscription writes before dropping its catalog
   property and physical column through supported logged schema operations.
   Preserve unrelated history and row identities; do not rewrite historical
   values to fabricate a new classification.
3. Add and catalog explicit saved intent and source feed-boundary fields through
   installed Life Data operations. Record writer ownership and refresh generated
   documentation. Do not embed personal migrations or values in a public repo.
4. Reconcile pre-existing explicit saves only from positive evidence. Not Started,
   absent provenance or a missing source does not establish saved intent. Present
   ambiguous prior captures for review without silently queueing the full catalog.
5. Establish a rollout boundary for already-followed sources without inventing
   historical follow times. Proposed default is activation time, with retained
   saved/progress/priority items and a visible way to browse/save older releases.
6. Provision and verify consumer contracts/credentials; test both allowed actions
   and denied unrelated records/fields with synthetic data before enrollment.
7. Ship native clients through the existing platform templates' CI signing and
   install paths, within this repository. Keep the Modal updater as the one
   scheduled producer. Native UI changes must not force an unnecessary poller
   deployment; scope CI workflows by paths.
8. Verify the actual schedule, a successful invocation and preservation of user
   edits after a subsequent ingestion pass. No second updater is introduced.

The public repository's older planning documents contain private source choices.
Preserve the planning privately and complete the compliance history scrub before
publishing new release artifacts. Generic technical requirements may remain in
public documentation; personal source lists and migration receipts may not.

## Verification and acceptance

Use synthetic catalogs, isolated storage and fake service credentials by default.
A normal app startup must never be used as a shortcut to testing against the
owner's enrolled data. Tests precede implementation, with targeted mutations
that prove important assertions detect a broken transition.

Required end-to-end cases:

- Follow a source with old and new releases; only boundary-eligible releases
  enter Feed, while the complete catalog remains browsable.
- Save an old item directly and via capture; both produce one identity and one
  visible item without resetting status or other user fields.
- Distinguish a past-tense consumption capture from a save-for-later capture.
- Unfollow a source; automatic entries disappear but independent save/progress
  entries remain. A tombstone cannot be resurrected by retry or stale caching.
- Follow, save and edit on one client; the second client reads matching shared
  state. Temporary filters do not mutate records.
- Show a ten-episode season release as one card with accurate episode details.
  Explicit episode/season edits affect only the confirmed rows.
- Opening a link, returning, dismissing a confirmation or deferring review never
  writes Finished or a consumption date.
- Conflicts, rejected writes, lost responses, revoked credentials, offline reads
  and interrupted capture expose truthful states and preserve the user's draft.
- Large catalogs use bounded requests, cancellable loading, deterministic paging
  and no duplicate/omitted records at page boundaries.
- iPhone and Mac runtime checks cover navigation, filters, Add/Save, status/date
  editing, confirmation review, Dynamic Type/VoiceOver and keyboard focus.
- Existing ingestion tests remain green and a second ingestion pass preserves
  save intent, consumption fields, source IDs, provenance and tombstones.

EARS requirements:

1. The system shall present followed future releases, explicit saves and active
   consumption in one deduplicated feed.
2. When a user follows a source, the system shall preserve its full library and
   apply a persisted release boundary to automatic feed inclusion.
3. When an existing item is saved, the system shall preserve all fields not
   explicitly included in the user's requested edit.
4. While a source is unfollowed, the system shall retain independently saved and
   in-progress items and shall continue its established ingestion contract.
5. When a source releases multiple TV episodes, the system shall group them by
   show while preserving individual episode identity and consumption state.
6. If a write conflicts or has an uncertain outcome, the system shall preserve
   the draft and reconcile through the supported service before another edit.
7. The system shall require explicit consumption evidence/action before changing
   consumption state; opening or dismissing content shall not establish completion.
8. The system shall keep every app consumer credential independent of ingestion,
   operator and provider credentials.
9. The system shall expose only catalog-permitted user fields as editable and
   shall preserve service-side validation, provenance and tombstones.
10. The system shall retain a single daily updater owned by this project.

## Review checklist

Accepted product decisions are listed at the top. Proposed defaults needing
written-spec review are external playback, return-time in-app confirmation,
online-only edits with cached browsing, device-local filters, ranking and the
activation boundary for existing follows. Service contract work above must be
resolved in the implementation plan; no unsupported API, full replica, invented
history or personal-data import is approved by this document alone.
