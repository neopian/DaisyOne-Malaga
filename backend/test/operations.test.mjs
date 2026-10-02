import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {nodeServer} from '../src/server.mjs';
import {randomId,randomToken,sha256,sign} from '../src/crypto.mjs';

const secret='operations-test-signing-secret-with-32-characters';
const path='/admin/operations/questions';
const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const bounded=async(promise,label,ms=8000)=>{
 let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error(`Timed out: ${label}`)),ms);})]);}finally{clearTimeout(timer);}
};
const compactKeys=['id','user_id','assigned_helper_user_id','country','city','region_name','category','urgency','title','reward_points','status','created_at','updated_at','expires_at','escrow_state','operational_flags'].sort();
const noFlags={question_hidden:false,traveler_suspended:false,guide_suspended:false,guide_application_restricted:false,participants_blocked:false};

test('real PostgreSQL admin operations demand, restrictions, counts and precise pages',async t=>{
 const connectionString=process.env.TEST_DATABASE_URL;
 assert.ok(connectionString,'Set TEST_DATABASE_URL to a disposable real PostgreSQL database. No in-memory fallback.');
 const pool=new pg.Pool({connectionString,max:2}),schema=`operations_${randomId().replaceAll('-','')}`;
 let db,server;const errors=[];
 try {
  await pool.query(`CREATE SCHEMA ${schema}`);
  db=await createDatabase({connectionString,schema});await migrate(db);
  const storage={get:async()=>{throw new Error('Operations must never read image bytes');}};
  const config={imageSigningSecret:secret,onError:error=>errors.push(error)};
  const handler=createApp({db,storage,config});
  server=nodeServer(handler);await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}/api`;
  const get=async(route,actor)=>{
   const response=await fetch(`${base}${route}`,{headers:actor?{Authorization:`Bearer ${actor.token}`}:{}});
   return {status:response.status,data:await response.json(),headers:response.headers};
  };
  const actor=async({admin=false,suspended=false,application=null}={})=>{
   const id=randomId(),token=randomToken(),sessionId=randomId();
   await db.query('INSERT INTO users(id,email,name,is_admin,is_suspended,point_balance) VALUES($1,$2,$3,$4,$5,1000)',[id,`${id}@example.invalid`,'Private participant name',admin,suspended]);
   await db.query("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '1 day')",[sessionId,id,await sha256(token)]);
   if(application)await db.query('INSERT INTO helper_applications(id,user_id,status,introduction,experience_description) VALUES($1,$2,$3,$4,$5)',[randomId(),id,application,'Private guide introduction','Private guide experience']);
   return {id,token,sessionId};
  };
  const question=async(owner,{guide=null,status='open',hidden=false,country='Spain',city='Málaga',created='2026-01-01T00:00:00.123456Z',expires=null}={})=>{
   const id=randomId(),escrow=status==='accepted'?'paid':status==='cancelled'?'refunded':'held';
   await db.query(`INSERT INTO questions(id,user_id,assigned_helper_user_id,country,city,region_name,category,urgency,title,body,reward_points,status,escrow_state,moderation_hidden,created_at,updated_at,expires_at)
    VALUES($1,$2,$3,$4,$5,'Centro','교통','보통','Synthetic travel question',$6,10,$7,$8,$9,$10,$10,$11)`,[id,owner.id,guide?.id??null,country,city,'PRIVATE-BODY-'.repeat(500),status,escrow,hidden,created,expires]);
   return id;
  };
  const admin=await actor({admin:true});
  const page=async(params='',who=admin)=>{
   const result=await get(`${path}${params?'?'+params:''}`,who);
   assert.equal(result.status,200,JSON.stringify(result.data));return result.data;
  };
  const collect=async(params='',who=admin)=>{
   const items=[];let cursor=null,pages=0;
   do {
    const data=await page(`${params}${cursor?`${params?'&':''}cursor=${encodeURIComponent(cursor)}`:''}`,who);
    assert.ok(data.items.length<=20);items.push(...data.items);cursor=data.next_cursor;
    assert.ok(++pages<30,'Pagination must make progress');
   }while(cursor!==null);
   return items;
  };

  await t.test('only current active administrators can read items or counts',async()=>{
   assert.equal((await get(path)).status,401);
   const owner=await actor(),guide=await actor({application:'approved'}),suspendedAdmin=await actor({admin:true,suspended:true});
   await question(owner,{hidden:true});await question(owner,{guide,status:'assigned'});
   for(const who of [owner,guide]){
    const result=await get(path,who);assert.equal(result.status,403);assert.equal(result.data.error.code,'ADMIN_REQUIRED');
    assert.deepEqual(Object.keys(result.data),['error']);
    assert.equal((await get(path+'?limit=100',who)).data.error.code,'ADMIN_REQUIRED','Authorization precedes query inspection');
   }
   assert.equal((await get(path,suspendedAdmin)).data.error.code,'ACCOUNT_SUSPENDED');
   assert.equal((await page()).summary.open_count,1);
   assert.equal((await page('status=assigned')).items.length,1);
  });

  await t.test('admin revocation, suspension and deletion after authentication are rechecked inside the safety gate',async()=>{
   for(const change of ['revoke','suspend','delete']){
    const who=await actor({admin:true});let authenticated;
    const seen=new Promise(resolve=>authenticated=resolve);
    const wrapped={...db,query:async(sql,params)=>{
     const result=await db.query(sql,params);
     if(sql==='SELECT * FROM users WHERE id=$1'&&params[0]===who.id){
      assert.equal(result.rows[0].is_admin,true);assert.equal(result.rows[0].is_suspended,false);authenticated();
     }
     return result;
    }};
    const racingHandler=createApp({db:wrapped,storage,config});let reading;
    await db.transaction(async tx=>{
     await tx.query('SELECT pg_advisory_xact_lock(73284129)');
     reading=racingHandler(new Request(`${base}${path}`,{headers:{Authorization:`Bearer ${who.token}`}}));
     await seen;
     if(change==='delete')await tx.query('DELETE FROM users WHERE id=$1',[who.id]);
     else await tx.query(`UPDATE users SET ${change==='revoke'?'is_admin=false':'is_suspended=true'} WHERE id=$1`,[who.id]);
    });
    const response=await reading,data=await response.json();
    assert.equal(response.status,change==='delete'?401:403);
    assert.equal(data.error.code,change==='revoke'?'ADMIN_REQUIRED':change==='suspend'?'ACCOUNT_SUSPENDED':'UNAUTHENTICATED');
    assert.deepEqual(Object.keys(data),['error']);
   }
  });

  for(const change of ['logout','expire'])await t.test(`a session ${change} during the safety-gate wait denies the private read`,async()=>{
   const who=await actor({admin:true}),privateId=await question(who);
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
     pending=racing(new Request(`${base}/admin/operations/questions`,{headers:{Authorization:`Bearer ${who.token}`}}));
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

  await t.test('account, session and safety locks survive until the complete private page is read',async()=>{
   const who=await actor({admin:true});await question(who);let reached,release,reading;
   const locked=new Promise(resolve=>reached=resolve),resume=new Promise(resolve=>release=resolve);
   const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    const result=await tx.query(sql,params);
    if(sql.includes('WITH summary AS (')){reached();await resume;}
    return result;
   }}))};
   const racing=createApp({db:wrapped,storage,config});
   try{
    reading=racing(new Request(`${base}/admin/operations/questions`,{headers:{Authorization:`Bearer ${who.token}`}}));
    await bounded(locked,'the page holds its authorization locks');
    for(const [sql,params] of [
     ['UPDATE users SET is_suspended=true WHERE id=$1',[who.id]],
     ['DELETE FROM sessions WHERE id=$1',[who.sessionId]],
     ["UPDATE sessions SET expires_at=clock_timestamp() WHERE id=$1",[who.sessionId]],
     ['SELECT pg_advisory_xact_lock(73284129)',[]],
    ])await assert.rejects(db.transaction(async tx=>{await tx.query("SET LOCAL lock_timeout='75ms'");await tx.query(sql,params);}),error=>error.code==='55P03');
   }finally{release();if(reading)assert.equal((await bounded(reading,'authorized page completes')).status,200);}
  });

  await t.test('hidden and restricted obligations remain visible with precise operational flags',async()=>{
   const owner=await actor(),guide=await actor({application:'approved'});
   const filter='country=France&city=Paris&status=assigned';
   const options={country:'France',city:'Paris',guide,status:'assigned'};
   const id=await question(owner,options);
   let row=(await page(filter)).items.find(q=>q.id===id);assert.deepEqual(row.operational_flags,noFlags);
   await db.query('UPDATE questions SET moderation_hidden=true WHERE id=$1',[id]);
   await db.query('UPDATE users SET is_suspended=true WHERE id=ANY($1::uuid[])',[[owner.id,guide.id]]);
   await db.query("UPDATE helper_applications SET status='suspended' WHERE user_id=$1",[guide.id]);
   await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[owner.id,guide.id]);
   row=(await page(filter)).items.find(q=>q.id===id);
   assert.deepEqual(row.operational_flags,{question_hidden:true,traveler_suspended:true,guide_suspended:true,guide_application_restricted:true,participants_blocked:true});
   assert.equal((await page(filter)).summary.assigned_count,1);
   await db.query('DELETE FROM user_blocks WHERE blocker_id=$1',[owner.id]);
   await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[guide.id,owner.id]);
   assert.equal((await page(filter)).items[0].operational_flags.participants_blocked,true,'Blocks work in both directions');
   await db.query('UPDATE users SET is_suspended=false WHERE id=ANY($1::uuid[])',[[owner.id,guide.id]]);
   assert.deepEqual((await get('/activity/questions',owner)).data.items,[],'Restricted participant work is still hidden');
   assert.equal((await get(path+'?'+filter,owner)).status,403);
   assert.equal((await get(path+'?'+filter,guide)).status,403);
   // The operator's own blocks do not erase unrelated operational obligations.
   await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[admin.id,owner.id]);
   assert.equal((await page(filter)).items.length,1);
   for(const application of [null,'pending','rejected','suspended','approved']){
    const participant=await actor({application});
    const q=await question(owner,{...options,guide:participant});
    const item=(await page(filter)).items.find(item=>item.id===q);
    assert.equal(item.operational_flags.guide_application_restricted,application!=='approved');
    assert.equal(item.operational_flags.participants_blocked,false);
   }
   const unassigned=await question(owner,{country:'France',city:'Paris'});
   row=(await page('country=France&city=Paris')).items.find(q=>q.id===unassigned);
   assert.equal(row.assigned_helper_user_id,null);assert.deepEqual(row.operational_flags,noFlags);
  });

  await t.test('more than 200 records paginate oldest first with exact microseconds and UUID ties',async()=>{
   const owner=await actor();
   await db.query(`INSERT INTO questions(id,user_id,country,city,category,urgency,title,body,reward_points,created_at)
    SELECT gen_random_uuid(),$1,'United Kingdom','London','교통','보통','Older demand','Private body',1,
    '2026-01-01T00:00:00.123001Z'::timestamptz+(floor(n/3)*interval '1 microsecond') FROM generate_series(0,246) n`,[owner.id]);
   const params='country=UK&city=London';
   const expected=(await db.query('SELECT id FROM questions WHERE user_id=$1 ORDER BY created_at,id',[owner.id])).rows.map(q=>q.id);
   const first=await page(params);assert.equal(first.items.length,20);assert.equal(first.summary.open_count,247);
   const items=await collect(params);assert.deepEqual(items.map(q=>q.id),expected);assert.equal(new Set(items.map(q=>q.id)).size,247);
   assert.ok(items.every(q=>/^2026-01-01T00:00:00\.123\d{3}Z$/.test(q.created_at)));
   assert.notEqual(items[0].created_at,items.at(-1).created_at);
   await question(owner,{country:'UK',city:'London',created:'2025-01-01T00:00:00.000001Z'});
   const next=await page(`${params}&cursor=${encodeURIComponent(first.next_cursor)}`);
   assert.deepEqual(next.items.map(q=>q.id),expected.slice(20,40),'New older work belongs to a refresh and does not shift a keyset page');
   assert.equal(next.summary.open_count,248,'Summary remains current and includes rows before the cursor');
   const exactly=await actor();for(let n=0;n<20;n++)await question(exactly,{country:'Austria',city:'Vienna'});
   const boundary=await page('country=Austria&city=Vienna');assert.equal(boundary.items.length,20);assert.equal(boundary.next_cursor,null);
  });

  await t.test('counts are exact within canonical geography across status and pages; elapsed expiry stays open',async()=>{
   const owner=await actor(),guide=await actor({application:'approved'});
   const aliases=[['Spain','Barcelona'],['ES','BARCELONA'],['스페인','바르셀로나'],['España','Barcelona']];
   for(let n=0;n<23;n++)await question(owner,{country:aliases[n%4][0],city:aliases[n%4][1],hidden:n%2===0,expires:'2020-01-01T00:00:00.000001Z'});
   for(let n=0;n<3;n++)await question(owner,{country:'Spain',city:'Barcelona',guide,status:'assigned'});
   for(let n=0;n<2;n++)await question(owner,{country:'ES',city:'바르셀로나',guide,status:'answered'});
   for(const status of ['accepted','cancelled','expired','disputed','reported'])await question(owner,{country:'Spain',city:'Barcelona',guide,status});
   await question(owner,{country:'Spain',city:'Madrid'});
   await question(owner,{country:'Unknown country',city:'Barcelona'});
   const summary={open_count:23,assigned_count:3,answered_count:2},params='country=Spain&city=Barcelona';
   const first=await page(params);assert.deepEqual(first.summary,summary);
   const second=await page(params+'&cursor='+first.next_cursor);assert.deepEqual(second.summary,summary);assert.equal(second.items.length,3);assert.equal(second.next_cursor,null);
   for(const status of ['open','assigned','answered']){
    const result=await page(params+'&status='+status);assert.deepEqual(result.summary,summary);assert.ok(result.items.every(q=>q.status===status));
   }
   assert.deepEqual((await page('country=ES&city=바르셀로나')).summary,summary);
   const all=await page();
   const expected=(await db.query("SELECT count(*) FILTER(WHERE status='open')::int AS open_count,count(*) FILTER(WHERE status='assigned')::int AS assigned_count,count(*) FILTER(WHERE status='answered')::int AS answered_count FROM questions")).rows[0];
   assert.deepEqual(all.summary,expected);
   assert.deepEqual(await page('country=US&city=Seattle'),{items:[],next_cursor:null,summary:{open_count:0,assigned_count:0,answered_count:0}});
  });

  await t.test('page and counts retain one snapshot when a transition commits during the read',async()=>{
   const owner=await actor();const id=await question(owner,{country:'Portugal',city:'Lisbon'});let observed=false;
   const wrapped={...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    const result=await tx.query(sql,params);
    if(sql.includes('WITH summary AS (')){
     observed=true;
     await db.query("UPDATE questions SET status='cancelled',escrow_state='refunded' WHERE id=$1",[id]);
    }
    return result;
   }}))};
   const racing=createApp({db:wrapped,storage,config});
   const response=await racing(new Request(`${base}${path}?country=Portugal&city=Lisbon`,{headers:{Authorization:`Bearer ${admin.token}`}}));
   assert.equal(response.status,200);assert.equal(observed,true);
   const result=await response.json();assert.deepEqual(result.items.map(q=>q.id),[id]);assert.equal(result.items[0].status,'open');assert.equal(result.summary.open_count,1);
   const latest=await page('country=Portugal&city=Lisbon');assert.deepEqual(latest.items,[]);assert.equal(latest.summary.open_count,0);
  });

  await t.test('compact payload omits bodies, nested data, names, emails, tokens and storage details',async()=>{
   const owner=await actor(),guide=await actor({application:'approved'});
   const id=await question(owner,{guide,status:'answered',country:'Italy',city:'Rome'}),answerId=randomId();
   await db.query("INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,'Private answer','Private evidence','Private method')",[answerId,id,guide.id]);
   await db.query("INSERT INTO question_comments(id,question_id,user_id,body) VALUES($1,$2,$3,'Private comment')",[randomId(),id,guide.id]);
   await db.query("INSERT INTO question_images(id,question_id,storage_key,content_type,byte_length) VALUES($1,$2,'private-file','image/png',100)",[randomId(),id]);
   const response=await get(path+'?status=answered&country=IT&city=Roma',admin),payload=JSON.stringify(response.data);
   assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'no-store');
   assert.deepEqual(Object.keys(response.data).sort(),['items','next_cursor','summary']);
   assert.deepEqual(Object.keys(response.data.items[0]).sort(),compactKeys);
   assert.deepEqual(response.data.items[0].operational_flags,noFlags);
   for(const sensitive of ['PRIVATE-BODY','Private','private-file','example.invalid',owner.token,guide.token,admin.token,'token_hash','storage_key','answers','question_images'])assert.ok(!payload.includes(sensitive),sensitive);
   assert.ok(payload.length<1500);
  });

  await t.test('strict query and signed cursors bind admin, status and canonical geographic filter',async()=>{
   const first=await page('country=UK&city=London'),cursor=first.next_cursor;
   assert.equal(typeof cursor,'string');
   for(const params of ['status=','status=all','status=expired','status=open&status=assigned','country=UK','city=London','country=&city=London','country=UK&city=','country=UK&city=Tokyo','country=Unknown&city=London','country=UK&country=GB&city=London','country=UK&city=London&city=London','cursor=a&cursor=b','limit=100','offset=1','user_id='+admin.id,'country='+('a'.repeat(101))+'&city=London']){
    const result=await get(path+'?'+params,admin);assert.equal(result.status,400,params);assert.equal(result.data.error.code,'INVALID_OPERATIONS_QUERY');
   }
   for(const value of ['','a','not.a.cursor',cursor+'.extra',cursor+'=',cursor.slice(0,-2)+'aa','x'.repeat(1025)]){
    const result=await get(path+'?country=UK&city=London&cursor='+encodeURIComponent(value),admin);assert.equal(result.status,400);assert.equal(result.data.error.code,'INVALID_OPERATIONS_CURSOR');
   }
   const other=await actor({admin:true});
   for(const [who,params] of [[other,'country=UK&city=London&'],[admin,''],[admin,'country=UK&city=London&status=assigned&'],[admin,'country=France&city=Paris&']]){
    assert.equal((await get(`${path}?${params}cursor=${cursor}`,who)).data.error.code,'INVALID_OPERATIONS_CURSOR');
   }
   const payload=JSON.parse(Buffer.from(cursor.split('.')[0],'base64url').toString());
   for(const changes of [{v:2},{created_at:'2026-02-30T00:00:00.123456Z'},{created_at:'0000-01-01T00:00:00.123456Z'},{created_at:'2026-01-01T00:00:00.123Z'},{created_at:'infinity'},{id:'not-a-uuid'},{extra:'ignored?'},{place:'gb-london '},{user:other.id},{status:'answered'}]){
    const encoded=Buffer.from(JSON.stringify({...payload,...changes})).toString('base64url');
    const signed=`${encoded}.${await sign(secret,`malaga-operations-v1:${encoded}`)}`;
    assert.equal((await get(path+'?country=UK&city=London&cursor='+signed,admin)).data.error.code,'INVALID_OPERATIONS_CURSOR');
   }
   assert.equal((await page('country=영국&city=런던&cursor='+cursor)).items.length,20,'Equivalent catalog aliases preserve cursor scope');
   const activityCursor=(await get('/activity/questions',await actor())).data.next_cursor;assert.equal(activityCursor,null);
   const encoded=Buffer.from(JSON.stringify(payload)).toString('base64url');
   const wrongDomain=`${encoded}.${await sign(secret,`malaga-activity-v1:${encoded}`)}`;
   assert.equal((await get(path+'?country=UK&city=London&cursor='+wrongDomain,admin)).data.error.code,'INVALID_OPERATIONS_CURSOR');
  });

  await t.test('operations reads leave balances, ledger, question status and escrow unchanged',async()=>{
   const snapshot=async()=>({
    users:(await db.query('SELECT id,point_balance FROM users ORDER BY id')).rows,
    ledger:(await db.query('SELECT * FROM point_transactions ORDER BY id')).rows,
    questions:(await db.query('SELECT id,status,escrow_state,assigned_helper_user_id,accepted_answer_id,updated_at FROM questions ORDER BY id')).rows,
    retries:(await db.query('SELECT * FROM idempotency_keys ORDER BY user_id,key')).rows,
   });
   const owner=await actor(),guide=await actor({application:'approved'});
   const id=await question(owner,{guide,status:'assigned'});
   await db.query("INSERT INTO point_transactions(id,user_id,question_id,type,amount) VALUES($1,$2,$3,'hold',-10)",[randomId(),owner.id,id]);
   await db.query('UPDATE users SET point_balance=point_balance-10 WHERE id=$1',[owner.id]);
   const before=await snapshot();
   for(const status of ['open','assigned','answered'])await collect('status='+status);
   await collect('country=Spain&city=Málaga');
   assert.deepEqual(await snapshot(),before);
  });
  assert.deepEqual(errors,[],'No unhandled database or API errors');
 }finally{
  if(server)await new Promise(resolve=>server.close(resolve));
  if(db)await db.close();await pool.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await pool.end();
 }
});
