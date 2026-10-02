# Account lifecycle implementation

This is an application implementation record, not a published privacy policy.
No email provider, public service, production account, or paid service was set up.
The backend contract and operator steps are in [ACCOUNT_BACKEND](ACCOUNT_BACKEND.md).

## User flows

- Login links to public password recovery and public service/privacy information
- Recovery can request an email, or resume by pasting the code or the configured
  email link directly. A successful reset returns the user to login; the server
  revokes existing sessions
- Account settings show the server's verified-email and suspended-account state
- Verification provides an explicit request/resend action and code/link entry
- Email responses say the request was accepted and delivery is queued where
  possible. `MAIL_UNAVAILABLE` explicitly states that no email was sent
- Browser demonstration codes are shown only when the build's `DEMO_MODE` is
  enabled and the response is marked `demo_only`. They do not establish real
  mailbox ownership
- Data export requires the current password. Stored-photo bytes are included
  by default; an explicit checkbox can exclude image bytes while retaining
  photo metadata. `EXPORT_TOO_LARGE` offers that retry or operator assistance. JSON remains in memory until the
  user explicitly opens the platform share/save action or copies it. There is
  no automatic destination or upload. iPad sharing uses the initiating control
  as its popover origin; browsers can use the plugin's download fallback
- Deletion explains its consequences, requires the current password and exact
  `DELETE` confirmation, and clears the session when the server acknowledges
  `account_deleted`, including a pending private-file-cleanup response
- Suspended accounts keep access to account controls and the support/about page

## State and storage boundaries

`AuthRepository` accepts a `SessionStore` abstraction. Native remembered sessions
use `flutter_secure_storage`: iOS Keychain with device-only unlocked
accessibility and no synchronization, and Android's default authenticated
cipher storage. Legacy plaintext preference tokens are removed and require a
fresh login instead of being copied into the new store. Secure-store failure
never falls back to plaintext. Native secure keys are namespaced by API server.

Browser persistence is optional browser local storage and is explicitly described
as such. It does not offer native Keychain protections. Passwords and challenge
codes are never stored. Existing synthetic tests inject preference/memory stores.

Reauthentication requests for account export and deletion use memory-only retry
keys. Concurrent and repeated requests can reuse the same operation within the
current process; no password-derived preference lookup or request body persists.
After a cold restart, the app must recheck account status and obtain the current
password again. Ordinary answer drafts and their non-secret operation IDs are
stored separately for interrupted contribution recovery.

Responses from an old session cannot populate export UI or delete a new session.
The deletion cleanup removes only the deleted owner's local question draft and
matching remembered email, and attempts each cleanup even if another fails.
A local storage error is disclosed after confirmed server deletion.

Native export files have feature-owned names and paths. iOS and the original
Android input file are removed after the share operation. Android's plugin copy
must remain readable after the chooser closes because the receiving app may
still be reading it. Exact feature-owned leftovers are removed at next startup,
next export or account deletion. Unrelated shared files are not purged. A user
copy saved outside the app is under the user's control.

## Dependency and platform constraints

Official packages are pinned to `flutter_secure_storage 11.2.0` and
`share_plus 13.3.1`; dependency resolution records transitive versions in
`pubspec.lock`. The Dart floor is 3.10. Android uses SDK minimum 23, Java 17,
Kotlin 2.2.0, Android Gradle Plugin 8.12.1 and Gradle 8.13. The owner-approved
iOS target is 15.0; see [native evidence](CLOUD_IOS_BUILD.md). Android's retained
23 target has not been validated and falls below Flutter 3.47's supported 24+
floor; review Android support separately before an Android release.
Android automatic app backup is disabled for secure storage compatibility.

- https://pub.dev/packages/flutter_secure_storage
- https://pub.dev/packages/share_plus

## Verification scope

Focused tests cover unavailable email, idempotent interrupted reset, incorrect
reauthentication, verified-email refresh, deleted-account cleanup, current-user
changes, token migration, secure storage injection, and 320-pixel screens at
2× text scaling. Completion evidence is in the project verification record.

Cloud Dart/Flutter checks do not validate a signed iOS build, device Keychain,
native share-sheet behavior, Android Gradle execution, real email delivery,
operational cleanup jobs, or an external legal/support page. Those checks remain
separate release requirements. There is no new claim about operator retention,
backups, third-party message copies, or App Store approval.
