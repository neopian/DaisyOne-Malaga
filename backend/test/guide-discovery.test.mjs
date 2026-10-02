import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {nodeServer} from '../src/server.mjs';
import {randomId,randomToken,sha256,sign} from '../src/crypto.mjs';
import {knownPlaces} from '../src/city-catalog.mjs';

const secret='discovery-test-signing-secret-with-32-characters';
const path='/guide/discovery';
const compactKeys=['id','user_id','assigned_helper_user_id','country','city','region_name','category','urgency','title','reward_points','status','created_at','updated_at','expires_at'].sort();
const bounded=async(promise,label)=>{
 let timer;try{return await Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error(`Timed out: ${label}`)),8000);})]);}finally{clearTimeout(timer);}
};

test('real PostgreSQL and HTTP guide discovery: eligibility, privacy and precise pagination',{timeout:180000},async t=>{
 const connectionString=process.env.TEST_DATABASE_URL;
 assert.ok(connectionString,'Set TEST_DATABASE_URL to disposable real PostgreSQL. No in-memory fallback.');
 const pool=new pg.Pool({connectionString,max:2}),schema=`discovery_${randomId().replaceAll('-','')}`;
 let db,server,handler;const errors=[];let imageReads=0;
 const storage={get:async()=>{imageReads++;throw new Error('Discovery must never read private images');}};
 const config={imageSigningSecret:secret,onError:error=>errors.push(error)};
 try {
  await pool.query(`CREATE SCHEMA ${schema}`);db=await createDatabase({connectionString,schema});await migrate(db);
  const rebuild=(database=db)=>{handler=createApp({db:database,storage,config});};rebuild();
  server=nodeServer(request=>handler(request));await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const base=`http://127.0.0.1:${server.address().port}/api`;
  const api=async(route,who,{method='GET',body}={})=>{
   const response=await fetch(`${base}${route}`,{method,headers:{...(who?{authorization:`Bearer ${who.token}`} : {}),...(body!==undefined?{'content-type':'application/json'}:{})},...(body!==undefined?{body:JSON.stringify(body)}:{})});
   return {status:response.status,data:await response.json(),headers:response.headers};
  };
  const actor=async({admin=false,suspended=false,application=null,regions=[]}={})=>{
   const id=randomId(),token=randomToken();
   await db.query('INSERT INTO users(id,email,name,is_admin,is_suspended,point_balance) VALUES($1,$2,$3,$4,$5,1000)',[id,`${id}@example.invalid`,'PRIVATE-PROFILE',admin,suspended]);
   await db.query("INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '1 day')",[randomId(),id,await sha256(token)]);
   if(application)await db.query("INSERT INTO helper_applications(id,user_id,status,introduction,experience_description) VALUES($1,$2,$3,'PRIVATE-INTRO','PRIVATE-EXPERIENCE')",[randomId(),id,application]);
   for(const region of regions)await db.query('INSERT INTO helper_regions(id,helper_user_id,country,city,region_name) VALUES($1,$2,$3,$4,$5)',[randomId(),id,region.country,region.city,region.region_name??null]);
   return {id,token};
  };
  const question=async(owner,{guide=null,status='open',hidden=false,country='Spain',city='Málaga',region_name=null,created='2026-01-01T00:00:00.123456Z',expires=null,body='PRIVATE-BODY',title='Synthetic travel question'}={})=>{
   const id=randomId(),escrow=status==='accepted'?'paid':status==='cancelled'?'refunded':'held';
   await db.query(`INSERT INTO questions(id,user_id,assigned_helper_user_id,country,city,region_name,category,urgency,title,body,reward_points,status,escrow_state,moderation_hidden,created_at,updated_at,expires_at)
    VALUES($1,$2,$3,$4,$5,$6,'교통','보통',$7,$8,10,$9,$10,$11,$12,$12,$13)`,[id,owner.id,guide?.id??null,country,city,region_name,title,body,status,escrow,hidden,created,expires]);
   return id;
  };
  const scope=async({admin=false}={})=>{
   const location={country:'Synthetic country',city:randomId()},owner=await actor(),guide=await actor({admin,application:'approved',regions:[location]});
   return {owner,guide,location,q:(options={})=>question(owner,{...location,...options})};
  };
  const page=async(who,params='')=>{
   const result=await api(`${path}${params?'?'+params:''}`,who);assert.equal(result.status,200,JSON.stringify(result));
   assert.equal(result.headers.get('cache-control'),'no-store');assert.deepEqual(Object.keys(result.data).sort(),['items','next_cursor']);return result.data;
  };
  const collect=async(who)=>{
   const items=[];let cursor=null,pages=0;
   do{const data=await page(who,cursor?`cursor=${encodeURIComponent(cursor)}`:'');assert.ok(data.items.length<=20);items.push(...data.items);cursor=data.next_cursor;assert.ok(++pages<100,'Keyset pages must progress');}while(cursor!==null);
   return items;
  };
  const error=(result,status,code)=>{assert.equal(result.status,status,JSON.stringify(result));assert.equal(result.data.error.code,code);assert.deepEqual(Object.keys(result.data),['error']);};

  await t.test('active accounts and approved applications are required even for administrators',async()=>{
   error(await api(path),401,'UNAUTHENTICATED');
   for(const admin of [false,true])for(const application of [null,'pending','rejected','suspended']){
    const who=await actor({admin,application});
    error(await api(path,who),403,'HELPER_NOT_APPROVED');
    error(await api(path+'?limit=200',who),403,'HELPER_NOT_APPROVED','Gate runs before query inspection');
   }
   const suspended=await actor({admin:true,suspended:true,application:'approved'});
   error(await api(path,suspended),403,'ACCOUNT_SUSPENDED');
   assert.deepEqual(await page(await actor({application:'approved'})),{items:[],next_cursor:null});
  });

  await t.test('more than 200 eligible rows remain reachable with exact ties and microseconds',async()=>{
   const {owner,guide,location,q}=await scope();
   await db.query(`INSERT INTO questions(id,user_id,country,city,category,urgency,title,body,reward_points,created_at,updated_at)
    SELECT gen_random_uuid(),$1,$2,$3,'교통','보통','Eligible','PRIVATE-BODY',1,
    stamp,stamp FROM (SELECT '2026-01-01T00:00:00.123999Z'::timestamptz-floor(n/3)*interval '1 microsecond' AS stamp FROM generate_series(0,246) n) times`,[owner.id,location.country,location.city]);
   await db.query(`INSERT INTO questions(id,user_id,country,city,category,urgency,title,body,reward_points,created_at)
    SELECT gen_random_uuid(),$1,$2,'Unrelated region','교통','보통','Unrelated','PRIVATE-BODY',1,
    '2026-02-01T00:00:00Z'::timestamptz+n*interval '1 microsecond' FROM generate_series(1,260) n`,[owner.id,location.country]);
   const expected=(await db.query("SELECT id FROM questions WHERE user_id=$1 AND title='Eligible' ORDER BY created_at DESC,id DESC",[owner.id])).rows.map(row=>row.id);
   const first=await page(guide);assert.equal(first.items.length,20);assert.equal(typeof first.next_cursor,'string');
   const items=await collect(guide);assert.deepEqual(items.map(row=>row.id),expected);assert.equal(new Set(items.map(row=>row.id)).size,247);
   assert.ok(items.every(row=>/^2026-01-01T00:00:00\.123\d{3}Z$/.test(row.created_at)));assert.notEqual(items[0].created_at,items.at(-1).created_at);
   assert.equal(items[0].created_at,items[1].created_at,'Exact timestamp ties use the UUID order');
   await q({created:'2026-03-01T00:00:00.000001Z'});
   assert.deepEqual((await page(guide,'cursor='+first.next_cursor)).items.map(row=>row.id),expected.slice(20,40),'Newer inserts do not shift older keyset pages');
   const exact=await scope();for(let n=0;n<20;n++)await exact.q();
   const boundary=await page(exact.guide);assert.equal(boundary.items.length,20);assert.equal(boundary.next_cursor,null);
  });

  await t.test('ineligible and hidden rows before and between pages cannot starve ordinary or admin guides',async()=>{
   for(const admin of [false,true]){
    const {owner,guide,location,q}=await scope({admin}),visible=[];
    for(let n=0;n<25;n++)visible.push(await q({created:`2026-01-01T00:00:${String(n).padStart(2,'0')}.000001Z`}));
    await db.query(`INSERT INTO questions(id,user_id,country,city,category,urgency,title,body,reward_points,moderation_hidden,created_at)
     SELECT gen_random_uuid(),$1,$2,$3,'교통','보통','Hidden','PRIVATE-BODY',1,true,
     '2026-02-01T00:00:00Z'::timestamptz+n*interval '1 microsecond' FROM generate_series(1,80) n`,[owner.id,location.country,location.city]);
    for(let n=0;n<24;n++)await q({hidden:true,created:`2026-01-01T00:00:${String(n).padStart(2,'0')}.500001Z`});
    await question(guide,{...location,created:'2026-02-01T00:00:00Z'});
    await q({expires:'2020-01-01T00:00:00Z'});
    for(const status of ['assigned','answered','accepted','cancelled','expired','reported','disputed'])await q({guide,status});
    await q({guide,status:'open'});
    for(const direction of ['outbound','inbound','suspended']){
     const other=await actor({suspended:direction==='suspended'});
     if(direction==='outbound')await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[guide.id,other.id]);
     if(direction==='inbound')await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[other.id,guide.id]);
     for(let n=0;n<25;n++)await question(other,{...location,created:'2026-02-01T00:00:00Z'});
    }
    const first=await page(guide);assert.equal(first.items.length,20);
    const second=await page(guide,'cursor='+first.next_cursor);assert.equal(second.items.length,5);assert.equal(second.next_cursor,null);
    assert.deepEqual([...first.items,...second.items].map(row=>row.id),visible.reverse());
    await db.query('UPDATE questions SET moderation_hidden=true WHERE id=ANY($1::uuid[])',[visible]);
    assert.deepEqual(await page(guide,'cursor='+first.next_cursor),{items:[],next_cursor:null});
   }
  });

  await t.test('catalog aliases and exact optional neighborhood rules agree with the authoritative claim gate',async()=>{
   for(const place of knownPlaces){
    const owner=await actor(),guide=await actor({application:'approved',regions:[{country:place.countryKo,city:place.nativeName.normalize('NFD').toUpperCase(),region_name:'Centro'}]});
    const cases=new Map();
    for(const country of new Set([place.country,place.countryKo,...place.countryAliases]))cases.set(JSON.stringify([country,place.city]),[country,place.city]);
    for(const city of new Set([place.city,place.cityKo,place.nativeName,...place.aliases]))cases.set(JSON.stringify([place.country,city]),[place.country,city]);
    const matching=[];
    for(const [country,city] of cases.values())matching.push(await question(owner,{country:country.toUpperCase().normalize('NFD'),city:city.toUpperCase().normalize('NFD'),region_name:'CENTRO'}));
    matching.push(await question(owner,{country:place.country,city:place.city,region_name:null}));
    matching.push(await question(owner,{country:place.country,city:place.city,region_name:''}));
    const wrongCountry=await question(owner,{country:'Unrelated country',city:place.city,region_name:'Centro'});
    const wrongNeighborhood=await question(owner,{country:place.country,city:place.city,region_name:'Central'});
    const partialNeighborhood=await question(owner,{country:place.country,city:place.city,region_name:'Centro East'});
    assert.deepEqual(new Set((await collect(guide)).map(row=>row.id)),new Set(matching),place.id);
    for(const id of [wrongCountry,wrongNeighborhood,partialNeighborhood])error(await api(`/questions/${id}/accept`,guide,{method:'POST',body:{}}),403,'REGION_MISMATCH');
    for(const id of matching)assert.equal((await api(`/questions/${id}/accept`,guide,{method:'POST',body:{}})).status,200,place.id);
    assert.deepEqual((await page(guide)).items,[]);
    // A blank guide region is city-wide, including a question neighborhood.
    await db.query("UPDATE helper_regions SET region_name='' WHERE helper_user_id=$1",[guide.id]);
    assert.deepEqual(new Set((await collect(guide)).map(row=>row.id)),new Set([wrongNeighborhood,partialNeighborhood]));
    for(const id of [wrongNeighborhood,partialNeighborhood])assert.equal((await api(`/questions/${id}/accept`,guide,{method:'POST',body:{}})).status,200);
   }
   const pairs=[
    [['Japan','東京'],['Japan','大阪']], [['Russia','Москва'],['Russia','Казань']],
    [['A:B','C'],['A','B:C']], [['Japan','A-B'],['Japan','AB']],
    [['日本','同名'],['中国','同名']], [['Spain','Valencia'],['España','VALENCIA']],
    [['Russia','Москва'],['Russia','МОСКВА']],
   ];
   for(const [region,wrongPlace] of pairs){
    const owner=await actor(),guide=await actor({application:'approved',regions:[{country:region[0],city:region[1]}]});
    const good=await question(owner,{country:region[0],city:region[1]}),bad=await question(owner,{country:wrongPlace[0],city:wrongPlace[1]});
    assert.deepEqual((await collect(guide)).map(row=>row.id),[good]);
    error(await api(`/questions/${bad}/accept`,guide,{method:'POST',body:{}}),403,'REGION_MISMATCH');
    assert.equal((await api(`/questions/${good}/accept`,guide,{method:'POST',body:{}})).status,200);
   }
  });

  await t.test('every next page rechecks current regions, approval, blocks, account and session',async()=>{
   const {guide,owner,location,q}=await scope();for(let n=0;n<23;n++)await q();
   const {next_cursor:cursor}=await page(guide),next=path+'?cursor='+cursor;
   await db.query("UPDATE helper_regions SET city='Changed region' WHERE helper_user_id=$1",[guide.id]);
   assert.deepEqual(await page(guide,'cursor='+cursor),{items:[],next_cursor:null});
   await db.query('UPDATE helper_regions SET city=$2 WHERE helper_user_id=$1',[guide.id,location.city]);
   assert.equal((await page(guide,'cursor='+cursor)).items.length,3);
   await db.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2)',[owner.id,guide.id]);
   assert.deepEqual(await page(guide,'cursor='+cursor),{items:[],next_cursor:null});
   await db.query('DELETE FROM user_blocks WHERE blocker_id=$1',[owner.id]);
   for(const status of ['suspended','pending','rejected']){
    await db.query('UPDATE helper_applications SET status=$2 WHERE user_id=$1',[guide.id,status]);error(await api(next,guide),403,'HELPER_NOT_APPROVED');
   }
   await db.query("UPDATE helper_applications SET status='approved' WHERE user_id=$1",[guide.id]);
   await db.query('UPDATE users SET is_suspended=true WHERE id=$1',[guide.id]);error(await api(next,guide),403,'ACCOUNT_SUSPENDED');
   await db.query('UPDATE users SET is_suspended=false WHERE id=$1',[guide.id]);
   await db.query('DELETE FROM sessions WHERE user_id=$1',[guide.id]);error(await api(next,guide),401,'UNAUTHENTICATED');
  });

  await t.test('revocation committed after authentication is enforced under the safety gate',async()=>{
   for(const change of ['approval','suspend','delete','logout','expire']){
    const {guide}=await scope();let seen;const authenticated=new Promise(resolve=>{seen=resolve;});
    const wrapped={...db,query:async(sql,params)=>{const result=await db.query(sql,params);if(sql==='SELECT * FROM users WHERE id=$1'&&params[0]===guide.id)seen();return result;}};
    rebuild(wrapped);let reading;
    try{
     await db.transaction(async tx=>{
      await tx.query('SELECT pg_advisory_xact_lock(73284129)');
      reading=api(path,guide);await bounded(authenticated,'authentication before revocation');
      if(change==='approval')await tx.query("UPDATE helper_applications SET status='suspended' WHERE user_id=$1",[guide.id]);
      else if(change==='suspend')await tx.query('UPDATE users SET is_suspended=true WHERE id=$1',[guide.id]);
      else if(change==='logout')await tx.query('DELETE FROM sessions WHERE user_id=$1',[guide.id]);
      else if(change==='expire')await tx.query("UPDATE sessions SET expires_at=now()-interval '1 day' WHERE user_id=$1",[guide.id]);
      else {
       await tx.query('DELETE FROM helper_regions WHERE helper_user_id=$1',[guide.id]);
       await tx.query('DELETE FROM helper_applications WHERE user_id=$1',[guide.id]);
       await tx.query('DELETE FROM users WHERE id=$1',[guide.id]);
      }
     });
     error(await bounded(reading,'revoked discovery'),['approval','suspend'].includes(change)?403:401,change==='approval'?'HELPER_NOT_APPROVED':change==='suspend'?'ACCOUNT_SUSPENDED':'UNAUTHENTICATED');
    }finally{rebuild();if(reading)await reading;}
   }
  });

  await t.test('account, session, approval, question and safety locks survive through the complete read',async()=>{
   const {guide,q}=await scope(),id=await q();let reached,release;
   const locked=new Promise(resolve=>{reached=resolve;}),resume=new Promise(resolve=>{release=resolve;});
   rebuild({...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    const result=await tx.query(sql,params);if(sql.includes('LIMIT $5 FOR SHARE OF q')){reached();await resume;}return result;
   }}))});
   const reading=api(path,guide);
   try{
    await bounded(locked,'discovery holds locks');
    for(const [sql,params] of [
     ['UPDATE users SET is_suspended=true WHERE id=$1',[guide.id]],
     ['DELETE FROM sessions WHERE user_id=$1',[guide.id]],
     ["UPDATE helper_applications SET status='suspended' WHERE user_id=$1",[guide.id]],
     ["UPDATE questions SET status='assigned',assigned_helper_user_id=$2 WHERE id=$1",[id,guide.id]],
     ['SELECT pg_advisory_xact_lock(73284129)',[]],
    ])await assert.rejects(db.transaction(async tx=>{await tx.query("SET LOCAL lock_timeout='75ms'");await tx.query(sql,params);}),error=>error.code==='55P03');
   }finally{release();rebuild();}
   const result=await bounded(reading,'locked discovery completes');assert.equal(result.status,200);assert.deepEqual(result.data.items.map(row=>row.id),[id]);
  });

  await t.test('question expiry uses the current read time after waiting for the safety gate',async()=>{
   const {guide,q}=await scope(),id=await q({expires:'2099-01-01T00:00:00Z'});let reached;
   const waiting=new Promise(resolve=>{reached=resolve;});
   rebuild({...db,transaction:fn=>db.transaction(tx=>fn({query:async(sql,params)=>{
    if(sql==='SELECT pg_advisory_xact_lock_shared(73284129)')reached();return tx.query(sql,params);
   }}))});
   let reading;
   try{
    await db.transaction(async tx=>{
     await tx.query('SELECT pg_advisory_xact_lock(73284129)');reading=api(path,guide);await bounded(waiting,'discovery transaction begins');
     await tx.query('UPDATE questions SET expires_at=clock_timestamp() WHERE id=$1',[id]);
    });
    const result=await bounded(reading,'expired discovery completes');assert.equal(result.status,200);assert.deepEqual(result.data,{items:[],next_cursor:null});
   }finally{rebuild();if(reading)await reading;}
  });

  await t.test('compact pages omit private detail and metadata without nested reads or state changes; legacy detail remains',async()=>{
   const {owner,guide,q}=await scope(),id=await q({body:'PRIVATE-BODY-'.repeat(800)}),answerId=randomId();
   await db.query("INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,'PRIVATE-ANSWER','PRIVATE-EVIDENCE','PRIVATE-METHOD')",[answerId,id,guide.id]);
   await db.query('UPDATE questions SET accepted_answer_id=$2 WHERE id=$1',[id,answerId]);
   await db.query("INSERT INTO answer_evidence_links(id,answer_id,url,title,source_type) VALUES($1,$2,'https://example.invalid/private-evidence','PRIVATE-LINK','other')",[randomId(),answerId]);
   await db.query("INSERT INTO question_comments(id,question_id,user_id,body) VALUES($1,$2,$3,'PRIVATE-COMMENT')",[randomId(),id,owner.id]);
   await db.query("INSERT INTO question_images(id,question_id,storage_key,content_type,byte_length) VALUES($1,$2,'PRIVATE-STORAGE','image/png',100)",[randomId(),id]);
   const snapshot=async()=>{const result={};for(const table of ['users','questions','answers','answer_evidence_links','question_comments','question_images','point_transactions','helper_applications','helper_regions','user_blocks','content_reports','moderation_actions','idempotency_keys'])result[table]=(await db.query(`SELECT row_to_json(t)::text AS row FROM ${table} t ORDER BY row_to_json(t)::text`)).rows;return result;};
   const before=await snapshot(),queries=[];
   rebuild({...db,transaction:fn=>db.transaction(tx=>fn({query:(sql,params)=>{queries.push(sql);assert.ok(!/\b(?:answers|answer_evidence_links|question_comments|question_images|point_transactions)\b/.test(sql),'Discovery must not query nested detail or metrics');return tx.query(sql,params);}}))});
   let data;try{data=await page(guide);}finally{rebuild();}
   assert.deepEqual(Object.keys(data.items[0]).sort(),compactKeys);assert.equal(data.items[0].id,id);
   const serialized=JSON.stringify(data);assert.ok(Buffer.byteLength(serialized)<1000);
   for(const privateValue of ['PRIVATE','example.invalid',guide.token,owner.token,'body','answers','accepted_answer_id','escrow','moderation','latitude','longitude'])assert.ok(!serialized.includes(privateValue),privateValue);
   assert.equal(queries.length,5,'One safety lock, current actor, session, approval, and bounded question SELECT');
   assert.deepEqual(await snapshot(),before,'Read changes no balances, escrow, assignment, statuses, moderation, regions or idempotency');
   const legacy=await api('/guide/questions',guide);assert.equal(legacy.status,200);assert.ok(Array.isArray(legacy.data));assert.equal(legacy.data[0].body,'PRIVATE-BODY-'.repeat(800));assert.equal(legacy.data[0].answers.length,1);assert.equal(legacy.data[0].question_images.length,1);
  });

  await t.test('strict query and signed cursors reject malformed, cross-account and cross-endpoint reuse',async()=>{
   const {guide,location,q}=await scope();for(let n=0;n<21;n++)await q();
   const other=await actor({application:'approved',regions:[location]}),{next_cursor:cursor}=await page(guide);
   for(const params of ['cursor=a&cursor=b','limit=200','offset=20','status=open','country=Spain','city=Málaga','region=Centro','role=guide','user_id='+guide.id])error(await api(path+'?'+params,guide),400,'INVALID_DISCOVERY_QUERY');
   for(const value of ['','a','not.a.cursor',cursor+'.extra',cursor+'=',cursor.slice(0,-2)+'aa','x'.repeat(1025)])error(await api(path+'?cursor='+encodeURIComponent(value),guide),400,'INVALID_DISCOVERY_CURSOR');
   error(await api(path+'?cursor='+cursor,other),400,'INVALID_DISCOVERY_CURSOR');
   error(await api('/activity/questions?cursor='+cursor,guide),400,'INVALID_ACTIVITY_CURSOR');
   const payload=JSON.parse(Buffer.from(cursor.split('.')[0],'base64url').toString());
   for(const changes of [{v:2},{user:other.id},{created_at:'2026-02-30T00:00:00.123456Z'},{created_at:'0000-01-01T00:00:00.123456Z'},{created_at:'2026-01-01T00:00:00.123Z'},{created_at:'infinity'},{id:'not-a-uuid'},{extra:'ignored?'}]){
    const encoded=Buffer.from(JSON.stringify({...payload,...changes})).toString('base64url'),signed=`${encoded}.${await sign(secret,`malaga-guide-discovery-v1:${encoded}`)}`;
    error(await api(path+'?cursor='+signed,guide),400,'INVALID_DISCOVERY_CURSOR');
   }
   for(const prefix of ['malaga-activity-v1:','malaga-operations-v1:','malaga-exchange-issues-v1:']){
    const encoded=cursor.split('.')[0],wrong=`${encoded}.${await sign(secret,`${prefix}${encoded}`)}`;error(await api(path+'?cursor='+wrong,guide),400,'INVALID_DISCOVERY_CURSOR');
   }
   const signedPayload=async(bytes)=>{const encoded=bytes.toString('base64url');return `${encoded}.${await sign(secret,`malaga-guide-discovery-v1:${encoded}`)}`;};
   for(const bytes of [Buffer.from('{bad json'),Buffer.from([0xff,0xfe]),Buffer.from('null'),Buffer.from('[]')])error(await api(path+'?cursor='+await signedPayload(bytes),guide),400,'INVALID_DISCOVERY_CURSOR');
   assert.equal((await page(guide,'cursor='+cursor)).items.length,1);
  });
  assert.equal(imageReads,0);assert.deepEqual(errors,[],'No unexpected database or API errors');
 }finally{
  if(server)await new Promise(resolve=>server.close(resolve));await db?.close();await pool.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await pool.end();
 }
});
