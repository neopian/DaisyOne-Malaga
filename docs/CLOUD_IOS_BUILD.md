# Cloud iOS validation

Prepared **2026-10-02**. A hosted macOS runner can compile this Flutter iOS
project without using the owner's Mac. An existing Apple Developer account
does not provide a macOS runner, resolve signing, or prove that an archive works.
Xcode on macOS remains required. [Flutter iOS release guide](https://docs.flutter.dev/deployment/ios)

This repository contains a provider-neutral **unsigned validation lane**, not an
active CI workflow. No provider account, repository integration, credential,
paid job, signing operation, upload, or App Store submission has been configured
or run. Linux checks below validate the script's guards and resource fixtures;
they are not native build evidence.

## Runner prerequisites

Use an owner-authorized, isolated macOS build environment with:

- Xcode **26 or later**, an **iOS 26 or later SDK**, and an OS version supported
  by that Xcode. The provider/owner must have completed Xcode installation,
  license acceptance and first-launch setup before this lane starts. Apple's
  upload SDK requirement took effect April 28, 2026; since September 9, 2026,
  uploaded apps must also target iOS 13 or later. This project targets iOS 13.
  Recheck the [current Apple requirements](https://developer.apple.com/news/upcoming-requirements/)
  and [Xcode support matrix](https://developer.apple.com/support/xcode/) when
  choosing the runner image
- Preinstalled **Flutter 3.47.5**, including cached iOS engine artifacts, and its
  bundled Dart SDK. This exact Flutter version matches the reviewed source
  baseline. A different version needs a deliberate review of project migrations,
  plugin compatibility and the script's version pin
- Preinstalled **CocoaPods 1.16.2**, matching the native lockfile's recorded tool
  version, plus Python 3 and Bash. The script does not install SDKs, gems, tools,
  certificates or command-line components
- A fresh checkout of the intended source revision, with access to its locked
  package registries. Dependency retrieval may use the network and execute normal
  dependency build hooks. Only use a runner/provider and source checkout the
  owner has approved; do not load signing secrets into this unsigned job
- A dedicated Flutter configuration that already has SwiftPM disabled. Flutter
  3.44+ enables SwiftPM by default and can automatically migrate the project.
  This first validation intentionally exercises the existing Podfile and its
  geocoding privacy-resource repair. The runner owner can prepare a dedicated
  runner with `flutter config --no-enable-swift-package-manager`; the script
  only reads and verifies that setting. It does not change global preferences.
  This is a bounded compatibility lane, not a recommendation to avoid a later
  reviewed migration. [Flutter native dependency guidance](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)

If the provider image contains several Xcode installations, select one in the
provider job environment using its documented `DEVELOPER_DIR` path. The script
checks the selected toolchain; it does not run `sudo xcode-select`, download an
SDK, accept a license, or alter system setup.

## Known first-run blocker: native lockfile

The current `ios/Podfile.lock` predates the reviewed plugin graph and Podfile.
It still lists `app_links`, omits the newer secure-storage and share plugins,
and records the old Podfile checksum. It must be regenerated and reviewed on
an authorized macOS environment before the locked validation can pass.

The lane intentionally runs `flutter pub get --enforce-lockfile` and
`pod install --deployment`. CocoaPods deployment mode rejects lockfile changes.
Every later CocoaPods call made by Flutter receives the same deployment flag
through a wrapper scoped to this one run. It never falls back to `pod update`
or an unlocked install. [CocoaPods command reference](https://guides.cocoapods.org/terminal/commands.html#pod_install)

For the separately authorized dependency refresh, use a disposable checkout
and the pinned tools: resolve Dart with the existing lock, run an ordinary
`pod install` in `ios`, then review the resulting native dependency graph,
checksums and Podfile resource repair. Review any required Xcode/Flutter
source migration separately. Preserve the actual generated lockfile; do not
fabricate one on Linux or bypass deployment mode to make the check green.
After the reviewed changes are in the selected source revision, rerun this lane.

## Run and inspect

This preview is inert and works on Linux:

```sh
bash scripts/verify-ios-macos.sh --dry-run
```

On the authorized, prepared macOS runner:

```sh
bash scripts/verify-ios-macos.sh
```

`FLUTTER_BIN` can select a preinstalled Flutter executable.
`VERIFY_IOS_REPORT_DIR` can select a writable report parent directory. The
default is `.verification/ios`; every run gets a fresh `run.*` directory. Use a
fresh disposable checkout because native tools generate files and may propose
project migrations. Dependency locks, Podfile, native project/scheme, workspace
and xcconfig fingerprints are checked against the run's initial source. An
unexpected mutation fails the lane and is left visible for review, never
silently reverted or committed.

The lane performs:

1. Host, Xcode/SDK, first-launch, pinned tool and SwiftPM-mode guards
2. Locked Dart resolution and CocoaPods installation, failing early on stale locks
3. Flutter analysis/tests and release configuration without signing
4. Xcode `build analyze` for the generic iOS device destination, with signing
   disabled and fresh DerivedData plus an `.xcresult` bundle
5. Inspection of the fresh `Runner.app`: recorded iOS SDK and deployment target,
   app executable/compiled asset presence, root and engine privacy manifests,
   and all nine expected plugin privacy bundles, including geocoding
6. Final lock/source fingerprint comparison

All build defines disable demo mode, development login and QA auto-login. The
API URL is deliberately `https://native-build.invalid/api`, a compile-only
synthetic value. The script does not launch the app or test any server. This
bundle is not a production candidate; a separately reviewed, real public HTTPS
API configuration is still necessary for release and device tests.

Keep the version files, source fingerprints, stage logs, `.xcresult` and
`bundled_resources.log` together with the exact source revision and provider
image identifier. Resource output contains paths, hashes and parsed manifest
declarations for review. Report directories are git-ignored. This script does
not upload artifacts; set private retention/access explicitly if the owner
later authorizes provider artifact storage.

## Provider job template (documentation only)

After the owner chooses and authorizes a provider, translate this checklist to
that provider's job format. No `.github/workflows` or provider configuration is
installed by this change.

```text
Trigger: manual, after provider/repository access and any cost are approved
Runner: a pinned macOS image with the prerequisites above
Source: the reviewed revision, including refreshed native lockfile
Secrets: none for this unsigned job
Command: bash scripts/verify-ios-macos.sh
Evidence: job result + stage logs + xcresult + resource inventory
Artifact access: private, only after storage/retention is approved
Distribution: none
```

## What a pass establishes

A real run's success establishes that the selected source compiled unsigned
with that recorded toolchain, the analysis command completed, and the checked
resources exist in its built app. Analyzer warnings still need review. Resource
presence and plist structure do not establish correct privacy reasons,
collection declarations, SDK signatures or App Store compliance. The expected
plugin bundle list must be reviewed when native dependencies change.

It does not validate a signed archive, provisioning, Keychain entitlements,
installation, simulator or physical-device flows, native photo/share behavior,
live mail/API/database services, App Store Connect processing or review. The
identity, icon, privacy and operating-policy gates in
[APP_STORE_READINESS.md](APP_STORE_READINESS.md) remain independent.

Signing and TestFlight are a later authorized stage: select the correct Apple
team/app record and owned bundle identity, prepare the approved distribution
credentials in the chosen provider's secure flow, use real release configuration,
build and inspect the archive, validate device behavior, then authorize its
upload/distribution. Existing Developer Program membership alone does not
authorize new persistent credentials or a provider integration.

## Linux-safe script tests

```sh
bash -n scripts/verify-ios-macos.sh
python3 scripts/verify-ios-macos-test.py
```

These cover Linux refusal before SDK/file operations, inert help/dry-run,
argument rejection, old-Xcode/SDK guards, and synthetic resource-fixture
failures. Fixture files are not genuine Apple app bundles. No native success
is inferred from these tests.
