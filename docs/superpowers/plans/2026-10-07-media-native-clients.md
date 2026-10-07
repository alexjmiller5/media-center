# Native Media Clients Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans task-by-task.

**Goal:** Ship native iPhone and Mac feed, library, capture and consumption controls against the reviewed service contracts.

**Architecture:** One MediaKit package owns feed policy and native client state. Platform shells use native SwiftUI navigation. Shared record state lives in Life Data; bounded caches and local filter preferences live in standard app storage. Canonical enrollment policy runs through the supported Life Data core/JSC entry.

**Tech Stack:** SwiftUI, Foundation, URLSession, Security/Keychain, JavaScriptCore, XcodeGen, Swift Testing/XCTest as appropriate; existing Python ingestion remains intact. iOS 17+ and macOS 14+ template floors.

**Spec:** ../specs/2026-10-07-native-media-center-design.md

## Global Constraints

All index constraints apply. No analytics (explicitly declined). No system notification permission. No player/web renderer for this version. Offline browsing is supported; edits require connection and retain unsent drafts. Source follows/saves/status synchronize; filters remain per device. Do not modify other applications' caches, simulators, enrolled credentials or running sessions.

## Review Focus

Cross-kind ID collisions (task 1); undated releases/timezone rollover (task 1); reconnect to a different endpoint with old cache (task 2); delayed stale patch/capture replies after logout (task 2); bulk episode partial receipts and accessibility-sized controls (task 3).

### Task 1: Pure feed model and deterministic merge

**Files (Media Center):** Create packages/MediaKit/Package.swift; Sources/MediaKit/MediaItem.swift, MediaBindings.swift, FeedPolicy.swift, TVProgress.swift and FeedPager.swift; Tests/MediaKitTests/FeedPolicyTests.swift, TVProgressTests.swift and FeedPagerTests.swift, all beneath that package. Keep fixtures synthetic and deterministic.

**Interfaces:** `MediaKind` cases are movie, tvShow, tvEpisode, youtubeVideo, article and podcastEpisode; source roles are tvShow, youtubeChannel and feed. Optional unavailable roles are omitted, not synthesized. `MediaIdentity: Hashable, Codable { kind: MediaKind, id: String }`; `FeedPolicy.eligible(item: MediaItem, source: MediaSource?, now: Date, calendar: Calendar) -> Set<FeedReason>`; `FeedPolicy.cards(items:sources:preferences:now:calendar:) -> [FeedCard]`; `TVProgress.nextEpisode(episodes: [MediaItem], now: Date, calendar: Calendar) -> MediaItem?`. `FeedPager.loadNext() async throws -> FeedPage` merges stable ordered per-kind page streams and deduplicates compound identities, with explicit hasMore/incomplete state.

- [ ] Write failing tests:

```swift
#expect(reasons(oldUnstarted, followedSinceNow).isEmpty)
#expect(reasons(oldSaved, unfollowed) == [.saved])
#expect(reasons(inProgress, unfollowed).contains(.inProgress))
#expect(cards(tenEpisodesFromOneShow).count == 1)
#expect(cards(twoKindsWithID42).count == 2)
#expect(nextEpisode(specialAndRegular)?.season == 1)
```

- [ ] Implement follow boundary, source deletion, explicit saves, Priority/In Progress ranking, chronological/duration variants, missing values and TV grouping exactly as the spec. Date-only release comparisons use the supplied calendar; never invent UTC instants. Finished/Gave Up/Watched Parts are excluded by default, retained in Library/History.
- [ ] Test all reason overlaps, future saved items labeled upcoming, followed new season on a Finished series, saved/in-progress unfollowed shows, no aired next episode, source removal, null dates/durations and filter changes that never mutate records.
- [ ] Test three sorted streams with duplicate dates and IDs, exhausted/empty pages, canceled loads, changed source/config generations and server cursor rejection. Restart on relevant changes, retain truthful incomplete state and never represent cursor traversal as a cross-request snapshot.
- [ ] Run `swift test --package-path packages/MediaKit --jobs 2` using external private scratch. Expected: pass. Mutations removing kind from identity, follow boundary and show grouping fail their named tests. Commit/push after clean restored checks.

### Task 2: Scoped connection, cache and draft state

**Files:** Create Sources/MediaKit/HubClient.swift, EnrollmentSession.swift, CredentialStore.swift, MediaCache.swift, DraftStore.swift and MediaWorkspace.swift; matching test files. Add scripts/build-enrollment-policy.ts and generated policy resource/codecs from the pinned supported core package; do not hand-edit generated output.

**Interfaces:** `HubClient.query(_ request: RowQuery) async throws -> RowPage`, `patch(_ edit: ConditionalEdit) async throws -> PatchReceipt`, `submitCapture(_ request: CaptureRequest) async throws -> CaptureReceipt`, `captureReceipt(id:) async throws -> CaptureReceipt`. `MediaWorkspace` is MainActor observable state, with connection generation, load state, cached content and a separate unsent draft. Credentials never enter cache/SwiftUI previews.

- [ ] Freeze the released service fixture versions before implementing transport. Write failing URLProtocol/fake-clock tests for revoked token, wrong profile, changed config revision, forbidden metadata, unexpected response shape, write rejection, conflict, timeout and late reply after logout/endpoint switch, plus restart recovery of an unsent draft without an automatic write.
- [ ] Implement supported enrollment through canonical core policy, Keychain device credential storage, explicit logout cleanup and endpoint-bound cache. Obtain runtime bindings/config only through the authorized profile endpoint; validate requested roles against grants and metadata without reproducing the catalog validator.
- [ ] Cache only bounded already-viewed pages using Foundation Codable atomic files under Application Support. Cap content cache at 50 MiB/50 pages with least-recently-used eviction; credentials and unsent drafts are excluded. DraftStore separately persists explicit unsent input as atomic Codable files bound to endpoint, profile revision and credential identity; it never automatically replays a mutation. Logout hides these drafts; discarding them requires an explicit app action. Reconnection revalidates grants before offering recovery. Cache read failure becomes an empty-cache state, never an account reset. Local defaults hold filters. Connection-generation checks reject stale asynchronous replies.
- [ ] Use online conditional patches only. Disable submission while offline but preserve editable drafts; receipt/readback controls Saved state. A timeout stays uncertain until reconciled, and a conflict retains both current values and the requested draft. No unconditional write fallback.
- [ ] Run package tests, canonical fixture conformance and policy-generation reproducibility checks. Expected: green; removing endpoint binding or generation fencing fails named tests. Commit/push after restoration.

### Task 3: Native navigation and complete interactions

**Files:** Create apps/ios/project.yml, apps/ios/App/MediaCenterApp.swift and apps/macos/project.yml, apps/macos/App/MediaCenterApp.swift from the approved platform templates without creating another repo. Shared SwiftUI code lives in packages/MediaKit/Sources/MediaKit/Views/{FeedView,LibraryView,HistoryView,MediaDetailView,SourceDetailView,AddMediaView,ConsumptionReviewView}.swift; add a test-only synthetic launch fixture and platform UI test targets. Add an app icon per the icons skill before claiming native completion.

**Interfaces:** Views consume `MediaWorkspace`; all user actions call its typed commands. `openMedia(identity:)` records only a local open candidate and launches the original URL. `setConsumption(identity:status:date:)`, `save(identity:)`, `setFollow(source:enabled:boundary:)` use typed conditional edits. `markSeasonFinished(show:season:)` presents exact aired rows and tracks one receipt per confirmed edit. `submitCapture(input:intent:)` reuses a persistent request UUID across retries and waits for a resolved saved receipt.

- [ ] Add failing synthetic UI tests for Feed/Library/History navigation, mixed-feed filters, show expansion, direct Add result, save/unfollow preservation and invalid catalog edits. Exercise actual rendered controls and record readback, not model methods alone.
- [ ] Implement native tab/sidebar shells, content imagery, accessible actions and Mac keyboard/multi-selection. Expose only catalog-permitted user edits; source metadata and poller bookkeeping have no editors. Missing optional roles show a clear unavailable state rather than a fake empty catalog.
- [ ] Add nonblocking return-time consumption review. The initial open/return/dismiss/leave-unchanged path must issue zero row patches. Confirmed consumption edits status and matching date together. Review candidates remain device-local; do not introduce another synced personal history table.
- [ ] Add bulk episode preview/progress with explicit row receipts, partial failure and uncertain states. Never report the entire season saved when one episode failed or had a lost acknowledgment; reread before retry. No automatic series status change.
- [ ] Run package/UI tests and render previews, then drive an isolated iPhone simulator and Mac app with screenshots/accessibility trees. Cover maximum Dynamic Type, VoiceOver labels, keyboard focus, offline/read-only/draft states and narrow window layouts. Mutation-test the zero-write dismissal case and one failed episode receipt.
- [ ] Commit/push reviewed UI changes and document actual test tiers. No personal enrollment or hardware acceptance is claimed by synthetic UI tests.

### Task 4: CI, integration and installable delivery

**Files:** Update root justfile, README.md and AGENTS.md; add root flake.nix with generic macOS package/home module as appropriate; adapt .github/workflows/check.yml, build-ios.yml and release-macos.yml from the templates. Scope existing deploy.yml to poller code, lockfile and service configuration changes. Reuse generic scripts/sign-ios.py/install helpers from the templates; personal signing values remain runtime/secret-manager configuration.

**Interfaces:** Preserve existing Python `just test/check/run` behavior and expose native equivalents through a small documented parameter/interface, staying within the repository's concise standard verb set. One project, two native targets, one existing poller. No version or tag is invented during ordinary feature commits; release numbering follows semver when actually releasing.

- [ ] Add CI path-filter and package checks before workflow changes. Native/docs-only commits must not invoke Modal deployment; poller code changes must still do so. Test signing/install helpers with synthetic inputs and no real device IDs in artifacts.
- [ ] Run existing Python checks and all native package/build/test checks through hosted CI when local headroom is insufficient. Keep derived data outside iCloud, respect currently free disk space, and stop only owned processes after each verification.
- [ ] Against approved synthetic service fixtures, run two-client follow/save/status readback, Add via native and Receptor-shaped capture, conflict/revocation/offline cases and subsequent poller preservation. Capture receipt, resulting item and existing-field conservation must all match.
- [ ] Complete the privacy scrub and service/migration prerequisites before release artifacts. Use project-specific credentials and approved shared Apple Signing access; no new provider scope is silently accepted.
- [ ] Sign the iPhone artifact in manual CI with ephemeral encrypted delivery, verify it, install through the paired host and confirm installed identity/version. Build/notarize the Mac release through CI and install declaratively through the project's generic Nix module/config. Follow the installed machine/signing skills at execution time.
- [ ] Watch every required CI/deploy/release run to completion; verify source revisions and installed artifacts separately. Record any genuinely human-only check, clean owned test data/caches/tabs/temporary artifacts, update current project-map and instructions, commit/push all safe changes, then close tracking tasks only after full acceptance.
