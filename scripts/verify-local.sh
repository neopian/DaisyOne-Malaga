#!/usr/bin/env bash
# Reproduce development checks without touching a configured application DB.
# Native archive/signing and live-service checks remain separate release gates.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
flutter_bin="${FLUTTER_BIN:-flutter}"
report_dir="${VERIFY_REPORT_DIR:-$repo_root/.verification}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
export CI=true BOT=true FLUTTER_SUPPRESS_ANALYTICS=true DASH__SUPPRESS_ANALYTICS=true
cd "$repo_root"

run_check() {
  local name="$1"
  shift
  echo "Checking $name"
  if "$@" >"$report_dir/$name.log" 2>&1; then
    echo "Passed $name"
  else
    local result=$?
    tail -n 60 "$report_dir/$name.log" >&2
    echo "Failed $name; see $report_dir/$name.log" >&2
    return "$result"
  fi
}

node --input-type=module -e "if(Number(process.versions.node.split('.')[0])<22)throw Error('Node.js22+ is required')"
run_check flutter_dependencies "$flutter_bin" pub get --enforce-lockfile
run_check flutter_analyze "$flutter_bin" analyze --no-pub
run_check flutter_tests "$flutter_bin" test --no-pub -r expanded
run_check backend_dependencies npm --prefix backend ci --no-audit --no-fund
run_check backend_syntax npm --prefix backend run check
run_check postgres_tests bash scripts/test-postgres-local.sh
run_check preflight_tests python3 scripts/release-preflight-test.py
run_check ios_runner_contracts python3 scripts/verify-ios-macos-test.py
run_check native_diagnostic_contracts python3 scripts/summarize-native-diagnostics-test.py
run_check web_build "$flutter_bin" build web --release --no-pub \
  --no-web-resources-cdn --pwa-strategy=none --dart-define=API_BASE_URL=/api \
  --dart-define=DEMO_MODE=false --dart-define=ENABLE_DEV_LOGIN=false \
  --dart-define=QA_AUTO_LOGIN=false

preflight_exit=0
python3 scripts/release-preflight.py \
  --config "${RELEASE_PUBLIC_CONFIG:-scripts/release-preflight.example.json}" \
  --json >"$report_dir/release-preflight.json" || preflight_exit=$?
if [[ "$preflight_exit" -gt 1 ]]; then
  echo 'Release preflight could not read or validate its public configuration.' >&2
  exit "$preflight_exit"
fi
if [[ "$preflight_exit" == 1 ]]; then
  echo "Development checks passed. Release gates remain blocked; inspect $report_dir/release-preflight.json"
else
  echo 'Development/static configuration checks passed. Native archive, devices and live operations are still unverified.'
fi
