import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import {execFileSync} from 'node:child_process';
import {createDatabase,migrate} from '../src/db.mjs';
import {createApp} from '../src/app.mjs';
import {seedDevelopment} from '../src/seed-data.mjs';
import {randomId,sha256} from '../src/crypto.mjs';
import {cityCatalog,knownPlaces,findCity,normalizeLocation,isSupportedLocation,nearestSupported,locationIdentity,locationAliases} from '../src/city-catalog.mjs';

const payload=(overrides={})=>({country:'France',city:'Paris',category:'교통',urgency:'보통',title:'Synthetic route question',body:'Which bus reaches the city center from this station?',reward_points:10,...overrides});
const application=(regions)=>({languages:['English','한국어'],regions,introduction:'Synthetic guide for local testing only.',experience_description:'Synthetic experience for testing the application flow.'});
const stable=value=>Array.isArray(value)?`[${value.map(stable).join(',')}]`:value&&typeof value==='object'?`{${Object.keys(value).sort().map(k=>`${JSON.stringify(k)}:${stable(value[k])}`).join(',')}}`:JSON.stringify(value);

test('proposed city catalog resolves country-scoped aliases and conservatively associates coordinates',()=>{
 assert.equal(cityCatalog.coverageStatus,'proposed');assert.equal(cityCatalog.availabilityGuaranteed,false);
 assert.equal(knownPlaces.length,20);assert.equal(knownPlaces.filter(p=>p.legacyDemo).length,1);
 for(const place of knownPlaces) {
  for(const country of [place.country,place.countryKo,...place.countryAliases])for(const city of [place.city,place.cityKo,place.nativeName,...place.aliases]) {
   assert.equal(findCity(country,city)?.id,place.id,`${country}/${city}`);
   assert.equal(findCity(country.toUpperCase(),city.normalize('NFD').toUpperCase())?.id,place.id);
  }
  assert.equal(nearestSupported({latitude:place.latitude,longitude:place.longitude,maxDistanceKm:0})?.id,place.id);
 }
 assert.equal(findCity('US','Paris'),null);assert.equal(findCity('France','New York'),null);
 assert.equal(isSupportedLocation('Spain','Valencia'),false);assert.equal(findCity('constructor','Paris'),null);
 assert.equal(normalizeLocation('  Ma\u0301LaGa! '),'malaga');assert.equal(normalizeLocation('말라가'.normalize('NFD')),'말라가');
 assert.equal(findCity('대한민국','Paris'),null);assert.equal(findCity('U.S.A.','Washington, D.C.')?.id,'us-washington-dc');
 for(const point of [{latitude:0,longitude:0},{latitude:53.3498,longitude:-6.2603},{latitude:NaN,longitude:0},{latitude:91,longitude:0},{latitude:0,longitude:181},{latitude:48.8566,longitude:2.3522,maxDistanceKm:-1}])assert.equal(nearestSupported(point),null);
 assert.equal(locationIdentity('스페인','말라가'),locationIdentity('ESPAÑA','Ma\u0301laga'));
 assert.equal(locationIdentity('España','Valencia'),locationIdentity('Spain','Valencia'));
 assert.notEqual(locationIdentity('España','Valencia'),locationIdentity('Spain','VALENCIA'));
 assert.notEqual(locationIdentity('US','Paris'),locationIdentity('France','Paris'));
 for(const [first,second] of [[['Japan','東京'],['Japan','大阪']],[['Russia','Москва'],['Russia','Казань']],[['A:B','C'],['A','B:C']],[['Japan','A-B'],['Japan','AB']],[['日本','同名'],['中国','同名']]])assert.notEqual(locationIdentity(...first),locationIdentity(...second));
 execFileSync(process.execPath,['scripts/generate-city-catalog.mjs','--check'],{cwd:new URL('../../',import.meta.url)});
});

test('real PostgreSQL catalog validation, legacy matches, permissions and durable retries',async t=>{
 assert.ok(process.env.TEST_DATABASE_URL,'TEST_DATABASE_URL must name disposable real PostgreSQL.');
 const admin=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL});
 const schema=`catalog_${randomId().replaceAll('-','')}`;let db;const errors=[];
 try {
  await admin.query(`CREATE SCHEMA ${schema}`);db=await createDatabase({connectionString:process.env.TEST_DATABASE_URL,schema});await migrate(db);await migrate(db);
  await seedDevelopment(db,{enabled:true});const rerun=await seedDevelopment(db,{enabled:true});assert.ok(rerun.every(row=>!row.created));
  const app=createApp({db,storage:{},config:{imageSigningSecret:'synthetic-catalog-test-secret-at-least-32-chars',onError:error=>errors.push(error)}});
  const call=async(path,{actor,method='GET',body,key=randomId()}={})=>{
   const response=await app(new Request(`http://localhost/api${path}`,{method,headers:{...(actor?{Authorization:`Bearer ${actor.token}`} : {}),...(body!==undefined?{'Content-Type':'application/json','Idempotency-Key':key}:{} )},...(body!==undefined?{body:JSON.stringify(body)}:{})}));
   return {status:response.status,data:await response.json()};
  };
  const login=async(email)=>{const result=await call('/auth/login',{method:'POST',body:{email,password:'daisy-dev-1234'}});assert.equal(result.status,200);return result.data;};
  const owner=await login('questioner1@example.com'),europe=await login('guide-europe@example.com'),us=await login('guide-us@example.com'),malaga=await login('answerer1@example.com'),reviewer=await login('admin@example.com'),applicant=await login('questioner3@example.com');
  const post=(actor,path,body={},key=randomId())=>call(path,{actor,method:'POST',body,key});
  const create=async(body)=>{const response=await post(owner,'/questions',payload(body));assert.equal(response.status,201,JSON.stringify(response));return response.data.id;};

  await t.test('PostgreSQL and JS normalization and identity agree for aliases and historical values',async()=>{
   const aliases=JSON.stringify(locationAliases);
   for(const place of knownPlaces)for(const country of [place.country,place.countryKo,...place.countryAliases])for(const city of [place.cityKo,place.nativeName]) {
    const c=country.toUpperCase().normalize('NFD'),p=city.toUpperCase().normalize('NFD');
    const {rows:[row]}=await db.query('SELECT normalize_location($1) AS country_key,normalize_location($2) AS city_key,location_identity($1,$2,$3::jsonb) AS identity',[c,p,aliases]);
   assert.equal(row.country_key,normalizeLocation(c));assert.equal(row.city_key,normalizeLocation(p));assert.equal(row.identity,locationIdentity(c,p));
   }
   for(const [country,city] of [['Japan','東京'],['Japan','大阪'],['Russia','МОСКВА'],['Russia','Казань'],['A:B','C'],['A','B:C'],['Japan','A-B'],['Japan','AB'],['日本','同名'],['中国','同名'],['  Spain  ','  Valencia  '],['\tCountry\u00a0','\u3000City\ufeff'],['Unknown','E\u0301vora'],['Country','A"B\\C']]) {
    const {rows:[row]}=await db.query('SELECT location_identity($1,$2,$3::jsonb) AS identity',[country,city,aliases]);
    assert.equal(row.identity,locationIdentity(country,city),`${country}/${city}`);
   }
  });
  await t.test('new locations canonicalize; wrong-country and unknown-city requests leave no debit or application',async()=>{
   const before=(await call('/profile',{actor:owner})).data.point_balance;
   for(const invalid of [{country:'United States',city:'Paris'},{country:'France',city:'New York'},{country:'Spain',city:'Valencia'}]) {
    const result=await post(owner,'/questions',payload(invalid));assert.equal(result.status,400);assert.equal(result.data.error.code,'UNSUPPORTED_CITY');
    assert.equal((await post(applicant,'/helper/application',application([invalid]))).data.error.code,'UNSUPPORTED_CITY');
   }
   assert.equal((await call('/profile',{actor:owner})).data.point_balance,before);
   assert.equal((await call('/helper/application',{actor:applicant})).data,null);
   const id=await create({country:'미국',city:'뉴욕'}),question=(await call(`/questions/${id}`,{actor:owner})).data;
   assert.equal(question.country,'United States');assert.equal(question.city,'New York');
   assert.equal((await post(europe,`/questions/${id}/accept`)).data.error.code,'REGION_MISMATCH');
   assert.ok((await call('/guide/questions',{actor:us})).data.some(q=>q.id===id));
   assert.ok(!(await call('/guide/questions',{actor:europe})).data.some(q=>q.id===id));
   assert.equal((await post(us,`/questions/${id}/accept`)).status,200);
   const profile=await call('/profile',{actor:owner,method:'PATCH',body:{current_country:'체코',current_city:'Praha'}});assert.equal(profile.data.current_country,'Czechia');assert.equal(profile.data.current_city,'Prague');
   assert.equal((await call('/profile',{actor:owner,method:'PATCH',body:{current_country:'France',current_city:'Boston'}})).data.error.code,'UNSUPPORTED_CITY');
   assert.equal((await call('/profile',{actor:owner,method:'PATCH',body:{current_country:null,current_city:null}})).status,200);
  });
  await t.test('application aliases deduplicate and review/claim permissions stay authoritative',async()=>{
   const body=application([{country:'프랑스',city:'파리'},{country:'FR',city:'PARIS'},{country:'US',city:'Boston'}]),key=randomId();
   const first=await post(applicant,'/helper/application',body,key);assert.equal(first.status,201);assert.deepEqual(await post(applicant,'/helper/application',body,key),first);
   assert.equal((await call('/helper/regions',{actor:applicant})).data.length,2);
   assert.equal((await call('/guide/questions',{actor:applicant})).status,403);
   assert.equal((await post(applicant,`/admin/applications/${first.data.id}/review`,{status:'approved'})).status,403);
   assert.equal((await post(reviewer,`/admin/applications/${first.data.id}/review`,{status:'approved'})).status,200);
   assert.deepEqual(await post(applicant,'/helper/application',body,key),first,'A replay does not reset approval to pending');
   assert.equal((await call('/helper/application',{actor:applicant})).data.status,'approved');
   assert.equal((await post(applicant,'/helper/application',{...body,regions:[{country:'US',city:'Paris'}]},key)).data.error.code,'IDEMPOTENCY_CONFLICT');
  });
  await t.test('legacy Spanish aliases and unknown historical cities use identical feed and claim rules',async()=>{
   await db.query("UPDATE helper_regions SET country='스페인',city='말라가' WHERE helper_user_id=$1",[malaga.user.id]);
   const canonical=await create({country:'ESPAÑA',city:'Ma\u0301laga'});
   assert.ok((await call('/guide/questions',{actor:malaga})).data.some(q=>q.id===canonical));
   assert.equal((await post(malaga,`/questions/${canonical}/accept`)).status,200);
   const historical=await create({country:'Spain',city:'Málaga'});
   await db.query("UPDATE questions SET country='España',city='Valencia' WHERE id=$1",[historical]);
   await db.query("INSERT INTO helper_regions(id,helper_user_id,country,city) VALUES($1,$2,'Spain','Valencia')",[randomId(),malaga.user.id]);
   assert.ok((await call('/guide/questions',{actor:malaga})).data.some(q=>q.id===historical));
   assert.equal((await post(malaga,`/questions/${historical}/accept`)).status,200);
   const evidence={body:'Synthetic bus route answer for this historical question.',evidence_summary:'A synthetic source for testing only.',verification_method:'Synthetic test',links:[{url:'https://example.com/synthetic-transit',source_type:'other'}]};
   assert.equal((await post(us,`/questions/${historical}/answers`,evidence)).status,404,'Only participants can answer a historical assigned question');
   const answer=await post(malaga,`/questions/${historical}/answers`,evidence);assert.equal(answer.status,201);
   const acceptPath=`/questions/${historical}/answers/${answer.data.id}/accept`;
   assert.equal((await post(owner,acceptPath)).status,200);assert.equal((await post(owner,acceptPath)).status,200);
   const metrics=(await call('/guide/me',{actor:malaga})).data;assert.equal(metrics.accepted_answer_count,1);assert.equal(metrics.earned_mock_points,10);
   const final=(await call(`/questions/${historical}`,{actor:owner})).data;assert.equal(final.country,'España');assert.equal(final.city,'Valencia');assert.equal(final.status,'accepted');
   const count=(await db.query("SELECT count(*)::int AS n FROM point_transactions WHERE question_id=$1 AND type='reward'",[historical])).rows[0].n;assert.equal(count,1);
  });
  await t.test('distinct historical scripts and punctuation cannot authorize another guide region',async()=>{
   const guide=await login('answerer2@example.com');
   const pairs=[
    [['Japan','東京'],['Japan','大阪']],
    [['Russia','Москва'],['Russia','Казань']],
    [['A:B','C'],['A','B:C']],
    [['日本','同名'],['中国','同名']],
    [['Japan','A-B'],['Japan','AB']],
    [['Russia','Москва'],['Russia','МОСКВА']],
   ];
   for(const [region,wrongPlace] of pairs) {
    await db.query('INSERT INTO helper_regions(id,helper_user_id,country,city) VALUES($1,$2,$3,$4)',[randomId(),guide.user.id,...region]);
    const matching=await create(),unrelated=await create();
    await db.query('UPDATE questions SET country=$2,city=$3 WHERE id=$1',[matching,...region]);
    await db.query('UPDATE questions SET country=$2,city=$3 WHERE id=$1',[unrelated,...wrongPlace]);
    const feed=(await call('/guide/questions',{actor:guide})).data;
    assert.ok(feed.some(q=>q.id===matching));assert.ok(!feed.some(q=>q.id===unrelated),`${wrongPlace} must not match ${region}`);
    assert.equal((await post(guide,`/questions/${unrelated}/accept`)).data.error.code,'REGION_MISMATCH');
    assert.equal((await post(guide,`/questions/${matching}/accept`)).status,200);
    const untouched=(await call(`/questions/${unrelated}`,{actor:owner})).data;
    assert.equal(untouched.country,wrongPlace[0]);assert.equal(untouched.city,wrongPlace[1]);assert.equal(untouched.status,'open');
   }
  });
  await t.test('committed old-city retries survive catalog removal without a second debit',async()=>{
   const key=randomId(),original=payload({country:'Spain',city:'Málaga'});
   const committed=await post(owner,'/questions',original,key);assert.equal(committed.status,201);
   // Model a request committed by the previous unrestricted-city release.
   const historical={...original,city:'Valencia'};
   await db.query("UPDATE questions SET city='Valencia' WHERE id=$1",[committed.data.id]);
   await db.query('UPDATE idempotency_keys SET fingerprint=$3 WHERE user_id=$1 AND key=$2',[owner.user.id,key,await sha256(`POST:/api/questions:${stable(historical)}`)]);
   const before=(await call('/profile',{actor:owner})).data.point_balance;
   assert.deepEqual(await post(owner,'/questions',historical,key),committed);
   assert.equal((await call('/profile',{actor:owner})).data.point_balance,before);
   assert.equal((await post(owner,'/questions',historical)).data.error.code,'UNSUPPORTED_CITY');
   assert.equal((await post(owner,`/questions/${committed.data.id}/cancel`)).status,200);
   assert.equal((await post(owner,`/questions/${committed.data.id}/cancel`)).status,200);
  });
  assert.deepEqual(errors,[]);
 } finally {await db?.close();await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await admin.end();}
});
