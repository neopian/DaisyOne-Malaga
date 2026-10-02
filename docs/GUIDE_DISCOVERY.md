# Guide discovery

The guide home uses `GET /api/guide/discovery` for eligible open questions.
The endpoint returns 20 compact summaries and an optional `next_cursor`.
It replaces the screen's capped, nested `/api/guide/questions` payload; that
legacy endpoint remains available for existing clients.

## Eligibility and privacy

Discovery and claiming use the same approved-guide and geographic rules,
including city aliases and neighborhood matching. The query excludes the
guide's own questions, assigned or non-held questions, expired questions,
hidden content, suspended authors and bilateral blocks before pagination.
Administrator status does not bypass these participant rules.

Every request checks the current account, live session and guide approval
after the moderation gate, then keeps the relevant rows stable through the
read. Expiry uses current wall-clock/statement time after a wait. A cursor is
signed for its account and endpoint and preserves PostgreSQL microseconds;
it is a position, not a reservation or an authorization token. Changed guide
regions and competing claims apply to each subsequent page.

Summaries contain identity, title, place, category, urgency, virtual reward,
status and recorded timestamps. They omit question bodies, media, answers,
comments, accepted-answer references and profiles. Opening a question performs
a separate authorized detail read, and claiming it still rechecks eligibility.
Successful JSON pages support the existing negotiated gzip transport.

## Client behavior

The list retains the guide's personal “맡은 질문” entry. A failed contribution
summary cannot hide eligible work. Loading, empty, refresh-failure and
page-failure states are distinct; page retries remain beside the load-more
action. A transient failure can retain explicitly stale summaries, while an
authorization loss clears them. Duplicate taps coalesce, cancelled/older
requests cannot overwrite a newer scope, and returning from detail refreshes
eligibility. All list state is in memory.

Shared question-detail state is also released when its last consumer leaves.
A later visit rechecks access instead of rendering an old conversation cached
while the page was away. This is separate from the existing foreground poll.

No online-guide count, response deadline, ranking, automatic assignment or
reward-policy change is introduced. The local preview implements these API
semantics using synthetic browser-local state; it does not run PostgreSQL or
demonstrate cross-device exchange.

## Checks

Backend fixtures cover more than 200 eligible questions, precise cursor ties,
pre-page visibility filtering, every catalog region/alias, approval/session
revocation while waiting, strict cursor scope and compact output. Client tests
cover long paging, retries, region/account changes, detail return and narrow
enlarged-text layouts. The final integrated counts and verification limits are
recorded in [VERIFICATION.md](VERIFICATION.md).
