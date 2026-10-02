# Personal traveler and guide activity

## Product behavior

`/activity/traveler` (내 질문) contains the signed-in traveler's questions. `/activity/guide` (맡은 질문) contains work assigned to the signed-in guide. Both are independent of map bounds, GPS, image loading and the shared discovery feed's newest-200 limit.

The home toolbar/drawer opens personal questions; the guide home/drawer opens assigned work before the open discovery feed. “진행 중” and “지난 질문” show actual server states and the appropriate next action. A submitted answer asks the traveler to review its evidence; a claimed question directs the guide back to writing. Waiting text does not promise response time or imply that a guide is currently online.

Cards show question registration time and offered virtual points. Detailed content, evidence and action eligibility are fetched again in the authorized detail screen. There is no new payment, expiry, reassignment, refund, rating or unread-count policy.

## API contract

`GET /api/activity/questions?role=traveler|guide&view=active|history&cursor=...`

- Authentication is required. Defaults are `traveler` and `active`
- Every page is scoped to the current user's author ID or assignee ID. Administrator status does not broaden this endpoint
- `active` includes nonterminal statuses; `history` includes accepted, cancelled and expired
- The fixed page size is 20. The response is `{items, next_cursor}`; a null cursor means that no further page was found at that read
- Newest creation time and ID determine ordering. Cursors preserve PostgreSQL microseconds and bind the account, role and view with a domain-separated server signature. Refresh after cursor invalidation or signing-secret rotation
- Hidden questions, suspended counterpart accounts and bilateral blocks are filtered before the limit. Account suspension/deletion is rechecked within the moderation read boundary
- Summaries contain only question ID, participant IDs, location labels, category, urgency, title, offered points, status and timestamps. Bodies, images, signed media URLs, comments, answers, accepted-answer IDs and guide profiles are absent
- Migration 007 adds author/assignee pagination indexes. Existing question and escrow mutation rules are unchanged

## Interrupted use and privacy

The list coalesces repeated loads, deduplicates records and ignores late responses from another account or tab. Loading more can be retried without discarding already loaded summaries. A transient refresh failure explicitly labels remaining rows as previously loaded. Authorization failures clear those rows. Account changes, view changes and disposal invalidate prior work; these summaries are held only in page memory, never written to an offline conversation cache.

Returning from detail refreshes the queue. A foreground poll refreshes visible work; the shared poller stops while the app is backgrounded. This is not a push notification or unread-message system.

For a recovered photo submission, the form now reads compact personal active/history pages and merges the newest ten owned questions. It no longer scans the shared public feed. This is still a conservative lookup: absence does not prove that an uncertain request failed, and the form does not automatically create a replacement.

## Related usability repairs

- A failed map feed shows an error and retry inside its sheet, including when expanded. It does not report zero questions. Creation and personal activity remain accessible
- Rejected guide applications display the stored rejection reason and existing reapplication action. Suspended participation is shown separately
- Evidence URL validation now agrees with the server's public HTTP(S) host rules and explains rejected inputs before submission
- An answer shows its recorded submission time in device-local time. This is not the time its information was independently checked

## Verification

The backend HTTP tests use real PostgreSQL 17.11: more than 200 newer unrelated questions, exact submillisecond/tied pagination, concurrent new rows, hidden runs, bilateral blocks, suspended accounts, administrator scope, terminal states, strict cursor parsing and compact payload fields. Flutter tests cover map failure/retry, recovery lookup, pagination, duplicate retries, account/view races, authorization clearing, detail return, empty states and 320px enlarged-text layouts.

Final integrated counts and native/deployment limits are recorded in [VERIFICATION.md](VERIFICATION.md). This implementation remains local until separately published; the existing private preview and historical unsigned iOS run are different revisions.
