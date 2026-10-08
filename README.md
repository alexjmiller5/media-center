# Media Center

Native iPhone and Mac apps combine saved articles, videos and next TV episodes
in one feed. A daily poller ingests TV episodes (TMDB), YouTube uploads (YouTube
Data API) and articles (RSS, generic link scraping, public Bluesky and Chrome
consumer feature updates) into Life Data.
The poller runs on [Modal](https://modal.com) as a single daily cron job.

## Native clients

The apps require iOS 17+ or macOS 14+. They use the supported Life Data API;
Life UI is another client of that service, not their backend.

Enter your Life Data HTTPS address, open browser approval, and verify the
device code. Each device enrolls its own scoped credential in Keychain.
The service operator configures the `media-center` enrollment profile,
runtime media field/status bindings, catalog metadata and capture adapter.
An unavailable or changed profile requires validated enrollment; clients
never need provider identifiers, operator tokens or poller credentials.
Replacement devices enroll again. Disconnect revokes that device's access.

- Feed combines explicit saves, Priority/In Progress and releases from followed
  sources after their activation date. Older catalog items remain saveable.
- Library and History expose catalog records through runtime filters. A new
  item's Not Started status does not mean it was saved.
- Save, follow and consumption are separate actions. Opening an original link,
  returning or dismissing the review never records consumption.
- TV cards show the next aired regular episode. Season changes require an exact
  preview and show individual receipts, including partial failures.
- Add waits for a resolved saved receipt. Offline input and unconfirmed changes
  remain device-local drafts; nothing retries automatically.
- Already-viewed pages support bounded offline browsing. Filter preferences stay
  on each device; shared saves, follows and consumption live in Life Data.

No analytics or mobile notifications are included.

## Install

**Mac.** Signed, notarized releases are published as GitHub release assets.
Install with Homebrew (`brew install --cask <tap-owner>/tap/media-center`) or
with Nix: add this repository as a flake input, import
`inputs.media-center.homeModules.default` in home-manager and set
`programs.media-center.enable = true;`. Open Media Center, enter your Life Data
HTTPS address and approve the device in the browser.

**iPhone.** Personal builds are Ad Hoc: the phone must be registered in the
signing team and included in the app's Ad Hoc profile. The manual
**Build iOS Ad Hoc** workflow archives, signs and verifies the app, then
uploads only an age-encrypted IPA for one day. Keep the private age identity
local and pass only its public recipient:

```sh
umask 077; dir=$(mktemp -d)
age-keygen -o "$dir/identity.txt"
gh workflow run build-ios.yml --ref main -f artifact_recipient="$(age-keygen -y "$dir/identity.txt")"
gh run watch <run-id> --exit-status
gh run download <run-id> -D "$dir"
age --decrypt -i "$dir/identity.txt" -o "$dir/MediaCenter.ipa" "$dir"/ios-ad-hoc-*/App.ipa.age
IOS_DEVICE_ID=<udid> just install "$dir/MediaCenter.ipa"   # paired Mac, same network
just ota "$dir/MediaCenter.ipa"                            # or: tailnet install link
```

`IOS_INSTALL_HOST=<ssh host>` installs through the Mac the phone is paired to.
Delete `$dir` after installation. Each device then enrolls on first launch.

## Development

```bash
just gen          # XcodeGen projects for apps/ios and apps/macos
just test         # poller pytest + MediaKit model tests
just test ios     # synthetic iPhone XCUITests (IOS_TEST_DESTINATION selects the simulator)
just test macos   # synthetic Mac XCUITests
just check        # ruff, workflow/signing script tests, unsigned iPhone and Mac builds
just run ios --synthetic --test-id "$(uuidgen)"   # Debug app with isolated synthetic data
```

Keep derived data outside cloud-synced folders (`IOS_DERIVED_DATA`).
Native CI runs the model tests, the signing/release helper tests, both platform
builds and synthetic UI interactions, including largest Dynamic Type iPhone layouts. Fixtures never enroll a personal device. The
generated canonical enrollment policy is checked against its pinned Life Data
revision; see [service contracts](tests/contracts/README.md).

## Daily ingestion

Every tracked show, channel and supported feed is catalogued regardless of
`follow`; follow only controls what a reader surfaces. Existing items keep
their user statuses, dates, notes and tags. Ended shows are checked on every
run to fill missing episodes and refresh changed air dates, titles and
positive runtimes on live episodes with matching stored ownership. Missing
source facts never erase existing values; refreshes leave user fields,
parent IDs, episode numbering and tombstones alone. YouTube deltas page until a nonempty page
is entirely known (or the playlist ends); incomplete writes leave the channel
eligible for a full backfill on the next run.

New items and provenance edges use the hub's atomic `/v1/rows/insert` route.
Existing rows, including tombstones created after our read, remain unchanged.
Primary writes count only the response's `inserted` IDs as new, record
`existing` IDs as known, and account for rejections after each chunk.
After a source failure, the poller re-reads stored IDs before processing
another source. If that recovery fails, it stops that kind while preserving
acknowledged progress. Provenance repair reads stored parent relationships
and creates missing edges even when upstream no longer lists an item.
Existing edges and tombstones are preserved; repairs never reset item state.

Bluesky uses canonical DID-based source URLs and public author feeds. It
retains original posts, quotes and media-only posts, excludes replies and
reposts, and preserves full records plus available embed payloads in optional
JSON `articles.content`. Source handles are not stable IDs. Unrecognized RSS
responses fail safely; recognized empty feeds and recoverable parse warnings
are allowed. Scraped links keep canonical order and the first nonempty title
among duplicate anchors; a wholly untitled link remains untitled.

Chrome consumer feature updates use `fetch = "chrome"` with the exact source
ID `https://www.google.com/chrome/whats-new/archive/`. Each feature card's
stable article ID retains the provider's feature-dialog URL fragment.
JSON `articles.content` stores `{feature_id, text}` with the original feature
instructions. `published_at` is null; no publication timestamp is invented.
Only new IDs are submitted, and the pipeline's atomic insert preserves
existing rows, user state and tombstones.

No notifications are sent. X is skipped by this poller. Podcasts have no
polling or subscriptions here.

## Durability limits

Creation counts and `detail.created_row=1` require an explicit `inserted`
acknowledgment. A dropped response can leave durable rows uncounted;
reconciliation repairs their missing edges with `created_row=0`. Retrying
insertion cannot overwrite a concurrent capture or tombstone. Existing
provenance edges are also protected by insert-only writes, but the parent
read and edge insert are separate operations, not one transaction.

Sparse TV refreshes and channel flags still use last-write-wins `push`.
They preserve omitted user fields, parents and deletion markers, but their
read-time eligibility checks are not compare-and-set conditions. A TV episode
moved or tombstoned after the read can still receive source metadata changes;
its user fields, parent and deletion marker remain unchanged. Stale/equal
timestamp pushes may be accepted no-ops, so a successful flag response does
not prove the flag changed.

Source walks finish in memory before item writes. YouTube's known-page
boundary assumes no missing older item lies behind that page; an incorrect
`backfilled=1` flag needs a full backfill. RSS/scrape history is limited to
items exposed by the source. Empty uploads playlists are accepted after an
initial 404 only if the channel API confirms the exact playlist and zero
public videos. Later-page failures remain errors, and empty channels keep
being polled for future uploads.

## Layout

```
app.py            Modal shim - image, secrets, cron schedule
src/core/         business logic (plain Python, portable)
tests/            pytest
packages/MediaKit shared native model, transport and enrollment policy
apps/             iPhone/Mac shells, shared SwiftUI and synthetic UI tests
nix/              signed Mac release package and home-manager module
.env.tpl          secrets manifest (1Password op:// refs, committed)
justfile          gen / test / check / fmt / run / install / ota / logs / sync-secrets / deploy
```

## Commands

See AGENTS.md. `just run poller` performs one ingestion on Modal.

Poller releases use the GitHub deploy workflow on a main-branch service change or an
approved manual dispatch. Verify the workflow SHA and successful completion;
`[skip ci]` suppresses push deployment. Native and documentation changes do
not trigger poller deployment.

## Manual setup

```bash
op-project-bootstrap .env.tpl --repo <owner>/<repo>
```

Signing CI reads shared Apple signing material, so the project CI service
account needs read access to that signing vault as well as the project vault
(service-account grants are fixed at creation). Native signing also needs:

- repository variables `IOS_PROVISIONING_PROFILE_ID` (App Store Connect ID of
  the app's active `IOS_APP_ADHOC` profile), `MACOS_PROVISIONING_PROFILE_ID`
  (its `MAC_APP_DIRECT` profile, which backs the Mac Data Protection Keychain)
  and `HOMEBREW_TAP_REPOSITORY` (`owner/repo` of the cask tap);
- an `IOS_DEVICE_ID` field in the project ENV item for the phone the Ad Hoc
  workflow verifies against.

A Mac release is an approved `vX.Y.Z` tag push: CI signs with Developer ID,
notarizes, publishes the zip and `SHA256SUMS`, then updates the cask. After it
succeeds, set `version` and `hash` in `nix/package.nix` to the published asset.

Then enroll the poller with a Life Data profile granting broad `tables:read`
and `tables:write` (`life login --profile <id> --name "Media Center poller"
--start pending.json`, approve the printed URL, then
`life login --claim pending.json --wait`) and put the printed token in the
`LIFE_HUB_TOKEN` field of the project's `<Project> ENV` item alongside
`LIFE_HUB_URL`, `TMDB_API_KEY` and `YOUTUBE_API_KEY`. Per-table grants cannot
replace the broad pair: the poller reads and inserts `provenance` edges, and
`provenance` is a reserved table no table-scoped grant can name.

Other one-time steps that cannot be codified:

- `uv run modal token new` - authenticate this machine with Modal

## Bring your own hub

This service is agnostic to which life-data hub it talks to - any endpoint
implementing `/v1/rows/pull`, `/v1/rows/insert`, `/v1/rows/push` and
`/v1/rows/patch` (see `src/core/hub.py`)
works, as long as it has these tables:

| Table | Role |
|---|---|
| `tv_shows` | source list - rows this service reads to know which shows to poll |
| `tv_episodes` | written - new TMDB episodes and sparse refreshes of mutable source facts |
| `youtube_channels` | source list - channels to poll, tracks per-channel backfill state |
| `youtube_videos` | written - uploaded video rows |
| `feeds` | source list - RSS/scrape/Bluesky/Chrome sources; `fetch = "x"` rows are skipped |
| `articles` | written - feed/scrape/Bluesky articles and Chrome consumer feature cards |
| `provenance` | read and written - missing source relationships repaired from live stored items |

`POST /v1/rows/insert` accepts the same `{table, columns, rows}` envelope
as push, atomically leaves existing IDs (including tombstones) untouched,
and returns `{inserted: [ids], existing: [ids], rejected: [...]}`. The
acknowledgment must account for every submitted ID with disjoint outcomes.
An unsupported route or invalid acknowledgment fails safely; there is no
upsert fallback. Deploy the compatible hub before releasing this poller.

Before activating Bluesky, catalog `bluesky` in both `feeds.fetch` and
`feeds.kind`, and optional JSON `articles.content`. Chrome requires `chrome`
in `feeds.fetch` and the same optional JSON content field. Activate a Chrome
source only after the compatible hub and poller are deployed.
The hub must validate partial updates against the merged stored row and
preserve omitted columns.
Channel flag writes contain only `id`, `backfilled` and `updated_at`; they
never echo the required user-owned `follow` field.
