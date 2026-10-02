ALTER TABLE users ADD COLUMN email_verified_at timestamptz;

CREATE TABLE account_tokens (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 purpose text NOT NULL CHECK (purpose IN ('verify_email','reset_password')),
 token_hash text NOT NULL UNIQUE, expires_at timestamptz NOT NULL,
 consumed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX account_tokens_user_idx ON account_tokens(user_id,purpose);
CREATE TABLE account_requests (
 scope_hash text NOT NULL, key text NOT NULL, fingerprint text NOT NULL,
 user_id uuid REFERENCES users(id) ON DELETE CASCADE,
 response_body jsonb, response_status integer, expires_at timestamptz NOT NULL,
 PRIMARY KEY(scope_hash,key)
);
CREATE TABLE account_rate_limits (
 scope_hash text PRIMARY KEY, attempts integer NOT NULL, expires_at timestamptz NOT NULL
);
-- Raw recovery tokens are hashed above. An encrypted dispatch envelope is kept
-- only until a local sink/MTA accepts it, then removed. Never log this payload.
CREATE TABLE account_mail_outbox (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 purpose text NOT NULL CHECK (purpose IN ('verify_email','reset_password')),
 encrypted_message text NOT NULL, attempts integer NOT NULL DEFAULT 0,
 available_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
-- Allocated before dispatch, so even an ambiguous sink write is erasable.
CREATE TABLE account_mail_deliveries (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now()
);
-- No account identifier, email, password, or content is retained in these jobs.
-- The receipt is keyed to the old session and intent; filenames permit reliable
-- post-commit physical removal without ever making the files publicly readable.
CREATE TABLE account_deletion_jobs (
 id uuid PRIMARY KEY, receipt_hash text NOT NULL UNIQUE, fingerprint text NOT NULL,
 storage_keys text[] NOT NULL DEFAULT '{}', mail_ids uuid[] NOT NULL DEFAULT '{}', completed_at timestamptz,
 retry_expires_at timestamptz NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
