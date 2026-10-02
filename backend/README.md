# Self-hosted travel Q&A API

Node 22+ (Docker uses Node 24), plain PostgreSQL 15+, and private local disk storage. No Supabase, hosted SQL subscription, or paid API is required. Points are **mock credits only**, not money. Account verification, password recovery, export and deletion are implemented with explicitly configured self-hosted mail; delivery is disabled by default. See [account lifecycle](../docs/ACCOUNT_BACKEND.md) for exact contracts, deletion consequences, local-only testing, and launch decisions still required.

## Start locally

Use an existing **development** PostgreSQL database. Do not point the test or seed commands at production.

```sh
cd backend
npm ci
cp .env.example .env
# Set DATABASE_URL to your own local PostgreSQL database.
npm run migrate
ALLOW_DEV_SEED=true npm run seed:dev
npm start
```

The API defaults to `http://127.0.0.1:8080/api`; `/health` and `/api/health` report database connectivity. Apply migrations explicitly before starting the API. Boot fails if migrations are missing or pending; migrations are not silently applied by the server.

The seed is explicit and forbidden when `NODE_ENV=production`. It creates only missing synthetic accounts, never resets existing passwords/balances or deletes data:

- `questioner1@example.com`, `questioner2@example.com`, `questioner3@example.com`
- `answerer1@example.com`, `answerer2@example.com` (approved Malaga helpers)
- `admin@example.com` (development administrator)

All use the existing development-only password `daisy-dev-1234`. Seeded helpers match `Spain / Malaga`, `Spain / Málaga`, `스페인 / 말라가`, and `스페인 / Malaga`. All new accounts get 1,000 mock credits by default. **Never enable this seed on a publicly accessible/shared deployment.** For a production operator, promote an individually controlled, registered account using a trusted database administration session; there is deliberately no public admin-bootstrap endpoint.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `DATABASE_URL` | Required | PostgreSQL connection URI; keep server-side only |
| `HOST` | `127.0.0.1` | HTTP listener; container sets `0.0.0.0` |
| `PORT` | `8080` | HTTP port |
| `NODE_ENV` | development | Set `production` outside isolated development |
| `PUBLIC_BASE_URL` | `http://127.0.0.1:8080` | API origin, **without `/api` or another path**; used for signed image URLs; HTTPS required in production |
| `IMAGE_SIGNING_SECRET` | Random per boot in development | At least 32 cryptographically random characters in production; also encrypts short-lived auth replay payloads; preserve across restarts |
| `UPLOAD_DIR` | `./data/uploads` | Private writable image directory; Docker uses `/app/data/uploads` |
| `CORS_ORIGINS` | Empty | Comma-separated exact browser origins; no wildcard; development also permits HTTP localhost/127.0.0.1 origins |
| `INITIAL_MOCK_POINTS` | `1000` | Integer 0–1,000,000 granted once at registration |
| `SESSION_TTL_SECONDS` | `604800` | Session lifetime, 60–2,592,000 seconds |
| `ALLOW_DEV_SEED` | false | CLI seed requires exact `true` and non-production mode |
| `MAIL_MODE` | `disabled` | `disabled`, development-only `local_sink`, or production `sendmail` |
| `MAIL_SINK_DIR` | `./data/mail-sink` | Private synthetic mail output; never real delivery |
| `MAIL_FROM` / `SENDMAIL_PATH` | Required / `/usr/sbin/sendmail` | Operator-owned sender and usable local MTA executable for sendmail mode |
| `ACCOUNT_ACTION_URL` | Required when mail enabled | App action URL without query/fragment; HTTPS in production |
| `EMAIL_VERIFICATION_POLICY` | `optional` in development | Production explicitly selects `optional` or `required_for_contributions` |

For containers, run migrations as a one-shot command with the same database/config before the API, persist `/app/data`, and terminate HTTPS at a reverse proxy. Do not publicly expose PostgreSQL or the plain HTTP API port. Keep database credentials and the signing secret out of Flutter, browser bundles, source control, logs, and images. `CORS_ORIGINS` needs the origin hosting the Flutter web app; CORS is not authentication.

See the repository deployment guide for the complete compose/reverse-proxy setup. The bundled Dockerfile has a non-root runtime and installs production dependencies only. It does not seed or migrate automatically.

## API contract

All payload/response model fields use `snake_case`. Dates are ISO-8601 strings. Errors are:

```json
{"error":{"code":"UNAUTHENTICATED","message":"Sign in to continue."}}
```

Authenticated routes require `Authorization: Bearer <opaque token>`. JSON mutations require `Content-Type: application/json`, including an empty `{}` body for action routes. `POST /auth/logout` accepts an empty body as well. Responses are not browser-cacheable.

Successful question feeds/details, guide feeds, and point ledgers can use streaming gzip when requested through `Accept-Encoding`; their JSON models and private-cache policy remain unchanged. Auth, account exports, errors, and images are excluded. See [HTTP transport](../docs/HTTP_TRANSPORT.md) for negotiation, cancellation handling, measured synthetic payload size, and operational limits.

| Method and route (under `/api`) | Input | Result |
| --- | --- | --- |
| POST `/auth/register` | `email, password, name` | 201 `{token,user}` |
| POST `/auth/login` | `email, password` | `{token,user}` |
| GET `/auth/me` | — | Full `AppUser` |
| POST `/auth/logout` | `{}` | `{ok:true}`, revokes current session |
| POST `/auth/email-verification/request` | `{}`, bearer | 202 conditional queue response; 503 if delivery disabled |
| POST `/auth/email-verification/confirm` | `token`, bearer | `{ok:true,email_verified_at}` |
| POST `/auth/password-reset/request` | `email` | 202 generic response for known/unknown email; 503 if disabled |
| POST `/auth/password-reset/confirm` | `token,password` | `{ok:true}`; revokes all sessions |
| POST `/account/export` | `password`, bearer | Private own-data JSON including own image bytes |
| POST `/account/delete` | `password,confirmation:"DELETE"`, bearer, key required | `account_deleted:true`, `status:"deleted"` or 202 `cleanup_pending` |
| GET `/profile` | — | Full `AppUser` |
| PATCH `/profile` | `current_country, current_city` (either optional/null) | Updated `AppUser`; no role/balance/name mutations |
| GET `/guide/questions` | — | Claimable regional question array for approved guide; otherwise 403 `HELPER_NOT_APPROVED` |
| GET `/guide/discovery` | Optional signed `cursor` | Compact claimable regional work, 20 newest-first items plus `next_cursor`; current guide approval required |
| GET `/guide/me` | — | Own accepted-answer count, earned/pending mock points, application status and activity regions |
| GET `/points` | — | Own ledger, newest first, up to 500 |
| GET `/questions?status=open` | Optional status filter | Visible questions, newest first, up to 200 |
| GET `/activity/questions` | `role`, `view`, optional signed cursor | Own compact work, 20 newest-first items plus `next_cursor`; see [personal activity](../docs/PERSONAL_ACTIVITY.md) |
| GET `/admin/operations/questions` | `status`, optional country+city and signed cursor | Current active-admin-only compact oldest-first work, 20 items, scoped counts and restriction flags; see [operator view](../docs/OPERATIONS_QUEUE.md) |
| GET `/questions/:id` | — | Question with `question_images`, `question_comments.commenter`, `answers.answer_evidence_links` |
| POST `/questions` | `country, city, region_name?, category, urgency, title, body, reward_points, latitude?, longitude?, images?` | 201 `{id}`, holds mock credits atomically |
| POST `/questions/:id/accept` | `{}` | `{ok:true}`; claims open question for matching approved helper |
| POST `/questions/:id/comments` | `body` | 201 `{id}` |
| POST `/questions/:id/cancel` | `{}` | `{ok:true}`; owner-only, open-only full escrow refund |
| POST `/questions/:id/answers` | `body, evidence_summary, verification_method, links` | 201 `{id}` |
| POST `/questions/:id/answers/:answerId/accept` | `{}` | `{ok:true}`; owner-only single reward transfer |
| GET `/helper/application` | — | Own application or `null` |
| GET `/helper/regions` | — | Own regions array |
| POST `/helper/application` | `languages, regions, introduction, experience_description` | 201 `{id}`; absent/rejected applications only |
| GET `/admin/applications` | — | Admin-only `[{application,regions}]` |
| POST `/admin/applications/:id/review` | `status, reject_reason?` | `{ok:true}`; pending→approved/rejected, approved→suspended |
| GET `/images/:id?...` | Server-created signed URL | Private image bytes |

Image input is `[{"name":"photo.png","content_type":"image/png","data_base64":"..."}]`. Up to five images, maximum 3 MiB each before and after sanitizing; only PNG/JPEG/WebP. The server uses sharp to strictly decode and re-encode each still image, applies EXIF rotation/mirroring, converts color to sRGB, and removes EXIF/GPS/XMP/IPTC/ICC metadata. Pixel dimensions are retained (apart from orientation); PNG, including 16-bit input, and WebP use lossless encoding, while JPEG uses quality 95 without additional chroma subsampling. Decoding is capped at 20 megapixels; malformed, animated, oversized, and mismatched content is rejected. Only sanitized bytes are stored, under random server-generated filenames. Returned `image_url` values are absolute URLs, signed for ten minutes and tied to the reading session; refresh the question to obtain fresh URLs. Every image request checks current session validity and current question visibility. Logout immediately invalidates its image URLs. No public static upload directory is served.

Photos are decoded one at a time within each request, with at most two active decoders and eight waiting images per process and a ten-second native processing timeout. A full queue returns `503 IMAGE_PROCESSING_BUSY`; retry the same intent and idempotency key. Invalid photos return `400 INVALID_IMAGE` before any question, credit hold, image record, or file is written. There is no original-byte fallback. The native photo picker opts out of requesting full metadata, but server sanitizing remains mandatory. Existing stored uploads are not rewritten by this change. See [sharp output metadata defaults](https://sharp.pixelplumbing.com/api-output/) and [decoder input safety options](https://sharp.pixelplumbing.com/api-constructor/).

Evidence links are `[{"url":"https://example.com/source","title":"...","description":"...","source_type":"official"}]`. At least one, at most ten. Only absolute HTTP(S), no embedded credentials, localhost, local domains, or IP literal destinations; scripts/data/file schemes are rejected. The server stores URLs but does not fetch them. A valid URL is not a guarantee that its content is accurate or trustworthy.

Validation limits: password 8–128 characters; name 2–100; question title 2–200 and body 10–10,000; answer body 10–10,000 with nonempty evidence summary and verification method; comments 1–600; helper introduction/experience each 10–5,000; coordinate pair within geographic bounds. Categories and urgency match the Flutter Korean enum strings. Only explicit allowlisted mutation fields are accepted.

## Local-guide progress and trust context

Authenticated `GET /api/guide/me` works for every user, including someone who has not applied:

```json
{"accepted_answer_count":0,"earned_mock_points":0,"pending_mock_points":0,"application_status":null,"activity_regions":[]}
```

- `accepted_answer_count`: actual answers whose status is accepted and reward was issued
- `earned_mock_points`: actual `reward` ledger entries, excluding signup grants/refunds and current spending balance
- `pending_mock_points`: held escrow on questions currently assigned to this guide in assigned/answered status; contingent, not earned or a payout
- `application_status`: own participation application status or null; approval is not expert verification
- `activity_regions`: own `{country,city,region_name}` application regions, not independently verified expertise

Authenticated `GET /api/guide/questions` returns only open, unexpired, escrow-held questions matching this approved guide’s activity regions, excluding their own questions. It uses the exact same case-insensitive country/city/optional-region predicate as claim; a blank question or guide region is city-wide. Missing/pending/rejected/suspended approval returns `403 HELPER_NOT_APPROVED`. Nested details retain the shared-lock read protection. The feed is a current view, not a reservation: the claim endpoint remains authoritative if another guide claims first. General `/questions` map/search behavior is unchanged.

`GET /api/guide/discovery` is the compact, paginated guide list. It returns `{items,next_cursor}` with at most 20 questions ordered by `(created_at,id)` descending, preserving PostgreSQL microseconds. Pass the opaque `next_cursor` as the next request's `cursor`; null means the current list is exhausted. Only this optional parameter is supported, and duplicate/unknown parameters return `400 INVALID_DISCOVERY_QUERY`. Malformed, modified, other-account or other-endpoint cursors return `400 INVALID_DISCOVERY_CURSOR`.

Each item contains only `id,user_id,assigned_helper_user_id,country,city,region_name,category,urgency,title,reward_points,status,created_at,updated_at,expires_at`. No question body, images, comments, answers, evidence, accepted-answer identifier, participant profile, coordinates, escrow or moderation metadata is loaded or returned. Open/unassigned/held/unexpired, own-question exclusion, approved region matching, hidden content, suspended travelers and bilateral blocks are checked before pagination. Administrators need their own approved application and receive the same ordinary discovery visibility as other guides. The account, session and application are checked again inside the safety transaction and held through the read; every page uses current approval, regions and visibility. A cursor is only a position and never preserves revoked access. Newer questions appear on refresh, and claim still rechecks eligibility. No assignment, balance, escrow, status or moderation state changes during discovery. The existing status/time index supports this ordering; no migration is needed. Legacy `/guide/questions` remains unchanged for older clients.

Question list/detail additionally includes `assigned_helper: null` or `{id,name,accepted_answer_count,application_status,activity_regions}` for its assigned participant. It is visible only through the already-authorized question response and contains no email, profile location, balance, earnings, pending points, or invented rating. There is no arbitrary-user guide lookup. Counts and totals are derived from persisted work/ledger rows in one query, never mutable reputation counters; duplicate acceptance cannot inflate them. No leaderboard, stars, cash reward or real payout is introduced.

## Idempotency, transactions, and authorization

Send an `Idempotency-Key` containing 8–128 letters/digits or `_.:-` for every mutation. It is **required** for question creation, cancellation, answer submission, and answer acceptance. Generate a fresh random key for a new user intent; persist and reuse the same key/body when retrying after timeout/network/5xx. A different request with a used key gets `409 IDEMPOTENCY_CONFLICT`. Successful authenticated responses are recorded in the same transaction as the operation, so parallel retries cannot create two holds/answers/rewards.

Auth login/register also support optional keys. Successful auth replay is available for ten minutes, encrypted with AES-GCM at rest rather than storing plaintext bearer tokens. Its request fingerprint is keyed so the record does not become a cheap offline password verifier. Expired, logged-out, or undecryptable auth replay returns `409 AUTH_RETRY_EXPIRED`: begin a new sign-in attempt with a fresh key. Signing-secret rotation invalidates outstanding image URLs and auth retries, but does not invalidate ordinary bearer sessions. Changing a password/name/email while retrying requires a fresh intent/key.

All balances/roles/helper status/ownership come from the database, never the client. Passwords use salted PBKDF2-SHA256 at 600,000 iterations; opaque random 256-bit tokens are stored only as SHA-256 session hashes. Financial operations use one database transaction, row locks, unique ledger guards, nonnegative balances, and an explicit held/paid/refunded escrow state. Balance locks use `FOR NO KEY UPDATE` to remain compatible with foreign-key key-share locks during concurrent requests. Repeated accept/refund operations cannot reward/refund twice even with different keys. Helpers cannot claim or answer their own questions, cannot claim another region, and require current approval to submit. Non-open question content is visible only to owner, assigned helper, or admin. List/detail reads keep shared question locks through nested comments/answers/images, preventing a concurrent claim from exposing newly private content to an in-flight public read.

An expired open question cannot be claimed; its owner may cancel for the full refund. There is no automatic expiry scheduler or forfeiture. Once assigned, cancellation/refund is rejected; disputes/manual operational policy are outside this MVP.

Disk write failures roll back the hold/question. A failed/ambiguous commit triggers a reference check before file cleanup, preserving any possibly committed image. A process crash can leave harmless unreferenced files; back up PostgreSQL and uploads together and reconcile orphans offline, never delete files merely because a request timed out.

## Private exchange issue records

`진행 문제 기록` is separate from abuse `/reports`. An owner and their assigned guide can each record one issue per exchange while it is assigned/answered with held mock points. Recording or marking a review changes no question/answer status, assignment, balances, escrow, ledger, block, moderation flag or guide approval. It promises no response, handling time, refund, reassignment or settlement.

All routes below have the `/api` prefix. List responses are `{items,next_cursor}`, at most 20 rows ordered by precise `(created_at,id)`, newest first for own records and oldest first for eligibility/admin queues; use the opaque signed `cursor` for the next page. Cursors bind the user, list and status, and unknown/repeated query parameters are rejected.

| Route | Request | Response |
| --- | --- | --- |
| GET `/exchange-issues/eligible` | Optional `cursor` | Own assigned/answered held exchanges: `question_id,role,title,content_available,status,created_at,updated_at,own_issue_id` |
| GET `/exchange-issues/eligible/:questionId` | — | One own eligible exchange with the same compact fields/redaction; unrelated or ineligible references return 404 |
| POST `/exchange-issues` | `question_id,reason,details?`; required Idempotency-Key | 201 `{id}`; identical existing normalized intent under another key returns 200 `{id}` |
| GET `/exchange-issues` | Optional `cursor` | Own records: `id,question_id,role,reason,details,status,created_at,reviewed_at` |
| GET `/exchange-issues/:id` | — | One own record with the same public fields; another reporter’s record returns 404 |
| GET `/admin/exchange-issues` | `status=open|reviewed` (default open), optional `cursor` | Current active-admin records: own-record fields plus `reporter_id,other_participant_id,reviewed_by,review_note` |
| POST `/admin/exchange-issues/:id/review` | `note?`; required Idempotency-Key | `{ok:true}`; one review preserving its first author, text and timestamp |

Roles are `traveler` or `guide`; reasons are `waiting_for_response`, `answer_problem`, `cannot_continue`, or `other`; statuses are `open` or `reviewed`. Optional details/note are trimmed, blank becomes null, maximum 1,000 characters. Mutation JSON is capped at 8 KiB. Content text is never stored in idempotency responses.

Intake derives both participants from the locked question. Unrelated users, including administrators, cannot file. A hidden question, bilateral block or suspended counterpart keeps its safe reference selectable, with null title and `content_available:false`; no question body, media, counterpart profile or counterpart issue is returned. This visibility rule also applies to administrators using the participant route. Actor suspension blocks these routes while account export/deletion remain available. No guide approval is needed to record an existing commitment.

New records are limited to 30 per reporter per rolling 24 hours, serialized against concurrent submissions; duplicates do not consume the quota. Existing identical text remains retryable after the exchange completes. Changed existing text returns `409 ISSUE_ALREADY_EXISTS`; ineligible new exchanges return `409 EXCHANGE_NOT_ELIGIBLE`. The same reviewer may retry identical review text; competing reviewers or changed text return `409 ISSUE_ALREADY_REVIEWED` without overwriting the first review. Current sessions and participant/admin authority are checked again before cached replay. The lock order retains idempotency before resource locks and question before reporter, matching acceptance.

Account exports include `exchange_issues` with only the user's own issue text and `exchange_issue_reviews` with only their authored review notes. Both contribute to row and byte preflight limits. Deleting either participant or the question cascades issue content. Deleting an unrelated reviewer clears their note before detaching the reviewer identity, preserving only the reviewed marker. No additional retention period is introduced.

## Verification

```sh
npm run check
TEST_DATABASE_URL=postgresql://YOUR_TEST_USER@127.0.0.1:5432/YOUR_TEST_DB npm test
```

The tests require **real PostgreSQL**; there is no in-memory fallback or silently skipped database suite. The test role needs permission to create/drop schemas in a disposable test database. Each run uses an isolated random schema and temporary image directory, then removes those exact test resources. It never truncates application tables.

Coverage includes actual network HTTP login→question→helper claim→evidence answer→reward→ledger; registration and privilege injection; encrypted auth retries; missing/forged/expired/revoked sessions; admin gates; matching regions/self-answer; signed/private disk images; concurrent create/claim/reward/cancel; same-key retry and changed-payload conflict; invalid evidence schemes; disk-failure rollback and ambiguous-commit image preservation; fresh-instance session/image/retry persistence and cross-instance logout; deterministic list/detail visibility-race regression; guide metrics throughout claim/answer/reward/cancel/retry and participant-summary privacy; claimable guide feed region/own/expiry/approval/state filtering; and conservation of balances plus escrow against issued mock credits. The runtime database adapter supports PostgreSQL only; the obsolete PGlite option and dependency have been removed.

Photo-specific tests decode all supported formats, verify private metadata is absent in stored/served/exported bytes, cover all eight EXIF orientations and 16-bit PNG depth, reject malformed/animated/oversized photos, bound processing capacity, and confirm rejected later attachments leave files, rows, credits, and idempotency records unchanged. Fixtures contain only generated synthetic pixels and metadata.

## Operational boundaries

- This is an MVP backend, not a payment processor. No cash conversion, external payment, or paid service is connected
- Login/register and account lifecycle routes use atomic PostgreSQL quotas across instances: authentication allows 60 attempts per source IP and 20 login/register attempts per normalized email per 15 minutes, including nonexistent accounts. Account recovery/verification/export/deletion add route-specific limits. Behind a proxy, connections conservatively share its address; forwarding headers are not trusted. A reviewed proxy/client-IP design and load testing remain deployment work
- Personal activity, guide discovery, operator demand and exchange issue lists use fixed-size signed-cursor pagination. General `/questions`, legacy `/guide/questions` and the point ledger remain bounded recent lists; higher-scale public discovery/search, ledger pagination and operational alert delivery remain future work
- Back up PostgreSQL, private uploads, and secrets securely. Use a least-privilege application database role and private network access
- Account maintenance removes already-expired sessions and auth replay envelopes in at most 250-row batches per table per tick, preserving current artifacts and skipping locked rows across instances. It does not prune financial/content idempotency, ledger rows, or mail-artifact manifests, or promise audit-history retention
- No production instance is deployed by these files or tests
