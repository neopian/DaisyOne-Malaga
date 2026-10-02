import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {mkdtemp,rm,readdir,readFile,stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {createDiskStorage} from '../src/storage.mjs';
import {nodeServer,loadConfig} from '../src/server.mjs';
import {createMemoryMailSink,createMailTransport,drainAccountMail,loadMailConfig} from '../src/account-mail.mjs';
import {cleanDeletedAccountFiles} from '../src/accounts.mjs';
import {randomId,sha256} from '../src/crypto.mjs';

const password='synthetic-account-password',newPassword='replacement-account-password';
const secret='account-test-only-signing-key-at-least-32-characters';
const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACXBIWXMAAAPoAAAD6AG1e1JrAAAADUlEQVQImWP4////fwAJ+wP9CNHoHgAAAABJRU5ErkJggg==';
const question={country:'Spain',city:'Malaga',category:'교통',urgency:'보통',title:'A synthetic travel question',body:'Which local bus can I use to reach the old town?',reward_points:100};
const answer={body:'Use the local airport bus route to the city.',evidence_summary:'Official synthetic source record.',verification_method:'Official timetable',links:[{url:'https://example.com/transit',source_type:'official'}]};

test('disk mail sink writes only private synthetic messages and removes them idempotently',async()=>{
 const directory=await mkdtemp(join(tmpdir(),'synthetic-mail-sink-'));
 try{
  const sink=await createMailTransport({mailMode:'local_sink',mailSinkDirectory:directory,production:false}),message={id:randomId(),to:'sink@example.com',text:'Synthetic mail only'};
  await sink.send(message);await sink.send(message);assert.equal((await readdir(directory)).length,1);const path=join(directory,`${message.id}.json`);assert.deepEqual(JSON.parse(await readFile(path,'utf8')),message);assert.equal((await stat(path)).mode&0o777,0o600);
  await assert.rejects(sink.send({...message,id:randomId(),to:'real@ordinary-domain.com'}),/synthetic/);await sink.remove(message.id);await sink.remove(message.id);assert.deepEqual(await readdir(directory),[]);
 }finally{await rm(directory,{recursive:true,force:true});}
});

async function fixture(run) {
 assert.ok(process.env.TEST_DATABASE_URL,'TEST_DATABASE_URL must name disposable real PostgreSQL.');
 const admin=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),schema=`account_test_${randomId().replaceAll('-','')}`;
 const directory=await mkdtemp(join(tmpdir(),'account-lifecycle-'));let db,server;
 try {
  await admin.query(`CREATE SCHEMA ${schema}`);db=await createDatabase({connectionString:process.env.TEST_DATABASE_URL,schema});await migrate(db);
  const storage=await createDiskStorage(directory),mail=createMemoryMailSink(),errors=[];
  let handler;server=nodeServer(request=>handler(request));await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`,config={publicBaseUrl:base,imageSigningSecret:secret,accountActionUrl:'http://localhost/account',mail,onError:error=>errors.push(error)};
  const rebuild=(changes={})=>{handler=createApp({db,storage,config:{...config,...changes}});};rebuild();
  const api=async(path,{token,method='POST',body={},key=randomId(),headers={}}={})=>{
   const response=await fetch(`${base}/api${path}`,{method,headers:{...(token?{authorization:`Bearer ${token}`} : {}),...(method!=='GET'?{'content-type':'application/json','idempotency-key':key}:{}),...headers},...(method!=='GET'?{body:JSON.stringify(body)}:{})});return {status:response.status,data:await response.json()};
  };
  const register=async(email,name='Synthetic account')=>{const r=await api('/auth/register',{body:{email,name,password}});assert.equal(r.status,201,JSON.stringify(r));return r.data;};
  const login=async(email,pw=password)=>api('/auth/login',{body:{email,password:pw}});
  const create=async actor=>{const r=await api('/questions',{token:actor.token,body:question});assert.equal(r.status,201,JSON.stringify(r));return r.data.id;};
  const approve=async actor=>{await db.query("INSERT INTO helper_applications(id,user_id,status,languages,introduction,experience_description) VALUES($1,$2,'approved',ARRAY['English'],'Synthetic introduction','Synthetic experience')",[randomId(),actor.user.id]);await db.query("INSERT INTO helper_regions(id,helper_user_id,country,city) VALUES($1,$2,'Spain','Malaga')",[randomId(),actor.user.id]);};
  const flush=()=>drainAccountMail({db,mail,secret,onError:error=>errors.push(error)});
  await run({db,storage,mail,directory,errors,api,register,login,create,approve,flush,rebuild,config,base});
 } finally{if(server)await new Promise(resolve=>server.close(resolve));await db?.close();await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await admin.end();await rm(directory,{recursive:true,force:true});}
}

test('account delivery fails closed and production requires an explicit mail and verification policy',async()=>{
 assert.equal(loadMailConfig({},false).mailMode,'disabled');
 assert.throws(()=>loadMailConfig({MAIL_MODE:'local_sink'},true),/Production/);
 assert.throws(()=>loadMailConfig({MAIL_MODE:'sendmail',MAIL_FROM:'account@example.com',ACCOUNT_ACTION_URL:'https://example.com/account'},true),/EMAIL_VERIFICATION_POLICY/);
 assert.throws(()=>loadMailConfig({MAIL_MODE:'sendmail',MAIL_FROM:'bad\nheader',ACCOUNT_ACTION_URL:'https://example.com/account',EMAIL_VERIFICATION_POLICY:'optional'},true),/MAIL_FROM/);
 assert.throws(()=>loadConfig({NODE_ENV:'production',PUBLIC_BASE_URL:'https://example.com',IMAGE_SIGNING_SECRET:secret}),/sendmail/);
 const sink=createMemoryMailSink();await assert.rejects(sink.send({id:randomId(),to:'real@ordinary-domain.com'}),/synthetic/);
 await fixture(async({api,rebuild,register})=>{const user=await register('disabled@example.com');rebuild({mail:{mode:'disabled'}});for(const [path,body,token] of [['/auth/password-reset/request',{email:'disabled@example.com'},null],['/auth/password-reset/request',{email:'missing@example.com'},null],['/auth/email-verification/request',{},user.token]]){const r=await api(path,{body,token});assert.equal(r.status,503);assert.equal(r.data.error.code,'MAIL_UNAVAILABLE');}});
});

test('verification is scoped, hashed, expiring, and one-use under concurrent retry',()=>fixture(async({api,db,mail,register,flush})=>{
 const a=await register('verify@example.com'),b=await register('other@example.com');assert.equal(a.user.email_verified_at,null);
 const key=randomId(),requested=await Promise.all([api('/auth/email-verification/request',{token:a.token,key}),api('/auth/email-verification/request',{token:a.token,key})]);assert.deepEqual(requested[0],requested[1]);assert.equal(requested[0].status,202);
 const before=(await db.query('SELECT * FROM account_mail_outbox')).rows;assert.equal(before.length,1);
 await flush();assert.equal(mail.messages.length,1);const raw=mail.messages[0].token;
 const link=new URL(mail.messages[0].text.split('\n').find(line=>line.startsWith('http')));assert.equal(link.search,'');assert.equal(new URLSearchParams(link.hash.slice(1)).get('token'),raw);assert.equal(new URLSearchParams(link.hash.slice(1)).get('action'),'verify_email');
 const stored=(await db.query('SELECT * FROM account_tokens WHERE user_id=$1',[a.user.id])).rows[0];assert.equal(stored.token_hash,await sha256(raw));assert.ok(!JSON.stringify(before).includes(raw));assert.ok(!JSON.stringify(requested).includes(raw));
 assert.equal((await api('/auth/email-verification/confirm',{token:b.token,body:{token:raw}})).data.error.code,'INVALID_OR_EXPIRED_TOKEN');
 const confirmKey=randomId(),results=await Promise.all([api('/auth/email-verification/confirm',{token:a.token,body:{token:raw},key:confirmKey}),api('/auth/email-verification/confirm',{token:a.token,body:{token:raw},key:confirmKey})]);assert.equal(results[0].status,200);assert.deepEqual(results[0],results[1]);assert.ok(results[0].data.email_verified_at);
 assert.equal((await api('/auth/email-verification/confirm',{token:a.token,body:{token:raw}})).status,400);
 assert.ok((await api('/profile',{method:'GET',token:a.token})).data.email_verified_at);
}));

test('reset hides membership, invalidates all sessions and auth retries, and retries cannot change the secret',()=>fixture(async({api,db,mail,register,login,flush})=>{
 const user=await register('reset@example.com');const second=(await login(user.user.email)).data;
 const known=await api('/auth/password-reset/request',{body:{email:user.user.email}}),unknown=await api('/auth/password-reset/request',{body:{email:'unknown@example.com'}});assert.deepEqual(known,unknown);await flush();assert.equal(mail.messages.length,1);
 const raw=mail.messages[0].token,body={token:raw,password:newPassword},key=randomId();
 const results=await Promise.all([api('/auth/password-reset/confirm',{body,key}),api('/auth/password-reset/confirm',{body,key})]);assert.equal(results[0].status,200,JSON.stringify(results));assert.deepEqual(results[0],results[1]);
 assert.equal((await api('/auth/password-reset/confirm',{body:{...body,password:'different-password'},key})).data.error.code,'IDEMPOTENCY_CONFLICT');
 assert.equal((await api('/auth/password-reset/confirm',{body})).data.error.code,'INVALID_OR_EXPIRED_TOKEN');
 for(const token of [user.token,second.token])assert.equal((await api('/profile',{method:'GET',token})).status,401);
 assert.equal((await login(user.user.email)).status,401);assert.equal((await login(user.user.email,newPassword)).status,200);
 assert.equal((await db.query('SELECT * FROM auth_idempotency_keys WHERE email=$1',[user.user.email])).rows.length,1,'Only the fresh new-password login replay exists');
}));

test('expired reset tokens and cross-instance database-backed limits reject abuse',()=>fixture(async({api,db,mail,register,flush,rebuild})=>{
 const user=await register('expires@example.com');await api('/auth/password-reset/request',{body:{email:user.user.email}});await flush();const raw=mail.messages[0].token;
 await db.query("UPDATE account_tokens SET expires_at=now()-interval '1 second'");assert.equal((await api('/auth/password-reset/confirm',{body:{token:raw,password:newPassword}})).data.error.code,'INVALID_OR_EXPIRED_TOKEN');
 for(let i=0;i<19;i++)assert.equal((await api('/auth/password-reset/request',{body:{email:`unknown${i}@example.com`}})).status,202);
 rebuild();const r=await api('/auth/password-reset/request',{body:{email:'another@example.com'}});assert.equal(r.status,429);assert.equal(r.data.error.code,'RATE_LIMIT');
}));

test('mail outage keeps encrypted work durable and retries safely against a deduplicating local sink',()=>fixture(async({api,db,mail,register,flush})=>{
 const user=await register('mail-retry@example.com');await api('/auth/password-reset/request',{body:{email:user.user.email}});
 const failures=[];await drainAccountMail({db,mail:{mode:'local_sink',send:async()=>{throw new Error('Synthetic sink outage');}},secret,onError:error=>failures.push(error)});
 assert.equal(failures.length,1);assert.equal((await db.query('SELECT attempts FROM account_mail_outbox')).rows[0].attempts,1);assert.equal(mail.messages.length,0);
 await db.query('UPDATE account_mail_outbox SET available_at=now()');await flush();await flush();assert.equal(mail.messages.length,1);assert.equal((await db.query('SELECT * FROM account_mail_outbox')).rows.length,0);
}));

test('own export reauthenticates without logging out, includes photos, and excludes other users and secrets',()=>fixture(async({api,db,storage,register})=>{
 const a=await register('export@example.com'),b=await register('other-export@example.com');
 const photo=await api('/questions',{token:a.token,body:{...question,images:[{name:'synthetic.png',content_type:'image/png',data_base64:png}]}});assert.equal(photo.status,201);
 await api('/questions',{token:b.token,body:{...question,title:'OTHER USER PRIVATE TITLE'}});
 const denied=await api('/account/export',{token:a.token,body:{password:'wrong-password'}});assert.equal(denied.status,403);assert.equal(denied.data.error.code,'REAUTHENTICATION_FAILED');assert.equal((await api('/profile',{token:a.token,method:'GET'})).status,200);
 assert.equal((await api('/account/export',{token:a.token,body:{password,user_id:b.user.id}})).status,400);
 const result=await api('/account/export',{token:a.token,body:{password}});assert.equal(result.status,200);assert.equal(result.data.profile.id,a.user.id);
 const saved=(await db.query('SELECT storage_key FROM question_images WHERE question_id=$1',[photo.data.id])).rows[0];assert.equal(result.data.images[0].data_base64,(await storage.get(saved.storage_key)).toString('base64'));assert.equal(result.data.questions.length,1);
 const serialized=JSON.stringify(result.data);for(const forbidden of [password,a.token,b.user.email,'OTHER USER PRIVATE TITLE','password_hash','token_hash','storage_key'])assert.ok(!serialized.includes(forbidden),forbidden);
 assert.equal((await db.query('SELECT count(*)::int AS count FROM sessions WHERE user_id=$1',[a.user.id])).rows[0].count,1);
}));

test('deletion erases owner data and photos, revokes sessions, removes mail, and preserves paid survivor credits',()=>fixture(async({api,db,mail,storage,register,approve,flush,directory})=>{
 const owner=await register('delete-owner@example.com','Erase this unique owner'),helper=await register('survivor@example.com');await approve(helper);
 const photo=await api('/questions',{token:owner.token,body:{...question,images:[{name:'synthetic.png',content_type:'image/png',data_base64:png}]}});const id=photo.data.id;
 assert.equal((await api(`/questions/${id}/accept`,{token:helper.token})).status,200);
 const ans=await api(`/questions/${id}/answers`,{token:helper.token,body:answer});assert.equal(ans.status,201);
 assert.equal((await api(`/questions/${id}/answers/${ans.data.id}/accept`,{token:owner.token})).status,200);
 await api('/auth/email-verification/request',{token:owner.token});await flush();assert.equal(mail.messages.length,1);
 const body={password,confirmation:'DELETE'},key=randomId();const results=await Promise.all([api('/account/delete',{token:owner.token,body,key}),api('/account/delete',{token:owner.token,body,key})]);assert.ok(results.every(r=>r.data.account_deleted),JSON.stringify(results));
 assert.equal((await api('/account/delete',{token:owner.token,body,key})).data.status,'deleted');
 assert.equal((await api('/profile',{token:owner.token,method:'GET'})).status,401);assert.equal((await api(`/questions/${id}`,{token:helper.token,method:'GET'})).status,404);
 assert.equal((await db.query('SELECT * FROM users WHERE id=$1',[owner.user.id])).rows.length,0);assert.equal(mail.messages.length,0);assert.deepEqual(await readdir(directory),[]);
 const reward=(await db.query("SELECT * FROM point_transactions WHERE user_id=$1 AND type='reward'",[helper.user.id])).rows;assert.equal(reward.length,1);assert.equal(reward[0].amount,100);assert.equal(reward[0].question_id,null);assert.equal(reward[0].answer_id,null);assert.equal((await api('/profile',{token:helper.token,method:'GET'})).data.point_balance,1100);
 for(const table of ['users','auth_idempotency_keys','helper_applications','helper_regions','questions','answers','question_comments','account_mail_outbox','account_mail_deliveries','account_requests','account_deletion_jobs']){const dump=JSON.stringify((await db.query(`SELECT * FROM ${table}`)).rows);assert.ok(!dump.includes(owner.user.email),table);assert.ok(!dump.includes('Erase this unique owner'),table);}
}));

test('deleting an unfinished guide refunds once while already-paid rewards stay paid',()=>fixture(async({api,db,register,create,approve})=>{
 const owner=await register('held-owner@example.com'),guide=await register('delete-guide@example.com');await approve(guide);
 const held=await create(owner),paid=await create(owner);
 for(const id of [held,paid])assert.equal((await api(`/questions/${id}/accept`,{token:guide.token})).status,200);
 const ans=await api(`/questions/${paid}/answers`,{token:guide.token,body:answer});assert.equal((await api(`/questions/${paid}/answers/${ans.data.id}/accept`,{token:owner.token})).status,200);
 const deletion=await api('/account/delete',{token:guide.token,body:{password,confirmation:'DELETE'}});assert.equal(deletion.status,200,JSON.stringify(deletion));
 const qs=(await db.query('SELECT * FROM questions WHERE id=ANY($1::uuid[])',[[held,paid]])).rows;
 assert.equal(qs.find(q=>q.id===held).escrow_state,'refunded');assert.equal(qs.find(q=>q.id===paid).escrow_state,'paid');assert.ok(qs.every(q=>q.assigned_helper_user_id===null&&q.accepted_answer_id===null));
 const refunds=(await db.query("SELECT * FROM point_transactions WHERE type='refund' AND question_id=$1",[held])).rows;assert.equal(refunds.length,1);
 assert.equal((await api('/profile',{token:owner.token,method:'GET'})).data.point_balance,900);
 assert.equal((await api(`/questions/${held}/cancel`,{token:owner.token})).status,200);assert.equal((await db.query("SELECT * FROM point_transactions WHERE type='refund' AND question_id=$1",[held])).rows.length,1);
}));

test('a private file removal failure is recoverable after the user and session are gone',()=>fixture(async({api,db,mail,storage,register,rebuild,directory,config,base})=>{
 const user=await register('pending-delete@example.com');await api('/questions',{token:user.token,body:{...question,images:[{name:'synthetic.png',content_type:'image/png',data_base64:png}]}});
 // Exercise the actual lifecycle through an injected storage failure, not a DB mock.
 const failing=createApp({db,storage:{...storage,delete:async()=>{throw new Error('Synthetic disk cleanup outage');}},config:{...config,onError:()=>{}}});
 const body={password,confirmation:'DELETE'},key=randomId();const response=await failing(new Request(`${base}/api/account/delete`,{method:'POST',headers:{authorization:`Bearer ${user.token}`,'content-type':'application/json','idempotency-key':key},body:JSON.stringify(body)}));const result=await response.json();assert.equal(response.status,202);assert.equal(result.account_deleted,true);assert.equal(result.status,'cleanup_pending');
 assert.equal((await api('/profile',{token:user.token,method:'GET'})).status,401);assert.equal((await readdir(directory)).length,1);
 await cleanDeletedAccountFiles({db,storage,mail});assert.deepEqual(await readdir(directory),[]);
 assert.equal((await api('/account/delete',{token:user.token,body,key})).data.status,'deleted');
 assert.equal((await api('/account/delete',{token:user.token,body:{...body,password:'changed-password'},key})).data.error.code,'IDEMPOTENCY_CONFLICT');
}));

test('an old-password login already in flight cannot create a session after password reset',()=>fixture(async({api,db,storage,config,base,register,mail,flush})=>{
 const user=await register('login-race@example.com');await api('/auth/password-reset/request',{body:{email:user.user.email}});await flush();
 let release,started;const waiting=new Promise(resolve=>{release=resolve;}),ready=new Promise(resolve=>{started=resolve;});
 const pausedDb={...db,transaction:async fn=>{started();await waiting;return db.transaction(fn);}};
 const loginApp=createApp({db:pausedDb,storage,config});
 const login=loginApp(new Request(`${base}/api/auth/login`,{method:'POST',headers:{'content-type':'application/json','idempotency-key':randomId()},body:JSON.stringify({email:user.user.email,password})}));
 await ready;assert.equal((await api('/auth/password-reset/confirm',{body:{token:mail.messages[0].token,password:newPassword}})).status,200);release();
 const response=await login;assert.equal(response.status,401);assert.equal((await response.json()).error.code,'INVALID_CREDENTIALS');assert.equal((await db.query('SELECT * FROM sessions WHERE user_id=$1',[user.user.id])).rows.length,0);
}));

test('deletion serializes against reward acceptance and new writes without duplicate refunds or orphan data',()=>fixture(async({api,db,register,create,approve})=>{
 const owner=await register('race-owner@example.com'),guide=await register('race-guide@example.com');await approve(guide);const id=await create(owner);
 await api(`/questions/${id}/accept`,{token:guide.token});const answerResult=await api(`/questions/${id}/answers`,{token:guide.token,body:answer});
 const [deleted,accepted]=await Promise.all([api('/account/delete',{token:guide.token,body:{password,confirmation:'DELETE'}}),api(`/questions/${id}/answers/${answerResult.data.id}/accept`,{token:owner.token})]);assert.equal(deleted.data.account_deleted,true);assert.ok([200,404,409].includes(accepted.status),JSON.stringify(accepted));
 const q=(await db.query('SELECT * FROM questions WHERE id=$1',[id])).rows[0];assert.ok(['paid','refunded'].includes(q.escrow_state));assert.equal(q.assigned_helper_user_id,null);
 assert.equal((await api('/profile',{token:owner.token,method:'GET'})).data.point_balance,q.escrow_state==='paid'?900:1000);
 const refundCount=(await db.query("SELECT count(*)::int AS n FROM point_transactions WHERE question_id=$1 AND type='refund'",[id])).rows[0].n;assert.equal(refundCount,q.escrow_state==='refunded'?1:0);
 const results=await Promise.all([api('/account/delete',{token:owner.token,body:{password,confirmation:'DELETE'}}),api('/questions',{token:owner.token,body:question}),api('/profile',{token:owner.token,method:'PATCH',body:{current_country:'France',current_city:'Paris'}})]);assert.equal(results[0].data.account_deleted,true);assert.ok([201,401].includes(results[1].status),JSON.stringify(results));assert.ok([200,401].includes(results[2].status),JSON.stringify(results));
 for(const table of ['users','questions','answers','question_images','point_transactions','idempotency_keys','sessions'])assert.equal((await db.query(`SELECT count(*)::int AS n FROM ${table}`)).rows[0].n,0,table);
}));

test('deletion clears safety reports, blocks and audit notes instead of retaining erased personal text',()=>fixture(async({api,db,register})=>{
 const a=await register('safety-delete@example.com'),b=await register('safety-survivor@example.com');
 assert.equal((await api(`/blocks/${a.user.id}`,{token:b.token})).status,200);
 const report=await api('/reports',{token:b.token,body:{target_type:'user',target_id:a.user.id,reason:'privacy',details:'Synthetic private report about safety-delete@example.com'}});assert.equal(report.status,201,JSON.stringify(report));
 const exported=await api('/account/export',{token:b.token,body:{password}});assert.equal(exported.data.reports.length,1);assert.equal(exported.data.blocks.length,1);
 assert.equal((await api('/account/delete',{token:a.token,body:{password,confirmation:'DELETE'}})).status,200);
 for(const table of ['content_reports','user_blocks','moderation_actions'])assert.equal((await db.query(`SELECT count(*)::int AS n FROM ${table}`)).rows[0].n,0,table);
}));

test('suspension preserves own export/deletion, and a deleted reviewer leaves no authored private note',()=>fixture(async({api,db,register})=>{
 const reviewer=await register('reviewer-delete@example.com'),reporter=await register('reporter@example.com'),subject=await register('subject@example.com');
 await db.query('UPDATE users SET is_admin=true WHERE id=$1',[reviewer.user.id]);
 const report=await api('/reports',{token:reporter.token,body:{target_type:'user',target_id:subject.user.id,reason:'spam',details:'Synthetic report details'}});
 const reviewed=await api(`/admin/reports/${report.data.id}/review`,{token:reviewer.token,body:{action:'dismiss',note:'Authored note reviewer-delete@example.com'}});assert.equal(reviewed.status,200,JSON.stringify(reviewed));
 await db.query("INSERT INTO helper_applications(id,user_id,status,languages,introduction,experience_description,reviewed_by,reviewed_at,reject_reason) VALUES($1,$2,'rejected',ARRAY['English'],'Synthetic introduction','Synthetic experience',$3,now(),'Authored reason reviewer-delete@example.com')",[randomId(),subject.user.id,reviewer.user.id]);
 await db.query('UPDATE users SET is_suspended=true WHERE id=$1',[reviewer.user.id]);
 const exported=await api('/account/export',{token:reviewer.token,body:{password}});assert.equal(exported.status,200);assert.equal(exported.data.moderation_notes.length,1);assert.match(exported.data.moderation_notes[0].note,/reviewer-delete/);assert.equal(exported.data.helper_reviews.length,1);assert.match(exported.data.helper_reviews[0].reject_reason,/reviewer-delete/);
 assert.equal((await api('/account/delete',{token:reviewer.token,body:{password,confirmation:'DELETE'}})).status,200);
 const actions=(await db.query('SELECT * FROM moderation_actions WHERE report_id=$1',[report.data.id])).rows;assert.equal(actions.length,1);assert.equal(actions[0].reviewer_id,null);assert.equal(actions[0].note,null);
 const application=(await db.query('SELECT status,reviewed_by,reject_reason FROM helper_applications WHERE user_id=$1',[subject.user.id])).rows[0];assert.equal(application.status,'rejected');assert.equal(application.reviewed_by,null);assert.equal(application.reject_reason,null);
 assert.equal((await db.query('SELECT * FROM content_reports WHERE id=$1',[report.data.id])).rows.length,1,'Unrelated report survives without deleted reviewer private text');
}));

test('login identity throttles are atomic across fresh API instances for known and missing accounts',()=>fixture(async({api,db,storage,config,base,register,rebuild})=>{
 const known=await register('shared-rate@example.com'),missing='missing-rate@example.com';assert.equal((await api('/auth/login',{body:{email:missing,password:'wrong-password'}})).status,401);
 const second=nodeServer(createApp({db,storage,config}));await new Promise(resolve=>second.listen(0,'127.0.0.1',resolve));
 try{
  const origins=[base,`http://127.0.0.1:${second.address().port}`];
  for(const email of [known.user.email,missing]){
   const results=await Promise.all(Array.from({length:24},async(_,index)=>{
    const response=await fetch(`${origins[index%2]}/api/auth/login`,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email:index%2?email.toUpperCase():email,password:'wrong-password'})});return {status:response.status,data:await response.json()};
   }));
   assert.equal(results.filter(r=>r.status===401).length,19,JSON.stringify(results));assert.equal(results.filter(r=>r.status===429).length,5);assert.ok(results.filter(r=>r.status===401).every(r=>r.data.error.code==='INVALID_CREDENTIALS'));
  }
  rebuild();assert.equal((await api('/auth/login',{body:{email:known.user.email,password}})).status,429);
  const persisted=(await db.query('SELECT * FROM account_rate_limits')).rows;assert.ok(!JSON.stringify(persisted).includes(known.user.email));assert.ok(!JSON.stringify(persisted).includes('127.0.0.1'));
  await db.query("UPDATE account_rate_limits SET expires_at=now()-interval '1 second'");assert.equal((await api('/auth/login',{body:{email:known.user.email,password}})).status,200);
 }finally{await new Promise(resolve=>second.close(resolve));}
}));

test('shared source-IP cap survives recreation and caller-supplied forwarding headers cannot bypass it',()=>fixture(async({api,rebuild})=>{
 const results=await Promise.all(Array.from({length:65},(_,i)=>api('/auth/login',{body:{},headers:{'x-daisy-client-ip':`forged-${i}`,'x-forwarded-for':`192.0.2.${i}`}})));
 assert.equal(results.filter(r=>r.status===400).length,60);assert.equal(results.filter(r=>r.status===429).length,5);
 rebuild();assert.equal((await api('/auth/register',{body:{email:'new-rate@example.com',password,name:'Synthetic'},headers:{'x-daisy-client-ip':'different-forged-client'}})).status,429);
}));

test('oversized exports fail before file reads and metadata-only export is explicit with no truncation',()=>fixture(async({api,db,storage,config,base,register})=>{
 const user=await register('export-bounds@example.com');const created=await api('/questions',{token:user.token,body:{...question,images:[{name:'synthetic.png',content_type:'image/png',data_base64:png}]}});assert.equal(created.status,201);
 await db.query('UPDATE question_images SET byte_length=30*1024*1024 WHERE question_id=$1',[created.data.id]);
 let reads=0;const handler=createApp({db,storage:{...storage,get:async()=>{reads++;throw new Error('Export must reject or omit photos before reading.');}},config});
 const exportRequest=async includeImages=>{const response=await handler(new Request(`${base}/api/account/export`,{method:'POST',headers:{authorization:`Bearer ${user.token}`,'content-type':'application/json'},body:JSON.stringify({password,include_images:includeImages})}));return {status:response.status,data:await response.json()};};
 const tooLarge=await exportRequest(true);assert.equal(tooLarge.status,413);assert.equal(tooLarge.data.error.code,'EXPORT_TOO_LARGE');assert.equal(tooLarge.data.profile,undefined);assert.equal(reads,0);
 const metadata=await exportRequest(false);assert.equal(metadata.status,200);assert.deepEqual(metadata.data.export_options,{include_images:false,images_included:0});assert.equal(metadata.data.images.length,1);assert.equal(metadata.data.images[0].data_base64,undefined);assert.equal(metadata.data.questions.length,1);assert.equal(reads,0);
 await db.query("INSERT INTO question_comments(id,question_id,user_id,body) SELECT gen_random_uuid(),$1,$2,'Synthetic row-count guard' FROM generate_series(1,10001)",[created.data.id,user.user.id]);
 const rowLimit=await exportRequest(false);assert.equal(rowLimit.status,413);assert.equal(rowLimit.data.error.code,'EXPORT_TOO_LARGE');assert.equal(rowLimit.data.comments,undefined);assert.equal(reads,0);
}));

test('an ambiguous local mail write remains erasable even after its outbox envelope expires',()=>fixture(async({api,db,mail,register})=>{
 const user=await register('ambiguous-sink@example.com');await api('/auth/password-reset/request',{body:{email:user.user.email}});
 await drainAccountMail({db,mail:{mode:'local_sink',send:async message=>{await mail.send(message);throw new Error('Synthetic failure after sink write');}},secret});assert.equal(mail.messages.length,1);
 await db.query('DELETE FROM account_mail_outbox');assert.equal((await api('/account/delete',{token:user.token,body:{password,confirmation:'DELETE'}})).status,200);assert.equal(mail.messages.length,0);
}));

test('one stuck file-removal job does not starve other deleted accounts',()=>fixture(async({db,storage,mail})=>{
 const stuck=`${randomId()}.png`,removable=`${randomId()}.png`;await storage.put(removable,Buffer.from(png,'base64'));
 for(const key of [stuck,removable])await db.query("INSERT INTO account_deletion_jobs(id,receipt_hash,fingerprint,storage_keys,retry_expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[randomId(),randomId(),randomId(),[key]]);
 await cleanDeletedAccountFiles({db,storage:{...storage,delete:async key=>{if(key===stuck)throw new Error('Synthetic persistent failure');await storage.delete(key);}},mail});
 assert.equal((await db.query('SELECT * FROM account_deletion_jobs WHERE completed_at IS NOT NULL')).rows.length,1);assert.equal((await db.query('SELECT * FROM account_deletion_jobs WHERE completed_at IS NULL')).rows.length,1);await assert.rejects(storage.get(removable),{code:'ENOENT'});
}));
