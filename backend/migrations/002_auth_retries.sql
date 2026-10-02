-- Auth retries are anonymous until credentials are checked. Replay payloads contain
-- bearer tokens, so encrypt them with the server key instead of storing plaintext.
CREATE TABLE auth_idempotency_keys (
 email text NOT NULL, key text NOT NULL, fingerprint text NOT NULL,
 encrypted_response text, response_status integer,
 expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(email,key)
);
CREATE INDEX auth_idempotency_expiry_idx ON auth_idempotency_keys(expires_at);
