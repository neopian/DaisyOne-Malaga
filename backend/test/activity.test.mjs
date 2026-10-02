import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {nodeServer} from '../src/server.mjs';
import {randomId,randomToken,sha256,sign} from '../src/crypto.mjs';

const secret='activity-test-signing-secret-with-32-characters';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const bounded=async(promise,label,ms=8000)=>{
 let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error(`Timed out: ${label}`)),ms);})]);}finally{clearTimeout(timer);}
};
const compactKeys=['id','user_id','assigned_helper_user_id','country','city','region_name','category','urgency','title','reward_points','status','created_at','updated_at','expires_at'].sort();

test('real PostgreSQL personal activity scope, visibility, and precise pagination',async t=>{
 const connectionString=process.env.TEST_DATABASE_URL;
 assert.ok(connectionString,'Set TEST_DATABASE_URL to a disposable real PostgreSQL database. No in-memory fallback.');
 const pool=new pg.Pool({connectionString,max:2}),schema=`activity_${randomId().replaceAll('-','')}`;
 let db,server;const errors=[];
 try {
  await pool.query(`CREATE SCHEMA ${schema}`);
  db=await createDatabase({connectionString,schema});await migrate(db);
  const storage={get:async()=>{throw new Error('Activity must never read image bytes');}};
  const config={imageSigningSecret:secret,onError:error=>errors.push(error)};
  const handler=createApp({db,storage,config});
  server=nodeServer(handler);await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}/api`;
  const get=async(path,actor)=>{
   const response=await fetch(`${base}${path}`,{headers:actor?{Authorization:`Bearer ${actor.token}`}:{}});
   return {status:response.status,data:await response.json(),headers:response.headers};
  };
  const actor=async({admin=false,suspended=false}={})=>{
   const id=randomId(),token=randomToken(),sessionId=randomId();
   await db.query('INSERT INTO users(id,email,name,is_admin,is_suspended) VALUES($1,$2,$3,$4,$5)',[id,`${id}@example.invalid`,'Synthetic participant',admin,suspended]);
   await db.query("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '1 day')",[sessionId,id,await sha256(token)]);
   return {id,token,sessionId};
  };
  const question=async(owner,{guide=null,status='open',hidden=false,created='2026-01-01T00:00:00.123456Z',body='Private body excluded from activity',title='Synthetic travel question'}={})=>{
   const id=randomId(),escrow=status==='accepted'?'paid':status==='cancelled'?'refunded':'held';
   await db.query(`INSERT INTO questions(id,user_id,assigned_helper_user_id,country,city,region_name,category,urgency,title,body,reward_points,status,escrow_state,moderation_hidden,created_at,updated_at)
    VALUES($1,$2,$3,'Spain','Málaga','Centro','교통','보통',$4,$5,10,$6,$7,$8,$9,$9)`,[id,owner.id,guide?.id??null,title,body,status,escrow,hidden,created]);
   return id;
  };
  const page=async(who,params='')=>{
   const result=await get(`/activity/questions${params?'?'+params:''}`,who);
   assert.equal(result.status,200,JSON.stringify(result.data));return result.data;
  };
  const collect=async(who,params='')=>{
   const items=[];let cursor=null,pages=0;
   do {
    const data=await page(who,`${params}${cursor?`${params?'&':''}cursor=${encodeURIComponent(cursor)}`:''}`);
    assert.ok(data.items.length<=20);items.push(...data.items);cursor=data.next_cursor;
    assert.ok(++pages<30,'Pagination must make progress');
   }while(cursor!==null);
   return items;
  };

  await t.test('authentication and own scope apply to traveler, guide, outsiders and administrators',async()=>{
   assert.equal((await get('/activity/questions')).status,401);
   const owner=await actor(),guide=await actor(),outsider=await actor(),admin=await actor({admin:true});
   const own=await question(owner),assigned=await question(owner,{guide,status:'assigned'}),adminOwn=await question(admin);
   assert.deepEqual(new Set((await page(owner)).items.map(q=>q.id)),new Set([own,assigned]));
   assert.deepEqual((await page(guide)).items,[]);
   assert.deepEqual((await page(guide,'role=guide')).items.map(q=>q.id),[assigned]);
   assert.deepEqual(await page(outsider),{items:[],next_cursor:null});
   assert.deepEqual((await page(admin)).items.map(q=>q.id),[adminOwn]);
   assert.deepEqual(await page(admin,'role=guide'),{items:[],next_cursor:null});
   assert.equal((await get(`/activity/questions?user_id=${owner.id}`,outsider)).status,400);
  });

  for(const change of ['logout','expire'])await t.test(`a session ${change} during the safety-gate wait denies the private read`,async()=>{
   const who=await actor(),privateId=await question(who);
   let attempted,transactionStarted,pending;
   const gateAttempt=new Promise(resolve=>attempted=resolve);
   const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    if(sql==='SELECT pg_advisory_xact_lock_shared(73284129)'){
     transactionStarted=(await tx.query('SELECT transaction_timestamp()::text AS started_at')).rows[0].started_at;
     // Initial bearer authentication and BEGIN both precede revocation.
     attempted();
    }
    return tx.query(sql,params);
   }}))};
   const racing=createApp({db:wrapped,storage,config});
   try{
    await db.transaction(async tx=>{
     await tx.query('SELECT pg_advisory_xact_lock(73284129)');
     pending=racing(new Request(`${base}/activity/questions`,{headers:{Authorization:`Bearer ${who.token}`}}));
     await bounded(gateAttempt,'authenticated read reaches the held safety gate');
     if(change==='logout')await tx.query('DELETE FROM sessions WHERE id=$1',[who.sessionId]);
     else {
      const expiry=(await tx.query("UPDATE sessions SET expires_at=clock_timestamp()+interval '30 milliseconds' WHERE id=$1 RETURNING expires_at>$2::timestamptz AS after_transaction_start",[who.sessionId,transactionStarted])).rows[0];
      assert.equal(expiry.after_transaction_start,true,'Transaction-start now() would incorrectly consider this session live');
      await bounded((async()=>{
       while(!(await tx.query('SELECT clock_timestamp()>=expires_at AS expired FROM sessions WHERE id=$1',[who.sessionId])).rows[0].expired)await pause(5);
      })(),'session expires before releasing the safety gate');
     }
    });
    const response=await bounded(pending,'revoked private read'),data=await response.json();
    assert.equal(response.status,401);assert.equal(data.error.code,'UNAUTHENTICATED');
    assert.deepEqual(Object.keys(data),['error']);assert.ok(!JSON.stringify(data).includes(privateId));
   }finally{if(pending)await pending;}
  });

  await t.test('guide activity and answer acceptance keep a consistent page without a lock-order cycle',async()=>{
   const owner=await actor(),guide=await actor(),id=await question(owner,{guide,status:'answered'}),answerId=randomId();
   await db.query("INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,'Synthetic answer','Synthetic evidence','Synthetic method')",[answerId,id,guide.id]);
   const before=(await db.query('SELECT point_balance FROM users WHERE id=$1',[guide.id])).rows[0].point_balance;
   let reached,release,rewardAttempt,reading,accepting;
   const locked=new Promise(resolve=>reached=resolve),resume=new Promise(resolve=>release=resolve),rewarding=new Promise(resolve=>rewardAttempt=resolve);
   const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    if(sql==='UPDATE users SET point_balance=point_balance+$2 WHERE id=$1'&&params[0]===guide.id)rewardAttempt();
    const result=await tx.query(sql,params);
    if(sql.includes('FROM sessions')&&sql.includes('FOR SHARE')&&params[0]===guide.sessionId){reached();await resume;}
    return result;
   }}))};
   const racing=createApp({db:wrapped,storage,config});
   try{
    reading=racing(new Request(`${base}/activity/questions?role=guide`,{headers:{Authorization:`Bearer ${guide.token}`}}));
    await bounded(locked,'activity holds the live account and session');
    accepting=racing(new Request(`${base}/questions/${id}/answers/${answerId}/accept`,{method:'POST',headers:{Authorization:`Bearer ${owner.token}`,'content-type':'application/json','idempotency-key':randomId()},body:'{}'}));
    await bounded(rewarding,'acceptance holds the question and waits to reward the guide');
    release();
    const [readResponse,accepted]=await bounded(Promise.all([reading,accepting]),'activity and acceptance both complete');
    assert.equal(readResponse.status,200);assert.equal(accepted.status,200);
    const data=await readResponse.json();assert.deepEqual(data.items.map(q=>[q.id,q.status]),[[id,'answered']]);
    assert.equal((await db.query('SELECT point_balance FROM users WHERE id=$1',[guide.id])).rows[0].point_balance,before+10);
    assert.equal((await db.query("SELECT count(*)::int AS count FROM point_transactions WHERE question_id=$1 AND type='reward'",[id])).rows[0].count,1);
    assert.deepEqual((await page(guide,'role=guide')).items,[]);
    assert.deepEqual((await page(guide,'role=guide&view=history')).items.map(q=>[q.id,q.status]),[[id,'accepted']]);
   }finally{release();if(reading)await reading;if(accepting)await accepting;}
  });

  await t.test('account, session and safety locks survive until the complete private page is read',async()=>{
   const who=await actor();await question(who);let reached,release,reading;
   const locked=new Promise(resolve=>reached=resolve),resume=new Promise(resolve=>release=resolve);
   const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    const result=await tx.query(sql,params);
    if(sql.includes('FROM questions q WHERE')){reached();await resume;}
    return result;
   }}))};
   const racing=createApp({db:wrapped,storage,config});
   try{
    reading=racing(new Request(`${base}/activity/questions`,{headers:{Authorization:`Bearer ${who.token}`}}));
    await bounded(locked,'the page holds its authorization locks');
    for(const [sql,params] of [
     ['UPDATE users SET is_suspended=true WHERE id=$1',[who.id]],
     ['DELETE FROM sessions WHERE id=$1',[who.sessionId]],
     ["UPDATE sessions SET expires_at=clock_timestamp() WHERE id=$1",[who.sessionId]],
     ['SELECT pg_advisory_xact_lock(73284129)',[]],
    ])await assert.rejects(db.transaction(async tx=>{await tx.query("SET LOCAL lock_timeout='75ms'");await tx.query(sql,params);}),error=>error.code==='55P03');
   }finally{release();if(reading)assert.equal((await bounded(reading,'authorized page completes')).status,200);}
  });

  await t.test('over 200 newer unrelated public questions cannot bury own work; ties retain all PostgreSQL microseconds',async()=>{
   const owner=await actor(),other=await actor();
   await db.query(`INSERT INTO questions(id,user_id,country,city,category,urgency,title,body,reward_points,created_at)
    SELECT gen_random_uuid(),$1,'Spain','Málaga','교통','보통','Own work','Synthetic body',1,
    '2026-01-01T00:00:00.123999Z'::timestamptz-(floor(n/2)*interval '1 microsecond') FROM generate_series(0,46) n`,[owner.id]);
   await db.query(`INSERT INTO questions(id,user_id,country,city,category,urgency,title,body,reward_points,created_at)
    SELECT gen_random_uuid(),$1,'Spain','Málaga','교통','보통','Unrelated question','Synthetic body',1,
    '2026-02-01T00:00:00Z'::timestamptz+n*interval '1 second' FROM generate_series(1,260) n`,[other.id]);
   const general=await get('/questions',owner);assert.equal(general.data.length,200);assert.ok(general.data.every(q=>q.user_id===other.id));
   const first=await page(owner);assert.equal(first.items.length,20);assert.equal(typeof first.next_cursor,'string');
   const expected=(await db.query('SELECT id FROM questions WHERE user_id=$1 ORDER BY created_at DESC,id DESC',[owner.id])).rows.map(q=>q.id);
   const items=await collect(owner);assert.deepEqual(items.map(q=>q.id),expected);assert.equal(new Set(items.map(q=>q.id)).size,47);
   assert.ok(items.every(q=>/^2026-01-01T00:00:00\.123\d{3}Z$/.test(q.created_at)));
   assert.notEqual(items[0].created_at,items.at(-1).created_at,'Submillisecond fractions must survive database decoding');
   // Newer work belongs to a refresh; it must not shift the next keyset page.
   await question(owner,{created:'2026-03-01T00:00:00.000001Z'});
   const next=await page(owner,`cursor=${encodeURIComponent(first.next_cursor)}`);
   assert.deepEqual(next.items.map(q=>q.id),expected.slice(20,40));
  });

  await t.test('hidden rows before and between pages neither leak nor block older visible work',async()=>{
   const owner=await actor();const visible=[];
   for(let n=0;n<25;n++)visible.push(await question(owner,{created:`2026-01-01T00:00:${String(n).padStart(2,'0')}.000001Z`}));
   await db.query(`INSERT INTO questions(id,user_id,country,city,category,urgency,title,body,reward_points,moderation_hidden,created_at)
    SELECT gen_random_uuid(),$1,'Spain','Málaga','교통','보통','Hidden work','Hidden body',1,true,
    '2026-02-01T00:00:00Z'::timestamptz+n*interval '1 microsecond' FROM generate_series(1,80) n`,[owner.id]);
   for(let n=0;n<24;n++)await question(owner,{hidden:true,created:`2026-01-01T00:00:${String(n).padStart(2,'0')}.500001Z`});
   const first=await page(owner);assert.equal(first.items.length,20);
   const second=await page(owner,`cursor=${encodeURIComponent(first.next_cursor)}`);assert.equal(second.items.length,5);assert.equal(second.next_cursor,null);
   assert.deepEqual([...first.items,...second.items].map(q=>q.id),visible.reverse());
   await db.query('UPDATE questions SET moderation_hidden=true WHERE user_id=$1',[owner.id]);
   assert.deepEqual(await page(owner),{items:[],next_cursor:null});
  });

  await t.test('bilateral blocks and suspended participants filter both roles; admins get ordinary personal visibility',async()=>{
   const owner=await actor(),guide=await actor(),admin=await actor({admin:true});
   const assigned=await question(owner,{guide,status:'assigned'});
   await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[owner.id,guide.id]);
   assert.deepEqual((await page(owner)).items,[]);assert.deepEqual((await page(guide,'role=guide')).items,[]);
   await db.query('DELETE FROM user_blocks WHERE blocker_id=$1',[owner.id]);
   await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[guide.id,owner.id]);
   assert.deepEqual((await page(owner)).items,[]);assert.deepEqual((await page(guide,'role=guide')).items,[]);
   await db.query('DELETE FROM user_blocks WHERE blocker_id=$1',[guide.id]);
   await db.query('UPDATE users SET is_suspended=true WHERE id=$1',[guide.id]);
   assert.deepEqual((await page(owner)).items,[]);
   assert.equal((await get('/activity/questions?role=guide',guide)).data.error.code,'ACCOUNT_SUSPENDED');
   await db.query('UPDATE users SET is_suspended=false WHERE id=$1',[guide.id]);
   await db.query("INSERT INTO helper_applications(id,user_id,status,introduction,experience_description) VALUES($1,$2,'suspended','Local experience','Prior participation')",[randomId(),guide.id]);
   assert.deepEqual((await page(guide,'role=guide')).items.map(q=>q.id),[assigned],'Application suspension must not erase existing work; writes retain approval gates');
   await question(admin,{hidden:true});
   await question(admin,{guide,status:'assigned'});
   await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[guide.id,admin.id]);
   assert.deepEqual(await page(admin),{items:[],next_cursor:null});
   await db.query('UPDATE users SET is_suspended=true WHERE id=$1',[admin.id]);
   assert.equal((await get('/activity/questions',admin)).status,403);
  });

  await t.test('terminal split and 20-item boundary are exact without inventing expiry transitions',async()=>{
   const owner=await actor(),guide=await actor();
   for(const status of ['open','assigned','answered','disputed','reported','accepted','cancelled','expired'])await question(owner,{guide,status});
   for(const who of [owner,guide]){
    const role=who===owner?'traveler':'guide';
    assert.deepEqual(new Set((await page(who,`role=${role}`)).items.map(q=>q.status)),new Set(['open','assigned','answered','disputed','reported']));
    assert.deepEqual(new Set((await page(who,`role=${role}&view=history`)).items.map(q=>q.status)),new Set(['accepted','cancelled','expired']));
   }
   const exactly=await actor();for(let n=0;n<20;n++)await question(exactly);
   const data=await page(exactly);assert.equal(data.items.length,20);assert.equal(data.next_cursor,null);
   await db.query("UPDATE questions SET expires_at=now()-interval '1 day' WHERE user_id=$1",[exactly.id]);
   assert.equal((await page(exactly)).items.length,20,'An elapsed expires_at is still open until an authorized transition');
   assert.deepEqual((await page(exactly,'view=history')).items,[]);
  });

  await t.test('compact summaries omit all body, nested, media, escrow and private participant data',async()=>{
   const owner=await actor(),guide=await actor();
   const id=await question(owner,{guide,status:'answered',body:'PRIVATE-CONTENT-'.repeat(500)});
   const answerId=randomId();await db.query("INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,'Private answer','Private evidence','Private method')",[answerId,id,guide.id]);
   await db.query("INSERT INTO question_comments(id,question_id,user_id,body) VALUES($1,$2,$3,'Private comment')",[randomId(),id,guide.id]);
   await db.query("INSERT INTO question_images(id,question_id,storage_key,content_type,byte_length) VALUES($1,$2,'private-file','image/png',100)",[randomId(),id]);
   const response=await get('/activity/questions',owner);assert.equal(response.status,200);
   assert.deepEqual(Object.keys(response.data).sort(),['items','next_cursor']);assert.deepEqual(Object.keys(response.data.items[0]).sort(),compactKeys);
   assert.ok(!JSON.stringify(response.data).includes('Private'));assert.ok(!JSON.stringify(response.data).includes('PRIVATE-CONTENT'));
   assert.ok(JSON.stringify(response.data).length<1000);assert.equal(response.headers.get('cache-control'),'no-store');
  });

  await t.test('malformed queries and cursors fail closed; cursors bind account, role, view and exact values',async()=>{
   const owner=await actor(),other=await actor();for(let n=0;n<21;n++)await question(owner);
   const {next_cursor:cursor}=await page(owner);
   for(const params of ['role=','role=admin','view=','view=all','role=guide&role=traveler','view=active&view=history','cursor=a&cursor=b','limit=100','offset=1','user_id='+other.id]){
    const result=await get('/activity/questions?'+params,owner);assert.equal(result.status,400,params);assert.equal(result.data.error.code,'INVALID_ACTIVITY_QUERY');
   }
   for(const value of ['', 'a', 'not.a.cursor',cursor+'.extra',cursor+'=',cursor.slice(0,-2)+'aa','x'.repeat(1025)]){
    const result=await get('/activity/questions?cursor='+encodeURIComponent(value),owner);assert.equal(result.status,400);assert.equal(result.data.error.code,'INVALID_ACTIVITY_CURSOR');
   }
   for(const [who,params] of [[other,''],[owner,'role=guide&'],[owner,'view=history&']])assert.equal((await get(`/activity/questions?${params}cursor=${cursor}`,who)).data.error.code,'INVALID_ACTIVITY_CURSOR');
   const payload=JSON.parse(Buffer.from(cursor.split('.')[0],'base64url').toString());
   for(const changes of [{v:2},{created_at:'2026-02-30T00:00:00.123456Z'},{created_at:'0000-01-01T00:00:00.123456Z'},{created_at:'2026-01-01T00:00:00.123Z'},{created_at:'infinity'},{id:'not-a-uuid'},{extra:'ignored?'}]){
    const encoded=Buffer.from(JSON.stringify({...payload,...changes})).toString('base64url');
    const signed=`${encoded}.${await sign(secret,`malaga-activity-v1:${encoded}`)}`;
    assert.equal((await get('/activity/questions?cursor='+signed,owner)).data.error.code,'INVALID_ACTIVITY_CURSOR');
   }
   assert.equal((await page(owner,'cursor='+cursor)).items.length,1);
  });
  assert.deepEqual(errors,[],'No unhandled database or API errors');
 }finally{
  if(server)await new Promise(resolve=>server.close(resolve));
  if(db)await db.close();await pool.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await pool.end();
 }
});
