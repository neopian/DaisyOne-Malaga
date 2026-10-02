import {createServer} from 'node:http';
import {Readable} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import {createGzip} from 'node:zlib';
import {createDatabase,assertMigrated} from './db.mjs';
import {createDiskStorage} from './storage.mjs';
import {createApp} from './app.mjs';
import {randomToken} from './crypto.mjs';
import {loadMailConfig,createMailTransport} from './account-mail.mjs';
import {runAccountMaintenance} from './account-maintenance.mjs';
import {createTextFilter} from './moderation.mjs';

export function loadConfig(env=process.env) {
 const production=env.NODE_ENV==='production',host=env.HOST??'127.0.0.1',port=Number(env.PORT??8080);
 if(!Number.isInteger(port)||port<0||port>65535)throw new Error('PORT must be 0–65535.');
 const publicBaseUrl=(env.PUBLIC_BASE_URL??`http://127.0.0.1:${port}`).replace(/\/$/,'');
 let publicUrl;try{publicUrl=new URL(publicBaseUrl);}catch{throw new Error('PUBLIC_BASE_URL must be an absolute HTTP(S) origin.');}
 if(!['http:','https:'].includes(publicUrl.protocol)||publicUrl.username||publicUrl.password||publicUrl.pathname!=='/'||publicUrl.search||publicUrl.hash)throw new Error('PUBLIC_BASE_URL must be an HTTP(S) origin with no credentials/path/query.');
 if(production&&publicUrl.protocol!=='https:')throw new Error('Production PUBLIC_BASE_URL requires HTTPS behind a reverse proxy.');
 if(production&&(!env.IMAGE_SIGNING_SECRET||env.IMAGE_SIGNING_SECRET.length<32))throw new Error('Production requires IMAGE_SIGNING_SECRET with at least 32 random characters.');
 const initialPoints=Number(env.INITIAL_MOCK_POINTS??1000),sessionTtlSeconds=Number(env.SESSION_TTL_SECONDS??604800);
 if(!Number.isSafeInteger(initialPoints)||initialPoints<0||initialPoints>1_000_000)throw new Error('INITIAL_MOCK_POINTS must be an integer from 0 to 1000000.');
 if(!Number.isSafeInteger(sessionTtlSeconds)||sessionTtlSeconds<60||sessionTtlSeconds>2592000)throw new Error('SESSION_TTL_SECONDS must be 60–2592000.');
 const corsOrigins=(env.CORS_ORIGINS??'').split(',').map(x=>x.trim()).filter(Boolean);
 let textFilterTerms;
 if(env.TEXT_FILTER_TERMS_JSON!==undefined){try{textFilterTerms=JSON.parse(env.TEXT_FILTER_TERMS_JSON);}catch{throw new Error('TEXT_FILTER_TERMS_JSON must be a JSON array.');}createTextFilter(textFilterTerms);}
 for(const origin of corsOrigins){let url;try{url=new URL(origin);}catch{throw new Error('Invalid CORS_ORIGINS origin.');}if(url.origin!==origin||!['http:','https:'].includes(url.protocol))throw new Error('CORS_ORIGINS must contain exact HTTP(S) origins, without paths or wildcards.');}
 return {host,port,production,publicBaseUrl,initialPoints,sessionTtlSeconds,corsOrigins,textFilterTerms,imageSigningSecret:env.IMAGE_SIGNING_SECRET??randomToken(),uploadDirectory:env.UPLOAD_DIR??'./data/uploads',...loadMailConfig(env,production)};
}

function contentEncoding(header) {
 // No/empty preference gets identity. Explicit entries override wildcard;
 // conflicting duplicate entries use the stricter quality (never bypass q=0).
 if(!header?.trim())return 'identity';
 const qualities=new Map();
 for(const item of header.split(',')) {
  const [raw,...parameters]=item.trim().split(';'),coding=raw.toLowerCase();
  if(!/^(?:[a-z0-9!#$%&'*+.^_`|~-]+)$/i.test(coding))continue;
  let quality=1;
  if(parameters.length){const match=parameters.length===1&&/^\s*q\s*=\s*(0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\s*$/i.exec(parameters[0]);quality=match?Number(match[1]):0;}
  qualities.set(coding,Math.min(qualities.get(coding)??1,quality));
 }
 const gzip=qualities.get('gzip')??qualities.get('*')??0;
 const identity=qualities.get('identity')??(qualities.get('*')===0?0:null);
 if(gzip>0&&(identity===null||gzip>=identity))return 'gzip';
 return identity===0?'unacceptable':'identity';
}
function varyEncoding(headers) {
 const tokens=(headers.get('vary')??'').split(',').map(token=>token.trim()).filter(Boolean);
 if(!tokens.some(token=>token==='*'||token.toLowerCase()==='accept-encoding'))tokens.push('Accept-Encoding');
 headers.set('Vary',tokens.join(', '));
}
function compressibleResponse(request,response) {
 const path=new URL(request.url).pathname.replace(/\/$/,'');
 return request.method==='GET'&&response.status===200&&response.body&&
  (path==='/api/questions'||/^\/api\/questions\/[0-9a-f-]{36}$/i.test(path)||path==='/api/guide/questions'||path==='/api/guide/discovery'||path==='/api/points'||path==='/api/activity/questions'||path==='/api/admin/operations/questions')&&
  /^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type')??'')&&
  !response.headers.has('content-encoding')&&!response.headers.has('content-range')&&
  !/(?:^|,)\s*no-transform\s*(?:,|$)/i.test(response.headers.get('cache-control')??'');
}
const disconnected=error=>['ABORT_ERR','ERR_STREAM_PREMATURE_CLOSE','ECONNRESET','EPIPE'].includes(error?.code)||error?.name==='AbortError';
const logBridgeError=error=>console.error('HTTP bridge failure:',error.code);

/** The HTTP bridge never trusts forwarding/IP headers or logs request URLs. */
export function nodeServer(handle,{publicBaseUrl='http://127.0.0.1:8080',onError=logBridgeError}={}) {
 const report=code=>{try{Promise.resolve(onError(Object.freeze({code}))).catch(()=>{});}catch{}};
 const server=createServer(async(req,res)=>{
  const abort=new AbortController();
  req.once('aborted',()=>abort.abort());req.once('error',()=>abort.abort());
  res.once('close',()=>{if(!res.writableFinished)abort.abort();});
  try {
   const headers=new Headers();for(const [key,value] of Object.entries(req.headers))if(value!==undefined)headers.set(key,Array.isArray(value)?value.join(', '):value);
   headers.set('x-daisy-client-ip',req.socket.remoteAddress??'unknown');
   const method=req.method??'GET';
   const request=new Request(new URL(req.url??'/',publicBaseUrl),{method,headers,signal:abort.signal,...(['GET','HEAD'].includes(method)?{}:{body:Readable.toWeb(req),duplex:'half'})});
   const response=await handle(request);
   if(abort.signal.aborted){await response.body?.cancel().catch(()=>{});return;}
   const outgoing=new Headers(response.headers);let gzip=false;
   if(compressibleResponse(request,response)) {
    varyEncoding(outgoing);const encoding=contentEncoding(headers.get('accept-encoding'));
    if(encoding==='unacceptable') {
     await response.body.cancel();outgoing.delete('content-length');
     res.writeHead(406,Object.fromEntries(outgoing.entries()));res.end(JSON.stringify({error:{code:'NOT_ACCEPTABLE',message:'Accept gzip or identity encoding for this response.'}}));return;
    }
    gzip=encoding==='gzip';
    if(gzip){outgoing.set('Content-Encoding','gzip');outgoing.delete('content-length');}
   }
   res.writeHead(response.status,Object.fromEntries(outgoing.entries()));
   if(!response.body||method==='HEAD'){await response.body?.cancel().catch(()=>{});res.end();return;}
   const source=Readable.fromWeb(response.body);
   // Pipeline owns backpressure, error listeners and destruction/cancellation of
   // every stream, including the Web body, if the client leaves mid-response.
   if(gzip)await pipeline(source,createGzip({level:4}),res,{signal:abort.signal});
   else await pipeline(source,res,{signal:abort.signal});
  } catch(error) {
   if(disconnected(error))return;
   report(res.headersSent?'RESPONSE_STREAM_FAILURE':'REQUEST_BRIDGE_FAILURE');
   if(res.destroyed)return;
   if(res.headersSent){res.destroy();return;}
   res.writeHead(500,{'content-type':'application/json','cache-control':'no-store'});
   res.end(JSON.stringify({error:{code:'INTERNAL_ERROR',message:'The request could not be completed.'}}));
  }
 });
 server.requestTimeout=30_000;server.headersTimeout=15_000;server.keepAliveTimeout=5_000;return server;
}

export async function startServer(env=process.env) {
 const config=loadConfig(env),db=await createDatabase({connectionString:env.DATABASE_URL});
 try {
  // Fail closed if schema wasn't migrated; never apply database changes at API boot.
  await assertMigrated(db);
  const storage=await createDiskStorage(config.uploadDirectory);
  const mail=await createMailTransport(config);
  const onError=error=>console.error('API failure:',error.code??error.name);
  const handle=createApp({db,storage,config:{...config,mail,onError}});
  const server=nodeServer(handle,{publicBaseUrl:config.publicBaseUrl});
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(config.port,config.host,resolve);});
  let maintenance=Promise.resolve(),busy=false;
  const tick=()=>{if(busy)return;busy=true;maintenance=runAccountMaintenance({db,storage,mail,secret:config.imageSigningSecret,onError}).catch(onError).finally(()=>{busy=false;});};
  const timer=setInterval(tick,30_000);timer.unref();tick();
  return {server,db,config,close:async()=>{clearInterval(timer);await new Promise((resolve,reject)=>server.close(error=>error?reject(error):resolve()));await maintenance;await db.close();}};
 } catch(error){await db.close();throw error;}
}

if(import.meta.url===new URL(process.argv[1],'file:').href) {
 const runtime=await startServer();console.log(`DaisyOne API listening on ${runtime.config.host}:${runtime.server.address().port} (mock points only)`);
 let closing=false;for(const signal of ['SIGINT','SIGTERM'])process.on(signal,async()=>{if(closing)return;closing=true;try{await runtime.close();process.exitCode=0;}catch{process.exitCode=1;}});
}
