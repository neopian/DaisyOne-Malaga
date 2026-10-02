import {drainAccountMail} from './account-mail.mjs';
import {cleanDeletedAccountFiles} from './accounts.mjs';

export const expiredArtifactBatchSize=250;

// Select and delete only already-expired artifacts. SKIP LOCKED lets multiple
// instances make progress without waiting for another maintenance/replay row.
// Every invocation does one finite batch; no drain-until-empty loop runs here.
async function deleteExpiredBatch(db,table,keys,predicate,order) {
 const result=await db.query(`WITH expired AS (
  SELECT ${keys.join(',')} FROM ${table} WHERE ${predicate}
  ORDER BY ${order} FOR UPDATE SKIP LOCKED LIMIT ${expiredArtifactBatchSize}
 ), removed AS (
  DELETE FROM ${table} AS target USING expired
  WHERE ${keys.map(key=>`target.${key}=expired.${key}`).join(' AND ')} RETURNING 1
 ) SELECT count(*)::int AS deleted_count FROM removed`);
 return result.rows[0].deleted_count;
}

export async function cleanExpiredAuthentication(db) {
 const sessions=await deleteExpiredBatch(db,'sessions',['id'],'expires_at<=now()','expires_at,id');
 const auth_retries=await deleteExpiredBatch(db,'auth_idempotency_keys',['email','key'],'expires_at<=now()','expires_at,email,key');
 return {sessions,auth_retries};
}

export async function runAccountMaintenance({db,storage,mail,secret,onError=()=>{}}) {
 await cleanDeletedAccountFiles({db,storage,mail,onError});
 await drainAccountMail({db,mail,secret,onError});
 // No request bodies, passwords, raw addresses, or raw tokens are logged.
 const authentication=await cleanExpiredAuthentication(db);
 await deleteExpiredBatch(db,'account_rate_limits',['scope_hash'],'expires_at<=now()','expires_at,scope_hash');
 await deleteExpiredBatch(db,'account_requests',['scope_hash','key'],'expires_at<=now()','expires_at,scope_hash,key');
 await deleteExpiredBatch(db,'account_tokens',['id'],'expires_at<=now()','expires_at,id');
 await deleteExpiredBatch(db,'account_deletion_jobs',['id'],'completed_at IS NOT NULL AND retry_expires_at<=now()','retry_expires_at,id');
 return authentication;
}

// Also usable as a supervised one-shot job, with the same private server config.
if(process.argv[1]&&import.meta.url===new URL(process.argv[1],'file:').href) {
 const {loadConfig}=await import('./server.mjs');
 const {createDatabase,assertMigrated}=await import('./db.mjs');
 const {createDiskStorage}=await import('./storage.mjs');
 const {createMailTransport}=await import('./account-mail.mjs');
 const config=loadConfig(),db=await createDatabase();
 try {await assertMigrated(db);await runAccountMaintenance({db,storage:await createDiskStorage(config.uploadDirectory),mail:await createMailTransport(config),secret:config.imageSigningSecret});}
 finally{await db.close();}
}
