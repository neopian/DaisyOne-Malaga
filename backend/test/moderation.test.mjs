import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {createTextFilter} from '../src/moderation.mjs';
import {loadConfig} from '../src/server.mjs';
import {randomId,randomToken,sha256,hashPassword} from '../src/crypto.mjs';

const png='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACXBIWXMAAAPoAAAD6AG1e1JrAAAADUlEQVQImWP4////fwAJ+wP9CNHoHgAAAABJRU5ErkJggg==';
const questionBody={country:'Spain',city:'Malaga',category:'교통',urgency:'보통',title:'Bus route information',body:'Where is the current airport bus stop?',reward_points:100};
const answerBody={body:'The bus stops beside the terminal exit.',evidence_summary:'Checked with the official transport operator.',verification_method:'Official published route',links:[{url:'https://www.emtmalaga.es/',title:'Operator',source_type:'official'}]};
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));

test('literal text filter normalizes Unicode and covers nested public fields only',()=>{
 const filter=createTextFilter(['restricted phrase']);
 assert.equal(filter({title:'RESTRICTED\u200b   PHRASE'}),true);
 assert.equal(filter({links:[{title:'ｒｅｓｔｒｉｃｔｅｄ phrase'}]}),true);
 assert.equal(filter({password:'restricted phrase',email:'restricted phrase',images:[{data_base64:'restricted phrase'}]}),false);
 assert.equal(filter({body:'A valid travel question.'}),false);
 assert.equal(createTextFilter([])('restricted phrase'),false);
 assert.throws(()=>createTextFilter(['']),/textFilterTerms/);
 assert.throws(()=>createTextFilter(['\u200b']),/textFilterTerms/);
 assert.throws(()=>createTextFilter(Array(501).fill('phrase')),/textFilterTerms/);
 assert.deepEqual(loadConfig({TEXT_FILTER_TERMS_JSON:'["configured phrase"]'}).textFilterTerms,['configured phrase']);
 assert.throws(()=>loadConfig({TEXT_FILTER_TERMS_JSON:'not json'}),/TEXT_FILTER_TERMS_JSON/);
 assert.throws(()=>loadConfig({TEXT_FILTER_TERMS_JSON:'[false]'}),/textFilterTerms/);
});

test('real PostgreSQL reports, bilateral blocking, moderation and safety races',async t=>{
 const databaseUrl=process.env.TEST_DATABASE_URL;
 assert.ok(databaseUrl,'Set TEST_DATABASE_URL to a disposable real PostgreSQL database.');
 const pool=new pg.Pool({connectionString:databaseUrl,max:2}),schema=`safety_${randomId().replaceAll('-','')}`;
 let db;const bytes=new Map(),errors=[];
 try {
  await pool.query(`CREATE SCHEMA ${schema}`);db=await createDatabase({connectionString:databaseUrl,schema});await migrate(db);
  const storage={put:async(k,v)=>bytes.set(k,v),get:async k=>{if(!bytes.has(k))throw new Error('missing');return bytes.get(k);},delete:async k=>bytes.delete(k)};
  const config={imageSigningSecret:'moderation-integration-secret-at-least-32-characters',textFilterTerms:['restricted phrase'],onError:e=>errors.push(e)};
  let handler=createApp({db,storage,config});
  const api=async(path,{actor,method='GET',body,key}={})=>{
   const response=await handler(new Request(path.startsWith('http')?path:`http://127.0.0.1:8080/api${path}`,{method,headers:{...(actor?{Authorization:`Bearer ${actor.token}`} : {}),...(body!==undefined?{'Content-Type':'application/json'}:{}),...(key?{'Idempotency-Key':key}:{})},...(body!==undefined?{body:JSON.stringify(body)}:{})}));
   return {status:response.status,data:response.headers.get('content-type')?.includes('json')?await response.json():await response.arrayBuffer()};
  };
  const post=(actor,path,body={},key=randomId())=>api(path,{actor,method:'POST',body,key});
  const actor=async(name,{admin=false,helper=false}={})=>{
   const id=randomId(),token=randomToken();
   await db.query('INSERT INTO users(id,email,name,is_admin,point_balance,email_verified_at) VALUES($1,$2,$3,$4,10000,now())',[id,`${id}@example.invalid`,name,admin]);
   await db.query("INSERT INTO point_transactions(id,user_id,type,amount) VALUES($1,$2,'charge_mock',10000)",[randomId(),id]);
   await db.query("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '1 day')",[randomId(),id,await sha256(token)]);
   if(helper){await db.query("INSERT INTO helper_applications(id,user_id,status,introduction,experience_description) VALUES($1,$2,'approved','Local knowledge','Transport routes')",[randomId(),id]);await db.query("INSERT INTO helper_regions(id,helper_user_id,country,city) VALUES($1,$2,'Spain','Malaga')",[randomId(),id]);}
   return {id,token};
  };
  const owner=await actor('Traveler'),reader=await actor('Reader'),writer=await actor('Commenter'),guide=await actor('Guide',{helper:true}),admin=await actor('Moderator',{admin:true});
  const create=async(who=owner,extra={})=>{const r=await post(who,'/questions',{...questionBody,...extra});assert.equal(r.status,201,JSON.stringify(r.data));return r.data.id;};
  const report=async(who,type,id,reason='spam',extra={})=>{const r=await post(who,'/reports',{target_type:type,target_id:id,reason,...extra});assert.ok([200,201].includes(r.status),JSON.stringify(r));return r.data.id;};
  const review=(id,action,note)=>post(admin,`/admin/reports/${id}/review`,{action,...(note?{note}:{})});
  const snapshot=async()=>(await db.query("SELECT (SELECT coalesce(sum(point_balance),0) FROM users)::int AS balances,(SELECT coalesce(sum(reward_points),0) FROM questions WHERE escrow_state='held')::int AS held,(SELECT count(*)::int FROM point_transactions) AS ledger_count")).rows[0];
  await t.test('reports validate access, fields, bounded text, role and same-key/different-key retries',async()=>{
   const q=await create(),key=randomId(),body={target_type:'question',target_id:q,reason:'spam',details:'Please review this example.'};
   const pair=await Promise.all([post(reader,'/reports',body,key),post(reader,'/reports',body,key)]);
   assert.equal(pair[0].status,201);assert.deepEqual(pair[0],pair[1]);
   assert.equal((await post(reader,'/reports',body)).data.id,pair[0].data.id);
   assert.equal((await post(reader,'/reports',{...body,reason:'hate'},key)).data.error.code,'IDEMPOTENCY_CONFLICT');
   assert.equal((await api('/reports',{actor:reader,method:'POST',body})).data.error.code,'IDEMPOTENCY_KEY_REQUIRED');
   for(const extra of [{target_type:'image'},{reason:'invented'},{target_id:randomId()},{details:'x'.repeat(1001)},{is_admin:true}])assert.ok([400,404].includes((await post(reader,'/reports',{...body,...extra})).status));
   assert.equal((await post(owner,'/reports',body)).data.error.code,'SELF_REPORT');
   assert.equal((await api('/admin/reports',{actor:reader})).status,403);
   assert.equal((await post(reader,`/admin/reports/${pair[0].data.id}/review`,{action:'hide'})).status,403);
   const queue=await api('/admin/reports',{actor:admin});assert.equal(queue.status,200);assert.ok(queue.data.some(r=>r.id===pair[0].data.id&&r.target.body===questionBody.body));assert.ok(!JSON.stringify(queue.data).includes('@example.invalid'));
   assert.equal((await db.query('SELECT count(*)::int AS n FROM content_reports WHERE target_id=$1',[q])).rows[0].n,1);
   await post(guide,`/questions/${q}/accept`);
   assert.equal((await post(writer,'/reports',{...body,target_type:'question'})).status,404,'Unrelated users cannot report private content to disclose it');
  });
  await t.test('bilateral blocks hide lists, details, comments and already-issued images; unblock affects only own block',async()=>{
   const q=await create(owner,{images:[{name:'pixel.png',content_type:'image/png',data_base64:png}]}),otherQuestion=await create(reader);
   const comment=await post(writer,`/questions/${otherQuestion}/comments`,{body:'A useful local observation.'});assert.equal(comment.status,201);
   const details=await api(`/questions/${q}`,{actor:reader}),image=details.data.question_images[0].image_url;assert.equal((await api(image)).status,200);
   const key=randomId();const results=await Promise.all([post(reader,`/blocks/${owner.id}`,{},key),post(reader,`/blocks/${owner.id}`,{},key)]);assert.deepEqual(results[0],results[1]);assert.equal(results[0].status,200);
   assert.equal((await api(`/questions/${q}`,{actor:reader})).status,404);assert.equal((await api(image)).status,404);
   assert.ok(!(await api('/questions',{actor:reader})).data.some(row=>row.id===q));
   assert.equal((await api(`/questions/${otherQuestion}`,{actor:owner})).status,404,'Block applies in both directions');
   assert.equal((await post(owner,`/questions/${otherQuestion}/comments`,{body:'Should not be posted.'})).status,404);
   assert.equal((await post(reader,`/blocks/${reader.id}`)).data.error.code,'SELF_BLOCK');
   const list=(await api('/blocks',{actor:reader})).data;assert.deepEqual(Object.keys(list[0]).sort(),['blocked_user_id','created_at','name']);
   await post(reader,`/blocks/${writer.id}`);assert.equal((await api(`/questions/${otherQuestion}`,{actor:reader})).data.question_comments.length,0);
   await post(owner,`/blocks/${reader.id}`);await post(reader,`/blocks/${owner.id}/unblock`);assert.equal((await api(`/questions/${q}`,{actor:reader})).status,404,'Unblocking does not remove the other user\'s block');
   await post(owner,`/blocks/${reader.id}/unblock`);assert.equal((await api(`/questions/${q}`,{actor:reader})).status,200);
   await post(reader,`/blocks/${writer.id}/unblock`);
  });
  await t.test('question hide and restore invalidate image access without changing escrow or lifecycle',async()=>{
   const q=await create(owner,{images:[{name:'pixel.png',content_type:'image/png',data_base64:png}]}),r=await report(reader,'question',q);
   const image=(await api(`/questions/${q}`,{actor:reader})).data.question_images[0].image_url,before=await snapshot();
   const key=randomId(),payload={action:'hide',note:'Unsafe example retained only for restricted review.'};
   const reviews=await Promise.all([post(admin,`/admin/reports/${r}/review`,payload,key),post(admin,`/admin/reports/${r}/review`,payload,key)]);assert.deepEqual(reviews[0],reviews[1]);assert.equal(reviews[0].status,200);
   assert.deepEqual(await snapshot(),before);assert.equal((await api(`/questions/${q}`,{actor:owner})).status,404);assert.equal((await api(image)).status,404);
   assert.equal((await api(`/questions/${q}`,{actor:admin})).status,200);
   assert.equal((await db.query('SELECT status,escrow_state FROM questions WHERE id=$1',[q])).rows[0].status,'open');
   assert.equal((await post(guide,`/questions/${q}/accept`)).status,404);
   assert.equal((await db.query('SELECT count(*)::int AS n FROM moderation_actions WHERE report_id=$1',[r])).rows[0].n,1);
   assert.equal((await review(r,'restore')).status,200);assert.equal((await api(`/questions/${q}`,{actor:reader})).status,200);assert.deepEqual(await snapshot(),before);
   await review(r,'hide');assert.equal((await post(owner,`/questions/${q}/cancel`)).status,200,'Existing open-owner cancellation remains available without exposing content');
  });
  await t.test('answer/comment moderation does not leak bodies, links or acceptance IDs or release held reward',async()=>{
   const q=await create();const c=(await post(writer,`/questions/${q}/comments`,{body:'Comment to review.'})).data.id;
   const cr=await report(reader,'comment',c);await review(cr,'hide');let detail=(await api(`/questions/${q}`,{actor:owner})).data;assert.equal(detail.question_comments.length,0);
   await review(cr,'restore');detail=(await api(`/questions/${q}`,{actor:owner})).data;assert.equal(detail.question_comments[0].id,c);
   assert.equal((await post(guide,`/questions/${q}/accept`)).status,200);const a=(await post(guide,`/questions/${q}/answers`,answerBody)).data.id;
   const ar=await report(owner,'answer',a),before=await snapshot();await review(ar,'hide');detail=(await api(`/questions/${q}`,{actor:owner})).data;
   assert.deepEqual(detail.answers,[]);assert.equal(detail.accepted_answer_id,null);assert.ok(!JSON.stringify(detail).includes(answerBody.links[0].url));
   assert.equal((await post(owner,`/questions/${q}/answers/${a}/accept`)).status,404);assert.deepEqual(await snapshot(),before);
   await review(ar,'restore');assert.equal((await post(owner,`/questions/${q}/answers/${a}/accept`)).status,200);
   const paid=await snapshot();await review(ar,'hide');detail=(await api(`/questions/${q}`,{actor:owner})).data;assert.equal(detail.accepted_answer_id,null);assert.deepEqual(detail.answers,[]);assert.deepEqual(await snapshot(),paid);
   await review(ar,'restore');assert.equal((await post(owner,`/questions/${q}/answers/${a}/accept`)).status,200);assert.deepEqual(await snapshot(),paid,'Retry after restore cannot pay twice');
  });
  await t.test('blocking an assigned guide prevents continuing interaction without silently settling escrow',async()=>{
   const q=await create();await post(guide,`/questions/${q}/accept`);const before=await snapshot();await post(owner,`/blocks/${guide.id}`);
   assert.equal((await api(`/questions/${q}`,{actor:owner})).status,404);assert.equal((await post(guide,`/questions/${q}/answers`,answerBody)).status,404);
   assert.equal((await post(owner,`/questions/${q}/cancel`)).data.error.code,'CANNOT_CANCEL');assert.deepEqual(await snapshot(),before);
   await post(owner,`/blocks/${guide.id}/unblock`);assert.equal((await post(guide,`/questions/${q}/answers`,answerBody)).status,201);
  });
  await t.test('suspension blocks writes, old retries and content while preserving account access; administrator protection',async()=>{
   const q=await create(writer),r=await report(reader,'user',writer.id),key=randomId(),body={...questionBody,title:'Previously accepted request'};
   assert.equal((await post(writer,'/questions',body,key)).status,201);const before=await snapshot();assert.equal((await review(r,'suspend')).status,200);
   assert.equal((await post(writer,'/questions',body,key)).data.error.code,'ACCOUNT_SUSPENDED');assert.equal((await post(writer,'/reports',{target_type:'user',target_id:owner.id,reason:'spam'})).data.error.code,'ACCOUNT_SUSPENDED');
   assert.equal((await api('/questions',{actor:writer})).data.error.code,'ACCOUNT_SUSPENDED');assert.equal((await api(`/questions/${q}`,{actor:reader})).status,404);
   assert.equal((await api('/profile',{actor:writer})).status,200);assert.deepEqual(await snapshot(),before);
   handler=createApp({db,storage,config});assert.equal((await post(writer,'/questions',questionBody)).data.error.code,'ACCOUNT_SUSPENDED','Suspension persists across API instances');
   assert.equal((await review(r,'reinstate')).status,200);assert.equal((await api(`/questions/${q}`,{actor:reader})).status,200);
   const protectedReport=await report(reader,'user',admin.id);assert.equal((await review(protectedReport,'suspend')).data.error.code,'PROTECTED_ACCOUNT');assert.equal((await review(protectedReport,'hide')).data.error.code,'INVALID_REVIEW');
   assert.equal((await db.query('SELECT is_admin,is_suspended FROM users WHERE id=$1',[admin.id])).rows[0].is_suspended,false);
  });
  await t.test('configured filter rejects public nested fields without ledger writes',async()=>{
   const before=await snapshot();assert.equal((await post(owner,'/questions',{...questionBody,title:'A restricted phrase'})).data.error.code,'CONTENT_REJECTED');assert.deepEqual(await snapshot(),before);
   const q=await create();assert.equal((await post(writer,`/questions/${q}/comments`,{body:'RESTRICTED\u200b PHRASE'})).data.error.code,'CONTENT_REJECTED');
   await post(guide,`/questions/${q}/accept`);assert.equal((await post(guide,`/questions/${q}/answers`,{...answerBody,links:[{...answerBody.links[0],description:'restricted phrase'}]})).data.error.code,'CONTENT_REJECTED');
   assert.equal((await db.query('SELECT count(*)::int AS n FROM answers WHERE question_id=$1',[q])).rows[0].n,0);
  });
  await t.test('suspended account export contains only own safety data and deletion cascades reports, notes, blocks',async()=>{
   const subject=await actor('Deletion subject'),password='synthetic-deletion-password';
   await db.query('INSERT INTO auth_credentials(user_id,password_hash) VALUES($1,$2)',[subject.id,await hashPassword(password)]);
   const q=await create(subject),reported=await report(reader,'question',q,'privacy',{details:'Private report about the subject.'});
   const ownReport=await report(subject,'user',owner.id,'spam',{details:'My own report text.'});
   await post(subject,`/blocks/${owner.id}`);await review(reported,'hide','Moderator-only review note.');await review(reported,'suspend');
   const exported=await post(subject,'/account/export',{password});assert.equal(exported.status,200,JSON.stringify(exported));
   assert.deepEqual(exported.data.reports.map(row=>row.id),[ownReport]);assert.deepEqual(exported.data.blocks.map(row=>row.blocked_user_id),[owner.id]);
   assert.ok(!JSON.stringify(exported.data).includes('Moderator-only review note.'));assert.ok(!JSON.stringify(exported.data).includes('Private report about the subject.'));
   const deleted=await post(subject,'/account/delete',{password,confirmation:'DELETE'});assert.equal(deleted.status,200,JSON.stringify(deleted));
   assert.equal((await db.query('SELECT count(*)::int AS n FROM content_reports WHERE reporter_id=$1 OR subject_user_id=$1',[subject.id])).rows[0].n,0);
   assert.equal((await db.query('SELECT count(*)::int AS n FROM moderation_actions WHERE report_id=ANY($1::uuid[])',[[reported,ownReport]])).rows[0].n,0);
   assert.equal((await db.query('SELECT count(*)::int AS n FROM user_blocks WHERE blocker_id=$1 OR blocked_id=$1',[subject.id])).rows[0].n,0);
   assert.equal((await api('/profile',{actor:subject})).status,401);assert.equal((await api('/profile',{actor:owner})).status,200);
  });
  await t.test('in-flight private image read holds safety gate; block applies before any later image read',async()=>{
   const q=await create(owner,{images:[{name:'pixel.png',content_type:'image/png',data_base64:png}]}),image=(await api(`/questions/${q}`,{actor:reader})).data.question_images[0].image_url;
   let entered,release;const seen=new Promise(resolve=>entered=resolve),resume=new Promise(resolve=>release=resolve);
   const slowStorage={...storage,get:async k=>{entered();await resume;return storage.get(k);}};
   handler=createApp({db,storage:slowStorage,config});
   const pendingImage=api(image);await seen;
   let settled=false;const pendingBlock=post(reader,`/blocks/${owner.id}`).then(r=>{settled=true;return r;});
   let waiting=false;
   for(let i=0;i<50&&!waiting;i++){waiting=(await db.query('SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype=\'advisory\' AND objid=73284129 AND NOT granted) AS waiting')).rows[0].waiting;if(!waiting)await pause(10);}
   assert.equal(waiting,true,'The block waits behind the authorized image read');assert.equal(settled,false);
   release();assert.equal((await pendingImage).status,200);assert.equal((await pendingBlock).status,200);assert.equal((await api(image)).status,404);
   handler=createApp({db,storage,config});await post(reader,`/blocks/${owner.id}/unblock`);
  });
  await t.test('report quota is bounded across concurrent requests and relational cleanup removes private reports',async()=>{
   const reporter=await actor('Bounded reporter'),target=await actor('Synthetic report subject');
   // Fill with synthetic question targets to exercise the real FK and user cap.
   const ids=[];for(let i=0;i<31;i++)ids.push(await create(target));
   for(const id of ids.slice(0,29))await report(reporter,'question',id);
   const attempts=await Promise.all(ids.slice(29).map(id=>post(reporter,'/reports',{target_type:'question',target_id:id,reason:'spam'})));
   assert.deepEqual(attempts.map(r=>r.status).sort(),[201,429]);
   assert.equal((await db.query('SELECT count(*)::int AS n FROM content_reports WHERE reporter_id=$1',[reporter.id])).rows[0].n,30);
   await post(reporter,`/blocks/${target.id}`);
   await db.query('DELETE FROM point_transactions WHERE user_id=$1',[reporter.id]);await db.query('DELETE FROM idempotency_keys WHERE user_id=$1',[reporter.id]);await db.query('DELETE FROM users WHERE id=$1',[reporter.id]);
   assert.equal((await db.query('SELECT count(*)::int AS n FROM content_reports WHERE reporter_id=$1',[reporter.id])).rows[0].n,0);assert.equal((await db.query('SELECT count(*)::int AS n FROM user_blocks WHERE blocker_id=$1',[reporter.id])).rows[0].n,0);
  });
  assert.deepEqual(errors,[],'Unexpected server errors');
 } finally {await db?.close();await pool.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await pool.end();}
});
