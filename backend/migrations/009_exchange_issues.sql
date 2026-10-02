-- Private participant intake is independent of abuse reports and exchange state.
CREATE TABLE exchange_issues (
 id uuid PRIMARY KEY,
 question_id uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
 reporter_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 other_participant_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 reason text NOT NULL CHECK(reason IN ('waiting_for_response','answer_problem','cannot_continue','other')),
 details text CHECK(details IS NULL OR (details=btrim(details) AND char_length(details) BETWEEN 1 AND 1000)),
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','reviewed')),
 created_at timestamptz NOT NULL DEFAULT now(),
 reviewed_at timestamptz,
 reviewed_by uuid REFERENCES users(id) ON DELETE SET NULL,
 review_note text CHECK(review_note IS NULL OR (review_note=btrim(review_note) AND char_length(review_note) BETWEEN 1 AND 1000)),
 UNIQUE(question_id,reporter_id),
 CHECK(reporter_id<>other_participant_id),
 CHECK((status='open' AND reviewed_at IS NULL AND reviewed_by IS NULL AND review_note IS NULL)
  OR (status='reviewed' AND reviewed_at IS NOT NULL))
);
CREATE INDEX exchange_issues_own_idx ON exchange_issues(reporter_id,created_at,id);
CREATE INDEX exchange_issues_queue_idx ON exchange_issues(status,created_at,id);
CREATE INDEX exchange_issues_other_participant_idx ON exchange_issues(other_participant_id);
CREATE INDEX exchange_issues_reviewer_idx ON exchange_issues(reviewed_by) WHERE reviewed_by IS NOT NULL;
