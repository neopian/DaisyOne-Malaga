# Self-hosted deployment guide

This is a deployment recipe, not a record of a production deployment. The app
uses Flutter, a Node.js API, PostgreSQL, and local image files. Supabase is no
longer required for the migrated app. All balances are **mock points**; there is
no real payment processing or cash-out.

## Local development

Use Node.js 22 or later, PostgreSQL 15 or later, and a Flutter SDK compatible
with Dart 3.8.1+. Install the versions your server administrator supports and
keep them patched. The verification report records exact versions tested here.

1. Create an empty development PostgreSQL database owned by an application user.
2. Copy `backend/.env.example` to `backend/.env`, set `DATABASE_URL`, and keep
   `NODE_ENV=development`. Never use a production database for test commands.
3. From `backend/`, run `npm ci`, `npm run migrate`, then `npm start`.
4. In another terminal, run Flutter from the repository root:

   ```sh
   flutter pub get
   flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8080/api
   ```

The API binds to loopback by default. For a physical phone, use a deliberately
configured development server reachable by that phone; `localhost` on the phone
is not your computer. Do not open the development API to the public internet.

### Optional synthetic accounts

Only in an isolated development database:

```sh
cd backend
ALLOW_DEV_SEED=true npm run seed:dev
```

This adds the existing questioner1–3 and answerer1–2 `@example.com` accounts,
plus `admin@example.com`. Their demo-only password is `daisy-dev-1234`. Existing
accounts, passwords, and balances are not reset. The seed refuses production.
Use `--dart-define=ENABLE_DEV_LOGIN=true` only for an isolated development build.

## Own-server recipe

The included Compose file is an optional packaging example. A native PostgreSQL
installation plus a Node service is equally valid. No managed SQL subscription
is required. Docker was not available in the validation environment; verify the
container deployment on a staging server before relying on it.

1. Choose the server, app/API HTTPS domains, backups, and maintenance owner.
2. Copy `deploy.env.example` to a private local `deploy.env`. Fill in a strong
   URL-safe owner and runtime database passwords (different values) and a random image-signing secret of at least
   32 characters. Do not paste secrets into chats or commit them. Protect the
   file using the server's normal secret-management procedure.
3. Set `PUBLIC_BASE_URL` to the API's HTTPS origin, without a path. Set
   `CORS_ORIGINS` to the exact browser origin, without a trailing slash. A
   comma-separated list is supported; wildcards are not.
   Configure the operator-owned local mail transport, sender, account action URL,
   and explicit verification policy described in [Account lifecycle](ACCOUNT_BACKEND.md).
   The bundled Node Docker base image needs a reviewed MTA integration before
   production startup; it does not silently disable recovery or claim delivery.
4. Start and migrate:

   ```sh
   docker compose --env-file deploy.env up -d db
   docker compose --env-file deploy.env run --rm migrate
   docker compose --env-file deploy.env up -d api
   ```

5. Put the API behind your existing HTTPS reverse proxy. Its container port is
   exposed only at `127.0.0.1:8080`; PostgreSQL has no host port. The API uses a separate non-superuser database
   role; the owner credential is used only for initialization/migrations. Forward `/api/`
   to the API without removing `/api`. Enforce a body limit at least 22 MiB if
   allowing five maximum-size images. Preserve request timeouts suitable for
   uploads. Do not log Authorization headers, signed image query strings, or
   request bodies containing passwords.
6. Build the production web bundle:

   ```sh
   flutter build web --release --dart-define=API_BASE_URL=https://api.example.com/api
   ```

   Serve `build/web` over HTTPS. Do not enable development login or demo mode.
   Do not copy the browser-preview service worker into production. Configure
   single-page fallback routing and a short/no-cache policy for the HTML entry
   and Flutter bootstrap; fingerprinted assets may be cached longer.
7. Register the first intended administrator normally, then promote that exact
   account through a reviewed database administration session:

   ```sql
   UPDATE users SET is_admin = true WHERE email = 'your-reviewed-admin-address';
   ```

   This is an explicit administrative action; the app never lets users promote
   themselves. Do not run the development seed in production.

The runtime-role initialization script runs only for a new PostgreSQL volume.
For an existing database, have its administrator apply an equivalent reviewed
role/grant change; do not delete the volume to rerun initialization. Keep the
owner credential away from the running API service.

## Storage, sessions, and operations

- Back up PostgreSQL and the upload volume together. Exercise restore into a
  separate environment; a database backup alone does not contain image bytes.
- Image access uses short-lived URLs tied to the requesting session. Logging
  out or expiry invalidates that access. Keep the signing secret stable across
  normal restarts; rotating it expires existing image URLs until a refresh.
- Sessions are opaque random tokens; the database stores token hashes.
  Passwords are salted and PBKDF2-hashed. Login attempts are rate-limited.
  Browser sessions use app storage, so HTTPS and XSS prevention remain essential.
- Authentication quotas are shared atomically in PostgreSQL across instances
  using keyed IP/account scopes and a stable shared signing secret. Forwarding
  headers are deliberately not trusted, so a reverse proxy may make all clients
  share one IP bucket. Review that proxy/client-IP design and load limits before
  public deployment; see [Account backend](ACCOUNT_BACKEND.md) for thresholds.
- Foreground question updates use 15-second polling rather than an external
  realtime service. There are no push notifications or offline write queues.
- Keep database and upload capacity monitored. Session/idempotency cleanup
  requires an explicit retention policy; do not delete retry records casually.
- Stop writes during a schema rollback. Restore a tested backup rather than
  reversing payment-state migrations by hand. All points remain fictional.

## Decisions before a public launch

The code is an MVP, not a public-launch declaration. Select a server and HTTPS
hosting, validate the implemented account recovery/email transport and select its verification policy, moderation and
dispute handling, retention/privacy rules, backup ownership, monitoring, and
load limits. A future import from the historical Supabase database is a separate
reviewed task; the preserved `supabase/` migrations are reference material, not
an automatic data-transfer script. Real money requires its own product and
security review and is intentionally absent.

## Shared city catalog in the API image

The Compose API/migration build context is the repository root so the image includes `config/cities.json` beside `/app/backend`. The root `.dockerignore` allowlists only server code, migrations, lockfiles and this public catalog; it excludes `.env`, local data, Flutter artifacts and credentials. For a manual image build use `docker build -f backend/Dockerfile .` from the repository root. A backend-only context is insufficient. Native Docker execution has not been available in the Linux validation workspace, so run the actual image/Compose smoke check on the chosen server before deployment.
