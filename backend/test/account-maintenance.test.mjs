import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {cleanExpiredAuthentication,runAccountMaintenance,expiredArtifactBatchSize} from '../src/account-maintenance.mjs';
import {randomId} from '../src/crypto.mjs';

test('expired authentication cleanup is bounded across instances and preserves live sessions/replays and core idempotency',async()=>{
 assert.ok(process.env.TEST_DATABASE_URL,'Use disposable real PostgreSQL for authentication maintenance checks.');
 const owner=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),schema=`auth_cleanup_${randomId().replaceAll('-','')}`;
 let first,second;
 try {
  await owner.query(`CREATE SCHEMA ${schema}`);
  first=await createDatabase({connectionString:process.env.TEST_DATABASE_URL,schema});second=await createDatabase({connectionString:process.env.TEST_DATABASE_URL,schema});await migrate(first);await migrate(first);
  assert.equal((await first.query("SELECT count(*)::int AS n FROM schema_migrations WHERE name='005_authentication_cleanup_indexes.sql'")).rows[0].n,1);
  const storage={put:async()=>{},delete:async()=>{},get:async()=>{throw new Error('No image access belongs in this test.');}};
  const config={imageSigningSecret:'maintenance-test-shared-secret-at-least-32-characters'};
  const firstApp=createApp({db:first,storage,config}),secondApp=createApp({db:second,storage,config});
  const call=async(app,path,{method='POST',body={},token,key=randomId()}={})=>{
   const response=await app(new Request(`http://localhost/api${path}`,{method,headers:{...(method!=='GET'?{'content-type':'application/json','idempotency-key':key}:{}),...(token?{authorization:`Bearer ${token}`}:{})},...(method!=='GET'?{body:JSON.stringify(body)}:{})}));return {status:response.status,data:await response.json()};
  };
  const body={email:'maintenance@example.com',password:'synthetic-maintenance-password',name:'Synthetic maintenance user'},registrationKey=randomId();
  const registered=await call(firstApp,'/auth/register',{body,key:registrationKey});assert.equal(registered.status,201);const user=registered.data;
  const questionKey=randomId(),questionBody={country:'Spain',city:'Malaga',category:'교통',urgency:'보통',title:'Maintenance-safe question',body:'Which synthetic transit route serves the old town?',reward_points:100};
  const created=await call(firstApp,'/questions',{token:user.token,key:questionKey,body:questionBody});assert.equal(created.status,201);
  await first.query("UPDATE idempotency_keys SET created_at='2000-01-01' WHERE user_id=$1",[user.user.id]);
  const coreBefore=(await first.query('SELECT * FROM idempotency_keys ORDER BY user_id,key')).rows;
  const ledgerBefore=(await first.query('SELECT * FROM point_transactions ORDER BY id')).rows;
  const currentSession=(await first.query('SELECT * FROM sessions')).rows;
  const currentReplay=(await first.query('SELECT * FROM auth_idempotency_keys')).rows;
  const manifest=randomId();await first.query("INSERT INTO account_mail_deliveries(id,user_id,created_at) VALUES($1,$2,'2000-01-01')",[manifest,user.user.id]);
  const total=expiredArtifactBatchSize*2+25;
  await first.query("INSERT INTO sessions(id,user_id,token_hash,created_at,expires_at) SELECT gen_random_uuid(),$1,lpad(n::text,64,'0'),now()-interval '8 days',now()-interval '1 day' FROM generate_series(1,$2::int) n",[user.user.id,total]);
  await first.query("INSERT INTO auth_idempotency_keys(email,key,fingerprint,encrypted_response,response_status,expires_at,created_at) SELECT 'expired-'||n||'@example.com','expired-intent-'||n,'synthetic-fingerprint','synthetic-expired-envelope',200,now()-interval '1 second',now()-interval '11 minutes' FROM generate_series(1,$1::int) n",[total]);
  const results=await Promise.all([cleanExpiredAuthentication(first),cleanExpiredAuthentication(second)]);
  for(const result of results){assert.equal(result.sessions,expiredArtifactBatchSize);assert.equal(result.auth_retries,expiredArtifactBatchSize);}
  for(const table of ['sessions','auth_idempotency_keys'])assert.equal((await first.query(`SELECT count(*)::int AS n FROM ${table} WHERE expires_at<=now()`)).rows[0].n,25,table);
  assert.deepEqual((await second.query('SELECT * FROM sessions WHERE expires_at>now()')).rows,currentSession);
  assert.deepEqual((await second.query('SELECT * FROM auth_idempotency_keys WHERE expires_at>now()')).rows,currentReplay);
  assert.equal((await call(secondApp,'/profile',{method:'GET',token:user.token})).status,200);
  assert.deepEqual(await call(secondApp,'/auth/register',{body,key:registrationKey}),registered,'Live auth replay remains exactly the original response and session');
  assert.deepEqual(await call(secondApp,'/questions',{token:user.token,key:questionKey,body:questionBody}),created,'Old core mutation replay remains valid');
  const finalBatch=await runAccountMaintenance({db:second,storage,mail:{mode:'disabled'},secret:config.imageSigningSecret});assert.deepEqual(finalBatch,{sessions:25,auth_retries:25});
  assert.deepEqual(await cleanExpiredAuthentication(first),{sessions:0,auth_retries:0});
  assert.deepEqual((await first.query('SELECT * FROM idempotency_keys ORDER BY user_id,key')).rows,coreBefore);
  assert.deepEqual((await first.query('SELECT * FROM point_transactions ORDER BY id')).rows,ledgerBefore);
  assert.equal((await first.query('SELECT * FROM account_mail_deliveries WHERE id=$1',[manifest])).rows.length,1,'Mail artifact manifests are not an expiry-pruning target');
 }finally{await first?.close();await second?.close();await owner.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await owner.end();}
});

test('cleanup migration supplies ordered expiry indexes and PostgreSQL can explain each bounded selection',async()=>{
 assert.ok(process.env.TEST_DATABASE_URL,'Use disposable real PostgreSQL.');
 const owner=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),schema=`auth_cleanup_index_${randomId().replaceAll('-','')}`;let db;
 try {
  await owner.query(`CREATE SCHEMA ${schema}`);db=await createDatabase({connectionString:process.env.TEST_DATABASE_URL,schema});await migrate(db);await migrate(db);
  const expected=[
   ['sessions','sessions_expiry_idx',['expires_at','id'],'expires_at<=now()','expires_at,id'],
   ['auth_idempotency_keys','auth_idempotency_expiry_idx',['expires_at','email','key'],'expires_at<=now()','expires_at,email,key'],
   ['account_rate_limits','account_rate_limits_expiry_idx',['expires_at','scope_hash'],'expires_at<=now()','expires_at,scope_hash'],
   ['account_requests','account_requests_expiry_idx',['expires_at','scope_hash','key'],'expires_at<=now()','expires_at,scope_hash,key'],
   ['account_tokens','account_tokens_expiry_idx',['expires_at','id'],'expires_at<=now()','expires_at,id'],
   ['account_deletion_jobs','account_deletion_jobs_completed_expiry_idx',['retry_expires_at','id'],'completed_at IS NOT NULL AND retry_expires_at<=now()','retry_expires_at,id']
  ];
  const indexes=(await db.query(`SELECT tbl.relname AS table_name,idx.relname AS index_name,ind.indisvalid,
   ARRAY(SELECT att.attname::text FROM unnest(ind.indkey) WITH ORDINALITY AS key(attnum,position)
    JOIN pg_attribute att ON att.attrelid=tbl.oid AND att.attnum=key.attnum ORDER BY key.position) AS columns,
   pg_get_expr(ind.indpred,ind.indrelid) AS predicate
   FROM pg_index ind JOIN pg_class idx ON idx.oid=ind.indexrelid JOIN pg_class tbl ON tbl.oid=ind.indrelid
   JOIN pg_namespace ns ON ns.oid=tbl.relnamespace WHERE ns.nspname=$1`,[schema])).rows;
  for(const [table,index,columns,predicate,order] of expected){
   const matching=indexes.filter(row=>row.table_name===table&&row.columns[0]===columns[0]);assert.equal(matching.length,1,`${table}: no redundant expiry-prefix index`);
   assert.equal(matching[0].index_name,index);assert.equal(matching[0].indisvalid,true);assert.deepEqual(matching[0].columns,columns);
   if(table==='account_deletion_jobs')assert.match(matching[0].predicate,/completed_at IS NOT NULL/);else assert.equal(matching[0].predicate,null);
   const explained=await db.query(`EXPLAIN (FORMAT JSON) SELECT ${columns.slice(1).join(',')} FROM ${table} WHERE ${predicate} ORDER BY ${order} FOR UPDATE SKIP LOCKED LIMIT ${expiredArtifactBatchSize}`);
   // Tiny fixtures may legitimately use sequential scans. Index definitions
   // establish capability; do not freeze cost estimates or planner node types.
   assert.ok(explained.rows[0]['QUERY PLAN'][0].Plan,table);
  }
 }finally{await db?.close();await owner.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await owner.end();}
});

test('maintenance skips locked expired sessions and replay envelopes without deleting current artifacts',async()=>{
 assert.ok(process.env.TEST_DATABASE_URL,'Use disposable real PostgreSQL.');
 const owner=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),schema=`auth_cleanup_lock_${randomId().replaceAll('-','')}`;let db,other,release;
 try {
  await owner.query(`CREATE SCHEMA ${schema}`);db=await createDatabase({connectionString:process.env.TEST_DATABASE_URL,schema});other=await createDatabase({connectionString:process.env.TEST_DATABASE_URL,schema});await migrate(db);
  const user=randomId(),session=randomId();await db.query("INSERT INTO users(id,email,name) VALUES($1,'locked@example.com','Synthetic locked user')",[user]);
  await db.query("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES($1,$2,'synthetic-expired-token-hash',now()-interval '1 second')",[session,user]);
  await db.query("INSERT INTO auth_idempotency_keys(email,key,fingerprint,expires_at) VALUES('locked@example.com','locked-intent','synthetic-fingerprint',now()-interval '1 second')");
  let signal;const ready=new Promise(resolve=>{signal=resolve;}),unlock=new Promise(resolve=>{release=resolve;});
  const locking=db.transaction(async tx=>{await tx.query('SELECT id FROM sessions WHERE id=$1 FOR UPDATE',[session]);await tx.query("SELECT key FROM auth_idempotency_keys WHERE email='locked@example.com' FOR UPDATE");signal();await unlock;});
  await ready;assert.deepEqual(await cleanExpiredAuthentication(other),{sessions:0,auth_retries:0});release();await locking;
  assert.deepEqual(await cleanExpiredAuthentication(other),{sessions:1,auth_retries:1});
 }finally{release?.();await db?.close();await other?.close();await owner.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await owner.end();}
});
