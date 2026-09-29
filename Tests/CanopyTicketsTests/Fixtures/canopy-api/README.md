# ticket-manager's API fixtures

These are ticket-manager's `convex/__tests__/fixtures/canopy-api/` at the commit in `SOURCE_COMMIT`, from its PR 22, which added the read-only API the Tickets plugin reads.
ticket-manager's own tests check its responses against them, and Canopy's tests decode them, so the two cannot drift apart without a test noticing.
`scripts/ticket-manager-stand-in.py` serves them for end-to-end runs and UI checks.
Copy them again, with the new commit in `SOURCE_COMMIT`, when the API changes.
