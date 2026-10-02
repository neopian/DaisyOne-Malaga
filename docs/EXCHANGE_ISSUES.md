# Private records for a stuck exchange

Participants can record a problem with an assigned or answered exchange at `/account/exchange-issues`. The question owner and assigned guide each have at most one private record for that question. The normal abuse-report flow is unchanged and still rejects self-reporting.

This records a concern for authorized operator review. It does not promise staffing or a response time, resolve a dispute, change an answer, reassign a guide or move virtual points. “검토 표시됨” means that an operator marked a review, not that the underlying problem was solved.

## Reachability and privacy

An eligible exchange must have an assigned guide, status assigned/answered and held points. A participant can still find its safe reference if blocking, a counterpart suspension or question hiding prevents reading its content. The eligibility response then omits the title and returns no body, media, names or contact information. The ordinary question-detail visibility rules remain intact.

Only the reporter's own record appears in participant lists/detail. The other participant's record, reviewer identity and internal review note are excluded. The administrator queue is separately authorized and displays private issue text for review, without automatically expanding the conversation. Suspended accounts cannot create records; their existing account export/deletion access remains unchanged.

## API under `/api`

| Route | Behavior |
|---|---|
| GET `/exchange-issues/eligible` | Twenty oldest-first safe exchange references; optional signed cursor |
| GET `/exchange-issues/eligible/:questionId` | One authorized eligible reference, with the same redaction; no query parameters |
| POST `/exchange-issues` | `{question_id, reason, details?}` and required idempotency key; returns `{id}` |
| GET `/exchange-issues` | Twenty newest-first reporter-owned records; optional signed cursor |
| GET `/exchange-issues/:id` | Exact reporter-owned record; never another participant's or operator's private note |
| GET `/admin/exchange-issues` | Active-admin-only, oldest-first records for `status=open` or `reviewed`; optional signed cursor |
| POST `/admin/exchange-issues/:id/review` | Required idempotency key and optional `{note}`; one immutable review, returns `{ok:true}` |

Reasons are waiting_for_response, answer_problem, cannot_continue and other. Extra text/internal notes are optional, trimmed and limited to 1000 characters, with an 8KiB request-body bound. There are no attachments. The existing abuse-intake convention of at most 30 new records per actor in 24 hours is enforced transactionally; duplicate retries do not consume another record.

An identical existing record returns its ID; a changed payload cannot replace it. A matching retry remains safe after the exchange has completed. A first review fixes reviewer/note/time; a competing or changed review receives an explicit conflict. The feature's current participant/admin/session checks run before an idempotency result is replayed. Cached replies contain only an ID or acknowledgement, never issue/review text.

Keyset cursors bind the actor and view, preserve PostgreSQL microsecond timestamps and reject malformed or cross-view use. Direct eligible and own-record reads avoid walking lists to open a known item on a weak connection. Authentication, moderation and resource locks are ordered consistently with acceptance, password reset and account deletion; concurrency tests exercise those boundaries.

## Account lifecycle

Migration 009 adds the private records and scoped indexes. Account export includes reporter-owned issue text and reviews authored by the exporting user. Both selections contribute to the existing SQL row/byte preflight; an administrator export does not become a global data export.

Deleting either participant or the question cascades its associated issue record. Deleting an unrelated reviewer clears their authored review note and identity while retaining the non-content reviewed marker. Tests include deletion waiting for an in-flight review, export size limits and absence of the counterpart's issue/internal notes. No new retention duration or backup-erasure promise is introduced; actual operator retention and privacy declarations remain release gates.

## Client interruption behavior

Forms and compact lists remain in page memory. A cancelled/reopened dialog retains its unsent text or frozen uncertain intent. Repeated sends use the same intent; an acknowledged creation opens its exact own record and is never posted again just because that read failed. Late replies do not close a newer dialog or repopulate another account.

Any authorization loss clears both tabs and private editors. A single deleted record is handled locally, so unrelated records remain usable. Reusing a route with a different question cancels the old selected lookup. Hidden references, empty/error/retry states, direct lookup, pagination, Cancel/Back, revoked access and 320px enlarged-text screens have behavioral coverage.

The guide application form was also repaired: a new account receives empty fields, an old city-picker result is ignored, and late submission feedback stays with its initiating account. Reauthentication of the same person preserves editable text while invalidating old asynchronous work.

## Verification

The integrated source passed 519 Flutter tests, complete analysis, 130 real PostgreSQL/backend tests and a production web release build. Tests demonstrated three old guide-form account-boundary failures before repair. A synthetic intake page was rendered by Flutter and visually inspected. Browser-local adapter parity is separately tested and is not PostgreSQL or a production security boundary.

No new hosted preview, native iOS build, signing, real email, production deployment or App Store submission is claimed by this milestone.
