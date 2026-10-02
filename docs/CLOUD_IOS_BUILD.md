# Cloud iOS validation

Updated **2026-10-02**. The owner approved **iOS 15 and later** as the device
support floor. This matches the pinned Flutter 3.47.5 support matrix and is
separate from the SDK used to build the app.
[Flutter supported platforms](https://docs.flutter.dev/reference/supported-platforms)

## Recorded native result

The authorized free standard GitHub macOS run
[36998188451](https://github.com/neopian/DaisyOne-Malaga/actions/runs/36998188451)
compiled source `930c683a7f79fdd932c79d0d4aa63d2da8662715` after a disposable
native bootstrap using Flutter 3.47.5, Xcode 26.6, iOS SDK 26.5 and CocoaPods
1.16.2. Xcode `build analyze` returned zero in **144 seconds**; total run time
was **350 seconds**. Flutter analysis and 307 tests passed. The built bundle
recorded minimum OS 15.0 and all 11 expected privacy manifests were present.

The successful command also reported **five third-party analyzer command
issues** involving geolocator/image-picker sources. Its retained tail does not
contain the full diagnostics. This is compilation evidence, not a clean native
analysis, signed archive, device test or App Store readiness result. No app
bundle, signing credential or provider artifact storage was used. The first
attempt stopped during Flutter cold-start metadata parsing before compilation;
the corrected workflow bootstraps Flutter before requesting machine JSON.

The public repository has a manual-only workflow for that bounded validation;
main received only the workflow. This local adoption does not publish another
revision or authorize another run. Future executions require the applicable
owner authorization and remain subject to the free-only constraint.

## Reviewed native baseline

The six generated files from that successful run are now adopted locally:

- Runner and Podfile deployment targets are 15.0
- Flutter's source AppFrameworkInfo no longer hardcodes a stale minimum; the
  build generates it and the built-bundle checks inspect the result
- AppDelegate registers plugins through the implicit-engine callback
- Info.plist configures FlutterSceneDelegate with multiple scenes disabled
- Podfile.lock reflects the resolved secure-storage/share plugins and removes
  stale app_links

The generated patch SHA-256 was
`d80728e4ff2cdd62aeb9da0ff88124825da948ae70d991e3ac29a48f744e9647`;
the generated lock SHA-256 was
`ad737472916a2f3821e5a3eca6d8a4c1dc56a44ef520dff54137639ea1a7eb88`.
Both were checked before application. The only follow-on Podfile change is a
comment correcting the support floor. Its lock `PODFILE CHECKSUM` was updated
from the file bytes; dependency versions, source checksums and resolution are
unchanged. This is not a Linux dependency resolution.

The lifecycle changes follow the pinned SDK migration and Flutter's
[UIScene adoption guidance](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate).
Native foreground/background, photo/share presentation and restoration still
need simulator/device validation. The later photo-read recovery correction and
new checker changes have not been included in another native build.

## Prepared runner and locked lane

An authorized isolated macOS environment needs:

- Preinstalled supported Xcode with iOS 26+ SDK; installation, license and
  first-launch setup completed by the provider/owner. Recheck Apple's
  [requirements](https://developer.apple.com/news/upcoming-requirements/) and
  [Xcode matrix](https://developer.apple.com/support/xcode/) before submission
- Flutter **3.47.5**, revision `6a19cca56475dbfba1478ee68d7bd0c2ef891da1`,
  its Dart SDK and cached iOS engine artifacts
- CocoaPods **1.16.2**, Python 3 and Bash
- A dedicated Flutter configuration with SwiftPM disabled for this reviewed
  CocoaPods lane and its geocoding resource repair. The script verifies this
  setting; it does not change system preferences
- A fresh checkout and access to locked dependency registries, without signing
  secrets. The lane does not install Xcode or accept licenses

If needed, select a preinstalled Xcode with the provider's documented
`DEVELOPER_DIR`. Run the inert Linux preview first:

```sh
bash scripts/verify-ios-macos.sh --dry-run
```

Then, only on an authorized prepared macOS runner:

```sh
bash scripts/verify-ios-macos.sh
```

`FLUTTER_BIN` selects a preinstalled executable. `VERIFY_IOS_REPORT_DIR`
selects a writable evidence directory. Each run uses fresh DerivedData and an
`.xcresult` bundle. The lane performs toolchain guards, locked Dart resolution,
`pod install --deployment`, analysis/tests, unsigned configuration, Xcode
`build analyze`, resource inspection and final source/lock comparison.
Every CocoaPods invocation gets deployment mode; no unlocked fallback occurs.
The framework plist is included in source fingerprints along with the Runner
files, native project, xcconfigs and locks.
[CocoaPods deployment mode](https://guides.cocoapods.org/terminal/commands.html#pod_install)

The app uses a compile-only `https://native-build.invalid/api` endpoint with
demo/dev/QA flags disabled. It does not contact a production service. The lane
retains stage logs and resource/diagnostic reports locally; it does not upload
artifacts or publish changes. Preserve the full log and xcresult when authorized
retention is available. A diagnostic summary cannot prove the absence of native
issues when the log is incomplete.

## Local checks and remaining gates

```sh
bash -n scripts/verify-ios-macos.sh
python3 scripts/verify-ios-macos-test.py
python3 scripts/release-preflight-test.py
python3 scripts/summarize-native-diagnostics-test.py
```

These checks validate script guards and synthetic fixtures on Linux. The stricter
15.0/framework checks added during adoption have not yet inspected a new native
bundle. No native success is inferred from these tests.

Still required: owned app identity/icon, authorized signing and archive,
physical iPhone/iPad behavior, complete privacy declarations and SDK review,
real API/mail/backup operations, release metadata and submission authorization.
See [APP_STORE_READINESS](APP_STORE_READINESS.md). An existing developer account
does not authorize new credentials or a signing-provider integration.
