import {sign} from './crypto.mjs';

/** Atomic shared quota. No raw IP/address is persisted; expired rows are pruned
 * by account maintenance. Stable signing config is required across instances. */
export async function consumeRateLimit(db,{secret,scope,maximum,seconds=900}) {
 const scopeHash=await sign(secret,`rate:${scope}`);
 const result=await db.query(`INSERT INTO account_rate_limits(scope_hash,attempts,expires_at)
  VALUES($1,1,now()+$2*interval '1 second') ON CONFLICT(scope_hash) DO UPDATE SET
  attempts=CASE WHEN account_rate_limits.expires_at<=now() THEN 1 ELSE LEAST(account_rate_limits.attempts+1,$3+1) END,
  expires_at=CASE WHEN account_rate_limits.expires_at<=now() THEN now()+$2*interval '1 second' ELSE account_rate_limits.expires_at END
  RETURNING attempts`,[scopeHash,seconds,maximum]);
 return result.rows[0].attempts<=maximum;
}
