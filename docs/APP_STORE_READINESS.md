# App Store readiness evidence

Reviewed 2026-10-02 UTC, in the dot cloud Linux workspace. **Not ready for App Store submission.** This is an engineering checklist, not a legal opinion, final privacy label, approval prediction, or record of Apple review. No Apple account, Mac, signing credentials, device, production deployment, submission, upload, purchase, or public sharing was used.

The folder name `DaisyOne-Malaga` identifies the work location. It does not choose the app's brand. The existing `Local Qa Concierge` display name, `com.example.localQaConcierge` bundle ID, signing-team value, and template artwork are deliberately retained until the owner makes those choices.

Status meaning: **CHECKED** means the stated source/configuration evidence was inspected; it does not imply native execution. **BLOCKED** needs implementation, native/deployment evidence, or operations. **DECISION** needs an owner choice. Integrated automated results belong in [VERIFICATION.md](VERIFICATION.md); prior web/widget/backend passes do not establish an iOS archive or physical-device pass.

## Release gates

| Status | Gate | Evidence and next action |
|---|---|---|
| DECISION | Name, bundle ID, icon, publisher/team | Choose owned identity; register the bundle ID, confirm team ownership, then update all platform metadata. Never substitute the Málaga folder for a brand. Current icons remain unchanged. |
| BLOCKED | SDK, signing and archive | As of this review, uploads require iOS/iPadOS **26 SDK or later**, effective April 28, 2026. Use a matching supported Xcode on macOS and inspect the archive. Linux cannot run Xcode, resolve Apple signing, build an iOS archive or validate a device. [Apple SDK requirement](https://developer.apple.com/news/?id=ueeok6yw) |
| CHECKED | Minimum supported device OS | Owner approved iOS 15+ on 2026-10-02. Runner/Podfile use 15.0; Flutter generates the framework minimum. The recorded unsigned build used15.0. New source/bundle checks guard this baseline and embedded-framework compatibility; their final native rerun remains pending. [Flutter support](https://docs.flutter.dev/reference/supported-platforms) |
| CHECKED | Permission scope and transport | Foreground location and photo-selection purpose strings describe use and question upload. No background location, camera, microphone, tracking prompt or ATS relaxation was added. Geolocator's always-location compilation path is disabled. |
| CHECKED / NATIVE RERUN OPEN | Native dependency resolution | The genuine CocoaPods lock from the successful unsigned run was adopted with the approved iOS 15 baseline. It removes `app_links` and includes the resolved secure-storage/share dependencies. The only subsequent lock change updates the Podfile checksum for its iOS 15 comment. Local tests verify the lock/configuration; a new native build of later local changes remains pending. See [native provenance](CLOUD_IOS_BUILD.md). |
| BLOCKED | Privacy manifests and SDK archive inventory | Runner now has an API-only manifest for app-private UserDefaults (`CA92.1`), included in resources. Its production collection/tracking declarations are deliberately incomplete and separately blocked by preflight. Nine resolved native plugins ship manifests, but the geocoding resource-path defect and preferences reason review below remain. Inspect the final archive and Xcode privacy report; SDK “no data” declarations are not the app's privacy label. |
| BLOCKED | Native session and export verification | `SessionStore` now selects Keychain-backed storage on native and keeps optional browser persistence explicitly separate. Default-app Keychain entitlements are wired for Debug/Profile/Release. Validate signed-device write/read/delete, cold start, lock/unlock, expiry, migration and failure behavior. Native export passes an iPad origin and scopes cleanup to owned files; real share completion/cache behavior still needs device verification. |
| DECISION | Operator policies and public contact | Supply real `PRIVACY_POLICY_URL`, `SUPPORT_URL`, `SUPPORT_EMAIL`, `TERMS_URL` and `COMMUNITY_GUIDELINES_URL`. Review them against actual production recipients, retention, deletion, report handling and location/photo use; verify accessibility in-app and outside authentication. No policy text or contact ownership is invented here. |
| BLOCKED | UGC release operations | Report/block/admin controls and filtering have source implementations. Validate the end-to-end flow and authorized moderator access. The default two-phrase English text filter is a development baseline, not evidence of adequate multilingual or image moderation. Choose supported-language/content coverage, image review, response ownership, escalation and appeal handling. |
| BLOCKED | Account lifecycle | Verify in-app account deletion against the final integrated backend, including all authored UGC, images, sessions, moderation data, retries and interrupted cleanup. Confirm account export and recovery on the final service. Database source alone cannot prove external MTA queues, backups or operational retention. |
| BLOCKED | Production backend and mail | Native API URL must be explicit public HTTPS. The app now checks native release configuration before auth/router creation and refuses demo/dev-login or malformed/insecure API settings. Development login/demo/QA auto-login and development seeding must be off; the preflight also rejects placeholder/private URL syntax. Validate real PostgreSQL migrations, limited runtime DB role, TLS, mail delivery, cleanup jobs, secrets, monitoring and backup restore. The supplied production Docker image has no MTA: the operator must provide a reviewed mail integration and test delivery. No live production service is configured by this audit. |
| DECIDED / OPEN | Points and launch content | Owner chose non-purchasable virtual points and factual reputation on 2026-10-02. No StoreKit/payment or cash-out integration. Free-point allocation, unfulfilled work/disputes and accurate release content still need decisions. |
| BLOCKED | App Review deliverable | Final metadata, age-rating answers, support URLs, device screenshots, permitted test account/instructions and working backend are still needed. Test iPhone and iPad, Dynamic Type/VoiceOver, offline/retry, denied/approximate location, gallery cancellation, account switching and suspended/deleted accounts. |

Apple Guideline 1.2 calls for objectionable-content filtering, reporting with timely action, blocking, and published contact information. Guideline 5.1 requires an accessible privacy policy and appropriate handling of collected data; account creation entails in-app deletion. These are separate from whether source code compiles. [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#user-generated-content)

Deletion should remove the account and associated content; disabling login alone is not deletion. Where removal is delayed or data must be retained, the actual behavior and timing need clear disclosure. Test the app's `cleanup_pending` path and its reliable completion, plus retention outside the application database. [Apple account deletion guidance](https://developer.apple.com/support/offering-account-deletion-in-your-app/)

## Observed data inventory

This is an inventory of code paths, not final App Store Connect answers. “Candidate label” indicates a category to assess against the final production behavior. Account-linked server rows are not anonymous just because IDs are UUIDs. A location permission prompt or encrypted transport does not remove collection from the inventory.

| Data and source | Storage, recipients and purpose observed | Candidate label / unresolved detail |
|---|---|---|
| Email, display name, user ID (`auth_repository.dart`, `users`) | Submitted to self-hosted API; PostgreSQL account/profile rows. Guide name/profile fields can be displayed to allowed participants; user email is not part of the assigned-guide projection. | Name, email address, user ID; app functionality/account management. Confirm all final visibility paths. |
| Password, session, recovery/verification (`crypto.mjs`, `accounts.mjs`) | Password is sent for authentication/reauthentication, stored as PBKDF2 hash. Server sessions store token hashes. Auth retry response is encrypted. Recovery/verification token hashes, rate-limit hashes and request metadata are stored; pending mail has an encrypted dispatch envelope. | Security/identity data inventory; assess applicable categories rather than adding a fictitious “password” label. Bound retention and inspect logs. |
| Optional remembered native session (`session_store.dart`) | `flutter_secure_storage`, device-only unlocked Keychain, synchronization disabled. Legacy plaintext preference token is removed and fresh sign-in requested; no silent plaintext fallback. Browser remember-me remains JavaScript-accessible local storage. | On-device persistence is distinct from backend collection. Validate real-device storage and failed delete handling. Keychain can outlive reinstall; server revocation/expiry remains necessary. |
| Question country/city/region and latitude/longitude (`location_service.dart`, `questions`) | GPS only after a user action; manual city/map selection is supported. Selected coordinates and text go to API/PostgreSQL on submission and can be shown to eligible guides/participants. Device requests medium accuracy but stored numeric coordinates are not deliberately coarsened. | Location, potentially precise. Do not declare coarse-only merely from requested accuracy. Clarify visibility before submission and honor denied/reduced-accuracy paths. |
| Photos (`create_question_page.dart`, `question_images`, `storage.mjs`) | Up to five selected images reach the API. New uploads must fully decode and re-encode through `image-processing.mjs` before persistence; EXIF/GPS/XMP/IPTC/ICC metadata is removed and orientation applied. Stored images use private storage and expiring session-bound URLs with authorization checks. Picker requests `requestFullMetadata: false`; native picker/cache files may exist. | Photos/videos. Raw request metadata may reach the server transiently before sanitation. Existing stored uploads are not rewritten. Verify cache lifetime, reviewer access and deletion backups. No camera or video capture feature was found. |
| Questions, answers, comments, evidence URLs and guide application text (`001_initial.sql`) | Account-linked text, guide languages/regions/introduction/experience, question category/urgency and evidence are retained in PostgreSQL. Role/region/assignment controls govern visibility. | Other user content; assess emails/text messages for private conversation features. Do not invent every sensitive category someone could type into generic text. |
| Reports, blocks, moderation decisions (`004_moderation.sql`) | Reporter/subject IDs, reason/details, block pairs, reviewer actions and timestamps in PostgreSQL; admin review and own-account export have scoped views. | User content/customer support/user IDs as applicable. Final retention, moderator access and deletion implications need operator review. |
| Private exchange issue intake (`009_exchange_issues.sql`) | Participant-authored problem text, counterpart reference, immutable internal operator review note and timestamps in PostgreSQL. Reporter reads exclude internal notes; scoped export/deletion includes authored records and reviewer notes. | Assess user content/customer support/user IDs against final production behavior. Decide operational access, retention and public disclosure before launch; no response guarantee is implemented. |
| Mock point ledger and guide metrics (`point_transactions`, guide summaries) | Account-linked holds, mock charges, rewards, refunds and timestamps. No card/bank data or real purchase was found. | Assess product interaction/other data based on final use. Do not describe mock events as real purchases, financial assets or payment information. |
| Saved question draft and retry keys (`travel_draft_store.dart`, `api_service.dart`) | Device preferences contain draft text, region/coordinates, request IDs and image counts scoped by account/server hash; photo bytes/passwords are not saved in this draft. Mutation retry keys/fingerprints are persisted separately. | On-device draft data is not itself off-device collection. Verify logout/account-deletion purge and shared-device behavior. |
| Map tiles and geocoding (`question_home_page.dart`, `travel_location_section.dart`) | `tile.openstreetmap.org` receives network requests with tile coordinates (map viewport), IP and normal network metadata. iOS geocoding uses Apple's platform geocoder. Evidence links open chosen external sites. | Review tile provider's actual logging/terms/retention and disclose applicable recipients. Do not claim no third-party transmission or zero location exposure from maps. External open-web navigation is a separate flow. |
| IP, logs, mail and backups (deployment-dependent) | API uses socket IP for abuse/rate controls. Reverse-proxy logging, MTA queues, hosting storage and backups are not inspectable in a deployed environment here. Production mail sends account email and action code/link through the operator's MTA. | Production data/recipient/retention decisions remain open. Local synthetic mail sink is not evidence of live delivery. |
| Account export (`accounts.mjs`, export helper) | Own data, including photo bytes, is assembled for a user-initiated JSON export. Native share targets are chosen by the user. Source cleans its original file after share completion and abandoned feature files on startup/export. Android's plugin copy is retained until the next cleanup so the receiver can finish reading. | Verify excluded authentication secrets/other users' private data, cancellation, large exports and actual file deletion. |

No analytics, ad, crash-reporting, ATT or payment SDK was found in the inspected app imports or resolved baseline lock. That observation is not a declaration of “no tracking” for unverified production services. Audit the final archive and all recipients before completing privacy answers.

Apple's collection definitions distinguish on-device processing from retained off-device data, and classify location based on precision rather than the permission string. The final privacy answers must include actual third-party practices and linked purposes. [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)

## Native SDK and manifest inventory

Final `pubspec.lock` and `.dart_tool/package_config.json` inspected after dependency resolution on 2026-10-02. The generated package config records Flutter 3.47.5 / Dart 3.13.4. The later unsigned run and its exact limits are recorded in [CLOUD_IOS_BUILD](CLOUD_IOS_BUILD.md). These package versions alone do not establish a native build:

| Dart package | Locked version | Native relevance |
|---|---:|---|
| `geolocator` / `geolocator_apple` | 14.0.2 / 2.3.14 | Foreground device location; compile out always-authorization path |
| `geocoding` / `geocoding_ios` | 4.0.0 / 3.1.0 | Platform geocoder |
| `image_picker` / `image_picker_ios` | 1.2.1 / 0.8.13 | User-selected photo access and temporary files |
| `shared_preferences` / `shared_preferences_foundation` | 2.5.3 / 2.5.4 | UserDefaults for drafts/retry keys, and browser session persistence |
| `url_launcher` / `url_launcher_ios` | 6.3.2 / 6.3.4 | User-initiated links |
| `package_info_plus` | 10.2.2 | Transitive native package metadata |
| `path_provider` / `path_provider_foundation` | 2.1.5 / 2.4.2 | Native private export/cache directories |
| `flutter_secure_storage` / `flutter_secure_storage_darwin` | 11.2.0 / 0.4.3 | Native session Keychain; Darwin podspec/SPM minimum iOS 13 |
| `share_plus` | 13.3.1 | Explicit user-initiated export; podspec/SPM minimum iOS 13 |
| `flutter_map`, `http`, `crypto` | 8.3.1, 1.6.0, 3.0.7 | Dart map/HTTP/hash logic, not equivalent to Apple's MapKit SDK |
| `Flutter` | Dart lock records 0.0.0; Pod records 1.0.0 | These are placeholder package versions, not engine/SDK release evidence. Capture `flutter --version` and the actual archive. |

The initially considered `share_plus` 11.1.0 conflicts with the secure-storage Windows dependency; the final graph resolves 13.3.1. Dart minimum is now 3.10; Android configuration is AGP 8.12.1, Gradle 8.13, Kotlin 2.2.0 and Java 17. Android remains unbuilt; the recorded unsigned iOS build is separate evidence, with device and signed-archive checks still open. Backend lockfile resolves `pg` 8.23.1 and `sharp` 0.35.5; Sharp runs on the server and is not an iOS SDK.


### Resolved manifest/resource inspection

All nine iOS-native plugin manifests parse as property lists. Their CocoaPods and Swift Package Manager resource entries were inspected in the exact package directories referenced by `.dart_tool/package_config.json`, not arbitrary cached versions.

| Resolved plugin | Required-reason entries in its supplied manifest | Resource evidence |
|---|---|---|
| `flutter_secure_storage_darwin` 0.4.3 | None | CocoaPods bundle + SPM `Resources` both include the file |
| `geocoding_ios` 3.1.0 | None | **CocoaPods path mismatch**; SPM includes its correct file |
| `geolocator_apple` 2.3.14 | None | CocoaPods + SPM include the file |
| `image_picker_ios` 0.8.13 | None | CocoaPods + SPM include `Resources` |
| `package_info_plus` 10.2.2 | None | CocoaPods + SPM include the file |
| `path_provider_foundation` 2.4.2 | None | CocoaPods + SPM include `Resources` |
| `share_plus` 13.3.1 | None | CocoaPods + SPM include the file |
| `shared_preferences_foundation` 2.5.4 | UserDefaults `1C8F.1` | File is included; reason scope needs review for this app's private standard defaults |
| `url_launcher_ios` 6.3.4 | None | CocoaPods + SPM include `Resources` |

Those SDK files declare no SDK collection/tracking. They do **not** declare that the host app collects no data. The Flutter 3.47.5 engine's iOS source manifest declares FileTimestamp `0A2A.1`/`C617.1` and SystemBootTime `35F9.1`; the recorded unsigned build contains the engine manifest, while signed-archive packaging/signatures remain unverified.

`geocoding_ios` ships its file at `geocoding_ios/Sources/geocoding_ios/PrivacyInfo.xcprivacy`, while its podspec references `geocoding_ios/Sources/PrivacyInfo.xcprivacy`. The Podfile now repairs only that exact known mapping during `pre_install`, verifies the real file exists, and retains the vendor manifest unchanged. It does not edit the package cache or fabricate a lockfile. The authorized macOS build executed this hook and its bundle inventory contained the geocoding privacy resource. Static preflight still reports the raw upstream path mismatch honestly; the hook does not repair the package cache, and future native builds must verify the bundled resource again. [CocoaPods pre-install hook](https://guides.cocoapods.org/syntax/podfile.html#pre_install)

Runner's scoped `CA92.1` reflects app-private draft/retry/account preferences, with no App Group/MDM use. It does not substitute for the preferences SDK's own manifest or claim that its group-oriented `1C8F.1` is correct for every code path. Resolve that SDK scope with vendor/current archive evidence before release. A read-only check of the official `shared_preferences_foundation 2.5.7` archive on 2026-10-02 found the same `1C8F.1` declaration, so a dependency upgrade was not treated as a demonstrated repair. See the [current package changelog](https://pub.dev/packages/shared_preferences_foundation/changelog). The app does not copy all engine API reasons into Runner merely because they exist in Flutter. [Apple UserDefaults reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)

The Runner file currently contains only `NSPrivacyAccessedAPITypes`. Completing `NSPrivacyCollectedDataTypes`, linked/purpose fields, and tracking declarations requires reconciling the data inventory and production recipients. Do not distribute it as a complete privacy declaration; the separate preflight gate remains red.

Required-reason APIs include categories such as UserDefaults, file timestamps and disk space. Inspect the actual executable/SDK calls and each shipped manifest. Use only a reason that matches how the app uses the API; a plugin's own declaration is not replaced by putting its reasons in the app manifest. Do not add generic reasons just to make validation quiet. [Required-reason API documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)

Apple lists Flutter and several relevant plugin families among SDKs requiring privacy manifests; binary distributions in scope also need signatures. Confirm current list membership and the exact resolved versions, including repackaged SDKs. [Third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/)

Complete the scoped app manifest after the collection inventory is reconciled, preserve its Runner resource membership, and inspect the Xcode privacy report. Validate key/value syntax and bundled resources, not just file existence. [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)

## Permission and secure-storage checks

- `NSLocationWhenInUseUsageDescription` reflects foreground map/question-region use and submitted-location sharing; manual region selection remains available. Check denied, permanently denied, reduced accuracy, service disabled, timeout and location changes during account switch. [Apple location purpose key](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocationwheninuseusagedescription)
- `NSPhotoLibraryUsageDescription` reflects choosing question attachments. `pickMultiImage` now uses `requestFullMetadata: false`; the server separately sanitizes newly submitted images before storage. Neither is a promise that cached or historical files are removed. Test limited library, cancellation, unsupported/oversized images and inaccessible selections. [Apple photos purpose key](https://developer.apple.com/documentation/bundleresources/information-property-list/nsphotolibraryusagedescription), [image_picker guidance](https://pub.dev/packages/image_picker)
- `BYPASS_PERMISSION_LOCATION_ALWAYS=1` is scoped only to `geolocator_apple`. No always-location or background mode is needed for the current flow. [Geolocator setup](https://pub.dev/packages/geolocator)
- `IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device, synchronizable: false)` limits remembered sessions to an unlocked device, without iCloud sync. Do not add a shared access group, biometrics or broader accessibility unless the feature requires it. [Apple Keychain accessibility](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly), [secure-storage setup](https://pub.dev/packages/flutter_secure_storage)
- For export, test the exact native share sheet and iPad origin, wait for share completion, clean temporary copies and ensure “cancel” never becomes “success.” [share_plus guidance](https://pub.dev/packages/share_plus)

## Initial model decided; future money changes require a new decision

1. The initial model is non-purchasable, non-redeemable virtual contribution points and factual accepted-answer records, as chosen by the owner on 2026-10-02. There is no checkout or cash-out promise. Point allocation/replenishment and dispute rules are still unresolved; a development demo is not a finished App Store product.
2. Selling digital credits or access to asynchronous in-app answers generally requires evaluating Apple's in-app purchase rules. Do not assume that calling a provider a guide makes text Q&A a live one-to-one service.
3. Real-time one-to-one services and services consumed outside the app have distinct rules. Only use those routes if the actual product fits, after current storefront/territory and operational review. No real-money implementation or processor is selected by this checklist.

[Apple payment rules, 3.1.1 and 3.1.3](https://developer.apple.com/app-store/review/guidelines/#payments)

## Deterministic local preflight

Run from the repository root:

```sh
python3 scripts/release-preflight-test.py
python3 scripts/release-preflight.py
python3 scripts/release-preflight.py --config scripts/release-preflight.example.json --json
```

The script is read-only and offline. It never opens accounts, resolves signing, contacts services, reads deployment secrets, builds, uploads or publishes. The example contains public facts only and leaves identity/URLs blank on purpose. Supply a separate reviewed configuration and use the same `dart_defines` object for the actual Flutter release build. **Do not pass the entire example directly to `--dart-define-from-file`: that flag expects the flat `dart_defines` object.** Backend settings go to the backend, never into a client bundle. Never place database credentials, signing secrets or mail credentials in this file.

Exit 1 is the expected unresolved-release result; exit 2 means invalid input. Exit 0 would mean only that static source and supplied-public-config checks pass. URLs are syntax-checked, not fetched; source guard markers are not behavioral test evidence; native/archive and operational gates remain manual. There is no override that silently treats missing metadata as release-ready.

Twenty focused preflight tests cover insecure/private/placeholder URLs, explicit disabled flags, unresolved configuration, contact header injection, forbidden permission/ATS expansion, avoiding secret echo, missing native manifest resources, the incomplete API-only declaration, and the approved iOS15/lifecycle/lock boundaries. Current example configuration reports24 checked/18 blocked. Before distribution, rerun the final Flutter/backend suites and then the macOS/native checks. Archive validation, Apple privacy answers, live moderation effectiveness, delivery and approval remain unverified here.

## Recorded cloud iOS result and remaining native work

The owner has an Apple developer account. The authorized free GitHub macOS
run compiled the unsigned app with Xcode 26.6/iOS SDK26.5 and generated the
reviewed native baseline now adopted for iOS15+. See [Cloud iOS validation](CLOUD_IOS_BUILD.md)
for the exact revision, timings, analyzer limitations and lock provenance.
Linux checks cannot validate signing, an archive, device behavior or submission.
The current local photo recovery and checker changes have not had another native
build. Europe/US scope and virtual rewards are decided; the
[20-city development list](CITY_COVERAGE.md) remains a proposed rollout list.
