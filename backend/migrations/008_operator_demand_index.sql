-- Oldest unresolved demand first, with deterministic UUID ties and bounded
-- pages. Terminal/disputed/reported history is outside this operations queue.
CREATE INDEX questions_operator_demand_idx ON questions(status,created_at,id)
 WHERE status IN ('open','assigned','answered');
