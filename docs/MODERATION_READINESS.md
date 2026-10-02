# User-generated content safety: implemented controls and release decisions

Verified against [Apple App Review Guideline 1.2](https://developer.apple.com/app-store/review/guidelines/#user-generated-content) on 2026-10-02. Apple calls for a way to filter objectionable submissions, reporting and timely handling, blocking abusive users, and published contact details. It also holds the developer responsible for removing violating content. The controls below are technical building blocks; they do not establish App Store compliance or guarantee approval.

The repository folder name is not a decided product or service brand. No production moderator, public support address, response-time promise, external moderation service, payment processor, or deployment is established by this work.

## API and client contract

All routes are under `/api`, require a current bearer session, and accept JSON. Every safety mutation requires an `Idempotency-Key` of 8–128 letters, digits, or `_.:-`. Retry the same intent with the same key and body; changed input requires a new key. Clients must clear affected cached lists and detail screens after a successful block or moderation action.

| Route | Payload or response |
| --- | --- |
| `POST /reports` | `{target_type, target_id, reason, details?}` → 201 `{id,status:"open"}` |
| `GET /blocks` | `[{blocked_user_id,name,created_at}]`, at most 500 |
| `POST /blocks/:userId` | `{}` → `{ok:true}` |
| `POST /blocks/:userId/unblock` | `{}` → `{ok:true}` |
| `GET /admin/reports?status=open` | Admin-only report queue, at most 200, oldest first; `reviewed` is also supported |
| `POST /admin/reports/:reportId/review` | `{action,note?}` → `{ok:true}` |

Report targets are `question`, `answer`, `comment`, or `user`. Reasons are `harassment`, `hate`, `sexual`, `violence`, `spam`, `privacy`, or `other`. Optional report details and moderator notes are each capped at 1,000 characters. A report does not automatically hide content or determine a penalty. Report details deliberately bypass the public text filter so someone can explain an abusive incident privately.

The same reporter can create only one report per target. A distinct-key duplicate returns 200 with its existing ID and current status. This does not reopen a reviewed report or create multiple queue entries. There is a transactional 30-new-reports-per-24-hours cap per account. Content reports require current access to the referenced content; private, hidden, or blocked content does not become readable by submitting its ID. Known existing user IDs can be reported directly. Self-reporting and self-blocking return a 400 error.

The queue includes the report, a restricted target preview, and action history. Only admins can access it; it does not include account emails, balances, credentials, storage paths, or bearer tokens. Answer/comment previews contain their question ID so an admin can inspect the associated detail and signed images through the normal authorized API. Report creation returns no private target preview to the reporter.

## Visibility, interaction, and financial boundaries

- Blocking works in both directions. A user cannot read, claim, answer, or comment on a question authored by, or assigned to, a blocked participant. Other visible questions omit blocked authors' comments and answers
- Removing one's own block does not remove a block created by the other person
- Hidden questions disappear from ordinary feeds and details. Their existing signed image URLs stop working. Hidden answers/comments and nested evidence are omitted; a hidden accepted answer's identifier is also omitted
- Admins can inspect hidden or blocked content for review. No public endpoint creates or elevates administrators
- Suspension prevents an account from posting or interacting, including replays of previously successful mutation keys. Its content is hidden from other ordinary users. Sign-in, own account details, own data export, recovery, logout, and account deletion remain available
- `hide` and `restore` affect question/answer/comment visibility. They are invalid on user reports. `suspend` and `reinstate` affect the author of any reported target. `dismiss` closes a report without changing content visibility. Administrator accounts require trusted operator review and cannot be suspended through this API
- Safety actions never change question/answer lifecycle states, point balances, ledger entries, or held/paid/refunded escrow. Accepting an invisible answer is rejected. Restoring already paid content cannot issue a second reward
- An active question owner can still cancel their own hidden **open** question through the existing cancellation operation for its existing full mock-credit refund. Assigned/answered work retains the existing cancellation restriction. Blocking or hiding that work creates no new automatic refund, forfeiture, payout, or dispute decision

The API takes a shared PostgreSQL transaction advisory lock for content reads/interactions and an exclusive lock for block, hide, suspension, and deletion. The account lifecycle module uses the same gate. Lock acquisition precedes row locks. A read authorized before a block may finish; once the block commits, later reads cannot fetch that content. Image reads retain the gate through the private storage read. This intentionally coarse locking favors a clear safety boundary for the current scale; high-throughput deployments should measure it before replacing it with carefully tested narrower locking.

## Text filtering and limits

`TEXT_FILTER_TERMS_JSON` configures up to 500 literal phrases, each at most 100 characters. It must be a valid JSON array of nonempty strings. The default list contains two explicit threat phrases. Configuration is validated at startup; an explicit empty array disables phrase rejection and must not be mistaken for a launch-safe moderation setting.

Public registration names, profile location fields, question text/metadata, comments, answer/evidence fields, and helper application text pass through server-side filtering. Matching normalizes Unicode compatibility characters, lowercases, removes common zero-width characters, and collapses whitespace. Rejection returns `422 CONTENT_REJECTED` before a content write or mock-point hold. Passwords, email addresses, and image bytes are not scanned by this text filter.

This filter is intentionally limited. It does not understand context or intent, reliably detect threats, cover languages automatically, resist all obfuscation, assess evidence URLs' destinations, scan image pixels, or verify local advice. It may reject a harmless quotation and miss serious abuse. Magic-byte image validation is a file-format check, not image moderation. A successful API call is not a declaration that content is safe or accurate.

## Data and audit behavior

`content_reports`, `user_blocks`, and `moderation_actions` are private operational tables. Admin actions and their notes are stored transactionally with the action. Same-key retries do not duplicate actions; repeated unchanged decisions do not add duplicate audit entries. Reversals remain explicit, auditable actions.

Own account export includes the user's submitted reports and block list, without other people's reports or private moderator notes. Deleting a reporting account, reported author, or targeted content cascades the corresponding reports and review notes; blocks cascade when either account is deleted. Reviewer's account deletion nulls the reviewer ID on any otherwise retained action. This is the implemented deletion behavior, not a settled legal retention policy.

## Decisions required before public release

1. Identify the actual service owner and publish working support/contact information in the app, support page, and store metadata
2. Appoint moderators, define coverage and triage priorities, verify queue access, and choose achievable response targets, escalation, appeals, and incident handling. Do not advertise staffing or response guarantees until they exist
3. Adopt community rules and choose supported languages, operator-maintained phrase lists, image review controls, and a way to handle evasion and illegal content. The current phrase filter alone is insufficient evidence of a complete safety operation
4. Define how blocked, hidden, or suspended participants' unfinished work is handled, independently of content visibility. Mock points have no cash value; any future real-money policy needs separate design and authorization
5. Set appropriate report/audit retention, access-review, backup, and deletion policies, including how operational obligations interact with account deletion
6. Verify the actual release build's report/block paths, admin access, contact links, account export/deletion, localized notices, and App Store metadata. Test accessibility and repeated/interrupted actions on the eventual supported devices

No owner decision in this list is silently made by the implementation. The application remains an undeployed development system with synthetic fixtures and mock credits.

## Verification

`backend/test/moderation.test.mjs` exercises real PostgreSQL endpoint behavior: permissions and field injection, duplicate and concurrent retries, bounded reporting, bilateral block/unblock, nested-content and signed-image visibility, hide/restore, suspension across instances, protected admins, text normalization, no reward/refund side effects, and a deterministic blocked image-read race. The test database uses isolated synthetic schemas and removes its own resources. This test suite validates those bounded behaviors; it cannot validate staffing, response times, legal policy, App Review acceptance, or image content classification.
