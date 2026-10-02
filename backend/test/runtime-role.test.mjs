import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {seedDevelopment} from '../src/seed-data.mjs';
import {randomId} from '../src/crypto.mjs';
import {createMemoryMailSink,drainAccountMail} from '../src/account-mail.mjs';

test('least-privilege runtime role can use final account and moderation schema', {
 skip: !process.env.TEST_RUNTIME_DATABASE_URL && 'Use scripts/test-postgres-local.sh for the separate runtime role check',
}, async()=>{
 assert.ok(process.env.TEST_DATABASE_URL);
 const schema=`runtime_${randomId().replaceAll('-','')}`;
 const admin=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
 let owner,runtime;
 try {
  await admin.query(`CREATE SCHEMA ${schema}`);
  owner=await createDatabase({connectionString:process.env.TEST_DATABASE_URL,schema});
  await migrate(owner);await seedDevelopment(owner,{enabled:true});
  const candidate=new pg.Pool({connectionString:process.env.TEST_RUNTIME_DATABASE_URL});
  const {rows:[role]}=await candidate.query('SELECT current_user AS name');await candidate.end();
  assert.match(role.name,/^[a-z_][a-z0-9_]*$/);
  await owner.query(`GRANT USAGE ON SCHEMA ${schema} TO ${role.name}`);
  await owner.query(`GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA ${schema} TO ${role.name}`);
  runtime=await createDatabase({connectionString:process.env.TEST_RUNTIME_DATABASE_URL,schema});
  const privilege=(await runtime.query('SELECT rolsuper,rolcreatedb,rolcreaterole FROM pg_roles WHERE rolname=current_user')).rows[0];
  assert.deepEqual(privilege,{rolsuper:false,rolcreatedb:false,rolcreaterole:false});
  await assert.rejects(runtime.query('CREATE TABLE forbidden_ddl(id integer)'),{code:'42501'});
  await assert.rejects(runtime.query('ALTER TABLE users ADD COLUMN forbidden integer'),{code:'42501'});
  const objects=new Map();
  const storage={put:async(key,bytes)=>objects.set(key,bytes),get:async key=>objects.get(key),delete:async key=>objects.delete(key)};
  const mail=createMemoryMailSink(),secret='runtime-role-only-synthetic-test-secret';
  const app=createApp({db:runtime,storage,config:{imageSigningSecret:secret,mail,accountActionUrl:'https://app.example.test/account',onError:error=>{throw error;}}});
  const call=async(path,{token,body,method=body?'POST':'GET'}={})=>{
   const response=await app(new Request(`https://app.example.test/api${path}`,{method,headers:{...(token?{Authorization:`Bearer ${token}`} : {}),...(body?{'Content-Type':'application/json','Idempotency-Key':randomId()}: {})},...(body?{body:JSON.stringify(body)}:{})}));
   const data=await response.json();assert.ok(response.status<400,JSON.stringify(data));return data;
  };
  const user=await call('/auth/register',{body:{email:'runtime@example.test',password:'synthetic-runtime-password',name:'Runtime traveler'}});
  const operator=await call('/auth/login',{body:{email:'admin@example.com',password:'daisy-dev-1234'}});
  const question=await call('/questions',{token:user.token,body:{country:'Spain',city:'Malaga',category:'교통',urgency:'보통',title:'A synthetic runtime travel question',body:'Where is the bus stop?',reward_points:100,latitude:36.72,longitude:-4.42}});
  const guide=await call('/auth/login',{body:{email:'answerer1@example.com',password:'daisy-dev-1234'}});
  assert.ok((await call('/guide/questions',{token:guide.token})).some(row=>row.id===question.id),'Runtime role can execute catalog-aware feed matching');
  await call('/auth/email-verification/request',{token:user.token,body:{}});
  await drainAccountMail({db:runtime,mail,secret});assert.equal(mail.messages.length,1);
  await call('/auth/email-verification/confirm',{token:user.token,body:{token:mail.messages[0].token}});
  const report=await call('/reports',{token:operator.token,body:{target_type:'question',target_id:question.id,reason:'other'}});
  await call(`/admin/reports/${report.id}/review`,{token:operator.token,body:{action:'hide',note:'Synthetic runtime check'}});
  await call(`/admin/reports/${report.id}/review`,{token:operator.token,body:{action:'restore'}});
  const exported=await call('/account/export',{token:user.token,body:{password:'synthetic-runtime-password'}});assert.equal(exported.profile.id,user.user.id);
  const deleted=await call('/account/delete',{token:user.token,body:{password:'synthetic-runtime-password',confirmation:'DELETE'}});assert.equal(deleted.account_deleted,true);
  assert.equal((await owner.query('SELECT id FROM users WHERE id=$1',[user.user.id])).rows.length,0);
 } finally {
  await runtime?.close();await owner?.close();await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await admin.end();
 }
});
