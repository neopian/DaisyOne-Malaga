import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {mkdtemp,rm,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {nodeServer,loadConfig} from '../src/server.mjs';
import {createDiskStorage} from '../src/storage.mjs';
import {seedDevelopment} from '../src/seed-data.mjs';
import {randomId,sha256} from '../src/crypto.mjs';

const databaseUrl=process.env.TEST_DATABASE_URL;
const password='integration-test-password';
const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACXBIWXMAAAPoAAAD6AG1e1JrAAAADUlEQVQImWP4////fwAJ+wP9CNHoHgAAAABJRU5ErkJggg==';
const questionPayload=(overrides={})=>({country:'Spain',city:'Malaga',region_name:null,category:'교통',urgency:'보통',title:'Getting to central Malaga',body:'What is the current best bus route to the city center?',reward_points:100,latitude:36.7213,longitude:-4.4214,...overrides});
const answerPayload=(overrides={})=>({body:'Take the airport express bus to the city center.',evidence_summary:'Verified against the official transport site.',verification_method:'공식 사이트에서 확인',links:[{url:'https://www.emtmalaga.es/',title:'Official transport',description:'Current route information',source_type:'official'}],...overrides});

// Deliberately no in-memory fallback: these tests must prove actual PostgreSQL behavior.
test('real PostgreSQL API integration, concurrency, and security',async t=>{
 assert.ok(databaseUrl,'Set TEST_DATABASE_URL to a disposable local PostgreSQL database. No tests use PGlite/in-memory substitution.');
 const adminPool=new pg.Pool({connectionString:databaseUrl,max:2});
 const schema=`test_${randomId().replaceAll('-','')}`;
 const uploads=await mkdtemp(join(tmpdir(),'malaga-api-test-'));
 let db,server;
 const errors=[];
 try {
  await adminPool.query(`CREATE SCHEMA ${schema}`);
  db=await createDatabase({connectionString:databaseUrl,schema});await migrate(db);await migrate(db);
  const storage=await createDiskStorage(uploads);await seedDevelopment(db,{enabled:true});await seedDevelopment(db,{enabled:true});
  let handler;server=nodeServer(request=>handler(request));
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  handler=createApp({db,storage,config:{publicBaseUrl:base,imageSigningSecret:'test-image-secret-with-at-least-32-characters',onError:error=>errors.push(error)}});
  const api=async(path,{method='GET',token,body,key,headers={}}={})=>{
   const response=await fetch(`${base}/api${path}`,{method,headers:{...(token?{Authorization:`Bearer ${token}`} : {}),...(body!==undefined?{'Content-Type':'application/json'}:{}),...(key?{'Idempotency-Key':key}:{}),...headers},...(body!==undefined?{body:JSON.stringify(body)}:{})});
   const data=await response.json();return {status:response.status,data};
  };
  const login=async(email,pw='daisy-dev-1234')=>{const r=await api('/auth/login',{method:'POST',body:{email,password:pw}});assert.equal(r.status,200,JSON.stringify(r.data));return r.data;};
  const register=async(email)=>{const r=await api('/auth/register',{method:'POST',body:{email,password,name:'Integration user'}});assert.equal(r.status,201,JSON.stringify(r.data));return r.data;};
  const key=()=>randomId();
  const create=async(actor,overrides={},idempotency=key())=>{const result=await api('/questions',{method:'POST',token:actor.token,key:idempotency,body:questionPayload(overrides)});assert.equal(result.status,201,JSON.stringify(result.data));return result.data.id;};
  const act=async(actor,path,body={},idempotency=key())=>api(path,{method:'POST',token:actor.token,key:idempotency,body});
  const profile=async actor=>(await api('/profile',{token:actor.token})).data;
  const conserve=async()=>{
   const {rows:[row]}=await db.query("SELECT (SELECT coalesce(sum(point_balance),0) FROM users)::text AS balances,(SELECT coalesce(sum(reward_points),0) FROM questions WHERE escrow_state='held')::text AS escrow,(SELECT coalesce(sum(amount),0) FROM point_transactions WHERE type='charge_mock')::text AS grants");
   assert.equal(Number(row.balances)+Number(row.escrow),Number(row.grants),'Balances + held escrow must equal initial mock grants');
   const mismatch=await db.query('SELECT u.id FROM users u LEFT JOIN point_transactions p ON p.user_id=u.id GROUP BY u.id,u.point_balance HAVING u.point_balance <> coalesce(sum(p.amount),0)');assert.equal(mismatch.rows.length,0,'Every balance must reconcile to its ledger');
  };
  let owner,other,helper,helper2,admin,newUser;
  await t.test('health, strict JSON/CORS, and auth boundary',async()=>{
   assert.deepEqual((await api('/health')).data,{ok:true,database:'postgres',mock_points:true});
   assert.equal((await api('/questions')).status,401);
   assert.equal((await api('/profile',{token:'fake'})).data.error.code,'UNAUTHENTICATED');
   assert.equal((await api('/auth/login',{method:'POST',body:{email:'x@example.com',password:'not-a-password'},headers:{Origin:'https://untrusted.example'}})).status,403);
   const malformed=await fetch(`${base}/api/auth/login`,{method:'POST',headers:{'content-type':'application/json'},body:'{'});assert.equal(malformed.status,400);
   const wrongType=await fetch(`${base}/api/auth/login`,{method:'POST',body:'hello'});assert.equal(wrongType.status,415);
   owner=await login('questioner1@example.com');other=await login('questioner2@example.com');helper=await login('answerer1@example.com');helper2=await login('answerer2@example.com');admin=await login('admin@example.com');
   assert.equal((await api('/admin/applications',{token:other.token})).status,403);
   assert.ok((await api('/admin/applications',{token:admin.token})).data.length>=2);
  });
  await t.test('registration owns roles/balance; passwords hashed; opaque sessions persist',async()=>{
   newUser=await register('New@Example.com');assert.equal(newUser.user.email,'new@example.com');assert.equal(newUser.user.is_admin,false);assert.equal(newUser.user.point_balance,1000);assert.equal(typeof newUser.user.helper_rating_avg,'number');assert.equal(newUser.token.length,43);assert.equal(newUser.user.password_hash,undefined);
   const credential=(await db.query('SELECT password_hash FROM auth_credentials WHERE user_id=$1',[newUser.user.id])).rows[0].password_hash;assert.ok(credential.startsWith('pbkdf2_sha256$600000$'));assert.ok(!credential.includes(password));
   const session=(await db.query('SELECT * FROM sessions WHERE user_id=$1',[newUser.user.id])).rows[0];assert.equal(session.token_hash,await sha256(newUser.token));assert.notEqual(session.token_hash,newUser.token);
   assert.equal((await api('/auth/register',{method:'POST',body:{email:'NEW@example.com',password,name:'Duplicate'}})).status,409);
   assert.equal((await api('/auth/register',{method:'POST',body:{email:'evil@example.com',password,name:'Evil user',is_admin:true}})).status,400);
   assert.equal((await api('/profile',{method:'PATCH',token:newUser.token,body:{point_balance:999999,is_admin:true}})).status,400);
   const update=await api('/profile',{method:'PATCH',token:newUser.token,body:{current_country:'Spain',current_city:'Malaga'}});assert.equal(update.status,200);assert.equal(update.data.current_city,'Málaga');
   assert.equal((await api('/auth/login',{method:'POST',body:{email:'new@example.com',password:'wrong-password'}})).data.error.code,'INVALID_CREDENTIALS');
   await conserve();
  });
  await t.test('auth retries are encrypted, exactly once, and reject changed/expired/revoked replay',async()=>{
   const requestKey=key(),body={email:'auth-retry@example.com',password,name:'Retry user'};
   const results=await Promise.all([api('/auth/register',{method:'POST',key:requestKey,body}),api('/auth/register',{method:'POST',key:requestKey,body})]);
   assert.equal(results[0].status,201);assert.deepEqual(results[0],results[1]);
   const created=results[0].data;
   const entry=(await db.query('SELECT * FROM auth_idempotency_keys WHERE email=$1',[body.email])).rows[0];assert.ok(!entry.encrypted_response.includes(created.token));assert.ok(!entry.fingerprint.includes(password));
   assert.equal((await api('/auth/register',{method:'POST',key:requestKey,body:{...body,name:'Different name'}})).data.error.code,'IDEMPOTENCY_CONFLICT');
   const loginKey=key(),loginBody={email:body.email,password};
   const logins=await Promise.all([api('/auth/login',{method:'POST',key:loginKey,body:loginBody}),api('/auth/login',{method:'POST',key:loginKey,body:loginBody})]);assert.equal(logins[0].status,200);assert.deepEqual(logins[0],logins[1]);
   await act(logins[0].data,'/auth/logout');
   assert.equal((await api('/auth/login',{method:'POST',key:loginKey,body:loginBody})).data.error.code,'AUTH_RETRY_EXPIRED');
   await db.query("UPDATE auth_idempotency_keys SET expires_at=now()-interval '1 minute' WHERE email=$1",[body.email]);
   assert.equal((await api('/auth/register',{method:'POST',key:requestKey,body})).data.error.code,'AUTH_RETRY_EXPIRED');
   assert.equal((await db.query("SELECT count(*)::int AS count FROM point_transactions WHERE user_id=$1 AND type='charge_mock'",[created.user.id])).rows[0].count,1);
   await conserve();
  });
  await t.test('helper application/review ownership and state gates',async()=>{
   assert.equal((await api('/helper/application',{token:newUser.token})).data,null);
   const application={languages:['English'],regions:[{country:'Spain',city:'Malaga'}],introduction:'I live locally and can verify information.',experience_description:'Several years answering travel questions.'};
   const applied=await act(newUser,'/helper/application',application);assert.equal(applied.status,201);
   assert.equal((await act(newUser,`/admin/applications/${applied.data.id}/review`,{status:'approved'})).status,403);
   assert.equal((await act(newUser,'/helper/application',application)).status,409);
   assert.equal((await act(admin,`/admin/applications/${applied.data.id}/review`,{status:'rejected',reject_reason:'Please add experience.'})).status,200);
   assert.equal((await act(newUser,'/helper/application',application)).status,201);
   assert.equal((await act(admin,`/admin/applications/${applied.data.id}/review`,{status:'approved'})).status,200);
   assert.equal((await api('/helper/application',{token:newUser.token})).data.status,'approved');
   assert.equal((await api('/helper/regions',{token:newUser.token})).data.length,1);
  });
  let imageQuestion,imageUrl;
  await t.test('question creation atomically holds points and persists private images',async()=>{
   const before=(await profile(owner)).point_balance,requestKey=key(),payload=questionPayload({images:[{name:'pixel.png',content_type:'image/png',data_base64:png}]});
   const [first,replay]=await Promise.all([api('/questions',{method:'POST',token:owner.token,key:requestKey,body:payload}),api('/questions',{method:'POST',token:owner.token,key:requestKey,body:payload})]);
   assert.equal(first.status,201,JSON.stringify(first.data));assert.deepEqual(first,replay);imageQuestion=first.data.id;
   assert.equal((await profile(owner)).point_balance,before-100);
   assert.equal((await api('/questions',{method:'POST',token:owner.token,key:requestKey,body:{...payload,title:'Different request'}})).status,409);
   assert.equal((await api('/questions',{method:'POST',token:owner.token,body:questionPayload()})).data.error.code,'IDEMPOTENCY_KEY_REQUIRED');
   const details=(await api(`/questions/${imageQuestion}`,{token:owner.token})).data;imageUrl=details.question_images[0].image_url;
   assert.equal(details.escrow_state,undefined);assert.ok(Array.isArray(details.question_comments));assert.ok(Array.isArray(details.answers));
   const image=await fetch(imageUrl);assert.equal(image.status,200);assert.equal(image.headers.get('content-type'),'image/png');const stored=(await db.query('SELECT storage_key,byte_length FROM question_images WHERE question_id=$1',[imageQuestion])).rows[0];const imageBytes=Buffer.from(await image.arrayBuffer());assert.deepEqual(imageBytes,await storage.get(stored.storage_key));assert.equal(imageBytes.length,stored.byte_length);
   assert.equal((await fetch(`${base}/api/images/${details.question_images[0].id}`)).status,401);
   const tampered=new URL(imageUrl);tampered.searchParams.set('sig','tampered');assert.equal((await fetch(tampered)).status,401);
   const files=await readdir(uploads);assert.equal(files.filter(x=>x.endsWith('.png')).length,1);
   assert.equal((await act(owner,'/questions',questionPayload({images:[{name:'bad.svg',content_type:'image/svg+xml',data_base64:png}]}))).status,400);
   await conserve();
  });
  await t.test('self acceptance, wrong helper, region checks, and concurrent assignment',async()=>{
   assert.equal((await act(owner,`/questions/${imageQuestion}/accept`)).data.error.code,'SELF_ANSWER');
   assert.equal((await act(other,`/questions/${imageQuestion}/accept`)).data.error.code,'HELPER_NOT_APPROVED');
   const mismatch=await create(owner,{city:'Madrid'});assert.equal((await act(helper,`/questions/${mismatch}/accept`)).data.error.code,'REGION_MISMATCH');
   assert.equal((await act(owner,`/questions/${mismatch}/cancel`)).status,200);
   const q=await create(owner);const results=await Promise.all([act(helper,`/questions/${q}/accept`),act(helper2,`/questions/${q}/accept`)]);
   assert.equal(results.filter(r=>r.status===200).length,1);assert.ok(results.every(r=>[200,404,409].includes(r.status)));
   const detail=(await api(`/questions/${q}`,{token:owner.token})).data;assert.ok([helper.user.id,helper2.user.id].includes(detail.assigned_helper_user_id));
   assert.equal((await api(`/questions/${q}`,{token:other.token})).status,404);
   assert.equal((await act(other,`/questions/${q}/comments`,{body:'I should not read this private thread.'})).status,404);
   assert.equal((await act(owner,`/questions/${q}/cancel`)).status,409);
   assert.equal((await act(owner,`/questions/${q}/answers`,answerPayload())).data.error.code,'SELF_ANSWER');
   await conserve();
  });
  await t.test('evidence URLs safe; answer submission and acceptance are exactly once',async()=>{
   const q=await create(other);assert.equal((await act(helper,`/questions/${q}/accept`)).status,200);
   for(const url of ['javascript:alert(1)','data:text/html,bad','file:///etc/passwd','http://localhost:3000','https://127.0.0.1','https://user:password@example.com','https://[::1]/']) {
    assert.equal((await act(helper,`/questions/${q}/answers`,answerPayload({links:[{url,source_type:'other'}]}))).data.error.code,'INVALID_EVIDENCE_URL',url);
   }
   assert.equal((await act(helper,`/questions/${q}/answers`,answerPayload({links:[]}))).status,400);
   assert.equal((await act(helper2,`/questions/${q}/answers`,answerPayload())).status,404);
   const answerKey=key(),answers=await Promise.all([act(helper,`/questions/${q}/answers`,answerPayload(),answerKey),act(helper,`/questions/${q}/answers`,answerPayload(),answerKey)]);
   assert.deepEqual(answers[0],answers[1]);assert.equal(answers[0].status,201);const answerId=answers[0].data.id;
   assert.equal((await act(helper,`/questions/${q}/answers`,answerPayload())).status,409);
   assert.equal((await act(helper,`/questions/${q}/answers/${answerId}/accept`)).status,403);
   assert.equal((await act(other,`/questions/${q}/answers/${randomId()}/accept`)).status,404);
   const before=(await profile(helper)).point_balance;
   const rewardResults=await Promise.all(Array.from({length:8},()=>act(other,`/questions/${q}/answers/${answerId}/accept`)));
   assert.ok(rewardResults.every(result=>result.status===200),JSON.stringify(rewardResults));
   assert.equal((await profile(helper)).point_balance,before+100);
   assert.equal((await db.query("SELECT count(*)::int AS count FROM point_transactions WHERE question_id=$1 AND type='reward'",[q])).rows[0].count,1);
   const detail=(await api(`/questions/${q}`,{token:other.token})).data;assert.equal(detail.status,'accepted');assert.equal(detail.accepted_answer_id,answerId);assert.equal(detail.answers[0].is_rewarded,true);assert.equal(detail.answers[0].answer_evidence_links.length,1);
   assert.equal((await act(other,`/questions/${q}/cancel`)).status,409);await conserve();
  });
  await t.test('comment serialization and visibility',async()=>{
   const response=await act(owner,`/questions/${imageQuestion}/comments`,{body:'Please verify current opening times.'});assert.equal(response.status,201);
   const detail=(await api(`/questions/${imageQuestion}`,{token:owner.token})).data;assert.equal(detail.question_comments[0].commenter.name,owner.user.name);
   assert.equal((await act(owner,`/questions/${imageQuestion}/comments`,{body:'x'.repeat(601)})).status,400);
  });
  await t.test('refund replay and cancellation races cannot mint points',async()=>{
   const q=await create(other),before=(await profile(other)).point_balance;
   assert.equal((await act(owner,`/questions/${q}/cancel`)).status,403);
   assert.equal((await act(other,`/questions/${q}/cancel`,{amount:9999})).status,400);
   const results=await Promise.all(Array.from({length:8},()=>act(other,`/questions/${q}/cancel`)));assert.ok(results.every(r=>r.status===200));
   assert.equal((await profile(other)).point_balance,before+100);
   assert.equal((await db.query("SELECT count(*)::int AS count FROM point_transactions WHERE question_id=$1 AND type='refund'",[q])).rows[0].count,1);
   const race=await create(other),raced=await Promise.all([act(other,`/questions/${race}/cancel`),act(helper,`/questions/${race}/accept`)]);
   assert.equal(raced.filter(r=>r.status===200).length,1);const state=(await api(`/questions/${race}`,{token:other.token})).data;assert.ok(['assigned','cancelled'].includes(state.status));await conserve();
  });
  await t.test('concurrent create cannot overspend; failed write rolls back all state',async()=>{
   const fresh=await register('overspend@example.com');
   const results=await Promise.all([act(fresh,'/questions',questionPayload({reward_points:700})),act(fresh,'/questions',questionPayload({reward_points:700}))]);
   assert.equal(results.filter(r=>r.status===201).length,1);assert.equal(results.filter(r=>r.data.error?.code==='INSUFFICIENT_POINTS').length,1);assert.equal((await profile(fresh)).point_balance,300);
   const before=(await profile(owner)).point_balance;
   const failing=createApp({db,storage:{...storage,put:async()=>{throw new Error('Simulated disk full');}},config:{publicBaseUrl:base,onError:()=>{}}});
   const result=await failing(new Request(`${base}/api/questions`,{method:'POST',headers:{authorization:`Bearer ${owner.token}`,'content-type':'application/json','idempotency-key':key()},body:JSON.stringify(questionPayload({images:[{name:'pixel.png',content_type:'image/png',data_base64:png}]}))}));
   assert.equal(result.status,500);assert.equal((await profile(owner)).point_balance,before);
   const filesBefore=await readdir(uploads);
   const partialDisk=createApp({db,storage:{...storage,put:async(key,bytes)=>{await storage.put(key,bytes);throw new Error('Failure after writing image');}},config:{publicBaseUrl:base,onError:()=>{}}});
   const partial=await partialDisk(new Request(`${base}/api/questions`,{method:'POST',headers:{authorization:`Bearer ${owner.token}`,'content-type':'application/json','idempotency-key':key()},body:JSON.stringify(questionPayload({images:[{name:'pixel.png',content_type:'image/png',data_base64:png}]}))}));
   assert.equal(partial.status,500);assert.deepEqual((await readdir(uploads)).sort(),filesBefore.sort(),'A known uncommitted file is removed after rollback');assert.equal((await profile(owner)).point_balance,before);
   let committed=false;
   const ambiguousDb={...db,transaction:async fn=>{const result=await db.transaction(fn);if(!committed){committed=true;throw new Error('Connection dropped after commit');}return result;}};
   const ambiguousKey=key(),ambiguousPayload=questionPayload({images:[{name:'pixel.png',content_type:'image/png',data_base64:png}]});
   const ambiguous=createApp({db:ambiguousDb,storage,config:{publicBaseUrl:base,onError:()=>{}}});
   const uncertain=await ambiguous(new Request(`${base}/api/questions`,{method:'POST',headers:{authorization:`Bearer ${owner.token}`,'content-type':'application/json','idempotency-key':ambiguousKey},body:JSON.stringify(ambiguousPayload)}));
   assert.equal(uncertain.status,500);assert.equal((await profile(owner)).point_balance,before-100);
   const recovered=await api('/questions',{method:'POST',token:owner.token,key:ambiguousKey,body:ambiguousPayload});assert.equal(recovered.status,201);
   const committedImage=(await api(`/questions/${recovered.data.id}`,{token:owner.token})).data.question_images[0].image_url;assert.equal((await fetch(committedImage)).status,200,'A committed image survives an ambiguous commit result');await conserve();
  });
  await t.test('detail, list and guide feed do not leak private content during concurrent claim',async()=>{
   for(const list of [false,true,'guide']) {
    const readerActor=list==='guide'?helper2:other;
    const q=await create(owner,{reward_points:10});
    let selectedResolve,releaseResolve,paused=false;
    const selected=new Promise(resolve=>selectedResolve=resolve),release=new Promise(resolve=>releaseResolve=resolve);
    const instrument=target=>({query:async(sql,params=[])=>{
     const result=await target.query(sql,params);
     if(!paused&&(sql.startsWith('SELECT * FROM questions')||sql.startsWith('SELECT q.* FROM questions'))&&result.rows.some(row=>row.id===q)) {
      paused=true;selectedResolve();await release;
     }
     return result;
    }});
    const readerDb={...db,...instrument(db),transaction:fn=>db.transaction(tx=>fn(instrument(tx)))};
    const readerApp=createApp({db:readerDb,storage,config:{publicBaseUrl:base,imageSigningSecret:'test-image-secret-with-at-least-32-characters',onError:error=>errors.push(error)}});
    const readerServer=nodeServer(readerApp);await new Promise(resolve=>readerServer.listen(0,'127.0.0.1',resolve));
    let reading,writing;
    try {
     reading=fetch(`http://127.0.0.1:${readerServer.address().port}/api${list==='guide'?'/guide/questions':`/questions${list?'?status=open':`/${q}`}`}`,{headers:{Authorization:`Bearer ${readerActor.token}`}});
     await selected;
     let finished=false,writeError;
     writing=(async()=>{
      assert.equal((await act(helper,`/questions/${q}/accept`)).status,200);
      assert.equal((await act(helper,`/questions/${q}/comments`,{body:'Private comment created after assignment.'})).status,201);
      assert.equal((await act(helper,`/questions/${q}/answers`,answerPayload())).status,201);
     })().catch(error=>{writeError=error;}).finally(()=>finished=true);
     let blocked=false;
     for(let i=0;i<200&&!finished&&!blocked;i++) {
      const waiting=await db.query("SELECT pid FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE 'SELECT * FROM questions WHERE id=$1 FOR UPDATE%'");
      blocked=waiting.rows.length>0;if(!finished&&!blocked)await new Promise(resolve=>setTimeout(resolve,5));
     }
     releaseResolve();
     const response=await reading;assert.equal(response.status,200);const result=await response.json(),visible=list?result.find(item=>item.id===q):result;
     await writing;if(writeError)throw writeError;
     assert.equal(visible.question_comments.length,0,`${list?'list':'detail'} must not expose comments written after the question became private`);
     assert.equal(visible.answers.length,0,`${list?'list':'detail'} must not expose answers written after the question became private`);
     assert.equal(blocked,true,'The question claim waits for the authorized nested read to finish');
     assert.equal((await api(`/questions/${q}`,{token:readerActor.token})).status,404,'New reads cannot view the now-private question');
    } finally {releaseResolve();if(reading)await reading;if(writing)await writing;await new Promise(resolve=>readerServer.close(resolve));}
   }
   await conserve();
  });
  await t.test('fresh API instance state preserves sessions, images and retries across instances',async()=>{
   const loginKey=key(),loginBody={email:'questioner3@example.com',password:'daisy-dev-1234'};
   const authenticated=await api('/auth/login',{method:'POST',key:loginKey,body:loginBody});assert.equal(authenticated.status,200);
   const actor=authenticated.data,createKey=key(),payload=questionPayload({images:[{name:'persistent.png',content_type:'image/png',data_base64:png}]});
   const created=await api('/questions',{method:'POST',token:actor.token,key:createKey,body:payload});assert.equal(created.status,201);
   const details=(await api(`/questions/${created.data.id}`,{token:actor.token})).data;
   const signed=new URL(details.question_images[0].image_url);
   const secondDb=await createDatabase({connectionString:databaseUrl,schema});
   let secondServer;
   try {
    const secondStorage=await createDiskStorage(uploads);
    const secondHandle=createApp({db:secondDb,storage:secondStorage,config:{publicBaseUrl:base,imageSigningSecret:'test-image-secret-with-at-least-32-characters',onError:error=>errors.push(error)}});
    secondServer=nodeServer(secondHandle);await new Promise(resolve=>secondServer.listen(0,'127.0.0.1',resolve));
    const secondBase=`http://127.0.0.1:${secondServer.address().port}`;
    const secondFetch=(path,options={})=>fetch(`${secondBase}/api${path}`,{...options,headers:{Authorization:`Bearer ${actor.token}`,...options.headers}});
    assert.equal((await secondFetch('/auth/me')).status,200);
    assert.equal((await fetch(`${secondBase}${signed.pathname}${signed.search}`)).status,200,'Stored bytes, session and signed URL survive fresh instance');
    const replay=await secondFetch('/questions',{method:'POST',headers:{'Content-Type':'application/json','Idempotency-Key':createKey},body:JSON.stringify(payload)});assert.equal(replay.status,201);assert.deepEqual(await replay.json(),created.data);
    const loginReplay=await secondFetch('/auth/login',{method:'POST',headers:{'Content-Type':'application/json','Idempotency-Key':loginKey},body:JSON.stringify(loginBody)});assert.equal(loginReplay.status,200);assert.deepEqual(await loginReplay.json(),actor);
    assert.equal((await secondFetch('/auth/logout',{method:'POST'})).status,200);
    assert.equal((await api('/auth/me',{token:actor.token})).status,401,'Revocation is shared across instances');
    assert.equal((await fetch(signed)).status,401);await conserve();
   } finally {if(secondServer)await new Promise(resolve=>secondServer.close(resolve));await secondDb.close();}
  });
  await t.test('guide progress uses owned ledger/work and participant-only public summaries',async()=>{
   assert.equal((await api('/guide/me')).status,401);
   const guide=await register('guide-metrics@example.com');
   const metrics=async()=>(await api('/guide/me',{token:guide.token})).data;
   assert.deepEqual(await metrics(),{accepted_answer_count:0,earned_mock_points:0,pending_mock_points:0,application_status:null,activity_regions:[]});
   assert.equal((await api(`/guide/${helper.user.id}`,{token:guide.token})).status,404);
   assert.equal((await api(`/guide/me?user_id=${helper.user.id}`,{token:guide.token})).data.earned_mock_points,0,'A query parameter cannot read another user’s rewards');
   const application=await act(guide,'/helper/application',{languages:['English'],regions:[{country:'Spain',city:'Malaga',region_name:'Centro'}],introduction:'Local guide answering practical travel questions.',experience_description:'I use official sources and current local information.'});assert.equal(application.status,201);
   assert.equal((await metrics()).application_status,'pending');
   assert.deepEqual((await metrics()).activity_regions,[{country:'Spain',city:'Málaga',region_name:'Centro'}]);
   assert.equal((await act(admin,`/admin/applications/${application.data.id}/review`,{status:'approved'})).status,200);
   const initial=await metrics();assert.equal(initial.application_status,'approved');
   const cancelled=await create(other,{reward_points:19,region_name:'Centro'});assert.equal((await act(other,`/questions/${cancelled}/cancel`)).status,200);assert.deepEqual(await metrics(),initial,'An unrelated open cancellation creates no guide earnings or reputation');
   const q=await create(other,{reward_points:37,region_name:'Centro'});
   assert.equal((await api(`/questions/${q}`,{token:guide.token})).data.assigned_helper,null);
   assert.deepEqual(await metrics(),initial,'Open unassigned work is not pending guide reward');
   assert.equal((await act(guide,`/questions/${q}/accept`)).status,200);
   assert.equal((await metrics()).pending_mock_points,37);assert.equal((await metrics()).earned_mock_points,0);assert.equal((await metrics()).accepted_answer_count,0);
   const detail=(await api(`/questions/${q}`,{token:other.token})).data,summary=detail.assigned_helper;
   assert.deepEqual(Object.keys(summary).sort(),['id','name','accepted_answer_count','application_status','activity_regions'].sort());
   assert.equal(summary.id,guide.user.id);assert.equal(summary.name,guide.user.name);assert.equal(summary.application_status,'approved');assert.equal(summary.accepted_answer_count,0);assert.deepEqual(summary.activity_regions,initial.activity_regions);
   assert.equal((await api(`/questions/${q}`,{token:owner.token})).status,404,'An unrelated user cannot see assigned-helper summary');
   assert.ok(!(await api('/questions',{token:owner.token})).data.some(item=>item.id===q));
   assert.equal((await act(other,`/questions/${q}/cancel`)).status,409);assert.equal((await metrics()).pending_mock_points,37);
   const answer=await act(guide,`/questions/${q}/answers`,answerPayload());assert.equal(answer.status,201);
   assert.equal((await metrics()).pending_mock_points,37);assert.equal((await metrics()).accepted_answer_count,0,'Submitted work is not accepted work');
   assert.equal((await act(other,`/questions/${q}/answers/${answer.data.id}/accept`)).status,200);
   const completed=await metrics();assert.deepEqual(completed,{...initial,accepted_answer_count:1,earned_mock_points:37,pending_mock_points:0});
   assert.equal((await profile(guide)).point_balance,1037,'Initial mock grant does not count as guide earnings');
   assert.ok((await Promise.all(Array.from({length:4},()=>act(other,`/questions/${q}/answers/${answer.data.id}/accept`)))).every(result=>result.status===200));
   assert.deepEqual(await metrics(),completed,'Duplicate acceptance cannot inflate guide metrics');
   assert.equal((await api(`/questions/${q}`,{token:other.token})).data.assigned_helper.accepted_answer_count,1);
   assert.equal((await act(admin,`/admin/applications/${application.data.id}/review`,{status:'suspended',reject_reason:'Synthetic review test.'})).status,200);
   assert.deepEqual(await metrics(),{...completed,application_status:'suspended'},'Approval changes do not rewrite real earned history');
   await conserve();
  });
  await t.test('guide feed matches claim rules: region, owner, expiry, state and approval',async()=>{
   assert.equal((await api('/guide/questions')).status,401);
   const guide=await register('region-feed@example.com'),questioner=await register('region-feed-owner@example.com');
   const feed=()=>api('/guide/questions',{token:guide.token});
   assert.equal((await feed()).data.error.code,'HELPER_NOT_APPROVED');
   const application=await act(guide,'/helper/application',{languages:['English'],regions:[{country:'Spain',city:'Malaga',region_name:'Centro'}],introduction:'I can help visitors within the city center.',experience_description:'Local knowledge checked against current official sources.'});assert.equal(application.status,201);
   assert.equal((await feed()).status,403);
   assert.equal((await act(admin,`/admin/applications/${application.data.id}/review`,{status:'approved'})).status,200);
   const exact=await create(questioner,{reward_points:10,region_name:'Centro'});
   const mixedCase=await create(questioner,{reward_points:10,country:'spain',city:'mALAGA',region_name:'cENTRO'});
   const broadQuestion=await create(questioner,{reward_points:10,region_name:null});
   const differentRegion=await create(questioner,{reward_points:10,region_name:'Teatinos'});
   const differentCity=await create(questioner,{reward_points:10,city:'Madrid',region_name:'Centro'});
   const differentCountry=await create(questioner,{reward_points:10,country:'Portugal',city:'Lisbon',region_name:'Centro'});
   const expired=await create(questioner,{reward_points:10,region_name:'Centro'});await db.query("UPDATE questions SET expires_at=now()-interval '1 minute' WHERE id=$1",[expired]);
   const assigned=await create(questioner,{reward_points:10,region_name:'Centro'});assert.equal((await act(helper,`/questions/${assigned}/accept`)).status,200);
   const cancelled=await create(questioner,{reward_points:10,region_name:'Centro'});assert.equal((await act(questioner,`/questions/${cancelled}/cancel`)).status,200);
   const own=await create(guide,{reward_points:10,region_name:'Centro'});
   const response=await feed();assert.equal(response.status,200);const ids=new Set(response.data.map(q=>q.id));
   for(const id of [exact,mixedCase,broadQuestion])assert.ok(ids.has(id),`Claimable regional question ${id} must be in feed`);
   for(const id of [differentRegion,differentCity,differentCountry,expired,assigned,cancelled,own])assert.ok(!ids.has(id),`Unclaimable question ${id} must be excluded`);
   assert.ok(response.data.every(q=>q.status==='open'&&q.user_id!==guide.user.id));
   const unchangedMap=(await api('/questions?status=open',{token:guide.token})).data;assert.ok(unchangedMap.some(q=>q.id===differentCity));assert.ok(unchangedMap.some(q=>q.id===own),'General map/search retains its original visibility');
   assert.equal((await act(guide,`/questions/${differentRegion}/accept`)).data.error.code,'REGION_MISMATCH');
   assert.equal((await act(guide,`/questions/${own}/accept`)).data.error.code,'SELF_ANSWER');
   assert.equal((await act(guide,`/questions/${expired}/accept`)).data.error.code,'QUESTION_EXPIRED');
   for(const id of [exact,mixedCase,broadQuestion])assert.equal((await act(guide,`/questions/${id}/accept`)).status,200,'Feed and claim share identical case-insensitive region rules');
   const after=new Set((await feed()).data.map(q=>q.id));for(const id of [exact,mixedCase,broadQuestion])assert.ok(!after.has(id));
   assert.equal((await act(admin,`/admin/applications/${application.data.id}/review`,{status:'suspended',reject_reason:'Synthetic suspension test.'})).status,200);
   assert.equal((await feed()).status,403);await conserve();
  });
  await t.test('question expiry, session expiry/logout, and image revocation',async()=>{
   const expired=await create(owner);await db.query("UPDATE questions SET expires_at=now()-interval '1 minute' WHERE id=$1",[expired]);
   assert.equal((await act(helper,`/questions/${expired}/accept`)).data.error.code,'QUESTION_EXPIRED');
   assert.equal((await act(owner,`/questions/${expired}/cancel`)).status,200);
   const short=await login('questioner3@example.com');await db.query("UPDATE sessions SET expires_at=now()-interval '1 second' WHERE token_hash=$1",[await sha256(short.token)]);
   assert.equal((await api('/auth/me',{token:short.token})).data.error.code,'UNAUTHENTICATED');
   assert.equal((await act(owner,'/auth/logout')).status,200);assert.equal((await api('/profile',{token:owner.token})).status,401);assert.equal((await fetch(imageUrl)).status,401);await conserve();
  });
  await t.test('no unexpected internal errors; production safety and seeder guards',async()=>{
   assert.deepEqual(errors.map(e=>`${e.code??''} ${e.message}`),[]);
   assert.throws(()=>loadConfig({NODE_ENV:'production',PUBLIC_BASE_URL:'http://example.com'}),/HTTPS/);
   assert.throws(()=>loadConfig({NODE_ENV:'production',PUBLIC_BASE_URL:'https://example.com'}),/IMAGE_SIGNING_SECRET/);
   assert.throws(()=>loadConfig({CORS_ORIGINS:'*'}),/origin/i);
   await assert.rejects(seedDevelopment(db,{enabled:false}),/disabled/);await assert.rejects(seedDevelopment(db,{enabled:true,production:true}),/disabled/);
  });
 } finally {
  if(server)await new Promise(resolve=>server.close(resolve));if(db)await db.close();
  await adminPool.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await adminPool.end();await rm(uploads,{recursive:true,force:true});
 }
});
