#!/usr/bin/env bash
# Run integration tests against a fresh, isolated PostgreSQL cluster.
# Only the temporary cluster created by this script is removed.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
pg_bin="${PG_BIN:-/usr/lib/postgresql/17/bin}"
pg_share="${PG_SHARE:-/usr/share/postgresql/17}"
if [[ ! -x "$pg_bin/initdb" || ! -x "$pg_bin/pg_ctl" ]]; then
  echo "Set PG_BIN and PG_SHARE to an installed PostgreSQL 15+ distribution." >&2
  exit 2
fi
cluster_root="$(mktemp -d "${TMPDIR:-/tmp}/travel-qa-pg.XXXXXX")"
mkdir -m 700 "$cluster_root/socket"
# Some cloud runners support loopback TCP but do not implement Unix sockets.
# TCP mode stays inside this invocation and uses a fresh temporary password.
pg_host="$cluster_root/socket"
pg_port=5447
pg_options="-k $cluster_root/socket -h '' -p $pg_port"
pg_auth=(--auth-local=trust --auth-host=reject)
if [[ "${TEST_PG_TCP:-0}" == 1 ]]; then
  pg_host=127.0.0.1
  pg_port="$(node --input-type=module -e "import net from 'node:net';const s=net.createServer();s.listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()});")"
  pg_options="-k '' -h 127.0.0.1 -p $pg_port"
  node -e "process.stdout.write(require('node:crypto').randomBytes(32).toString('hex'))" >"$cluster_root/password"
  chmod 600 "$cluster_root/password"
  export PGPASSWORD="$(cat "$cluster_root/password")"
  pg_auth=(--auth-local=reject --auth-host=scram-sha-256 --pwfile="$cluster_root/password")
fi
cleanup() {
  "$pg_bin/pg_ctl" -D "$cluster_root/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf -- "$cluster_root"
}
trap cleanup EXIT INT TERM
"$pg_bin/initdb" -D "$cluster_root/data" -L "$pg_share" \
  --username=cluster_owner "${pg_auth[@]}" \
  --no-locale --encoding=UTF8 >"$cluster_root/init.log"
if ! "$pg_bin/pg_ctl" -D "$cluster_root/data" -l "$cluster_root/postgres.log" \
  -o "$pg_options" -w start >/dev/null; then
  cat "$cluster_root/postgres.log" >&2
  exit 1
fi
"$pg_bin/psql" -h "$pg_host" -p "$pg_port" -U cluster_owner -d postgres \
  -v ON_ERROR_STOP=1 -c 'CREATE ROLE app_test LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;' \
  -c 'CREATE ROLE app_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;' \
  -c 'CREATE DATABASE app_test OWNER app_test;' >/dev/null
if [[ "${TEST_PG_TCP:-0}" == 1 ]]; then
  "$pg_bin/psql" -h "$pg_host" -p "$pg_port" -U cluster_owner -d postgres \
    -v ON_ERROR_STOP=1 -v "test_password=$PGPASSWORD" <<'SQL' >/dev/null
ALTER ROLE app_test PASSWORD :'test_password';
ALTER ROLE app_runtime PASSWORD :'test_password';
SQL
fi
export TEST_DATABASE_URL="postgresql:///app_test?host=$pg_host&port=$pg_port&user=app_test"
export TEST_RUNTIME_DATABASE_URL="postgresql:///app_test?host=$pg_host&port=$pg_port&user=app_runtime"
cd "$repo_root/backend"
if [[ $# -gt 0 ]]; then
  node --test --test-concurrency=1 "$@"
else
  npm test
fi
