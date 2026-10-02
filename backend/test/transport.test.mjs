import test from 'node:test';
import assert from 'node:assert/strict';
import {request as httpRequest} from 'node:http';
import {gzipSync,gunzipSync} from 'node:zlib';
import {setTimeout as delay} from 'node:timers/promises';
import {nodeServer} from '../src/server.mjs';

const paragraph='Synthetic local travel advice: airport bus stops, old-town walking access, official timetable evidence, and current opening hours. 교통 경로와 현지 확인 정보. ';
const questions=Array.from({length:60},(_,i)=>({id:`synthetic-question-${i}`,title:`Transit and walking question ${i}`,body:paragraph.repeat(12),country:'Spain',city:'Malaga',answers:[{id:`answer-${i}`,body:paragraph.repeat(8),evidence_summary:'Checked a synthetic timetable.',answer_evidence_links:[{url:'https://example.com/transit',title:'Synthetic public source',source_type:'official'}]}],question_comments:Array.from({length:4},(_,j)=>({id:`comment-${i}-${j}`,body:`Current details ${j}: ${paragraph}`,commenter:{name:'Synthetic participant'}}))}));
const payload=Buffer.from(JSON.stringify(questions)),questionId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const response=(bytes=payload,{status=200,headers={}}={})=>new Response(bytes,{status,headers:{'content-type':'application/json; charset=utf-8','cache-control':'no-store','content-length':String(bytes.length),...headers}});
const raw=(base,path='/api/questions',{headers={},method='GET'}={})=>new Promise((resolve,reject)=>{
 const req=httpRequest(new URL(base),{path,method,headers},res=>{const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks)}));res.on('error',reject);});req.on('error',reject);req.end();
});
async function withServer(handle,run,options={}) {
 const server=nodeServer(handle,options);await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 try{return await run(`http://127.0.0.1:${server.address().port}`);}finally{server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
}

test('real HTTP gzip reduces representative question payload bytes and exactly restores search/details and CORS headers',async t=>{
 await withServer(()=>response(payload,{headers:{'access-control-allow-origin':'https://app.example.com',vary:'Origin'}}),async base=>{
  const identity=await raw(base),compressed=await raw(base,'/api/questions?status=open',{headers:{'accept-encoding':'gzip',origin:'https://app.example.com'}});
  assert.equal(identity.status,200);assert.equal(compressed.status,200);assert.equal(identity.headers['content-encoding'],undefined);assert.equal(compressed.headers['content-encoding'],'gzip');
  assert.deepEqual(gunzipSync(compressed.body),identity.body);assert.deepEqual(JSON.parse(gunzipSync(compressed.body)),questions);
  assert.ok(compressed.body.length<payload.length*0.3,`${compressed.body.length}/${payload.length}`);
  assert.equal(compressed.headers['content-length'],undefined);assert.equal(identity.headers['content-length'],String(payload.length));assert.equal(compressed.headers['cache-control'],'no-store');assert.equal(compressed.headers['access-control-allow-origin'],'https://app.example.com');
  assert.deepEqual(compressed.headers.vary.toLowerCase().split(',').map(x=>x.trim()).sort(),['accept-encoding','origin']);assert.equal(identity.headers.vary,compressed.headers.vary);
  for(const path of [`/api/questions/${questionId}`,'/api/guide/questions','/api/points'])assert.equal((await raw(base,path,{headers:{'accept-encoding':'gzip'}})).headers['content-encoding'],'gzip');
  t.diagnostic(`Synthetic HTTP payload: ${payload.length} identity bytes -> ${compressed.body.length} gzip bytes (${(100*compressed.body.length/payload.length).toFixed(1)}%); decompressed bytes identical`);
 });
});

test('encoding negotiation honors quality, exclusions, wildcard, identity, absent headers and an unavailable representation',async()=>{
 await withServer(()=>response(),async base=>{
  for(const value of [undefined,'','identity','br','gzip;q=0','gzip;q=0, *;q=1','gzip;q=0.5, identity;q=1','gzip;q=invalid','gzip;q=0, gzip;q=1']){
   const r=await raw(base,'/api/questions',{headers:value===undefined?{}:{'accept-encoding':value}});assert.equal(r.status,200,value);assert.equal(r.headers['content-encoding'],undefined,value);assert.deepEqual(r.body,payload,value);
  }
  for(const value of ['gzip','GZip;Q=1.000','deflate, gzip;q=0.4','*','gzip;q=1, identity;q=0.2','gzip;q=0.5, identity;q=0','*;q=0, gzip;q=1']){
   const r=await raw(base,'/api/questions',{headers:{'accept-encoding':value}});assert.equal(r.status,200,value);assert.equal(r.headers['content-encoding'],'gzip',value);assert.deepEqual(gunzipSync(r.body),payload,value);
  }
  for(const value of ['gzip;q=0, identity;q=0','br, *;q=0']){const r=await raw(base,'/api/questions',{headers:{'accept-encoding':value}});assert.equal(r.status,406);assert.equal(JSON.parse(r.body).error.code,'NOT_ACCEPTABLE');assert.equal(r.headers['cache-control'],'no-store');}
});
});

test('compact personal, discovery and operator pages use negotiated gzip without compressing denied responses',async()=>{
 const page=Buffer.from(JSON.stringify({items:Array.from({length:20},(_,i)=>({id:`synthetic-${i}`,title:`공항 이동 질문 ${i}`,status:'assigned',country:'France',city:'Paris',reward_points:100})),next_cursor:'synthetic-opaque-cursor'}));
 await withServer(request=>new URL(request.url).searchParams.has('denied')?
  response(Buffer.from('{"error":{"code":"ADMIN_REQUIRED"}}'),{status:403}):response(page),async base=>{
  for(const path of ['/api/activity/questions?role=traveler','/api/guide/discovery?cursor=synthetic','/api/admin/operations/questions?status=assigned']){
   const plain=await raw(base,path),compressed=await raw(base,path,{headers:{'accept-encoding':'gzip'}});
   assert.equal(compressed.headers['content-encoding'],'gzip');
   assert.equal(compressed.headers['cache-control'],'no-store');
   assert.deepEqual(gunzipSync(compressed.body),plain.body);
   assert.ok(compressed.body.length<plain.body.length);
   const denied=await raw(base,`${path}&denied=true`,{headers:{'accept-encoding':'gzip'}});
   assert.equal(denied.status,403);assert.equal(denied.headers['content-encoding'],undefined);
  }
 });
});

test('bridge preserves errors/status and excludes auth, exports, images, existing encodings and no-transform responses',async()=>{
 const encoded=gzipSync(payload),image=Buffer.from([137,80,78,71,13,10,26,10]);
 await withServer(request=>{
  const url=new URL(request.url);
  if(url.searchParams.has('error'))return response(Buffer.from(JSON.stringify({error:{code:'UNAUTHENTICATED',message:'Sign in to continue.'}})),{status:401,headers:{vary:'Origin','access-control-allow-origin':'https://app.example.com'}});
  if(url.searchParams.has('created'))return response(Buffer.from('{"id":"synthetic"}'),{status:201});
  if(url.searchParams.has('empty'))return new Response(null,{status:204,headers:{'cache-control':'no-store'}});
  if(url.searchParams.has('encoded'))return response(encoded,{headers:{'content-encoding':'gzip'}});
  if(url.searchParams.has('plain'))return response(payload,{headers:{'content-type':'text/plain'}});
  if(url.searchParams.has('no-transform'))return response(payload,{headers:{'cache-control':'private, no-store, no-transform'}});
  if(url.searchParams.has('star-vary'))return response(payload,{headers:{vary:'*'}});
  if(url.searchParams.has('existing-vary'))return response(payload,{headers:{vary:'Origin, accept-encoding'}});
  if(url.pathname.startsWith('/api/images/'))return response(image,{headers:{'content-type':'image/png','cache-control':'private, no-store'}});
  return response();
 },async base=>{
  for(const path of ['/api/auth/login','/api/auth/me','/api/profile','/api/account/export','/api/guide/me','/api/questions?plain','/api/questions?no-transform'])assert.equal((await raw(base,path,{headers:{'accept-encoding':'gzip'}})).headers['content-encoding'],undefined,path);
  const failure=await raw(base,'/api/questions?error',{headers:{'accept-encoding':'gzip'}});assert.equal(failure.status,401);assert.equal(failure.headers['content-encoding'],undefined);assert.equal(JSON.parse(failure.body).error.code,'UNAUTHENTICATED');assert.equal(failure.headers['cache-control'],'no-store');assert.equal(failure.headers.vary,'Origin');assert.equal(failure.headers['access-control-allow-origin'],'https://app.example.com');
  const created=await raw(base,'/api/questions?created',{headers:{'accept-encoding':'gzip'}});assert.equal(created.status,201);assert.equal(created.headers['content-encoding'],undefined);
  const empty=await raw(base,'/api/questions?empty',{headers:{'accept-encoding':'gzip'}});assert.equal(empty.status,204);assert.equal(empty.body.length,0);assert.equal(empty.headers['content-encoding'],undefined);
  const already=await raw(base,'/api/questions?encoded',{headers:{'accept-encoding':'gzip'}});assert.deepEqual(already.body,encoded);assert.equal(already.headers['content-length'],String(encoded.length));assert.deepEqual(gunzipSync(already.body),payload);
  const photo=await raw(base,`/api/images/${questionId}?session=synthetic&sig=synthetic`,{headers:{'accept-encoding':'gzip'}});assert.deepEqual(photo.body,image);assert.equal(photo.headers['content-encoding'],undefined);assert.equal(photo.headers['cache-control'],'private, no-store');
  assert.equal((await raw(base,'/api/questions?star-vary',{headers:{'accept-encoding':'gzip'}})).headers.vary,'*');assert.equal((await raw(base,'/api/questions?existing-vary',{headers:{'accept-encoding':'gzip'}})).headers.vary,'Origin, accept-encoding');
 });
});

test('aborting a gzip response cancels its streaming body without an unhandled error',async()=>{
 let cancelled;const cancellation=new Promise(resolve=>{cancelled=resolve;});const reported=[];
 await withServer(()=>new Response(new ReadableStream({async pull(controller){await delay(2);controller.enqueue(new TextEncoder().encode(paragraph.repeat(150)));},cancel(){cancelled();}}),{headers:{'content-type':'application/json','cache-control':'no-store'}}),async base=>{
  await new Promise((resolve,reject)=>{const req=httpRequest(`${base}/api/questions`,{headers:{'accept-encoding':'gzip'}},res=>{res.once('data',()=>{res.destroy();req.destroy();resolve();});res.on('error',()=>{});});req.on('error',error=>{if(error.code==='ECONNRESET')resolve();else reject(error);});req.end();});
  await Promise.race([cancellation,delay(1500).then(()=>{throw new Error('Aborted Web body was not cancelled.');})]);await delay(20);assert.deepEqual(reported,[]);
 },{onError:error=>reported.push(error)});
});

test('source stream failures terminate the response and report only a fixed error category',async()=>{
 const reported=[],privateValue='synthetic-signed-token-never-log';
 await withServer(()=>new Response(new ReadableStream({start(controller){controller.enqueue(new TextEncoder().encode('{"partial":'));setTimeout(()=>controller.error(new Error(privateValue)),15);}}),{headers:{'content-type':'application/json','cache-control':'no-store'}}),async base=>{
  await assert.rejects(raw(base,'/api/questions',{headers:{'accept-encoding':'gzip'}}));await delay(20);assert.deepEqual(reported,[{code:'RESPONSE_STREAM_FAILURE'}]);assert.ok(!JSON.stringify(reported).includes(privateValue));
 },{onError:error=>reported.push(error)});
});

test('default bridge logging never dumps malformed request URLs, signed query values or exception text',async()=>{
 const original=console.error,logged=[];console.error=(...args)=>logged.push(args);
 try{await withServer(()=>{throw new Error('synthetic-secret-from-handler');},async base=>{
  const malformed=await raw(base,'http://[bad?sig=synthetic-private-signature');assert.equal(malformed.status,500);assert.equal(JSON.parse(malformed.body).error.code,'INTERNAL_ERROR');
  assert.equal((await raw(base,'/api/questions?sig=synthetic-private-signature')).status,500);
  const output=JSON.stringify(logged);assert.ok(!output.includes('synthetic-private-signature'));assert.ok(!output.includes('synthetic-secret-from-handler'));assert.ok(!output.includes('http://[bad'));assert.deepEqual(logged,[['HTTP bridge failure:','REQUEST_BRIDGE_FAILURE'],['HTTP bridge failure:','REQUEST_BRIDGE_FAILURE']]);
 });}finally{console.error=original;}
});
