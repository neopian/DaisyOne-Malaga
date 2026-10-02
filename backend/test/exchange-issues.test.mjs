import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {nodeServer} from '../src/server.mjs';
import {randomId,randomToken,sha256,hashPassword,sign} from '../src/crypto.mjs';

const secret='exchange-issues-test-signing-secret-at-least-32-characters';
const password='synthetic-exchange-account-password';
const eligiblePath='/exchange-issues/eligible',ownPath='/exchange-issues',adminPath='/admin/exchange-issues';
const eligibleKeys=['question_id','role','title','content_available','status','created_at','updated_at','own_issue_id'].sort();
const ownKeys=['id','question_id','role','reason','details','status','created_at','reviewed_at'].sort();
const adminKeys=['id','question_id','reporter_id','other_participant_id','role','reason','details','status','created_at','reviewed_at','reviewed_by','review_note'].sort();
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const bounded=async(promise,label,ms=8000)=>{
 let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error(`Timed out: ${label}`)),ms);})]);}finally{clearTimeout(timer);}
};

test('real PostgreSQL exchange issues: private intake, immutable review, concurrency and erasure',{timeout:180000},async t=>{
 const connectionString=process.env.TEST_DATABASE_URL;
 assert.ok(connectionString,'Set TEST_DATABASE_URL to a disposable real PostgreSQL database. No in-memory fallback.');
 const pool=new pg.Pool({connectionString,max:2}),schema=`exchange_issues_${randomId().replaceAll('-','')}`;
 let db,server,handler;const errors=[];let imageReads=0;
 const storage={get:async()=>{imageReads++;throw new Error('Issue and preflight routes must never read private image bytes');},delete:async()=>{}};
 const config={imageSigningSecret:secret,onError:error=>errors.push(error)};
 try {
  await pool.query(`CREATE SCHEMA ${schema}`);db=await createDatabase({connectionString,schema});await migrate(db);
  const rebuild=(database=db)=>{handler=createApp({db:database,storage,config});};rebuild();
  server=nodeServer(request=>handler(request));await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}/api`;
  const api=async(path,{actor,method='GET',body,key}={})=>{
   const response=await fetch(`${base}${path}`,{method,headers:{...(actor?{authorization:`Bearer ${actor.token}`} : {}),...(body!==undefined?{'content-type':'application/json'}:{}),...(key!==undefined?{'idempotency-key':key}:{})},...(body!==undefined?{body:JSON.stringify(body)}:{})});
   return {status:response.status,data:await response.json(),cache:response.headers.get('cache-control')};
  };
  const post=(actor,path,body={},key=randomId())=>api(path,{actor,method:'POST',body,key});
  const actor=async({admin=false,suspended=false,helper=false,credentials=false}={})=>{
   const id=randomId(),token=randomToken(),sessionId=randomId();
   await db.query('INSERT INTO users(id,email,name,is_admin,is_suspended,point_balance,email_verified_at) VALUES($1,$2,$3,$4,$5,1000,now())',[id,`${id}@example.invalid`,'Private synthetic participant',admin,suspended]);
   await db.query("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '1 day')",[sessionId,id,await sha256(token)]);
   if(helper){await db.query("INSERT INTO helper_applications(id,user_id,status,introduction,experience_description) VALUES($1,$2,'approved','Private guide introduction','Private guide experience')",[randomId(),id]);await db.query("INSERT INTO helper_regions(id,helper_user_id,country,city) VALUES($1,$2,'Spain','Malaga')",[randomId(),id]);}
   if(credentials)await db.query('INSERT INTO auth_credentials(user_id,password_hash) VALUES($1,$2)',[id,await hashPassword(password)]);
   return {id,token,sessionId};
  };
  const question=async(owner,guide,{status='assigned',hidden=false,created='2026-01-01T00:00:00.123456Z',title='Synthetic private travel title'}={})=>{
   const id=randomId(),escrow=status==='accepted'?'paid':status==='cancelled'?'refunded':'held';
   await db.query(`INSERT INTO questions(id,user_id,assigned_helper_user_id,country,city,category,urgency,title,body,reward_points,status,escrow_state,moderation_hidden,created_at,updated_at)
    VALUES($1,$2,$3,'Spain','Malaga','교통','보통',$4,'PRIVATE-QUESTION-BODY',10,$5,$6,$7,$8,$8)`,[id,owner.id,guide?.id??null,title,status,escrow,hidden,created]);return id;
  };
  const syntheticIssue=async(reporter,other,questionId,{reason='other',details=null,status='open',reviewer=null,note=null,created='2026-01-01T00:00:00.123456Z'}={})=>{
   const id=randomId();await db.query(`INSERT INTO exchange_issues(id,question_id,reporter_id,other_participant_id,reason,details,status,created_at,reviewed_at,reviewed_by,review_note)
    VALUES($1,$2,$3,$4,$5,$6,$7,$8,CASE WHEN $7='reviewed' THEN $8::timestamptz ELSE NULL END,$9,$10)`,[id,questionId,reporter.id,other.id,reason,details,status,created,reviewer?.id??null,note]);return id;
  };
  const page=async(path,who)=>{const result=await api(path,{actor:who});assert.equal(result.status,200,JSON.stringify(result));assert.equal(result.cache,'no-store');assert.deepEqual(Object.keys(result.data).sort(),['items','next_cursor']);return result.data;};
  const collect=async(path,who)=>{
   const items=[];let cursor=null,pages=0;
   do{const result=await page(`${path}${cursor?`${path.includes('?')?'&':'?'}cursor=${encodeURIComponent(cursor)}`:''}`,who);assert.ok(result.items.length<=20);items.push(...result.items);cursor=result.next_cursor;assert.ok(++pages<100,'Keyset pagination must progress');}while(cursor!==null);
   return items;
  };
  const error=(result,status,code)=>{assert.equal(result.status,status,JSON.stringify(result));assert.equal(result.data.error.code,code);assert.deepEqual(Object.keys(result.data),['error']);};
  const issueBody=(id,extra={})=>({question_id:id,reason:'waiting_for_response',...extra});
  const admin=await actor({admin:true});

  await t.test('authentication, active accounts and current admin role precede protected data access',async()=>{
   const traveler=await actor(),guide=await actor({helper:true}),suspended=await actor({admin:true,suspended:true});
   const q=await question(traveler,guide);
   for(const route of [eligiblePath,ownPath,adminPath])error(await api(route),401,'UNAUTHENTICATED');
   error(await post(null,ownPath,issueBody(q)),401,'UNAUTHENTICATED');
   for(const who of [traveler,guide]){
    error(await api(`${adminPath}?limit=100`,{actor:who}),403,'ADMIN_REQUIRED');
    error(await post(who,`${adminPath}/${randomId()}/review`,{note:'private'}),403,'ADMIN_REQUIRED');
   }
   for(const route of [eligiblePath,ownPath,adminPath])error(await api(route,{actor:suspended}),403,'ACCOUNT_SUSPENDED');
   error(await post(suspended,ownPath,issueBody(q)),403,'ACCOUNT_SUSPENDED');
   assert.deepEqual(await page(eligiblePath,admin),{items:[],next_cursor:null},'Admin status does not make unrelated exchanges eligible');
   assert.deepEqual(await page(ownPath,guide),{items:[],next_cursor:null});
  });

  await t.test('eligible lists contain only own held assigned/answered obligations with exact compact fields',async()=>{
   const traveler=await actor(),guide=await actor({helper:true}),stranger=await actor();
   const assigned=await question(traveler,guide),answered=await question(traveler,guide,{status:'answered'});
   for(const status of ['open','accepted','cancelled','expired','disputed','reported'])await question(traveler,status==='open'?null:guide,{status});
   await question(stranger,guide);await question(stranger,await actor());
   const filed=await post(guide,ownPath,issueBody(answered));assert.equal(filed.status,201);
   const rows=(await page(eligiblePath,traveler)).items;
   assert.deepEqual(new Set(rows.map(row=>row.question_id)),new Set([assigned,answered]));
   for(const row of rows){assert.deepEqual(Object.keys(row).sort(),eligibleKeys);assert.equal(row.role,'traveler');assert.equal(row.content_available,true);assert.equal(row.title,'Synthetic private travel title');assert.equal(row.own_issue_id,null);assert.match(row.created_at,/\.123456Z$/);}
   const guideRows=await collect(eligiblePath,guide);assert.equal(guideRows.length,3);assert.ok(guideRows.every(row=>row.role==='guide'));
   assert.equal(guideRows.find(row=>row.question_id===answered).own_issue_id,filed.data.id);
   assert.equal((await page(ownPath,traveler)).items.length,0,'A counterpart issue never becomes my issue');
   const unrelated=await actor();assert.deepEqual(await page(eligiblePath,unrelated),{items:[],next_cursor:null});
   const serialized=JSON.stringify(guideRows);for(const value of ['PRIVATE-QUESTION-BODY','example.invalid',traveler.token,'point_balance','assigned_helper_user_id'])assert.ok(!serialized.includes(value),value);
  });

  await t.test('direct eligible lookup reaches an own exchange beyond the first page with exact scoped fields',async()=>{
   const traveler=await actor(),guide=await actor(),stranger=await actor();
   for(let n=0;n<25;n++)await question(traveler,guide);
   const q=await question(traveler,guide,{status:'answered',created:'2026-06-01T00:00:00.123456Z'});
   const travelerIssue=await syntheticIssue(traveler,guide,q),guideIssue=await syntheticIssue(guide,traveler,q);
   assert.ok(!(await page(eligiblePath,traveler)).items.some(row=>row.question_id===q),'Known question is outside the initial page');
   for(const [who,ownIssue,role] of [[traveler,travelerIssue,'traveler'],[guide,guideIssue,'guide']]){
    const result=await api(`${eligiblePath}/${q}`,{actor:who});assert.equal(result.status,200);assert.equal(result.cache,'no-store');
    assert.deepEqual(Object.keys(result.data).sort(),eligibleKeys);assert.equal(result.data.role,role);assert.equal(result.data.own_issue_id,ownIssue);
    assert.deepEqual(result.data,(await collect(eligiblePath,who)).find(row=>row.question_id===q));
   }
   error(await api(`${eligiblePath}/${q}`),401,'UNAUTHENTICATED');
   for(const who of [stranger,admin])error(await api(`${eligiblePath}/${q}`,{actor:who}),404,'NOT_FOUND');
   error(await api(`${eligiblePath}/${randomId()}`,{actor:traveler}),404,'NOT_FOUND');
   error(await api(`${eligiblePath}/invalid-id`,{actor:traveler}),400,'INVALID_ID');
   for(const query of ['cursor=ignored','status=assigned','question_id='+q,'cursor=a&cursor=b'])error(await api(`${eligiblePath}/${q}?${query}`,{actor:traveler}),400,'INVALID_EXCHANGE_ISSUES_QUERY');
   for(const status of ['open','accepted','cancelled','expired','disputed','reported']){
    const id=await question(traveler,status==='open'?null:guide,{status});
    for(const who of [traveler,guide])error(await api(`${eligiblePath}/${id}`,{actor:who}),404,'NOT_FOUND');
   }
   await db.query('UPDATE users SET is_suspended=true WHERE id=$1',[traveler.id]);
   error(await api(`${eligiblePath}/${q}`,{actor:traveler}),403,'ACCOUNT_SUSPENDED');
  });

  await t.test('hidden, bilateral blocked and suspended-counterpart exchanges retain safe intake even for admin participants',async()=>{
   for(const kind of ['hidden','traveler-blocks','guide-blocks','guide-suspended','traveler-suspended']){
    const traveler=await actor({admin:true}),guide=await actor({admin:true,helper:true});
    const q=await question(traveler,guide,{hidden:kind==='hidden'});
    if(kind==='traveler-blocks'||kind==='guide-blocks')await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',kind==='traveler-blocks'?[traveler.id,guide.id]:[guide.id,traveler.id]);
    if(kind.endsWith('-suspended'))await db.query('UPDATE users SET is_suspended=true WHERE id=$1',[kind==='guide-suspended'?guide.id:traveler.id]);
    const reporters=kind==='guide-suspended'?[traveler]:kind==='traveler-suspended'?[guide]:[traveler,guide];
    for(const who of reporters){
     const row=(await page(eligiblePath,who)).items[0];assert.equal(row.question_id,q,kind);assert.equal(row.content_available,false,kind);assert.equal(row.title,null,kind);
     const direct=await api(`${eligiblePath}/${q}`,{actor:who});assert.equal(direct.status,200);assert.deepEqual(direct.data,row,kind+' direct lookup has identical safe redaction');
     const result=await post(who,ownPath,issueBody(q,{reason:'cannot_continue'}));assert.equal(result.status,201,JSON.stringify(result));
     assert.equal((await page(eligiblePath,who)).items[0].own_issue_id,result.data.id);
     assert.equal((await api(`${eligiblePath}/${q}`,{actor:who})).data.own_issue_id,result.data.id);
    }
   }
   const traveler=await actor(),guide=await actor({helper:true}),q=await question(traveler,guide);
   await db.query("UPDATE helper_applications SET status='suspended' WHERE user_id=$1",[guide.id]);
   assert.equal((await page(eligiblePath,guide)).items[0].question_id,q,'Application restrictions do not erase an already assigned obligation');
   assert.equal((await post(guide,ownPath,issueBody(q))).status,201);
  });

  await t.test('intake validates a bounded normalized intent and enforces participant and lifecycle authorization',async()=>{
   const traveler=await actor(),guide=await actor(),stranger=await actor();const q=await question(traveler,guide),body=issueBody(q);
   error(await api(ownPath,{actor:traveler,method:'POST',body}),400,'IDEMPOTENCY_KEY_REQUIRED');
   error(await post(traveler,ownPath,body,'short'),400,'INVALID_IDEMPOTENCY_KEY');
   error(await post(traveler,ownPath,issueBody(q,{details:'invalid\0text'})),400,'VALIDATION');
   error(await post(traveler,ownPath,issueBody(q,{details:'x'.repeat(8193)})),413,'PAYLOAD_TOO_LARGE');
   for(const invalid of [{},issueBody('bad-id'),issueBody(q,{reason:'spam'}),issueBody(q,{details:'x'.repeat(1001)}),issueBody(q,{details:123}),issueBody(q,{status:'reviewed'}),issueBody(q,{reporter_id:guide.id})])assert.equal((await post(traveler,ownPath,invalid)).status,400,JSON.stringify(invalid));
   error(await post(stranger,ownPath,body),404,'NOT_FOUND');error(await post(admin,ownPath,body),404,'NOT_FOUND');error(await post(traveler,ownPath,issueBody(randomId())),404,'NOT_FOUND');
   for(const status of ['open','accepted','cancelled','expired','disputed','reported']){
    const id=await question(traveler,status==='open'?null:guide,{status});error(await post(traveler,ownPath,issueBody(id)),409,'EXCHANGE_NOT_ELIGIBLE');
   }
   for(const reason of ['waiting_for_response','answer_problem','cannot_continue','other']){
    const id=await question(traveler,guide),result=await post(traveler,ownPath,issueBody(id,{reason,details:'  '+'x'.repeat(1000)+'  '}));assert.equal(result.status,201,JSON.stringify(result));
    const row=(await db.query('SELECT reason,details FROM exchange_issues WHERE id=$1',[result.data.id])).rows[0];assert.deepEqual(row,{reason,details:'x'.repeat(1000)});
   }
   for(const details of [undefined,null,'','   ']){
    const id=await question(traveler,guide);const result=await post(traveler,ownPath,issueBody(id,{details}));assert.equal(result.status,201,JSON.stringify(result));assert.equal((await db.query('SELECT details FROM exchange_issues WHERE id=$1',[result.data.id])).rows[0].details,null);
   }
  });

  await t.test('concurrent same-key and distinct-key filings create one issue per reporter and preserve normalized intent',async()=>{
   const traveler=await actor(),guide=await actor(),q=await question(traveler,guide),key=randomId(),body=issueBody(q,{details:'  Please review this exchange.  '});
   const same=await Promise.all([post(traveler,ownPath,body,key),post(traveler,ownPath,body,key)]);assert.equal(same[0].status,201);assert.deepEqual(same[0],same[1]);
   assert.deepEqual((await db.query('SELECT response_body FROM idempotency_keys WHERE user_id=$1 AND key=$2',[traveler.id,key])).rows[0].response_body,{id:same[0].data.id},'Creation retry storage contains only a safe reference');
   const duplicate=await post(traveler,ownPath,{...body,details:'Please review this exchange.'});assert.equal(duplicate.status,200);assert.deepEqual(duplicate.data,same[0].data);assert.deepEqual(Object.keys(duplicate.data),['id']);
   error(await post(traveler,ownPath,{...body,reason:'other'},key),409,'IDEMPOTENCY_CONFLICT');
   for(const change of [{reason:'other'},{details:'Changed request'}])error(await post(traveler,ownPath,{...body,...change}),409,'ISSUE_ALREADY_EXISTS');
   const q2=await question(traveler,guide);const many=await Promise.all(Array.from({length:8},()=>post(traveler,ownPath,issueBody(q2))));
   assert.equal(many.filter(result=>result.status===201).length,1);assert.equal(many.filter(result=>result.status===200).length,7);assert.equal(new Set(many.map(result=>result.data.id)).size,1);
   const other=await post(guide,ownPath,issueBody(q));assert.equal(other.status,201);assert.notEqual(other.data.id,same[0].data.id);
   assert.equal((await db.query('SELECT count(*)::int AS n FROM exchange_issues WHERE question_id=$1',[q])).rows[0].n,2);
   await db.query("UPDATE questions SET status='accepted',escrow_state='paid' WHERE id=$1",[q]);
   assert.equal((await post(traveler,ownPath,{...body,details:'Please review this exchange.'})).status,200,'Existing normalized intent remains harmless after settlement');
   assert.deepEqual((await post(traveler,ownPath,body,key)).data,same[0].data,'Same-key replay remains stable after settlement');
   error(await post(traveler,ownPath,{...body,details:'Changed after completion'}),409,'ISSUE_ALREADY_EXISTS');
   assert.ok(!(await collect(eligiblePath,traveler)).some(row=>row.question_id===q));
   assert.ok((await collect(ownPath,traveler)).some(row=>row.id===same[0].data.id),'History survives completion');
  });

  await t.test('current participation is checked before cached creation replay',async()=>{
   const traveler=await actor(),guide=await actor(),replacement=await actor(),q=await question(traveler,guide),key=randomId(),body=issueBody(q);
   assert.equal((await post(guide,ownPath,body,key)).status,201);
   await db.query('UPDATE questions SET assigned_helper_user_id=$2 WHERE id=$1',[q,replacement.id]);
   error(await post(guide,ownPath,body,key),404,'NOT_FOUND');error(await post(guide,ownPath,body),404,'NOT_FOUND');
   assert.deepEqual((await page(eligiblePath,guide)).items,[]);
  });

  await t.test('thirty-new-issues daily quota is atomic across distinct keys and duplicates do not consume capacity',async()=>{
   const traveler=await actor(),guide=await actor();const ids=[];
   for(let n=0;n<32;n++)ids.push(await question(traveler,guide));
   for(const q of ids.slice(0,29))assert.equal((await post(traveler,ownPath,issueBody(q))).status,201);
   const duplicates=await Promise.all(Array.from({length:5},()=>post(traveler,ownPath,issueBody(ids[0]))));assert.ok(duplicates.every(result=>result.status===200));
   const race=await Promise.all(ids.slice(29).map(q=>post(traveler,ownPath,issueBody(q))));assert.deepEqual(race.map(result=>result.status).sort(),[201,429,429]);
   for(const result of race.filter(result=>result.status===429))assert.equal(result.data.error.code,'ISSUE_LIMIT');
   assert.equal((await db.query('SELECT count(*)::int AS n FROM exchange_issues WHERE reporter_id=$1',[traveler.id])).rows[0].n,30);
   assert.equal((await post(traveler,ownPath,issueBody(ids[0]))).status,200,'Even a full quota permits an identical existing intent');
   const unfiled=ids.find((_,index)=>index>=29&&race[index-29].status===429);
   await db.query("UPDATE exchange_issues SET created_at=now()-interval '25 hours' WHERE reporter_id=$1",[traveler.id]);
   assert.equal((await post(traveler,ownPath,issueBody(unfiled))).status,201,'Only the current trailing 24 hours count');
   assert.equal((await post(guide,ownPath,issueBody(ids[0]))).status,201,'Quota is per reporter');
  });

  await t.test('own history contains only own safe fields, while admin queues expose only compact issue metadata',async()=>{
   const traveler=await actor(),guide=await actor(),q=await question(traveler,guide),privateNote='PRIVATE-OPERATOR-NOTE';
   const own=await syntheticIssue(traveler,guide,q,{details:'TRAVELER-PRIVATE-DETAILS',status:'reviewed',reviewer:admin,note:privateNote});
   const other=await syntheticIssue(guide,traveler,q,{details:'GUIDE-PRIVATE-DETAILS'});
   await db.query("INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,'PRIVATE-ANSWER','PRIVATE-EVIDENCE','PRIVATE-METHOD')",[randomId(),q,guide.id]);
   await db.query("INSERT INTO question_comments(id,question_id,user_id,body) VALUES($1,$2,$3,'PRIVATE-COMMENT')",[randomId(),q,guide.id]);
   await db.query("INSERT INTO question_images(id,question_id,storage_key,content_type,byte_length) VALUES($1,$2,'private-exchange-image','image/png',10)",[randomId(),q]);
   const history=(await page(ownPath,traveler)).items;assert.equal(history.length,1);assert.equal(history[0].id,own);assert.equal(history[0].status,'reviewed');assert.equal(history[0].role,'traveler');assert.ok(history[0].reviewed_at);assert.deepEqual(Object.keys(history[0]).sort(),ownKeys);
   assert.ok(!JSON.stringify(history).includes(privateNote));assert.ok(!JSON.stringify(history).includes('GUIDE-PRIVATE-DETAILS'));
   const detail=await api(`${ownPath}/${own}`,{actor:traveler});assert.equal(detail.status,200);assert.deepEqual(detail.data,history[0]);assert.equal(detail.cache,'no-store');
   for(const who of [guide,admin,await actor()])error(await api(`${ownPath}/${own}`,{actor:who}),404,'NOT_FOUND');
   error(await api(`${ownPath}/${own}`),401,'UNAUTHENTICATED');error(await api(`${ownPath}/${randomId()}`,{actor:traveler}),404,'NOT_FOUND');
   error(await api(`${ownPath}/${own}?include_notes=true`,{actor:traveler}),400,'INVALID_EXCHANGE_ISSUES_QUERY');
   const opened=(await collect(adminPath,admin)).find(row=>row.id===other),reviewed=(await collect(`${adminPath}?status=reviewed`,admin)).find(row=>row.id===own);
   assert.equal(opened.role,'guide');assert.equal(opened.reporter_id,guide.id);assert.equal(opened.other_participant_id,traveler.id);assert.equal(opened.review_note,null);assert.equal(reviewed.review_note,privateNote);assert.equal(reviewed.reviewed_by,admin.id);
   for(const row of [opened,reviewed])assert.deepEqual(Object.keys(row).sort(),adminKeys);
   const serialized=JSON.stringify([opened,reviewed]);for(const value of ['PRIVATE-QUESTION-BODY','Synthetic private travel title','PRIVATE-ANSWER','PRIVATE-EVIDENCE','PRIVATE-METHOD','PRIVATE-COMMENT','private-exchange-image','example.invalid',traveler.token,guide.token])assert.ok(!serialized.includes(value),value);
   assert.equal(imageReads,0);
  });

  await t.test('eligible/operator pages are oldest first and own history newest first with microseconds and UUID ties',async()=>{
   const traveler=await actor(),guide=await actor();
   await db.query(`WITH created AS (
    INSERT INTO questions(id,user_id,assigned_helper_user_id,country,city,category,urgency,title,body,reward_points,status,escrow_state,created_at,updated_at)
    SELECT gen_random_uuid(),$1,$2,'Spain','Malaga','교통','보통','Paged exchange','Private body',10,'assigned','held',
     '2026-01-01T00:00:00.123001Z'::timestamptz+floor(n/3)*interval '1 microsecond','2026-01-01T00:00:00.123001Z'::timestamptz FROM generate_series(0,66) n RETURNING id,created_at
   ) INSERT INTO exchange_issues(id,question_id,reporter_id,other_participant_id,reason,created_at)
    SELECT gen_random_uuid(),id,$1,$2,'other',created_at FROM created`,[traveler.id,guide.id]);
   const eligible=await collect(eligiblePath,traveler),own=await collect(ownPath,traveler);
   assert.equal(eligible.length,67);assert.equal(own.length,67);
   assert.deepEqual(eligible.map(row=>row.question_id),(await db.query('SELECT id FROM questions WHERE user_id=$1 ORDER BY created_at,id',[traveler.id])).rows.map(row=>row.id));
   assert.deepEqual(own.map(row=>row.id),(await db.query('SELECT id FROM exchange_issues WHERE reporter_id=$1 ORDER BY created_at DESC,id DESC',[traveler.id])).rows.map(row=>row.id));
   for(const rows of [eligible,own]){assert.equal(new Set(rows.map(row=>row.id??row.question_id)).size,67);assert.ok(rows.every(row=>/^2026-01-01T00:00:00\.123\d{3}Z$/.test(row.created_at)));}
   const operators=await collect(adminPath,admin);assert.deepEqual(operators.map(row=>row.id),(await db.query("SELECT id FROM exchange_issues WHERE status='open' ORDER BY created_at,id")).rows.map(row=>row.id));
   const first=await page(eligiblePath,traveler);assert.equal(first.items.length,20);assert.equal(typeof first.next_cursor,'string');
   const old=await question(traveler,guide,{created:'2025-01-01T00:00:00.000001Z'});assert.ok(old);
   assert.deepEqual((await page(`${eligiblePath}?cursor=${first.next_cursor}`,traveler)).items.map(row=>row.question_id),eligible.slice(20,40).map(row=>row.question_id),'New earlier work does not shift the next keyset page');
   const exact=await actor();for(let n=0;n<20;n++)await question(exact,guide);
   assert.equal((await page(eligiblePath,exact)).next_cursor,null,'Exactly twenty rows have no next page');
  });

  await t.test('strict signed cursors bind the exact user, view and status with no unknown query fields',async()=>{
   const traveler=await actor(),guide=await actor(),otherAdmin=await actor({admin:true});
   for(let n=0;n<21;n++){const q=await question(traveler,guide);await syntheticIssue(traveler,guide,q);}
   const eligible=(await page(eligiblePath,traveler)).next_cursor,own=(await page(ownPath,traveler)).next_cursor,queue=(await page(adminPath,admin)).next_cursor;
   for(const route of [eligiblePath,ownPath,adminPath])for(const query of ['limit=100','offset=1','user_id='+traveler.id,'cursor=a&cursor=b','status=open&status=reviewed'])error(await api(`${route}?${query}`,{actor:route===adminPath?admin:traveler}),400,'INVALID_EXCHANGE_ISSUES_QUERY');
   for(const route of [eligiblePath,ownPath])error(await api(`${route}?status=open`,{actor:traveler}),400,'INVALID_EXCHANGE_ISSUES_QUERY');
   for(const status of ['','all','assigned','OPEN','open '])error(await api(`${adminPath}?status=${encodeURIComponent(status)}`,{actor:admin}),400,'INVALID_EXCHANGE_ISSUES_QUERY');
   for(const value of ['', 'a','not.a.cursor',eligible+'.extra',eligible+'=',eligible.slice(0,-1)+(eligible.endsWith('A')?'B':'A'),'x'.repeat(1025)])error(await api(`${eligiblePath}?cursor=${encodeURIComponent(value)}`,{actor:traveler}),400,'INVALID_EXCHANGE_ISSUES_CURSOR');
   for(const [route,who,cursor] of [[eligiblePath,guide,eligible],[ownPath,traveler,eligible],[eligiblePath,traveler,own],[adminPath,otherAdmin,queue],[`${adminPath}?status=reviewed`,admin,queue],[ownPath,admin,queue]])error(await api(`${route}${route.includes('?')?'&':'?'}cursor=${cursor}`,{actor:who}),400,'INVALID_EXCHANGE_ISSUES_CURSOR');
   const payload=JSON.parse(Buffer.from(eligible.split('.')[0],'base64url').toString());assert.deepEqual(Object.keys(payload).sort(),['v','user','view','status','created_at','id'].sort());assert.equal(payload.status,null);
   for(const changes of [{v:2},{user:guide.id},{view:'unknown'},{status:'open'},{created_at:'2026-02-30T00:00:00.123456Z'},{created_at:'0000-01-01T00:00:00.123456Z'},{created_at:'2026-01-01T00:00:00.123Z'},{created_at:'infinity'},{id:'not-a-uuid'},{extra:true}]){
    const encoded=Buffer.from(JSON.stringify({...payload,...changes})).toString('base64url'),signed=`${encoded}.${await sign(secret,`malaga-exchange-issues-v1:${encoded}`)}`;
    error(await api(`${eligiblePath}?cursor=${signed}`,{actor:traveler}),400,'INVALID_EXCHANGE_ISSUES_CURSOR');
   }
   const missing={...payload};delete missing.status;
   for(const [value,domain] of [[missing,'malaga-exchange-issues-v1:'],[payload,'malaga-activity-v1:']]){
    const encoded=Buffer.from(JSON.stringify(value)).toString('base64url');error(await api(`${eligiblePath}?cursor=${encoded}.${await sign(secret,`${domain}${encoded}`)}`,{actor:traveler}),400,'INVALID_EXCHANGE_ISSUES_CURSOR');
   }
  });

  await t.test('first review is immutable; normalized retries succeed and conflicting concurrent reviewers lose',async()=>{
   const traveler=await actor(),guide=await actor(),otherAdmin=await actor({admin:true}),q=await question(traveler,guide),id=await syntheticIssue(traveler,guide,q),route=`${adminPath}/${id}/review`;
   error(await api(route,{actor:admin,method:'POST',body:{note:'A private note'}}),400,'IDEMPOTENCY_KEY_REQUIRED');
   error(await post(admin,route,{note:'invalid\0text'}),400,'VALIDATION');error(await post(admin,route,{note:'x'.repeat(8193)}),413,'PAYLOAD_TOO_LARGE');
   for(const body of [{note:123},{note:'x'.repeat(1001)},{status:'reviewed'},{action:'refund'}])assert.equal((await post(admin,route,body)).status,400);
   error(await post(admin,`${adminPath}/${randomId()}/review`,{}),404,'NOT_FOUND');
   const body={note:'  A private immutable review.  '},key=randomId();
   const same=await Promise.all([post(admin,route,body,key),post(admin,route,body,key)]);assert.equal(same[0].status,200);assert.deepEqual(same[0],same[1]);assert.deepEqual(same[0].data,{ok:true});
   assert.deepEqual((await db.query('SELECT response_body FROM idempotency_keys WHERE user_id=$1 AND key=$2',[admin.id,key])).rows[0].response_body,{ok:true},'Review retry storage never duplicates private notes');
   const original=(await db.query('SELECT * FROM exchange_issues WHERE id=$1',[id])).rows[0];assert.equal(original.status,'reviewed');assert.equal(original.review_note,'A private immutable review.');assert.equal(original.reviewed_by,admin.id);assert.ok(original.reviewed_at);
   assert.equal((await post(admin,route,{note:'A private immutable review.'})).status,200);
   error(await post(admin,route,{note:'Changed review'},key),409,'IDEMPOTENCY_CONFLICT');error(await post(admin,route,{note:'Changed review'}),409,'ISSUE_ALREADY_REVIEWED');error(await post(otherAdmin,route,{note:'A private immutable review.'}),409,'ISSUE_ALREADY_REVIEWED');
   assert.deepEqual((await db.query('SELECT * FROM exchange_issues WHERE id=$1',[id])).rows[0],original);
   const q2=await question(traveler,guide),id2=await syntheticIssue(traveler,guide,q2),route2=`${adminPath}/${id2}/review`;
   const race=await Promise.all([post(admin,route2,{note:'First reviewer'}),post(otherAdmin,route2,{note:'Second reviewer'})]);assert.deepEqual(race.map(result=>result.status).sort(),[200,409]);assert.equal(race.find(result=>result.status===409).data.error.code,'ISSUE_ALREADY_REVIEWED');
   const winner=(await db.query('SELECT reviewed_by,review_note FROM exchange_issues WHERE id=$1',[id2])).rows[0];assert.deepEqual(winner,race[0].status===200?{reviewed_by:admin.id,review_note:'First reviewer'}:{reviewed_by:otherAdmin.id,review_note:'Second reviewer'});
   const q3=await question(traveler,guide),id3=await syntheticIssue(traveler,guide,q3);assert.equal((await post(admin,`${adminPath}/${id3}/review`,{})).status,200);assert.equal((await post(admin,`${adminPath}/${id3}/review`,{note:null})).status,200);assert.equal((await post(admin,`${adminPath}/${id3}/review`,{note:'   '})).status,200);
  });

  await t.test('post-authentication revocation, suspension, deletion and session expiry defeat reads and cached replays',async()=>{
   const gated=async(who,request,change)=>{
    let seen;const authenticated=new Promise(resolve=>{seen=resolve;});
    const wrapped={...db,query:async(sql,params)=>{const result=await db.query(sql,params);if(sql==='SELECT * FROM users WHERE id=$1'&&params[0]===who.id)seen();return result;}};
    let pending;rebuild(wrapped);
    try{
     await db.transaction(async tx=>{await tx.query('SELECT pg_advisory_xact_lock(73284129)');pending=request();await bounded(authenticated,'request authenticates before gate');await change(tx);});
     return await bounded(pending,'gated response');
    }finally{rebuild();}
   };
   for(const change of ['revoke','suspend','delete','session-delete','session-expire']){
    const who=await actor({admin:true}),traveler=await actor(),guide=await actor(),q=await question(traveler,guide),id=await syntheticIssue(traveler,guide,q),key=randomId(),route=`${adminPath}/${id}/review`,body={note:'Original review'};
    assert.equal((await post(who,route,body,key)).status,200);
    const mutate=async tx=>{if(change==='revoke')await tx.query('UPDATE users SET is_admin=false WHERE id=$1',[who.id]);else if(change==='suspend')await tx.query('UPDATE users SET is_suspended=true WHERE id=$1',[who.id]);else if(change==='delete'){await tx.query('DELETE FROM idempotency_keys WHERE user_id=$1',[who.id]);await tx.query('DELETE FROM users WHERE id=$1',[who.id]);}else if(change==='session-delete')await tx.query('DELETE FROM sessions WHERE user_id=$1',[who.id]);else await tx.query("UPDATE sessions SET expires_at=now()-interval '1 second' WHERE user_id=$1",[who.id]);};
    const result=await gated(who,()=>post(who,route,body,key),mutate);error(result,['revoke','suspend'].includes(change)?403:401,change==='revoke'?'ADMIN_REQUIRED':change==='suspend'?'ACCOUNT_SUSPENDED':'UNAUTHENTICATED');
   }
   for(const route of [eligiblePath,ownPath,adminPath,`${ownPath}/${randomId()}`,`${eligiblePath}/${randomId()}`]){
    const who=await actor({admin:true});const result=await gated(who,()=>api(route,{actor:who}),tx=>tx.query('DELETE FROM sessions WHERE user_id=$1',[who.id]));error(result,401,'UNAUTHENTICATED');
   }
   for(const change of ['session-delete','session-expire','suspend','reassign','complete','hide']){
    const traveler=await actor(),guide=await actor(),replacement=await actor(),q=await question(traveler,guide),who=change==='reassign'?guide:traveler;
    const result=await gated(who,()=>api(`${eligiblePath}/${q}`,{actor:who}),async tx=>{
     if(change==='session-delete')await tx.query('DELETE FROM sessions WHERE user_id=$1',[who.id]);
     else if(change==='session-expire')await tx.query("UPDATE sessions SET expires_at=now()-interval '1 second' WHERE user_id=$1",[who.id]);
     else if(change==='suspend')await tx.query('UPDATE users SET is_suspended=true WHERE id=$1',[who.id]);
     else if(change==='reassign')await tx.query('UPDATE questions SET assigned_helper_user_id=$2 WHERE id=$1',[q,replacement.id]);
     else if(change==='complete')await tx.query("UPDATE questions SET status='accepted',escrow_state='paid' WHERE id=$1",[q]);
     else await tx.query('UPDATE questions SET moderation_hidden=true WHERE id=$1',[q]);
    });
    if(change==='hide'){assert.equal(result.status,200);assert.equal(result.data.title,null);assert.equal(result.data.content_available,false);}
    else error(result,change.startsWith('session-')?401:change==='suspend'?403:404,change.startsWith('session-')?'UNAUTHENTICATED':change==='suspend'?'ACCOUNT_SUSPENDED':'NOT_FOUND');
   }
   for(const change of ['suspend','session-delete']){
    const traveler=await actor(),guide=await actor(),q=await question(traveler,guide),body=issueBody(q),key=randomId();assert.equal((await post(traveler,ownPath,body,key)).status,201);
    const result=await gated(traveler,()=>post(traveler,ownPath,body,key),tx=>change==='suspend'?tx.query('UPDATE users SET is_suspended=true WHERE id=$1',[traveler.id]):tx.query('DELETE FROM sessions WHERE user_id=$1',[traveler.id]));error(result,change==='suspend'?403:401,change==='suspend'?'ACCOUNT_SUSPENDED':'UNAUTHENTICATED');
   }
  });

  await t.test('sessions expiring after transaction start while waiting for the safety gate cannot read or replay',async()=>{
   for(const operation of ['own-list','eligible-list','own-detail','eligible-detail','admin-list','create-replay','review-replay']){
    const traveler=await actor(),guide=await actor(),reviewer=await actor({admin:true}),q=await question(traveler,guide);
    const body=issueBody(q,{details:'PRIVATE-EXPIRING-SESSION-INTENT'}),createKey=randomId(),created=await post(traveler,ownPath,body,createKey);
    assert.equal(created.status,201);const id=created.data.id,reviewKey=randomId(),reviewBody={note:'PRIVATE-EXPIRING-SESSION-REVIEW'};
    if(operation==='review-replay')assert.equal((await post(reviewer,`${adminPath}/${id}/review`,reviewBody,reviewKey)).status,200);
    const who=['admin-list','review-replay'].includes(operation)?reviewer:traveler;
    const request=()=>operation==='create-replay'?post(who,ownPath,body,createKey):operation==='review-replay'?post(who,`${adminPath}/${id}/review`,reviewBody,reviewKey):
     api(operation==='own-list'?ownPath:operation==='eligible-list'?eligiblePath:operation==='own-detail'?`${ownPath}/${id}`:operation==='eligible-detail'?`${eligiblePath}/${q}`:adminPath,{actor:who});
    const snapshot=async()=>{const result={};for(const table of ['exchange_issues','idempotency_keys','questions','answers','point_transactions','users','helper_applications','user_blocks'])result[table]=(await db.query(`SELECT row_to_json(t)::text AS row FROM ${table} t ORDER BY row_to_json(t)::text`)).rows;return result;};
    const before=await snapshot();let attempted,transactionStarted,pending,seenGate=false;
    const gateAttempt=new Promise(resolve=>attempted=resolve);
    const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
     if(!seenGate&&sql==='SELECT pg_advisory_xact_lock_shared(73284129)'){
      seenGate=true;transactionStarted=(await tx.query('SELECT transaction_timestamp()::text AS started_at')).rows[0].started_at;
      // Initial bearer authentication has finished, and BEGIN has happened.
      // Signal this exact lock attempt rather than racing the earlier auth read.
      attempted();
     }
     return tx.query(sql,params);
    }}))};
    rebuild(wrapped);
    try{
     await db.transaction(async tx=>{
      await tx.query('SELECT pg_advisory_xact_lock(73284129)');pending=request();await bounded(gateAttempt,operation+' begins its shared-gate wait');
      const expiry=(await tx.query("UPDATE sessions SET expires_at=clock_timestamp()+interval '30 milliseconds' WHERE id=$1 RETURNING expires_at>$2::timestamptz AS after_transaction_start",[who.sessionId,transactionStarted])).rows[0];
      assert.equal(expiry.after_transaction_start,true,'Expiry is after request transaction start, so now() would incorrectly consider the session live');
      await bounded((async()=>{
       while(!(await tx.query('SELECT clock_timestamp()>=expires_at AS expired FROM sessions WHERE id=$1',[who.sessionId])).rows[0].expired)await pause(5);
      })(),operation+' session expires while gate is held');
     });
     error(await bounded(pending,operation+' after gate release'),401,'UNAUTHENTICATED');
     assert.deepEqual(await snapshot(),before,operation+' cannot change records, cached responses or exchange/financial state');
    }finally{rebuild();if(pending)await pending;}
   }
  });

  await t.test('live admin row is held FOR SHARE through queue reads and review writes',async()=>{
   for(const operation of ['list','review']){
    const reviewer=await actor({admin:true}),traveler=await actor(),guide=await actor(),q=await question(traveler,guide),id=await syntheticIssue(traveler,guide,q);let entered,release,paused=false;
    const reached=new Promise(resolve=>entered=resolve),resume=new Promise(resolve=>release=resolve);
    const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
     const result=await tx.query(sql,params);
     if(!paused&&sql.includes('FROM users')&&/FOR SHARE/i.test(sql)&&params?.includes(reviewer.id)){paused=true;entered();await resume;}return result;
    }}))};
    rebuild(wrapped);let request,revocation;
    try{
     request=operation==='list'?api(adminPath,{actor:reviewer}):post(reviewer,`${adminPath}/${id}/review`,{note:'Review under live role lock'});
     await bounded(reached,'administrator row share lock');
     let updated=false;revocation=db.query('UPDATE users SET is_admin=false WHERE id=$1',[reviewer.id]).then(result=>{updated=true;return result;});
     let waiting=false;
     for(let n=0;n<60&&!waiting;n++){waiting=(await db.query("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE 'UPDATE users SET is_admin=false%') AS waiting")).rows[0].waiting;if(!waiting)await pause(10);}
     assert.equal(waiting,true,'Trusted SQL revocation waits until the authorized operation finishes');assert.equal(updated,false);release();assert.equal((await bounded(request,'authorized operation')).status,200);await bounded(revocation,'role revocation');
    }finally{release();rebuild();if(request)await request;if(revocation)await revocation;}
    error(await api(adminPath,{actor:reviewer}),403,'ADMIN_REQUIRED');
   }
  });

  await t.test('guide intake queues behind acceptance before locking the guide balance row',async()=>{
   const traveler=await actor(),guide=await actor(),q=await question(traveler,guide,{status:'answered'}),answerId=randomId();
   await db.query("INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,'Lock-order answer','Synthetic evidence','Synthetic check')",[answerId,q,guide.id]);
   let reached,release,held=false;const locked=new Promise(resolve=>reached=resolve),resume=new Promise(resolve=>release=resolve);
   const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    const result=await tx.query(sql,params);if(!held&&/FROM questions.*FOR UPDATE/.test(sql)&&params?.includes(q)){held=true;reached();await resume;}return result;
   }}))};
   rebuild(wrapped);let accepting,filing;
   try{
    accepting=post(traveler,`/questions/${q}/answers/${answerId}/accept`,{});await bounded(locked,'acceptance question lock');
    filing=post(guide,ownPath,issueBody(q));let waiting=false;
    for(let n=0;n<80&&!waiting;n++){waiting=(await db.query("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE wait_event_type='Lock' AND query LIKE 'SELECT id,user_id,assigned_helper_user_id,status,escrow_state FROM questions%') AS waiting")).rows[0].waiting;if(!waiting)await pause(10);}
    assert.equal(waiting,true,'Guide intake is waiting on the accepted question');release();
    const [accepted,filed]=await bounded(Promise.all([accepting,filing]),'question-before-guide lock ordering',12000);assert.equal(accepted.status,200,JSON.stringify(accepted));error(filed,409,'EXCHANGE_NOT_ELIGIBLE');
   }finally{release();rebuild();if(accepting)await accepting;if(filing)await filing;}
   assert.equal((await db.query('SELECT point_balance FROM users WHERE id=$1',[guide.id])).rows[0].point_balance,1010);
   assert.equal((await db.query("SELECT count(*)::int AS n FROM point_transactions WHERE question_id=$1 AND type='reward'",[q])).rows[0].n,1);
   assert.equal((await db.query('SELECT count(*)::int AS n FROM exchange_issues WHERE question_id=$1',[q])).rows[0].n,0);
  });

  await t.test('cross-route reuse of one owner idempotency key queues before question locking and cannot deadlock',async()=>{
   const traveler=await actor(),guide=await actor(),q=await question(traveler,guide,{status:'answered'}),answerId=randomId(),key=randomId();
   await db.query("INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,'Cross-route answer','Synthetic evidence','Synthetic check')",[answerId,q,guide.id]);
   let reached,release,held=false;const locked=new Promise(resolve=>reached=resolve),resume=new Promise(resolve=>release=resolve);
   const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    const result=await tx.query(sql,params);if(!held&&/FROM questions.*FOR SHARE/.test(sql)&&params?.includes(q)){held=true;reached();await resume;}return result;
   }}))};
   rebuild(wrapped);let filing,accepting;
   try{
    filing=post(traveler,ownPath,issueBody(q),key);await bounded(locked,'intake holds question and idempotency key');
    accepting=post(traveler,`/questions/${q}/answers/${answerId}/accept`,{},key);let waiting=false;
    for(let n=0;n<80&&!waiting;n++){waiting=(await db.query("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE wait_event_type='Lock' AND (query LIKE 'INSERT INTO idempotency_keys%' OR query LIKE 'SELECT * FROM questions%')) AS waiting")).rows[0].waiting;if(!waiting)await pause(10);}
    assert.equal(waiting,true,'Second route waits behind the existing idempotency operation');release();
    const [filed,accepted]=await bounded(Promise.all([filing,accepting]),'cross-route same-key ordering',12000);assert.equal(filed.status,201,JSON.stringify(filed));error(accepted,409,'IDEMPOTENCY_CONFLICT');
   }finally{release();rebuild();if(filing)await filing;if(accepting)await accepting;}
   assert.deepEqual((await db.query('SELECT status,escrow_state FROM questions WHERE id=$1',[q])).rows[0],{status:'answered',escrow_state:'held'});
   assert.equal((await db.query("SELECT count(*)::int AS n FROM point_transactions WHERE question_id=$1 AND type='reward'",[q])).rows[0].n,0);
  });

  await t.test('deletion waits for in-flight review and then erases its newly authored note',async()=>{
   const traveler=await actor(),guide=await actor(),reviewer=await actor({admin:true,credentials:true}),q=await question(traveler,guide),id=await syntheticIssue(traveler,guide,q);
   let reached,release,held=false;const locked=new Promise(resolve=>reached=resolve),resume=new Promise(resolve=>release=resolve);
   const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    const result=await tx.query(sql,params);if(!held&&sql.includes('FROM users')&&/FOR SHARE/.test(sql)&&params?.includes(reviewer.id)){held=true;reached();await resume;}return result;
   }}))};
   rebuild(wrapped);let reviewing,deleting;
   try{
    reviewing=post(reviewer,`${adminPath}/${id}/review`,{note:'AUTHORED-DURING-DELETION-RACE'});await bounded(locked,'review holds shared moderation and live admin locks');
    deleting=post(reviewer,'/account/delete',{password,confirmation:'DELETE'});let waiting=false;
    for(let n=0;n<80&&!waiting;n++){waiting=(await db.query("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE locktype='advisory' AND objid=73284129 AND NOT granted) AS waiting")).rows[0].waiting;if(!waiting)await pause(10);}
    assert.equal(waiting,true,'Account deletion waits for the active review');release();
    const [reviewed,deleted]=await bounded(Promise.all([reviewing,deleting]),'review before erasure',12000);assert.equal(reviewed.status,200,JSON.stringify(reviewed));assert.equal(deleted.status,200,JSON.stringify(deleted));assert.equal(deleted.data.account_deleted,true);
   }finally{release();rebuild();if(reviewing)await reviewing;if(deleting)await deleting;}
   assert.deepEqual((await db.query('SELECT status,reviewed_by,review_note FROM exchange_issues WHERE id=$1',[id])).rows[0],{status:'reviewed',reviewed_by:null,review_note:null});
   assert.equal((await db.query('SELECT id FROM users WHERE id=$1',[reviewer.id])).rows.length,0);
   assert.ok(!JSON.stringify((await db.query('SELECT * FROM exchange_issues WHERE id=$1',[id])).rows).includes('AUTHORED-DURING-DELETION-RACE'));
  });

  await t.test('accepting an answer and filing an issue share safe lock order without deadlocks or duplicate settlement',async()=>{
   for(let n=0;n<8;n++){
    const traveler=await actor(),guide=await actor({helper:true}),q=await question(traveler,guide,{status:'answered'}),answerId=randomId();
    await db.query("INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,'Answer for acceptance race','Official synthetic source','Synthetic check')",[answerId,q,guide.id]);
    const [accepted,filed]=await bounded(Promise.all([post(traveler,`/questions/${q}/answers/${answerId}/accept`,{}),post(n%2?guide:traveler,ownPath,issueBody(q))]),'acceptance and issue filing',12000);
    assert.equal(accepted.status,200,JSON.stringify(accepted));assert.ok([201,409].includes(filed.status),JSON.stringify(filed));if(filed.status===409)assert.equal(filed.data.error.code,'EXCHANGE_NOT_ELIGIBLE');
    const saved=(await db.query('SELECT status,escrow_state FROM questions WHERE id=$1',[q])).rows[0];assert.deepEqual(saved,{status:'accepted',escrow_state:'paid'});
    assert.equal((await db.query("SELECT count(*)::int AS n FROM point_transactions WHERE question_id=$1 AND type='reward'",[q])).rows[0].n,1);
    assert.equal((await db.query('SELECT point_balance FROM users WHERE id=$1',[guide.id])).rows[0].point_balance,1010);
   }
  });

  await t.test('intake, reads and review make no question, answer, balance, escrow, helper, rating or block changes',async()=>{
   const traveler=await actor(),guide=await actor({helper:true}),reviewer=await actor({admin:true}),q=await question(traveler,guide,{status:'answered'}),answerId=randomId();
   await db.query("INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,'Unchanged answer','Unchanged evidence','Unchanged method')",[answerId,q,guide.id]);
   await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[traveler.id,guide.id]);
   const snapshot=async()=>{const result={};for(const table of ['users','questions','answers','answer_evidence_links','question_comments','question_images','point_transactions','helper_applications','helper_regions','user_blocks','content_reports','moderation_actions'])result[table]=(await db.query(`SELECT row_to_json(t)::text AS row FROM ${table} t ORDER BY row_to_json(t)::text`)).rows;return result;};
   const before=await snapshot(),created=await post(traveler,ownPath,issueBody(q,{reason:'cannot_continue',details:'The exchange is blocked.'}));assert.equal(created.status,201);
   await page(eligiblePath,traveler);assert.equal((await api(`${eligiblePath}/${q}`,{actor:traveler})).status,200);await page(ownPath,traveler);await page(adminPath,reviewer);assert.equal((await post(reviewer,`${adminPath}/${created.data.id}/review`,{note:'Review recorded only.'})).status,200);await page(`${adminPath}?status=reviewed`,reviewer);
   error(await post(traveler,ownPath,issueBody(q,{reason:'other'})),409,'ISSUE_ALREADY_EXISTS');
   assert.deepEqual(await snapshot(),before);assert.equal(imageReads,0);
  });

  await t.test('exports isolate own issues and own authored notes and account deletion erases reviewer text',async()=>{
   const traveler=await actor({credentials:true}),guide=await actor({credentials:true}),reviewer=await actor({admin:true,credentials:true}),otherReviewer=await actor({admin:true}),q=await question(traveler,guide);
   const own=await syntheticIssue(traveler,guide,q,{details:'TRAVELER-EXPORT-ONLY',status:'reviewed',reviewer,note:'REVIEWER-PRIVATE-AUTHORED-NOTE'}),other=await syntheticIssue(guide,traveler,q,{details:'GUIDE-EXPORT-ONLY',status:'reviewed',reviewer:otherReviewer,note:'OTHER-REVIEWER-NOTE'});
   const travelerExport=await post(traveler,'/account/export',{password,include_images:false});assert.equal(travelerExport.status,200,JSON.stringify(travelerExport));assert.deepEqual(travelerExport.data.exchange_issues.map(row=>row.id),[own]);assert.deepEqual(travelerExport.data.exchange_issue_reviews,[]);assert.deepEqual(Object.keys(travelerExport.data.exchange_issues[0]).sort(),ownKeys);
   for(const value of ['GUIDE-EXPORT-ONLY','REVIEWER-PRIVATE-AUTHORED-NOTE','OTHER-REVIEWER-NOTE',guide.token,reviewer.token])assert.ok(!JSON.stringify(travelerExport.data).includes(value),value);
   await db.query('UPDATE users SET is_suspended=true WHERE id=$1',[reviewer.id]);
   const reviewerExport=await post(reviewer,'/account/export',{password,include_images:false});assert.equal(reviewerExport.status,200,JSON.stringify(reviewerExport));assert.deepEqual(reviewerExport.data.exchange_issues,[]);assert.equal(reviewerExport.data.exchange_issue_reviews.length,1);assert.ok(JSON.stringify(reviewerExport.data.exchange_issue_reviews).includes('REVIEWER-PRIVATE-AUTHORED-NOTE'));assert.ok(!JSON.stringify(reviewerExport.data).includes('OTHER-REVIEWER-NOTE'));assert.ok(!JSON.stringify(reviewerExport.data).includes('TRAVELER-EXPORT-ONLY'));
   const deleted=await post(reviewer,'/account/delete',{password,confirmation:'DELETE'});assert.equal(deleted.status,200,JSON.stringify(deleted));
   const survivor=(await db.query('SELECT status,reviewed_by,review_note FROM exchange_issues WHERE id=$1',[own])).rows[0];assert.deepEqual(survivor,{status:'reviewed',reviewed_by:null,review_note:null});assert.equal((await db.query('SELECT review_note FROM exchange_issues WHERE id=$1',[other])).rows[0].review_note,'OTHER-REVIEWER-NOTE');
   assert.equal((await post(guide,'/account/delete',{password,confirmation:'DELETE'})).status,200);
   assert.equal((await db.query('SELECT count(*)::int AS n FROM exchange_issues WHERE question_id=$1',[q])).rows[0].n,0,'Deleting either participant removes both reporters\' issues');
  });

  await t.test('exchange issue and review exports both contribute to SQL row and byte preflight before materialization',async()=>{
   const reporter=await actor({credentials:true}),owner=await actor(),reviewer=await actor({admin:true,credentials:true});
   await db.query(`WITH created AS (
    INSERT INTO questions(id,user_id,assigned_helper_user_id,country,city,category,urgency,title,body,reward_points,status,escrow_state)
    SELECT gen_random_uuid(),$1,$2,'Spain','Malaga','교통','보통','Export fixture','Export fixture',10,'assigned','held' FROM generate_series(1,10001) RETURNING id
   ) INSERT INTO exchange_issues(id,question_id,reporter_id,other_participant_id,reason,status,reviewed_at,reviewed_by,review_note)
    SELECT gen_random_uuid(),id,$2,$1,'other','reviewed',now(),$3,'Review count fixture' FROM created`,[owner.id,reporter.id,reviewer.id]);
   const observed=[];let materialized=false;
   const guarded={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    if(sql.includes('exchange_issues')){observed.push(sql);if(!sql.includes('count(*)')&&!sql.includes('sum(')&&/^\s*SELECT/i.test(sql))materialized=true;}return tx.query(sql,params);
   }}))};
   rebuild(guarded);
   try{
    for(const who of [reporter,reviewer]){observed.length=0;materialized=false;const result=await post(who,'/account/export',{password,include_images:false});error(result,413,'EXPORT_TOO_LARGE');assert.ok(observed.some(sql=>sql.includes('octet_length')&&sql.includes('exchange_issues')),'Issue export gets a database byte/row preflight');assert.equal(materialized,false,'Reject before fetching unbounded issue rows');}
    await db.query(`DELETE FROM exchange_issues WHERE id IN (SELECT id FROM exchange_issues WHERE reporter_id=$1 ORDER BY id OFFSET 7000)`,[reporter.id]);
    await db.query("UPDATE exchange_issues SET details=repeat('𐀀',1000),review_note=repeat('𐀁',1000) WHERE reporter_id=$1",[reporter.id]);
    for(const who of [reporter,reviewer]){materialized=false;const result=await post(who,'/account/export',{password,include_images:false});error(result,413,'EXPORT_TOO_LARGE');assert.equal(materialized,false,'Escaped/uncompressed UTF-8 text bytes count before materialization');}
   }finally{rebuild();}
   assert.equal(imageReads,0);
  });

  await t.test('schema constraints preserve participant/question cascades and nullable erased reviewer links',async()=>{
   const constraints=(await db.query("SELECT pg_get_constraintdef(c.oid) AS definition FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname=$1 AND t.relname='exchange_issues'",[schema])).rows.map(row=>row.definition);
   for(const column of ['question_id','reporter_id','other_participant_id'])assert.ok(constraints.some(definition=>definition.includes(`FOREIGN KEY (${column})`)&&definition.includes('ON DELETE CASCADE')),column);
   assert.ok(constraints.some(definition=>definition.includes('FOREIGN KEY (reviewed_by)')&&definition.includes('ON DELETE SET NULL')));
   const traveler=await actor(),guide=await actor(),q=await question(traveler,guide),id=await syntheticIssue(traveler,guide,q);
   await db.query('DELETE FROM questions WHERE id=$1',[q]);assert.equal((await db.query('SELECT id FROM exchange_issues WHERE id=$1',[id])).rows.length,0);
   const columns=(await db.query('SELECT column_name FROM information_schema.columns WHERE table_schema=$1 AND table_name=\'exchange_issues\'',[schema])).rows.map(row=>row.column_name);assert.ok(!columns.includes('role'),'Participant role is derived, not stale persisted authorization');
  });

  assert.deepEqual(errors,[],'No internal server errors, deadlocks or uncaught PostgreSQL constraint failures');
 }finally{
  if(server)await new Promise(resolve=>server.close(resolve));await db?.close();await pool.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await pool.end();
 }
});
