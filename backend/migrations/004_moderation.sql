-- Safety controls are independent of question/answer and mock-escrow states.
ALTER TABLE users ADD COLUMN is_suspended boolean NOT NULL DEFAULT false;
ALTER TABLE questions ADD COLUMN moderation_hidden boolean NOT NULL DEFAULT false;
ALTER TABLE answers ADD COLUMN moderation_hidden boolean NOT NULL DEFAULT false;
ALTER TABLE question_comments ADD COLUMN moderation_hidden boolean NOT NULL DEFAULT false;

CREATE TABLE user_blocks (
 blocker_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 blocked_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(blocker_id,blocked_id), CHECK(blocker_id <> blocked_id)
);
CREATE INDEX user_blocks_reverse_idx ON user_blocks(blocked_id,blocker_id);

CREATE TABLE content_reports (
 id uuid PRIMARY KEY,
 reporter_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 subject_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 target_type text NOT NULL CHECK(target_type IN ('question','answer','comment','user')),
 target_id uuid NOT NULL,
 question_id uuid REFERENCES questions(id) ON DELETE CASCADE,
 answer_id uuid REFERENCES answers(id) ON DELETE CASCADE,
 comment_id uuid REFERENCES question_comments(id) ON DELETE CASCADE,
 reason text NOT NULL CHECK(reason IN ('harassment','hate','sexual','violence','spam','privacy','other')),
 details text CHECK(details IS NULL OR char_length(trim(details)) BETWEEN 1 AND 1000),
 status text NOT NULL DEFAULT 'open' CHECK(status IN ('open','reviewed')),
 created_at timestamptz NOT NULL DEFAULT now(), reviewed_at timestamptz,
 UNIQUE(reporter_id,target_type,target_id),
 CHECK((target_type='question' AND target_id=question_id AND question_id IS NOT NULL AND answer_id IS NULL AND comment_id IS NULL)
 OR (target_type='answer' AND target_id=answer_id AND answer_id IS NOT NULL AND question_id IS NULL AND comment_id IS NULL)
 OR (target_type='comment' AND target_id=comment_id AND comment_id IS NOT NULL AND question_id IS NULL AND answer_id IS NULL)
 OR (target_type='user' AND target_id=subject_user_id AND question_id IS NULL AND answer_id IS NULL AND comment_id IS NULL))
);
CREATE INDEX reports_queue_idx ON content_reports(status,created_at,id);
CREATE INDEX reports_rate_idx ON content_reports(reporter_id,created_at);
CREATE TABLE moderation_actions (
 id uuid PRIMARY KEY, report_id uuid NOT NULL REFERENCES content_reports(id) ON DELETE CASCADE,
 reviewer_id uuid REFERENCES users(id) ON DELETE SET NULL,
 action text NOT NULL CHECK(action IN ('dismiss','hide','restore','suspend','reinstate')),
 note text CHECK(note IS NULL OR char_length(trim(note)) BETWEEN 1 AND 1000),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX moderation_actions_report_idx ON moderation_actions(report_id,created_at,id);
