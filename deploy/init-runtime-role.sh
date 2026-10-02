#!/bin/sh
# Runs only when the PostgreSQL volume is initialized. No credentials are printed.
set -eu
: "${APP_DATABASE_PASSWORD:?Set a separate runtime database password}"
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set=ON_ERROR_STOP=1 \
  --set=app_password="$APP_DATABASE_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE malaga_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L', :'app_password') \gexec
GRANT CONNECT ON DATABASE malaga TO malaga_app;
GRANT USAGE ON SCHEMA public TO malaga_app;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO malaga_app;
SQL
