# Self-hosted account backend

Verification, recovery, export, and deletion run on the existing Node/PostgreSQL
server. Tests use synthetic addresses and a private local mail sink only. No
real delivery, paid provider, service credentials, public deployment, or legal
compliance is implied. See [client behavior](ACCOUNT_LIFECYCLE.md) separately.

## Explicit delivery configuration

`MAIL_MODE=disabled` is the development default. Mail requests return
`503 MAIL_UNAVAILABLE`, never a sent-message claim.

`MAIL_MODE=local_sink` requires `ACCOUNT_ACTION_URL` and optionally
`MAIL_SINK_DIR` (default `./data/mail-sink`). It writes mode-0600 JSON files only
for `@example.com`, `@example.net`, `@example.org`, `.test`, or `.invalid`
addresses. It cannot run in production and never contacts an email provider.
These private test artifacts contain codes; do not publish/commit them. Deleting
an account removes its sink copies, including possibly written messages whose
dispatch transaction failed after the file write.

Production requires:

- `MAIL_MODE=sendmail`
- `MAIL_FROM`, a plain operator-owned sender mailbox
- `SENDMAIL_PATH`, an absolute executable path, default `/usr/sbin/sendmail`
- `ACCOUNT_ACTION_URL`, an HTTPS app URL with no query, fragment or credentials
- `EMAIL_VERIFICATION_POLICY=optional` or `required_for_contributions`, explicitly
  selected by the operator
- The existing HTTPS API origin and stable, strong signing secret

The local MTA owns relay authentication, TLS, domain configuration, queueing,
bounces and deliverability. No shell is invoked. Startup verifies the configured
executable exists and is executable. The bundled Node Docker base image does
not include an MTA; the operator must supply and test its integration. Mailbox
delivery is not proven by local tests or successful MTA acceptance.

Messages contain a copyable code and a link using
`#action=verify_email&token=...` or `#action=reset_password&token=...`.
Tokens never enter URL queries; fragments are not sent in HTTP requests or
Referer headers. The configured app domain and any native universal-link
association still require deployment/device validation. The client can extract
the pasted code without opening the link.

Verification remains optional in development. The explicit production
`required_for_contributions` setting gates question, claim, answer, comment,
and helper-application mutations. Cancellation and account export/deletion
remain available. Existing accounts are not silently treated as verified.

## Account API

All routes below use `/api`, JSON, and `snake_case`. Use fresh intent keys and
reuse the same body/key on network retries. Public users include nullable
`email_verified_at`.

| Route | POST input | Success |
| --- | --- | --- |
| `/auth/email-verification/request` | Bearer; `{}` | 202 conditional queued-request response |
| `/auth/email-verification/confirm` | Bearer; `{token}` | `{ok:true,email_verified_at}` |
| `/auth/password-reset/request` | `{email}` | Identical 202 for known/unknown addresses |
| `/auth/password-reset/confirm` | `{token,password}` | `{ok:true}`, revokes every session |
| `/account/export` | Bearer; `{password,include_images?}` | Own-data JSON attachment |
| `/account/delete` | Bearer; `{password,confirmation:"DELETE"}`, required key | Deleted or private-cleanup-pending result |

Recovery codes expire after 30 minutes; verification codes after 24 hours.
They are 256-bit random values stored as SHA-256 hashes. Verification is bound
to the current account. Invalid, expired, wrong-account and used codes all
return `400 INVALID_OR_EXPIRED_TOKEN`. A new mail request after the one-minute
cooldown invalidates older unused codes and removes their unsent envelopes.
The account-specific cooldown is silent to avoid membership disclosure.

Same-key successful confirmation can replay for 24 hours; another intent/key
cannot reuse the token. Changed body/key pairing returns
`409 IDEMPOTENCY_CONFLICT`. Sensitive retry fingerprints are keyed HMACs, never
plaintext passwords or cheap password verifiers. Password reset replaces the
salted password hash, removes all sessions and prior auth-retry payloads, and
does not automatically sign in. An already-started old-password login cannot
mint a session after reset commits. Export/deletion wrong passwords return
`403 REAUTHENTICATION_FAILED`; a valid session remains usable. `401` identifies
a missing, expired, or revoked session.

## Shared abuse controls

All counters below are atomic PostgreSQL rows and survive API recreation.
Multiple instances must share the same signing secret and database.

| Scope | Maximum per 15 minutes |
| --- | --- |
| Authentication source IP, including account routes | 60 |
| Normalized login/register email, whether registered or not | 20 |
| Verification/recovery mail request source IP | 20 |
| Code confirmation source IP | 30 |
| Export/deletion reauthentication source IP | 10 |

Database scopes contain HMACs, never raw IPs/emails. Expired rows are pruned.
Limits are enforced before password work, apply equally to missing and existing
identities, and return generic `429 RATE_LIMIT`. Unknown-account login still
performs the same password derivation when within limits. The HTTP bridge
overwrites its internal IP header from the socket and never trusts forwarding
headers. A proxy therefore conservatively groups its clients into one IP
bucket; reviewed client-IP handling and realistic load limits remain required.

## Own-data export

Export requires the current session and password, accepts no target user ID,
and uses a consistent database snapshot. It contains the profile; authored
questions/answers/comments/evidence; owned sanitized image bytes as base64;
helper application/regions; own mock-point ledger; session creation/expiry
dates; authored reports and own blocks; and any moderator notes authored by
this user, including authored helper-application review reasons. Sharing a
thread does not automatically export others' content.
It excludes passwords/hashes, session IDs/tokens/hashes, codes, mail envelopes,
storage keys, and other administrators' private notes. The server retains no
extra export file. Users must deliberately choose a private save/share location.

`include_images` defaults to true. PostgreSQL preflights row counts, decompressed
JSON text lengths, and base64 expansion before materializing the export or
reading image files. Exports above 10,000 total rows or an estimated 25 MiB JSON
response return `413 EXPORT_TOO_LARGE` without a partial payload. Retrying with
`include_images:false` returns complete structured/text data and all image
metadata, explicitly omitting image bytes. `export_options` records this choice
and the included-image count. Even metadata-only exports can hit these limits;
the error directs the user to operator assistance instead of silently truncating
data. A streamed/partitioned media archive and an operational large-account
export process remain future work.

## Irreversible deletion semantics

The current password and exact `DELETE` confirmation authorize only the current
session's account. Suspended users retain export/deletion access. One database
transaction:

1. Deletes the profile, credential, sessions, account codes, auth retries, own
   application/regions, own ledger, and own mutation retry records
2. Deletes the user's questions and their entire threads, including other
   people's answers/comments and associated images
3. Deletes the user's answers, evidence and comments on surviving questions
4. Cancels unfinished questions assigned to the deleted guide and refunds each
   surviving owner's held mock points once; already-paid rewards stay paid
5. Preserves surviving users' balances/ledger amounts while clearing references
   to erased questions/answers; paid surviving questions lose the deleted
   helper/accepted-answer reference but remain paid
6. Cascades related blocks, reports, details and audit notes; on unrelated audit
   records, the deleted reviewer's own note/rejection reason and identity are removed,
   leaving only non-content action metadata
7. Creates a durable file-removal job containing random filenames/message IDs
   and an opaque keyed retry receipt, no profile/account ID/email/password/body

Remaining fictional points belonging to the erased user are forfeited. There
is no retained identity tombstone, real-money payment, or cash refund. Aggregate
historical grant totals change when user ledgers disappear; surviving individual
balances continue to reconcile. This design must not be reused for real-money
accounting without a separate policy/design review.

After commit, the API removes private image and local-sink files. Complete
removal returns `{ok:true,account_deleted:true,status:"deleted"}`. A disk failure
returns 202 with `account_deleted:true`, `status:"cleanup_pending"`, and a clear
message that inaccessible files await server removal. Both responses clear
client sessions/drafts. The user/database account is gone; old image URLs cannot
read leftover files. Background retry needs no client session. A same-body,
same-key, old-bearer retry can recover an ambiguous response for 24 hours and
cannot authorize other actions.

Deletion takes an exclusive transaction safety lock shared by writes,
moderation, private reads, and reward/refund operations. A racing acceptance
either commits first and remains paid, or deletion refunds held escrow; never
both. Files are not removed before the database transaction commits. SQL/disk
cannot share an atomic commit, so pending physical removal is explicitly tracked.

## Worker, maintenance, and launch decisions

The API processes bounded mail/removal batches every 30 seconds, including at
most 100 image files and 100 local-mail files per deletion job per pass. One
stuck job does not block other jobs. A supervised
one-shot equivalent, using the same private server configuration, is:

```sh
node --env-file-if-exists=.env src/account-maintenance.mjs
```

The transactional outbox retains an encrypted token/message envelope only until
the sink/MTA accepts it. Failures back off until code expiry. IDs of possible
sink artifacts are recorded before dispatch, so ambiguous file writes remain
erasable. The local sink deduplicates IDs. A real MTA handoff can deliver the
same message twice after an ambiguous failure; it reuses the same single-use
token and never resets a password twice. Signing-secret rotation makes pending
old envelopes unreadable until they expire; coordinate rotations accordingly.

Pending removal jobs persist until successful cleanup. Completed receipts and
expired retry/rate/code records are pruned. Operators must monitor job age,
retry failures, outbox backlog, storage, database availability, and backups.

Each maintenance tick also removes at most 250 expired bearer sessions and 250
expired authentication retry envelopes, using their existing `expires_at`
timestamps. The authentication replay window remains ten minutes; this cleanup
does not extend it or create an audit-history retention promise. Use a fresh
intent key for a new login attempt after the replay window. Current sessions
and current encrypted auth replays are preserved. Multiple instances use row
locks with `SKIP LOCKED`, so they process disjoint batches and skip a row in use.
There is no loop that drains a table until empty in one tick. The four existing
expired account-rate/request/code/completed-deletion-receipt cleanup operations
are also limited to 250 rows per table per tick, with unchanged expiry criteria.
Financial/content `idempotency_keys`, mock-point ledger rows, and possible
mail-artifact manifests are outside this authentication-expiry cleanup.

Migration `005_authentication_cleanup_indexes.sql` supplies each cleanup table's
expiry-plus-tie-break order. It widens the two existing session/auth-retry expiry
indexes under their original names rather than leaving redundant prefix
indexes, adds the four missing account-table indexes, and uses a partial index
for completed deletion receipts only. The existing migration runner executes
this migration in a transaction. These are normal index builds, not
`CREATE INDEX CONCURRENTLY`; existing-data size determines build time and the
required lock window. Plan/test that migration window before deployment. No
production table or live database was inspected or migrated for this change.
Schema-catalog assertions and PostgreSQL `EXPLAIN` validate availability without
assuming a particular optimizer plan for tiny test tables.

Deletion covers live app data and protected local artifacts. Previously
delivered recipient email, MTA queues/logs, offline exports, backups, external
copies, and user-owned files are separate. Explicit mail/log/backup retention,
restore-and-redelete procedures, privacy policy, support contact, verification
policy, moderation appeals, and delivery monitoring are still operator/product
decisions. No legal retention period or compliance claim is invented here.

## Tests

`backend/test/accounts.test.mjs` runs against real PostgreSQL and actual HTTP,
with isolated schemas/private temporary storage and synthetic mail. It covers
disabled delivery/configuration, private disk sink, hashed/expiring/one-use
tokens, owner scoping, reset/session/login races, concurrent idempotent replay,
unknown-address parity, cross-instance quotas and forwarding spoof resistance,
outbox outage recovery, scoped exports and wrong-password session preservation,
full deletion, cleanup after session removal, paid-survivor ledger preservation,
refund/reward/new-write races, safety cascades, and suspended-reviewer note erasure.

`backend/test/account-maintenance.test.mjs` separately verifies bounded concurrent
expiry cleanup against real PostgreSQL, live sessions and exact auth replays
across API instances, preservation of old core idempotency/ledger rows and mail
manifests, and nonblocking progress around already-locked expired records.

## Private exchange issue records

Account export now includes `exchange_issues` (reporter-owned text only) and
`exchange_issue_reviews` (the exporting user's authored internal reviews).
Both are included in SQL row/byte bounds before materialization. Deleting either
participant or its question cascades the issue; deleting an unrelated reviewer
clears their authored internal note before the reviewer foreign key is nulled.
See [issue contracts and tests](EXCHANGE_ISSUES.md). These additions do not set an
operator retention period or claim deletion from unconfigured external backups.
