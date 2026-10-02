-- Support the exact expiry + deterministic tie-break order used by bounded
-- maintenance. Reuse the existing expiry index names without leaving redundant
-- same-prefix indexes behind. This migration is transactional, not CONCURRENT;
-- operators must schedule the index-build/table-lock window before deployment.
CREATE INDEX sessions_expiry_order_idx ON sessions(expires_at,id);
DROP INDEX sessions_expiry_idx;
ALTER INDEX sessions_expiry_order_idx RENAME TO sessions_expiry_idx;

CREATE INDEX auth_idempotency_expiry_order_idx ON auth_idempotency_keys(expires_at,email,key);
DROP INDEX auth_idempotency_expiry_idx;
ALTER INDEX auth_idempotency_expiry_order_idx RENAME TO auth_idempotency_expiry_idx;

CREATE INDEX account_rate_limits_expiry_idx ON account_rate_limits(expires_at,scope_hash);
CREATE INDEX account_requests_expiry_idx ON account_requests(expires_at,scope_hash,key);
CREATE INDEX account_tokens_expiry_idx ON account_tokens(expires_at,id);
-- Pending physical-removal jobs are never eligible for receipt pruning.
CREATE INDEX account_deletion_jobs_completed_expiry_idx ON account_deletion_jobs(retry_expires_at,id)
 WHERE completed_at IS NOT NULL;
