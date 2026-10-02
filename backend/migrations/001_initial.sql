-- Plain PostgreSQL 15+. No Supabase/auth/storage schema or paid service needed.
CREATE TABLE users (
 id uuid PRIMARY KEY, email text NOT NULL UNIQUE CHECK (email = lower(email)), name text NOT NULL,
 avatar_url text, current_country text, current_city text,
 point_balance integer NOT NULL DEFAULT 0 CHECK (point_balance >= 0),
 questioner_rating_avg numeric(3,2) NOT NULL DEFAULT 0, helper_rating_avg numeric(3,2) NOT NULL DEFAULT 0,
 questioner_rating_count integer NOT NULL DEFAULT 0, helper_rating_count integer NOT NULL DEFAULT 0,
 is_admin boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE auth_credentials (user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, password_hash text NOT NULL);
CREATE TABLE sessions (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 token_hash text NOT NULL UNIQUE, created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL
);
CREATE INDEX sessions_expiry_idx ON sessions(expires_at);
CREATE TABLE helper_applications (
 id uuid PRIMARY KEY, user_id uuid NOT NULL UNIQUE REFERENCES users(id),
 status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','approved','rejected','suspended')),
 languages text[] NOT NULL DEFAULT '{}', introduction text NOT NULL, experience_description text NOT NULL,
 applied_at timestamptz NOT NULL DEFAULT now(), reviewed_at timestamptz, reviewed_by uuid REFERENCES users(id), reject_reason text
);
CREATE TABLE helper_regions (
 id uuid PRIMARY KEY, helper_user_id uuid NOT NULL REFERENCES users(id), country text NOT NULL, city text NOT NULL,
 region_name text, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE questions (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id), assigned_helper_user_id uuid REFERENCES users(id),
 country text NOT NULL, city text NOT NULL, region_name text,
 category text NOT NULL CHECK(category IN ('교통','번역','생활','쇼핑','식당','긴급도움','기타')),
 urgency text NOT NULL CHECK(urgency IN ('보통','빠름','매우 급함')),
 title text NOT NULL, body text NOT NULL, reward_points integer NOT NULL CHECK(reward_points > 0),
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','assigned','answered','accepted','cancelled','expired','disputed','reported')),
 escrow_state text NOT NULL DEFAULT 'held' CHECK(escrow_state IN ('held','paid','refunded')),
 accepted_answer_id uuid, latitude double precision CHECK(latitude BETWEEN -90 AND 90),
 longitude double precision CHECK(longitude BETWEEN -180 AND 180),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz,
 CHECK(assigned_helper_user_id IS NULL OR assigned_helper_user_id <> user_id),
 CHECK((status = 'accepted' AND escrow_state = 'paid') OR (status = 'cancelled' AND escrow_state = 'refunded') OR (status NOT IN ('accepted','cancelled') AND escrow_state = 'held'))
);
CREATE TABLE question_images (
 id uuid PRIMARY KEY, question_id uuid NOT NULL REFERENCES questions(id), storage_key text NOT NULL UNIQUE,
 content_type text NOT NULL CHECK(content_type IN ('image/png','image/jpeg','image/webp')), byte_length integer NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE question_comments (
 id uuid PRIMARY KEY, question_id uuid NOT NULL REFERENCES questions(id), user_id uuid NOT NULL REFERENCES users(id),
 body text NOT NULL CHECK(char_length(trim(body)) BETWEEN 1 AND 600),
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE answers (
 id uuid PRIMARY KEY, question_id uuid NOT NULL UNIQUE REFERENCES questions(id), helper_user_id uuid NOT NULL REFERENCES users(id),
 body text NOT NULL, evidence_summary text NOT NULL, verification_method text NOT NULL,
 status text NOT NULL DEFAULT 'submitted' CHECK(status IN ('submitted','accepted','disputed','rejected','reported')),
 is_rewarded boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(id,question_id)
);
-- A selected answer must actually belong to this question.
ALTER TABLE questions ADD CONSTRAINT questions_selected_answer_fk FOREIGN KEY(accepted_answer_id,id) REFERENCES answers(id,question_id);
CREATE TABLE answer_evidence_links (
 id uuid PRIMARY KEY, answer_id uuid NOT NULL REFERENCES answers(id), url text NOT NULL CHECK(url ~ '^https?://'), title text, description text,
 source_type text NOT NULL CHECK(source_type IN ('official','map','transport','store','local_info','other')), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE point_transactions (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id), question_id uuid REFERENCES questions(id), answer_id uuid REFERENCES answers(id),
 type text NOT NULL CHECK(type IN ('charge_mock','hold','reward','refund','penalty','admin_adjustment')), amount integer NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(),
 CHECK((type='hold' AND amount < 0) OR (type IN ('charge_mock','reward','refund') AND amount > 0) OR type IN ('penalty','admin_adjustment'))
);
CREATE UNIQUE INDEX point_question_operation_unique ON point_transactions(question_id,type) WHERE type IN ('hold','reward','refund');
CREATE UNIQUE INDEX point_initial_grant_unique ON point_transactions(user_id) WHERE type='charge_mock';
CREATE TABLE idempotency_keys (
 user_id uuid NOT NULL REFERENCES users(id), key text NOT NULL, fingerprint text NOT NULL,
 response_body jsonb, response_status integer, created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(user_id,key)
);
CREATE INDEX questions_visibility_idx ON questions(status,user_id,assigned_helper_user_id);
CREATE INDEX helper_regions_location_idx ON helper_regions(helper_user_id,country,city);
CREATE INDEX comments_question_idx ON question_comments(question_id,created_at);
CREATE INDEX point_transactions_user_idx ON point_transactions(user_id,created_at DESC);
