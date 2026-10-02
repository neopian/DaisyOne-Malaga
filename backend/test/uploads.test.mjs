import test from 'node:test';
import assert from 'node:assert/strict';
import pg from 'pg';
import sharp from 'sharp';
import {mkdtemp,rm,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createApp} from '../src/app.mjs';
import {createDatabase,migrate} from '../src/db.mjs';
import {createDiskStorage} from '../src/storage.mjs';
import {randomId} from '../src/crypto.mjs';
import {metadataPhoto,invalidPhotos,privateMarker} from './image-fixtures.mjs';

const question={country:'Spain',city:'Malaga',category:'교통',urgency:'보통',title:'Synthetic photo question',body:'Which local bus reaches the old town from here?',reward_points:100};
const upload=({bytes,mime})=>({name:'synthetic-photo',content_type:mime,data_base64:bytes.toString('base64')});

test('real PostgreSQL uploads store and serve sanitized photos, and rejected photos never hold credits or write files',async t=>{
 assert.ok(process.env.TEST_DATABASE_URL,'TEST_DATABASE_URL must name disposable real PostgreSQL.');
 const admin=new pg.Pool({connectionString:process.env.TEST_DATABASE_URL}),schema=`photo_test_${randomId().replaceAll('-','')}`;
 const directory=await mkdtemp(join(tmpdir(),'photo-sanitization-'));let db;
 try {
  await admin.query(`CREATE SCHEMA ${schema}`);db=await createDatabase({connectionString:process.env.TEST_DATABASE_URL,schema});await migrate(db);
  const errors=[],storage=await createDiskStorage(directory);
  // Production and direct Request/Response construction use the same mandatory
  // sanitizer; there is no test-only default that would retain original bytes.
  const app=createApp({db,storage,config:{production:true,publicBaseUrl:'https://synthetic.example.com',imageSigningSecret:'synthetic-photo-secret-with-at-least-32-characters',onError:error=>errors.push(error)}});
  const api=async(path,{token,body,method='POST',key=randomId()}={})=>{
   const response=await app(new Request(`https://synthetic.example.com/api${path}`,{method,headers:{...(token?{authorization:`Bearer ${token}`} : {}),...(body!==undefined?{'content-type':'application/json','idempotency-key':key}: {})},...(body!==undefined?{body:JSON.stringify(body)}:{})}));
   return {status:response.status,data:await response.json()};
  };
  const registration=await api('/auth/register',{body:{email:'photos@example.com',name:'Synthetic photo user',password:'synthetic-photo-password'}});assert.equal(registration.status,201,JSON.stringify(registration));
  const actor=registration.data,token=actor.token;
  await t.test('accepted photos are sanitized on disk, in signed responses and export with exactly one retry hold',async()=>{
   const originals=await Promise.all(['jpeg','png','webp'].map(async format=>({bytes:await metadataPhoto(format),mime:`image/${format}`})));
   const body={...question,images:originals.map(upload)},key=randomId();
   const result=await api('/questions',{token,body,key});assert.equal(result.status,201,JSON.stringify(result));assert.deepEqual(await api('/questions',{token,body,key}),result);
   const id=result.data.id,rows=(await db.query('SELECT * FROM question_images WHERE question_id=$1 ORDER BY content_type',[id])).rows;
   assert.equal(rows.length,3);assert.equal((await readdir(directory)).length,3);
   const detail=(await api(`/questions/${id}`,{token,method:'GET'})).data;
   const exported=await api('/account/export',{token,body:{password:'synthetic-photo-password'}});assert.equal(exported.status,200,JSON.stringify(exported));
   for(const row of rows){
    const bytes=await storage.get(row.storage_key),original=originals.find(x=>x.mime===row.content_type).bytes;
    assert.notDeepEqual(bytes,original);assert.equal(bytes.length,row.byte_length);assert.equal(bytes.includes(Buffer.from(privateMarker)),false);
    const metadata=await sharp(bytes,{failOn:'warning'}).metadata();assert.deepEqual([metadata.width,metadata.height],[8,12]);
    for(const name of ['exif','xmp','iptc','icc','orientation'])assert.equal(metadata[name],undefined);
    await sharp(bytes,{failOn:'warning'}).raw().toBuffer();
    const url=detail.question_images.find(x=>x.id===row.id).image_url,response=await app(new Request(url));assert.equal(response.status,200);assert.equal(response.headers.get('content-type'),row.content_type);assert.deepEqual(Buffer.from(await response.arrayBuffer()),bytes);
    assert.equal(exported.data.images.find(x=>x.id===row.id).data_base64,bytes.toString('base64'));
   }
   assert.equal((await db.query("SELECT count(*)::int AS n FROM point_transactions WHERE user_id=$1 AND type='hold'",[actor.user.id])).rows[0].n,1);
  });
  await t.test('a malformed later photo leaves no new files, questions, image rows, holds or idempotency records',async()=>{
   const snapshot=async()=>({rows:(await db.query(`SELECT (SELECT point_balance FROM users WHERE id=$1) AS balance,(SELECT count(*)::int FROM questions) AS questions,(SELECT count(*)::int FROM question_images) AS images,(SELECT count(*)::int FROM point_transactions) AS ledger,(SELECT count(*)::int FROM idempotency_keys) AS retries`,[actor.user.id])).rows,files:await readdir(directory)});
   const before=await snapshot(),valid=upload({bytes:await metadataPhoto('png'),mime:'image/png'});
   for(const bad of await invalidPhotos()){
    const response=await api('/questions',{token,body:{...question,images:[valid,upload(bad)]}});
    assert.equal(response.status,400,bad.name+JSON.stringify(response));assert.equal(response.data.error.code,'INVALID_IMAGE');assert.deepEqual(await snapshot(),before,bad.name);
   }
   for(const data_base64 of ['!!!!','A===','AAA','',`${'A'.repeat(4*1024*1024)}AAAA`]){
    const response=await api('/questions',{token,body:{...question,images:[{...valid,data_base64}]}});assert.equal(response.status,400);assert.equal(response.data.error.code,'INVALID_IMAGE');assert.deepEqual(await snapshot(),before);
   }
  });
  assert.deepEqual(errors,[]);
 } finally{await db?.close();await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await admin.end();await rm(directory,{recursive:true,force:true});}
});
