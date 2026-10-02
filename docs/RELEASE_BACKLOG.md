# Travel Q&A release backlog

Updated 2026-10-02. This is an implementation plan for the existing travel/local-guide Q&A product, not a launch announcement. The service name remains undecided. Europe/US major cities, virtual contribution points and factual reputation, and iOS 15+ are owner decisions already made.

## Product outcome

A traveler on a weak connection can ask a short location-specific question, find it again without a map, understand who needs to act, read a useful sourced answer and complete the exchange. A guide can find eligible questions and their existing commitments, recover interrupted writing and understand the actual accepted-answer record and virtual reward. No part of this flow should imply live staffing, guaranteed response time, professional verification or cash payment.

## Independent implementation order

| Priority | Work | Evidence / acceptance | State |
|---|---|---|---|
| P0 | Personal traveler and guide activity | Existing global map query mixes public/owned/assigned records and caps them at 200. Guide discovery removes a question after claim. Add authenticated owner/assignee queues, 20-item cursor pages, current/history views and explicit next actions. Verify old work stays findable behind more than 200 unrelated questions, pagination, account changes, moderation and retry. | Verified locally: 362 Flutter / 96 PostgreSQL tests |
| P0 | Recovered submission lookup | The photo-recovery form searches the same capped public feed. Use the personal summary API for recent own questions; absence still cannot prove that an uncertain request failed. Preserve draft/request identity and no automatic resubmission. | Verified locally: 362 Flutter / 96 PostgreSQL tests |
| P0 | Honest map failure state | A failed list becomes an empty map and expanding its sheet hides the only error notice. Show an error and retry inside the sheet; do not claim zero questions. Keep question creation and personal activity reachable. | Verified locally: 362 Flutter / 96 PostgreSQL tests |
| P1 | Guide submission and return path | Align source URL validation with the server; show an existing rejection reason and permitted reapplication; label an answer's submission time without inventing a verification time. | Verified locally: 362 Flutter / 96 PostgreSQL tests |
| P1 | Operator view of unmet demand | Add an authorized, paginated view of open questions and accepted work still awaiting an answer, with actual recorded age/status and location filters. Distinguish registered guide participation from online availability. Validate that ordinary accounts cannot access operator data. No response deadline, staffing promise or automatic refund is introduced. | Verified locally: 396 Flutter / 107 PostgreSQL tests |
| P1 | Escalation for a stuck exchange | Design a clearly labeled way for a participant to report a problem with their existing exchange and for an authorized operator to find it. Reuse moderation/contact foundations where appropriate. Do not imply staffed support or mutate escrow until settlement policy is approved. Review existing report semantics before implementation. | Verified locally: 519 Flutter / 130 PostgreSQL tests |
| P1 | Eligible guide discovery beyond 200 records | Compact cursor pages use the exact existing claim-region rule, preserve newest-first eligibility and avoid nested content/media downloads. The guide screen retains paging/retry state, rechecks detail access and guards repeated navigation. No new ranking or availability policy. | Verified locally: 561 Flutter / 149 PostgreSQL tests |
| P1 | Return-to-app attention | An old completed exchange can receive a comment without moving in the creation-sorted personal queue. Add a derived Recent view from currently visible recorded activity, retain active/history, and remove answer-review promises when the answer is hidden. No unread counter or event store is needed; device push remains separate. | Next independent product slice |
| P0 | Authorization after database waits | Four queued personal/operator reads reproduced expired/logout sessions returning private data; fixed with current session gates and a deadlock-tested statement snapshot. Private issue and discovery routes also recheck expiry. Earlier gated read/mutation routes still need the same targeted audit; narrow tests are not whole-surface authorization evidence. | New queue routes verified; older routes pending audit |
| P1 | Narrow/mobile accessibility and interruption | Test each new screen at small width and enlarged text, loading/error/empty states, tab/navigation/account transitions, concurrent retry and interrupted requests. Preserve existing photo and HTTP-408 idempotency regressions. | Required for each milestone |
| P2 | Final release reproducibility | Keep source/lock/native configuration consistent, fix stale checklist entries, retain native diagnostic summaries, and create tested local recovery packages for validated commits. Fresh native compilation, signing and device checks remain separate evidence. | Continuous |

## Owner or deployment gates

These do not block the independent work above. They do block a truthful claim that the app is ready for distribution.

- Owned service identity, bundle ID, app icon and publisher/team details
- Real self-hosted server/domain/TLS, production PostgreSQL operations and backup restore, mail integration and actual delivery
- Public privacy/terms/community/support contacts and accountable moderation coverage, including supported languages and image handling
- Pilot cities/hours and real guide/operations staffing; a catalog entry is not an availability promise
- Maximum unmatched/assigned waiting time, reassignment/refund/dispute handling and free-point replenishment. Existing open-question cancellation and accepted-answer reward behavior remains the only implemented settlement policy
- Data retention and final collection/recipient declarations; do not silently persist private conversations for offline use
- Signed native archive, physical iPhone/iPad/accessibility/Keychain/gallery testing, App Review metadata and actual submission authorization
- Android support floor (current source 23 vs the pinned Flutter's documented 24+ support) is a separate platform decision; no Android release is claimed

## Evidence discipline

Guide discovery and queued-session corrections pass 561 Flutter tests, 149 real PostgreSQL/backend tests, analysis and production/preview web builds. Private issue intake previously passed 519 Flutter / 130 backend tests; operator/profile passed 396 / 107; personal activity passed 362 / 96. The baseline at `bb4b39b` passed 320 Flutter tests. Validated local milestones and approved native adoption are retained in recovery packages. The earlier successful unsigned macOS run compiled public revision `930c683`; it is not native validation of later local source. See [verification](VERIFICATION.md) and [cloud iOS record](CLOUD_IOS_BUILD.md).

Each milestone records tests against its exact source, current limitations and recovery artifacts. No new repository/Site publication, remote CI, live mail, production deployment, paid resource, signing credential or user-computer access is part of this local implementation pass.
