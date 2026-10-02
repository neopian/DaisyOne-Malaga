-- Scope personal work before pagination, independently of the public feed.
CREATE INDEX questions_author_activity_idx ON questions(user_id,created_at DESC,id DESC);
CREATE INDEX questions_guide_activity_idx ON questions(assigned_helper_user_id,created_at DESC,id DESC)
 WHERE assigned_helper_user_id IS NOT NULL;
