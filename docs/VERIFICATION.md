# Verification record

Cloud development only. No production application server or user-computer deployment was performed.
The owner-private development Site is a separate browser-local demonstration.
All accounts, questions, images, and point balances used for checks were synthetic.

## 2026-10-02 Europe/US city scope and cloud iOS preparation

The owner selected Europe/US major cities and an initial virtual-point plus
factual-reputation model. The shared 20-city catalog is an implementation
proposal, not a city-by-city launch commitment or guide availability signal.

- Full Flutter suite: **307 passed**; analyzer clean. A final responsive-header
  adjustment was additionally checked with the home UI suite and all capture
  cases. Production and normal-login preview release builds were regenerated
- Final backend suite: **88 passed, zero skips**, using actual PostgreSQL 17.11,
  HTTP and codec checks. City aliases and country pairs, unsupported cities,
  guide eligibility, stored retry replay and historical completion are covered
- Legacy names outside the catalog use a conservative case-sensitive NFC/trim
  JSON-pair identity. Different Japanese/Cyrillic names and separator-containing
  pairs cannot collapse and accidentally expand another guide's permissions.
  No ICU dependency, historical rewrite or live data migration was introduced
- Preview: **35 API suites**, 3 image API unit suites, 37 launcher checks and
  12 packaging/cache checks; self-contained classic worker remains under 64 KB
- iOS preparation: **13 Linux-safe runner/resource contract tests** passed.
  The inert runner refuses Linux, stale native locks or unapproved tool modes.
  No Xcode build, signing, account integration or remote CI execution ran
- **15 local Flutter capture cases / 36 PNGs** cover mobile, desktop and 320px
  double text. US/European city search and selected traveler/guide destinations
  are asserted. Real glyph review fixed oversized map cluster text and stacked
  the question action/header for large text. Tiles in these local map captures
  are intentionally blank offline fixtures, not verified network map rendering
- Generated catalog drift, shell/Python syntax and whitespace checks pass.
  API/catalog files were copied to a clean image-layout fixture and imported
  successfully. Compose now includes the root catalog with a strict source-only
  Docker context; Docker/Compose execution remains unverified

Reproduce development checks with `bash scripts/verify-local.sh`. On read-only
home-directory environments, the analyzer supports
`ANALYZER_STATE_LOCATION_OVERRIDE` for its writable state location; no user
computer access is needed. Current release preflight still reports **20 checked /
21 blocked**, reflecting unresolved identity, actual services and native evidence.
An existing Apple developer account does not resolve the missing authorized
macOS runner or the reviewed native lockfile refresh described in
[CLOUD_IOS_BUILD](CLOUD_IOS_BUILD.md).

The private preview remains browser-local synthetic state with normal login.
Existing guide regions are preserved; a newly selectable destination does not
silently widen an existing guide's permissions. Hosted browser interactions and
native browser photo codecs remain unverified. Published hosting status does
not substitute for those checks.

## 2026-10-02 interrupted-guide and reproducibility follow-up

`scripts/verify-local.sh` completed against the integrated working source:
lockfile-enforced dependencies, clean analysis, **300 Flutter tests**, backend
syntax, **80 backend checks** with real PostgreSQL/HTTP and codec tests, **10
preflight tests**, and the production web build. There were no skipped backend
checks. The public-example release preflight remains **20 checked / 21 blocked**;
this is expected and does not indicate App Store readiness.

The guide form now preserves account/server/question-scoped answer text and
links. Unknown outcomes retain an immutable payload and request ID across
restart or reauthentication; acknowledged completion clears only its matching
draft. Unsent restored content requires fresh confirmations. Tests cover delayed
question/account changes, late acknowledgements, storage failure, and small
screens. Local Flutter captures cover both editable and pending states at three
viewports, with explicit fixture-state assertions and the same font limits as
previous captures.

Expired authentication cleanup uses bounded, ordered, skip-locked batches and
supporting indexes. Live sessions/auth replays and ordinary mutation idempotency
remain intact. Streaming gzip preserves the full content/search response model;
representative encoded/decompressed bytes and interrupted transport were tested.
No real network-speed claim is made. See [HTTP_TRANSPORT](HTTP_TRANSPORT.md).

Account reauthentication retry lookups now stay in memory, including the body
fingerprint. No password-derived preference key is created. Ordinary answer and
question retry keys remain durable; tests cover both boundaries.

A final wording-only change clarifies that a restored pending answer has an
unknown delivery result. Focused answer UI tests and captures were repeated
after it. No new operational policy, payment, live service or native signing was
introduced. Remaining launch gates stay in [APP_STORE_READINESS](APP_STORE_READINESS.md).

## 2026-10-02 account, safety and release-readiness milestone

This is a development milestone, **not App Store submission readiness**. The
historical sections below retain the earlier MVP/UI evidence and limitations.

- Final Flutter analysis: no issues. Full suite: **282 passed** after account,
  moderation, export, secure-storage and navigation changes
- Node backend: **71 checks passed, zero skips**. These include real PostgreSQL
  17.11/HTTP integration, role and concurrency checks, plus 19 image-codec cases.
  They are not 71 independent on-device or production tests
- A separate runtime role, granted only schema usage and table CRUD, completed
  registration, verification, report/review, export and deletion; CREATE/ALTER
  table operations were rejected
- Preview adapter: 27 API/contract/fault suites, 3 browser-image API unit suites,
  37 startup checks and 12 packaging/cache checks
- Release preflight: 10 tests pass. The release check intentionally fails on
  unresolved identity, live service/contact/policy and native/archive evidence
- 24 actual local Flutter capture cases produced 27 PNGs at mobile, desktop and
  320px/2× text. Font families are explicitly loaded for the test renderer. These
  are synthetic widget renders, not hosted-browser or physical-device captures
- Pixel review found and fixed direct-entry Back navigation on account screens.
  Navigation tests cover direct routes, stacked routes and suspended accounts
- Source SDK: Flutter 3.47.5 / Dart 3.13.4. New secure-storage and export plugins
  require Dart 3.10+; Android build configuration was aligned with their stated
  requirements, but Android Gradle execution is not claimed

The backend account tests cover one-use expiring tokens, request ambiguity,
constant-result recovery responses, cross-instance throttling, reset/login and
deletion/reward races, removal of private reviewer notes, durable file/mail-sink
cleanup, and size-bounded exports without silent truncation. Mail tests use only
synthetic local sinks. No message was delivered to an actual inbox.

Safety tests cover bilateral blocks, nested-content/private-image visibility,
admin permission checks, hide/restore/suspension, repeated reports/reviews,
configured text filtering and unchanged mock escrow. Runtime photo processing
strictly decodes, strips metadata, corrects orientation and bounds image size;
existing historical uploads are not rewritten. Human/image content moderation,
response staffing and policy quality are separate launch requirements.

Hosted QA remains distinct: the existing private Site requires a fresh sign-in
in the cloud browser. No authentication bypass or sharing change was used.
Hosting screenshot fields were absent at the last version-17 check. New preview
publication will be verified by the hosting result; that alone cannot prove all
browser interactions or native browser photo codec behavior. The Node canvas
unit doubles and sharp contract tests do not claim to test real browser codecs.

See [account server](ACCOUNT_BACKEND.md), [account UI](ACCOUNT_LIFECYCLE.md),
[safety controls](MODERATION_READINESS.md) and the concrete
[App Store gates](APP_STORE_READINESS.md). Remaining sign-off includes real
mail/TLS/backup operation, final policies/contact/name, final CocoaPods/privacy
report, signed iOS archive, iPhone/iPad/VoiceOver/Safari and actual network tests.

## Environment

- Base application: Git commit `e01397914b36f3e6d5e66290ab4a42373e66582e`
- Flutter 3.47.5 / Dart 3.13.4
- Node.js 24.19.0
- Real PostgreSQL 17.11, official Debian binaries, isolated loopback listener
- Browser demonstration: separate synthetic browser-local adapter; not a hosted DB

## Checks

Validated against the integrated source on 2026-10-01 UTC:

- `flutter analyze`: no issues
- `flutter test -r expanded`: 234 tests passed
- Production `flutter build web --release --no-web-resources-cdn` with `/api`:
  succeeded, development/demo/QA auto-login disabled
- Backend syntax checks: passed
- Real PostgreSQL 17.11 + HTTP integration: 17 tests passed, no failures/skips
- Independent migrate/seed/start/HTTP core journey: passed
- Same HTTP journey using a separate non-superuser runtime database role: passed;
  verified the role cannot create schema objects and can write app tables
- Compose YAML parsed and bootstrap shell syntax checked. Docker execution itself
  was not possible here and is not claimed
- Private hosted Flutter rendering: normal login, traveler question entry, Spain map
  and local-guide progress screens visually verified from actual hosted browser screenshots
- Lightweight browser preview: 12 API/contract/fault suites, 37 startup checks,
  12 packaging/cache checks passed. It is a separate synthetic implementation

Regression coverage includes concurrent point holds/claims/rewards/refunds,
recorded guide metrics, role/region eligibility, nested-read consistency,
commit-acknowledgement loss, retries through reauthentication, account switches
while loading photos, late logout responses, session/image revocation, saved
text drafts, optional map/GPS fallback, and small-phone enlarged-text layouts.

The production backend and frontend tests are not replaced by preview checks.

The backend suite uses a real HTTP listener and PostgreSQL connections. It
creates its own random schema and cleans only that schema. It does not silently
fall back to an in-memory database. A separate `scripts/smoke-core-flow.mjs`
journey exercises a running local API, seed, migrations, retry, acceptance,
reward ledger, refund, and logout revocation.

The browser-local preview is a separate implementation of the app API contract,
with its own synthetic state and API parity checks. It does not execute the
production SQL server in the browser. It remains a single-browser
preview: no cross-device synchronization, no real payment, and no real user data.

## Hosted preview verification detail

The delivered browser preview uses the same Flutter application source, with a
preview-only error-reporting entrypoint. The normal delivered build has
`QA_AUTO_LOGIN=false`; test accounts are chosen on the login screen. Temporary
screenshot builds sign into synthetic fixtures automatically to display a
specific screen, and are removed before final handoff.

The initial preview loader discovered Flutter files only after asynchronous
worker setup. Moving independent Flutter asset loading earlier allowed the
normal login and traveler question page to render in the hosting capture.
Preloading the same required Flutter assets also verified the map and guide
progress screens. The screenshots display synthetic fixtures only. App
execution still waits for a successful version-matched local API health check.
The intro is hidden only by Flutter's first-frame event, not a timer.

A screenshot is evidence that the pictured screen rendered, not a claim that
every control was clicked. Authenticated browser interaction was not available
through the permitted cloud browser session. API journeys, failure/retry
semantics and Flutter widget interactions were verified by the separate tests.

## Explicitly not validated here

- Docker/Compose execution on a server; Docker is not installed in this workspace
- Production DNS/TLS, reverse proxy, backups, restoration or operational load
- User Safari interaction via remote control, or multi-device live interaction
- Historical Supabase production data migration
- Public-launch readiness, real payments, email recovery or moderation policy

These limits do not replace the passing real-database and Flutter checks. They
identify the remaining deployment/product decisions before a shared service.


## 2026-10-02 UI-only follow-up

- Final Flutter analysis clean; all 244 Flutter tests passed after UI edits
- Production and normal-preview web release builds succeeded
- Preview contract/fault suites: 12 passed; startup checks: 37; packaging: 12
- Backend, SQL, API/repository permission logic and dependency lockfiles unchanged
- Prior 17 real-PostgreSQL tests remain historical evidence; not rerun for this UI-only change
- New mobile/desktop/large-text screenshots are local Flutter rasterizations, with
  synthetic fixtures and explicit font loading. Offline map fixture has no map tiles
- Hosted browser QA stopped at fresh ChatGPT sign-in; no credentials or tokens
  supplied. Hosting screenshot fields remained empty. A successful deployment is
  not represented as proof of a rendered hosted UI

See [UI_UPDATE](UI_UPDATE.md) for the UI changes and capture boundaries.
