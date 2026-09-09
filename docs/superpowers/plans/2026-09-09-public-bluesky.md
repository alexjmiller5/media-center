# Public Bluesky Implementation Plan

**Goal:** Add public Bluesky ingestion to the existing article pipeline.
**Architecture:** A plain Python adapter returns existing Entry objects.
Optional content flows through article_rows; the hub pull seam exposes
article tombstones for duplicate detection without changing source pulls.
**Tech stack:** Python 3.13, stdlib, existing httpx and pytest.
**Spec:** ../specs/2026-09-09-public-bluesky.md

Approved scope governs execution in the assigned checkout. Execute inline,
without subagents, production access, secrets, pushes or deployment.

- [x] Run baseline `uv run pytest -q`, ruff check and format check.
- [x] Add tests/test_bluesky.py using synthetic author-feed pages and
  MockTransport. Exercise feeds.entries/article_rows and sync_feeds through
  the real HubClient. Assert history paging, filtering, stable IDs, payload
  preservation, unchanged read/tombstone state, retries and safe failures.
  Run `uv run pytest tests/test_bluesky.py -q` and record expected RED.
- [x] Add core/bluesky.py `entries(profile_url, http) -> list[Entry]` with
  strict page/URI/cursor validation and full pagination. Dispatch from
  core.feeds before URL fetching. Add optional Entry.content and serialize
  only when present. Add keyword-only include_deleted=False to HubClient.pull;
  use True in sync_feeds' known article lookup and adapt the existing FakeHub.
- [x] Run focused and full pytest plus ruff. Mutation-check filtering,
  DID identity, paging and tombstone protection by temporarily breaking
  each behavior, observing failures and restoring the implementation.
- [x] Update AGENTS.md with the adapter and content/soft-delete contract.
  Self-review against every spec requirement and review diff for private
  data.
- Commit all safe changes and write the requested external report with
  RED/GREEN commands, coverage, changed files, SHA and concerns.

- [x] Correct justfile run/logs to use bare `modal`; verify with
  `just --dry-run run` and `just --dry-run logs`. Deployment and secret
  handling are unchanged.
