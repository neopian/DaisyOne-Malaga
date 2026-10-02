#!/usr/bin/env bash
# Provider-neutral, unsigned native validation. Run only on an authorized Mac.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/verify-ios-macos.sh [--dry-run]

Requires preinstalled macOS, licensed/initialized Xcode 26+, iOS 26+ SDK,
Flutter 3.47.5 with iOS artifacts, CocoaPods 1.16.2, and Python 3.
The dedicated runner's Flutter configuration must already disable SwiftPM.
See docs/CLOUD_IOS_BUILD.md for the reviewed iOS 15 baseline and native evidence.

--dry-run prints the plan on any OS; it runs no build or dependency command.
FLUTTER_BIN may select a preinstalled Flutter executable.
VERIFY_IOS_REPORT_DIR may select an existing writable report parent directory.
No signing, account login, upload, provider setup, or SDK installation is done.
USAGE
}

fail() { echo "ERROR: $*" >&2; exit 2; }
case "${1:-}" in
  --help|-h) [[ $# == 1 ]] || fail 'Unexpected extra arguments'; usage; exit 0 ;;
  --dry-run) [[ $# == 1 ]] || fail 'Unexpected extra arguments'; dry_run=true ;;
  '') dry_run=false ;;
  *) usage >&2; fail "Unknown argument: $1" ;;
esac

if "$dry_run"; then
  cat <<'PLAN'
DRY RUN ONLY: no native validation has run and no files are written.
1. Require Darwin, ready/licensed Xcode >=26 and iphoneos SDK >=26.
2. Require preinstalled Flutter 3.47.5, CocoaPods 1.16.2 and Python 3.
3. Verify SwiftPM is explicitly disabled for this CocoaPods validation lane.
4. Snapshot dependency locks and native project source; record tool versions.
5. flutter pub get --enforce-lockfile
6. pod install --deployment --project-directory=ios
7. flutter analyze --no-pub
8. flutter test --no-pub -r expanded
9. flutter build ios --release --no-codesign --config-only --no-pub \
     --dart-define=API_BASE_URL=https://native-build.invalid/api \
     --dart-define=DEMO_MODE=false --dart-define=ENABLE_DEV_LOGIN=false \
     --dart-define=QA_AUTO_LOGIN=false
10. Reject dependency lock or native project changes; Flutter's child pod
    invocations also use --deployment via a run-local wrapper.
11. xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
      -configuration Release -sdk iphoneos -destination generic/platform=iOS \
      -derivedDataPath <fresh-report-directory>/DerivedData \
      -resultBundlePath <fresh-report-directory>/native.xcresult \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
      DEVELOPMENT_TEAM= -disableAutomaticPackageResolution build analyze
12. Summarize the complete Xcode log before any provider tail limit, preserving
    its exit code and analyzer warnings separately from compilation success.
13. Inspect fresh Runner.app: built SDK/target, executable, compiled assets,
    Runner/Flutter manifests and all nine expected plugin manifest bundles.
14. Recheck source/lock hashes. A pass is unsigned build/resource evidence only.
The .invalid URL is compile-only synthetic configuration, never a live service.
PLAN
  exit 0
fi

# This must precede any SDK invocation, directory creation or dependency change.
[[ "$(uname -s)" == Darwin ]] || fail 'macOS with Xcode is required; native iOS validation did not run.'
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
flutter_bin="${FLUTTER_BIN:-flutter}"
for tool in "$flutter_bin" pod python3 xcodebuild xcrun xcode-select; do
  command -v "$tool" >/dev/null 2>&1 || fail "Required preinstalled tool missing: $tool"
done
flutter_bin="$(command -v "$flutter_bin")"
pod_bin="$(command -v pod)"
[[ "$pod_bin" == /* ]] || fail 'CocoaPods must resolve to an absolute executable path.'
export CI=true BOT=true FLUTTER_SUPPRESS_ANALYTICS=true DASH__SUPPRESS_ANALYTICS=true
export COCOAPODS_DISABLE_STATS=true

xcode_version="$(xcodebuild -version)"
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
python3 - "$xcode_version" "$sdk_version" <<'PY'
import re, sys
xcode = re.search(r'^Xcode (\d+)(?:\.\d+)*$', sys.argv[1], re.M)
sdk = re.fullmatch(r'(\d+)(?:\.\d+)*', sys.argv[2].strip())
if not xcode or int(xcode[1]) < 26 or not sdk or int(sdk[1]) < 26:
    sys.exit('ERROR: Require Xcode 26+ and the iOS 26+ SDK; no native build ran.')
PY
# Readiness check only: never accept a license or install first-launch components.
xcodebuild -checkFirstLaunchStatus >/dev/null || fail 'Xcode first-launch/license setup must be completed by the runner owner.'
flutter_version="$("$flutter_bin" --version --machine)"
python3 - "$flutter_version" <<'PY'
import json, sys
if json.loads(sys.argv[1]).get('frameworkVersion') != '3.47.5':
    sys.exit('ERROR: This lane is pinned to Flutter 3.47.5. Review changes before updating it.')
PY
[[ "$(pod --version)" == 1.16.2 ]] || fail 'This lane requires preinstalled CocoaPods 1.16.2.'
flutter_config="$("$flutter_bin" config --machine)"
python3 - "$flutter_config" <<'PY'
import json, pathlib, re, sys
if json.loads(sys.argv[1]).get('enable-swift-package-manager') is not False:
    sys.exit('ERROR: The dedicated runner must already have SwiftPM disabled; see CLOUD_IOS_BUILD.md.')
if re.search(r'^\s*enable-swift-package-manager\s*:', pathlib.Path('pubspec.yaml').read_text(), re.M):
    sys.exit('ERROR: Project-level SwiftPM configuration changed; review this CocoaPods lane first.')
PY

report_parent="${VERIFY_IOS_REPORT_DIR:-$repo_root/.verification/ios}"
mkdir -p "$report_parent"
report_dir="$(mktemp -d "$report_parent/run.XXXXXX")"
report_dir="$(cd "$report_dir" && pwd)"
echo "Unsigned iOS validation reports: $report_dir"
printf '%s\n' "$xcode_version" "iOS SDK $sdk_version" >"$report_dir/xcode-version.txt"
printf '%s\n' "$flutter_version" >"$report_dir/flutter-version.json"
printf '%s\n' '1.16.2' >"$report_dir/cocoapods-version.txt"
xcode-select -p >"$report_dir/xcode-selection.txt"

run_check() {
  local name="$1"
  shift
  echo "Checking $name"
  if "$@" >"$report_dir/$name.log" 2>&1; then
    echo "Passed $name"
  else
    local status=$?
    tail -n 60 "$report_dir/$name.log" >&2
    echo "Failed $name. No native success is claimed; see $report_dir/$name.log" >&2
    return "$status"
  fi
}

snapshot_sources() {
  python3 - <<'PY'
import hashlib, json, pathlib
paths = ['pubspec.yaml', 'pubspec.lock', 'ios/Podfile', 'ios/Podfile.lock',
         'ios/Runner.xcodeproj/project.pbxproj',
         'ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme',
         'ios/Runner.xcworkspace/contents.xcworkspacedata',
         'ios/Flutter/Debug.xcconfig', 'ios/Flutter/Release.xcconfig',
         'ios/Flutter/AppFrameworkInfo.plist']
paths += [str(p) for p in pathlib.Path('ios/Runner').rglob('*')
          if p.is_file() and not p.name.startswith('GeneratedPluginRegistrant.')]
print(json.dumps({p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
                  for p in paths}, indent=2, sort_keys=True))
PY
}
check_source_snapshot() {
  snapshot_sources >"$report_dir/source-after.json"
  cmp -s "$report_dir/source-before.json" "$report_dir/source-after.json" ||
    fail "Locks or native source changed. Review changes before rerunning; $report_dir/source-after.json"
}
snapshot_sources >"$report_dir/source-before.json"

# Flutter may invoke CocoaPods itself, even for --config-only. Keep every such
# install in deployment mode rather than merely noticing a changed lock afterward.
mkdir "$report_dir/bin"
cat >"$report_dir/bin/pod" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  install) shift; exec "$VERIFY_IOS_POD_EXECUTABLE" install --deployment "$@" ;;
  update) echo 'pod update is disabled in locked validation.' >&2; exit 2 ;;
  *) exec "$VERIFY_IOS_POD_EXECUTABLE" "$@" ;;
esac
WRAPPER
chmod +x "$report_dir/bin/pod"
export VERIFY_IOS_POD_EXECUTABLE="$pod_bin"
export PATH="$report_dir/bin:$PATH"

run_check flutter_dependencies "$flutter_bin" pub get --enforce-lockfile
run_check pods_locked pod install --project-directory=ios
run_check flutter_analyze "$flutter_bin" analyze --no-pub
run_check flutter_tests "$flutter_bin" test --no-pub -r expanded
run_check ios_configuration "$flutter_bin" build ios --release --no-codesign --config-only --no-pub \
  --dart-define=API_BASE_URL=https://native-build.invalid/api \
  --dart-define=DEMO_MODE=false --dart-define=ENABLE_DEV_LOGIN=false \
  --dart-define=QA_AUTO_LOGIN=false
check_source_snapshot
xcode_status=0
run_check xcode_build_analyze xcodebuild \
  -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$report_dir/DerivedData" -resultBundlePath "$report_dir/native.xcresult" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM= \
  -disableAutomaticPackageResolution build analyze || xcode_status=$?
# Generate evidence even after a failed native command. This parser does not
# turn warnings into an artificial success or replace the actual Xcode status.
python3 scripts/summarize-native-diagnostics.py "$report_dir/xcode_build_analyze.log" \
  --input-completeness complete --xcode-exit-code "$xcode_status" \
  > "$report_dir/native-diagnostics.json"
[[ "$xcode_status" == 0 ]] || exit "$xcode_status"
run_check bundled_resources python3 scripts/verify-ios-resources.py \
  "$report_dir/DerivedData/Build/Products/Release-iphoneos/Runner.app"
check_source_snapshot
echo 'Unsigned native build, analysis invocation and resource checks passed.'
echo 'Signing, installation, device behavior, privacy correctness, live services and App Store submission remain unverified.'
echo "Review native-diagnostics.json, the full log and resource inventory in $report_dir before making release claims."
