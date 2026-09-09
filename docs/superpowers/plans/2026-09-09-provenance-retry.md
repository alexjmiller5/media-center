# Provenance retry repair

Approved review fix: reconcile missing imported_from edges for feeds, TV
and YouTube using live stored item parent columns and existing provenance
IDs. Reconciliation runs after source ingestion, independently of whether
upstream still lists an item. Existing edges (including tombstones) and
item state must not be overwritten. Old-item repairs carry created_row=0;
only items accepted as new in this run may carry created_row=1.

1. Baseline suite/static checks, then real HubClient/MockTransport RED cases
   for provenance rejection, lost HTTP responses and restart after item
   acceptance across all three ingestion kinds.
2. Replace per-source edge pushes with one shared reconciliation helper per
   kind. Count edge rejection/failure; derive edges from stored relationships.
   Include all item tombstones in ingestion duplicate checks.
3. Verify stored-owner repair, unchanged user state/edges/tombstones,
   cumulative rejection counts when a later edge chunk fails, and mutation
   checks. Update the current-state spec and AGENTS.md, commit locally,
   append verification and findings disposition to the handoff report.
