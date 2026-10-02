# Unanswered-demand operations view

The authorized operator page `/admin/operations` separates questions waiting for a guide, waiting for a guide's answer, and waiting for the traveler's review. It shows oldest registered questions first, can filter a catalog city and can load beyond the old 200-record discovery limit.

This is a read-only view of recorded work. It does not allocate guides, mark anyone online, promise a response time or change balances, escrow, refunds or question states. Operational staffing, response deadlines and settlement decisions remain owner gates.

## API

`GET /api/admin/operations/questions?status=open|assigned|answered&country=...&city=...&cursor=...`

- Active current administrator required. The user row is rechecked and held after the shared moderation gate; an earlier authentication snapshot cannot preserve a revoked role
- Default status is open. Country and city must be supplied together and match the catalog; canonical and legacy aliases share a filter identity
- Fixed 20-record keyset pages, oldest creation time then ID. Signed cursors bind account, status and city while preserving PostgreSQL microseconds
- Response is `{items, next_cursor, summary: {open_count, assigned_count, answered_count}}`
- Counts cover all three statuses in the selected geography, independent of the page and selected status. Counts, records and flags come from one SQL statement snapshot
- Compact records include question references, title, geographic labels, status, offered points, escrow state, registration/update timestamps and five flags: hidden question, suspended traveler, suspended guide, unapproved guide participation and bilateral blocking
- Hidden/restricted obligations remain visible to authorized operators. Body text, images, comments, answers, participant profiles and contact information are not expanded
- Accepted, cancelled, expired and legacy disputed/reported records are outside this three-state operational queue. The view does not claim to be a complete audit log

The UI labels registration and last-change timestamps as recorded times, not exact assignment durations. It never substitutes a failed count request with zero. Transient errors label any remaining in-memory rows as previously loaded; authorization failure, account switch or role/suspension change clears private rows and counts. Status/city changes invalidate old responses. No operation data is written to persistent client storage.

The administrator home also has a retry for a failed profile read. The compact personal and operator APIs participate in the existing negotiated streaming gzip path; denied responses, auth, exports and images remain excluded.

## Related account-boundary repair

The profile's old location controllers retained a prior account's city. More seriously, a delayed GPS lookup could call `PATCH /profile` only after the user had switched accounts, using the new account's session.

The profile now renders the current server profile directly and binds location work to the initiating account, session token and request generation before starting GPS. Account changes or reauthentication discard that old result before any HTTP mutation; late acknowledgements cannot alter another session's visible state. Location permission scope is unchanged.

Five regressions cover displayed city replacement, old GPS completion, late HTTP acknowledgement, same-account reauthentication and a valid current-account update. Three original failures were demonstrated before repair.

## Verification

Real PostgreSQL/HTTP tests cover revoked, suspended and deleted admins, 247-row microsecond/tie pagination, aliases/cursor scope, restricted obligations, concurrent transitions with coherent counts and unchanged financial/workflow state. Client tests cover access loss, late filter results, interrupted paging, exact/unknown counts, city choice, detail navigation and doubled text. A synthetic Korean operator screen was rendered by Flutter and visually inspected.

The integrated milestone passed 396 Flutter tests, 107 real PostgreSQL/backend tests, analysis and a production web build. It remains local source; no new hosted preview, native iOS compilation, signing, production service or App Store submission is implied.
