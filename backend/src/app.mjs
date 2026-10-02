import {randomId,randomToken,sha256,hashPassword,verifyPassword,sign,verifySignature,fromBase64,seal,unseal} from './crypto.mjs';
import {createAccountLifecycle,accountSafetyLock} from './accounts.mjs';
import {consumeRateLimit} from './rate-limits.mjs';
import {createModeration} from './moderation.mjs';
import {sanitizeImage,ImageProcessingError} from './image-processing.mjs';
import {findCity,locationAliases} from './city-catalog.mjs';
import {createActivity} from './activity.mjs';
import {createOperations} from './operations.mjs';
import {createExchangeIssues} from './exchange-issues.mjs';
import {createGuideDiscovery} from './guide-discovery.mjs';

export class ApiError extends Error {
 constructor(status,code,message) {super(message);this.status=status;this.code=code;}
}
const fail=(status,code,message)=>{throw new ApiError(status,code,message);};
const json=(body,status=200)=>new Response(JSON.stringify(body),{status,headers:{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store'}});
const one=async(db,sql,params=[]) => (await db.query(sql,params)).rows[0];
// One region rule for both the guide feed and authoritative claim action.
const regionMatchSql=aliases=>`location_identity(r.country,r.city,${aliases}::jsonb)=location_identity(q.country,q.city,${aliases}::jsonb)
 AND (coalesce(q.region_name,'')='' OR coalesce(r.region_name,'')='' OR lower(r.region_name)=lower(q.region_name))`;
const regionAliases=JSON.stringify(locationAliases);
const selectedCity=(country,city)=>{
 const place=findCity(country,city);
 if(!place)fail(400,'UNSUPPORTED_CITY','Select a country and city from the proposed city catalog. Guide availability is not guaranteed.');
 return place;
};

const uuid=value=>{if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value))fail(400,'INVALID_ID','Invalid identifier.');return value;};
const text=(value,name,{min=1,max=1000,optional=false}={})=>{
 if(optional && (value===undefined || value===null || value===''))return null;
 if(typeof value!=='string'||value.trim().length<min||value.trim().length>max)fail(400,'VALIDATION',`${name} must contain ${min}–${max} characters.`);
 return value.trim();
};
const choice=(value,name,values)=>{if(!values.includes(value))fail(400,'VALIDATION',`Invalid ${name}.`);return value;};
function fields(body,allowed) {for(const key of Object.keys(body))if(!allowed.includes(key))fail(400,'VALIDATION',`Unsupported field: ${key}.`);}
function publicUser(user) {
 const result={...user}; delete result.password_hash; delete result.token_hash; delete result.session_id;
 result.questioner_rating_avg=Number(result.questioner_rating_avg);result.helper_rating_avg=Number(result.helper_rating_avg);
 return result;
}
function stable(value) {
 if(Array.isArray(value)) return `[${value.map(stable).join(',')}]`;
 if(value&&typeof value==='object') return `{${Object.keys(value).sort().map(k=>`${JSON.stringify(k)}:${stable(value[k])}`).join(',')}}`;
 return JSON.stringify(value);
}
async function readJson(request,{maximum=22*1024*1024}={}) {
 if(!/^application\/json(?:;|$)/i.test(request.headers.get('content-type')??''))fail(415,'CONTENT_TYPE','Use application/json.');
 if(Number(request.headers.get('content-length'))>maximum)fail(413,'PAYLOAD_TOO_LARGE','Request too large.');
 const reader=request.body?.getReader();if(!reader) return {};
 const chunks=[];let length=0;
 while(true){const {done,value}=await reader.read();if(done)break;length+=value.length;if(length>maximum){await reader.cancel();fail(413,'PAYLOAD_TOO_LARGE','Request too large.');}chunks.push(value);}
 const bytes=new Uint8Array(length);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 let body;try{body=JSON.parse(new TextDecoder().decode(bytes));}catch{fail(400,'INVALID_JSON','Malformed JSON.');}
 if(!body||typeof body!=='object'||Array.isArray(body))fail(400,'INVALID_JSON','A JSON object is required.');return body;
}
function safeEvidenceUrl(value) {
 const raw=text(value,'url',{max:2048});let url;
 try{url=new URL(raw);}catch{fail(400,'INVALID_EVIDENCE_URL','Use a valid public HTTP(S) evidence URL.');}
 const host=url.hostname.toLowerCase().replace(/^\[|\]$/g,'');
 if(!['http:','https:'].includes(url.protocol)||url.username||url.password||!host||/[\s\x00-\x1f\x7f]/.test(raw)||host==='localhost'||host.endsWith('.localhost')||host.endsWith('.local')||host.includes(':')||/^\d+\.\d+\.\d+\.\d+$/.test(host))
  fail(400,'INVALID_EVIDENCE_URL','Use a public HTTP(S) URL without credentials or local/IP addresses.');
 return url.href;
}
async function imageInput(image) {
 if(!image||typeof image!=='object'||Array.isArray(image))fail(400,'INVALID_IMAGE','Invalid image.');
 fields(image,['name','content_type','data_base64']);
 text(image.name,'image name',{max:255});
 const mime=choice(image.content_type,'image content type',['image/jpeg','image/png','image/webp']);
 if(typeof image.data_base64!=='string'||image.data_base64.length>4*1024*1024||image.data_base64.length%4!==0||!/^[A-Za-z0-9+/]*={0,2}$/.test(image.data_base64))fail(400,'INVALID_IMAGE','Invalid or oversized image (maximum 3 MiB).');
 let bytes;try{bytes=fromBase64(image.data_base64);}catch{fail(400,'INVALID_IMAGE','Invalid image data.');}
 if(!bytes.length||bytes.length>3*1024*1024)fail(400,'INVALID_IMAGE','Invalid image size.');
 try{return await sanitizeImage({bytes,mime});}catch(error){if(error instanceof ImageProcessingError)fail(error.status,error.code,error.message);throw error;}
}

/** Pure Web Request/Response API; db.query and db.transaction(fn), storage.put/get/delete are injected. */
export function createApp({db,storage,config={}}) {
 const cfg={production:false,publicBaseUrl:'http://127.0.0.1:8080',initialPoints:1000,sessionTtlSeconds:7*24*3600,imageSigningSecret:randomToken(),corsOrigins:[],...config};
 if(cfg.production && (!config.imageSigningSecret || config.imageSigningSecret.length<32))throw new Error('Production requires a strong IMAGE_SIGNING_SECRET.');
 async function authRate(request,{identity}={}) {
  const scope=identity===undefined?`auth:ip:${request.headers.get('x-daisy-client-ip')??'local'}`:`auth:identity:${identity}`;
  if(!await consumeRateLimit(db,{secret:cfg.imageSigningSecret,scope,maximum:identity===undefined?60:20}))fail(429,'RATE_LIMIT','Too many authentication attempts; try again later.');
 }
 async function authenticate(request) {
  const match=/^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get('authorization')??'');
  if(!match)fail(401,'UNAUTHENTICATED','Sign in to continue.');
  const session=await one(db,'SELECT id,user_id FROM sessions WHERE token_hash=$1 AND expires_at>now()',[await sha256(match[1])]);
  if(!session)fail(401,'UNAUTHENTICATED','Your session has expired. Sign in again.');
  const user=await one(db,'SELECT * FROM users WHERE id=$1',[session.user_id]);
  if(!user)fail(401,'UNAUTHENTICATED','Your session has expired. Sign in again.');
  return {user:publicUser(user),session};
 }
 async function newSession(tx,user) {
  const token=randomToken();await tx.query('INSERT INTO sessions(id,user_id,token_hash,expires_at) VALUES($1,$2,$3,$4)',[randomId(),user.id,await sha256(token),new Date(Date.now()+cfg.sessionTtlSeconds*1000).toISOString()]);
  return {token,user:publicUser(user)};
 }
 async function authMutation(request,email,body,status,operation) {
  const key=request.headers.get('idempotency-key');
  if(key&&!/^[A-Za-z0-9_.:-]{8,128}$/.test(key))fail(400,'INVALID_IDEMPOTENCY_KEY','Idempotency-Key must contain 8–128 safe characters.');
  // Keyed fingerprint does not create a cheap offline password verifier in the DB.
  const fingerprint=key?await sign(cfg.imageSigningSecret,`auth:${new URL(request.url).pathname}:${stable(body)}`):null;
  const associatedData=`${email}:${key}:${fingerprint}`;
  return db.transaction(async tx=>{
   await accountSafetyLock(tx);
   await tx.query('SELECT pg_advisory_xact_lock(73284130,hashtext($1))',[email]);
   if(key) {
    const expires=new Date(Date.now()+10*60_000).toISOString();
    const inserted=await tx.query('INSERT INTO auth_idempotency_keys(email,key,fingerprint,expires_at) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING RETURNING key',[email,key,fingerprint,expires]);
    const entry=await one(tx,'SELECT * FROM auth_idempotency_keys WHERE email=$1 AND key=$2 FOR UPDATE',[email,key]);
    if(entry.fingerprint!==fingerprint)fail(409,'IDEMPOTENCY_CONFLICT','This key was used for a different sign-in request.');
    if(!inserted.rows.length) {
     if(new Date(entry.expires_at).getTime()<=Date.now())fail(409,'AUTH_RETRY_EXPIRED','Start a new sign-in attempt.');
     let payload;try{payload=await unseal(cfg.imageSigningSecret,entry.encrypted_response,associatedData);}catch{fail(409,'AUTH_RETRY_EXPIRED','Start a new sign-in attempt.');}
     if(!await one(tx,'SELECT id FROM sessions WHERE token_hash=$1 AND expires_at>now()',[await sha256(payload.token)]))fail(409,'AUTH_RETRY_EXPIRED','Start a new sign-in attempt.');
     return json(payload,entry.response_status);
    }
   }
   const payload=await operation(tx);
   if(key)await tx.query('UPDATE auth_idempotency_keys SET encrypted_response=$3,response_status=$4 WHERE email=$1 AND key=$2',[email,key,await seal(cfg.imageSigningSecret,payload,associatedData),status]);
   return json(payload,status);
  });
 }
 async function ledger(tx,userId,type,amount,questionId=null,answerId=null) {
  await tx.query('INSERT INTO point_transactions(id,user_id,question_id,answer_id,type,amount) VALUES($1,$2,$3,$4,$5,$6)',[randomId(),userId,questionId,answerId,type,amount]);
 }
 function canSee(question,user) {return question.status==='open'||question.user_id===user.id||question.assigned_helper_user_id===user.id||user.is_admin;}
 async function question(tx,id,user,lock=false,{allowHidden=false}={}) {
  await moderation.lock(tx);await moderation.assertActive(tx,user);
  const q=await one(tx,`SELECT * FROM questions WHERE id=$1${lock==='share'?' FOR SHARE':lock?' FOR UPDATE':''}`,[uuid(id)]);
  if(!q||!canSee(q,user))fail(404,'NOT_FOUND','Question not found.');
  if(!allowHidden)await moderation.assertQuestionVisible(tx,q,user);return q;
 }
 async function helperApproved(tx,id) {
  const app=await one(tx,'SELECT status FROM helper_applications WHERE user_id=$1 FOR SHARE',[id]);
  if(app?.status!=='approved')fail(403,'HELPER_NOT_APPROVED','Only an approved helper can do this.');
 }
 async function imageUrl(row,session) {
  const expires=Math.floor(Date.now()/1000)+600;
  const signature=await sign(cfg.imageSigningSecret,`${row.id}:${session.id}:${expires}`);
  return `${cfg.publicBaseUrl.replace(/\/$/,'')}/api/images/${row.id}?session=${session.id}&expires=${expires}&sig=${signature}`;
 }
 async function guideMetrics(tx,userId) {
  // Derive reputation/rewards from existing completed work and escrow, never a
  // mutable counter. One statement gives a consistent snapshot of all totals.
  const metrics=await one(tx,`SELECT
   (SELECT count(*) FROM answers WHERE helper_user_id=$1 AND status='accepted' AND is_rewarded=true) AS accepted_answer_count,
   (SELECT coalesce(sum(amount),0) FROM point_transactions WHERE user_id=$1 AND type='reward') AS earned_mock_points,
   (SELECT coalesce(sum(reward_points),0) FROM questions WHERE assigned_helper_user_id=$1 AND status IN ('assigned','answered') AND escrow_state='held') AS pending_mock_points,
   (SELECT status FROM helper_applications WHERE user_id=$1) AS application_status,
   coalesce((SELECT jsonb_agg(jsonb_build_object('country',country,'city',city,'region_name',region_name) ORDER BY country,city,region_name,id) FROM helper_regions WHERE helper_user_id=$1),'[]'::jsonb) AS activity_regions`,[userId]);
  return {...metrics,accepted_answer_count:Number(metrics.accepted_answer_count),earned_mock_points:Number(metrics.earned_mock_points),pending_mock_points:Number(metrics.pending_mock_points)};
 }
 async function assignedHelper(tx,userId) {
  if(!userId)return null;
  const helper=await one(tx,'SELECT id,name FROM users WHERE id=$1',[userId]);
  if(!helper)return null;
  const {accepted_answer_count,application_status,activity_regions}=await guideMetrics(tx,userId);
  return {...helper,accepted_answer_count,application_status,activity_regions};
 }
 async function detail(tx,q,session,user) {
  const images=(await tx.query('SELECT id FROM question_images WHERE question_id=$1 ORDER BY created_at,id',[q.id])).rows;
  const answers=(await tx.query('SELECT * FROM answers WHERE question_id=$1 ORDER BY created_at DESC',[q.id])).rows;
  for(const answer of answers)answer.answer_evidence_links=(await tx.query('SELECT * FROM answer_evidence_links WHERE answer_id=$1 ORDER BY created_at,id',[answer.id])).rows;
  const comments=(await tx.query('SELECT c.*,u.name AS author_name,u.avatar_url AS author_avatar_url FROM question_comments c JOIN users u ON u.id=c.user_id WHERE c.question_id=$1 ORDER BY c.created_at,c.id',[q.id])).rows.map(row=>{const {author_name,author_avatar_url,...comment}=row;return {...comment,commenter:{name:author_name,avatar_url:author_avatar_url}};});
  const safe=await moderation.filterDetail(tx,q,{answers,comments,assignedHelper:await assignedHelper(tx,q.assigned_helper_user_id)},user);
  const {escrow_state,...visible}=q;
  return {...visible,accepted_answer_id:safe.accepted_answer_id,assigned_helper:safe.assignedHelper,question_images:await Promise.all(images.map(async row=>({id:row.id,image_url:await imageUrl(row,session)}))),answers:safe.answers,question_comments:safe.comments};
 }
 async function mutate(request,actor,body,required,operation,options={}) {
  const key=request.headers.get('idempotency-key');
  if(required&&!key)fail(400,'IDEMPOTENCY_KEY_REQUIRED','Send a unique Idempotency-Key and reuse it when retrying this request.');
  if(key&&!/^[A-Za-z0-9_.:-]{8,128}$/.test(key))fail(400,'INVALID_IDEMPOTENCY_KEY','Idempotency-Key must contain 8–128 safe characters.');
  const fingerprint=key?await sha256(`${request.method}:${new URL(request.url).pathname}:${stable(body)}`):null;
  const written=[];
  try {
   return await db.transaction(async tx=>{
    await moderation.lock(tx,options.safetyWrite===true);
    if(!await one(tx,'SELECT id FROM sessions WHERE id=$1 AND user_id=$2 AND expires_at>now()',[actor.session.id,actor.user.id]))fail(401,'UNAUTHENTICATED','Your session has expired. Sign in again.');
    if(!options.allowSuspended)await moderation.assertActive(tx,actor.user);
    if(cfg.emailVerificationPolicy==='required_for_contributions'&&/\/api\/(questions|helper\/application)/.test(new URL(request.url).pathname)&&!new URL(request.url).pathname.endsWith('/cancel')) {
     const current=await one(tx,'SELECT email_verified_at FROM users WHERE id=$1',[actor.user.id]);
     if(!current?.email_verified_at)fail(403,'EMAIL_VERIFICATION_REQUIRED','Verify your email before contributing.');
    }
    if(key) {
     const inserted=await tx.query('INSERT INTO idempotency_keys(user_id,key,fingerprint) VALUES($1,$2,$3) ON CONFLICT DO NOTHING RETURNING key',[actor.user.id,key,fingerprint]);
     const entry=await one(tx,'SELECT * FROM idempotency_keys WHERE user_id=$1 AND key=$2 FOR UPDATE',[actor.user.id,key]);
     // Opt-in current authorization runs even when replay skips the operation.
     // Keep idempotency before resource/user locks, as other mutation routes do.
     if(options.authorize)await options.authorize(tx);
     if(entry.fingerprint!==fingerprint)fail(409,'IDEMPOTENCY_CONFLICT','This key was already used for a different request.');
     if(!inserted.rows.length) {
      if(entry.response_status===null)fail(409,'REQUEST_IN_PROGRESS','The request is still in progress. Retry with the same key.');
      return json(entry.response_body,entry.response_status);
     }
    }
    if(!key&&options.authorize)await options.authorize(tx);
    const result=await operation(tx,written);
    const status=result.status??200,body=result.body??result;
    if(key)await tx.query('UPDATE idempotency_keys SET response_body=$3::jsonb,response_status=$4 WHERE user_id=$1 AND key=$2',[actor.user.id,key,JSON.stringify(body),status]);
    return json(body,status);
   });
  } catch(error) {
   for(const key of written) {
    // A connection can drop after COMMIT: verify references before removing bytes.
    // Leave an orphan rather than deleting a potentially committed image on uncertainty.
    try {if(!await one(db,'SELECT id FROM question_images WHERE storage_key=$1',[key]))await storage.delete(key);}catch{}
   }
   throw error;
  }
 }
 const accounts=createAccountLifecycle({db,storage,cfg,fail,json,one,readJson,fields,text,publicUser,authenticate,authRate});
 const moderation=createModeration({db,cfg,fail,json,one,readJson,fields,text,choice,uuid,mutate});
 const activityQuestions=createActivity({db,moderation,secret:cfg.imageSigningSecret,fail});
 const guideDiscovery=createGuideDiscovery({db,moderation,secret:cfg.imageSigningSecret,fail,helperApproved,regionMatchSql,regionAliases});
 const operationsQuestions=createOperations({db,moderation,secret:cfg.imageSigningSecret,fail});
 const exchangeIssues=createExchangeIssues({db,moderation,secret:cfg.imageSigningSecret,fail,json,one,readJson,fields,text,choice,uuid,mutate});
 accounts.setModeration(moderation);
 accounts.setExchangeIssues(exchangeIssues);
 async function route(request) {
  const url=new URL(request.url),path=url.pathname.replace(/\/$/,''),method=request.method;
  if(method==='GET'&&(path==='/health'||path==='/api/health')){await db.query('SELECT 1');return json({ok:true,database:db.engine??'postgres',mock_points:true});}
  const accountResponse=await accounts.route(request,path,method);if(accountResponse)return accountResponse;
  if(method==='POST'&&(path==='/api/auth/register'||path==='/api/auth/login')) {
   await authRate(request);const body=await readJson(request);fields(body,path.endsWith('register')?['email','password','name']:['email','password']);
   const email=text(body.email,'email',{max:254}).toLowerCase();if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))fail(400,'VALIDATION','Enter a valid email address.');
   await authRate(request,{identity:email});
   if(typeof body.password!=='string'||body.password.length<8||body.password.length>128)fail(400,'VALIDATION','Password must contain 8–128 characters.');
   if(path.endsWith('register')) {
    const name=text(body.name,'name',{min:2,max:100});const passwordHash=await hashPassword(body.password);
    moderation.assertText({name});
    return authMutation(request,email,body,201,async tx=>{
     if(await one(tx,'SELECT id FROM users WHERE email=$1',[email]))fail(409,'EMAIL_EXISTS','An account with this email already exists.');
     const id=randomId();const user=await one(tx,'INSERT INTO users(id,email,name,point_balance) VALUES($1,$2,$3,$4) RETURNING *',[id,email,name,cfg.initialPoints]);
     await tx.query('INSERT INTO auth_credentials(user_id,password_hash) VALUES($1,$2)',[id,passwordHash]);
     if(cfg.initialPoints>0)await ledger(tx,id,'charge_mock',cfg.initialPoints);
     return newSession(tx,user);
    });
   }
   const candidate=await one(db,'SELECT u.*,c.password_hash FROM users u JOIN auth_credentials c ON c.user_id=u.id WHERE u.email=$1',[email]);
   // Always run PBKDF2, even for a missing account, to reduce account timing leaks.
   const dummy='pbkdf2_sha256$600000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
   if(!await verifyPassword(body.password,candidate?.password_hash??dummy)||!candidate)fail(401,'INVALID_CREDENTIALS','Invalid email or password.');
   return authMutation(request,email,body,200,async tx=>{
    const current=await one(tx,'SELECT u.*,c.password_hash FROM users u JOIN auth_credentials c ON c.user_id=u.id WHERE u.id=$1 FOR NO KEY UPDATE OF u',[candidate.id]);
    if(!current||current.password_hash!==candidate.password_hash)fail(401,'INVALID_CREDENTIALS','Invalid email or password.');
    return newSession(tx,current);
   });
  }
  const imageMatch=/^\/api\/images\/([^/]+)$/.exec(path);
  if(method==='GET'&&imageMatch) {
   const id=uuid(imageMatch[1]),sessionId=url.searchParams.get('session'),expires=url.searchParams.get('expires'),sig=url.searchParams.get('sig');
   if(!sessionId||!/^\d+$/.test(expires??'')||Number(expires)<Date.now()/1000||Number(expires)>Date.now()/1000+660||!sig||!await verifySignature(cfg.imageSigningSecret,`${id}:${sessionId}:${expires}`,sig))fail(401,'INVALID_IMAGE_TOKEN','Image link expired or invalid. Refresh the question.');
   return db.transaction(async tx=>{
    await moderation.lock(tx);
    const user=await one(tx,'SELECT u.* FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.id=$1 AND s.expires_at>now()',[uuid(sessionId)]);
    if(!user)fail(401,'INVALID_IMAGE_TOKEN','Image session expired.');
    const image=await one(tx,'SELECT * FROM question_images WHERE id=$1',[id]);if(!image)fail(404,'NOT_FOUND','Image not found.');
    await question(tx,image.question_id,user,'share');let bytes;try{bytes=await storage.get(image.storage_key);}catch{fail(404,'NOT_FOUND','Image not found.');}
    return new Response(bytes,{headers:{'Content-Type':image.content_type,'Cache-Control':'private, no-store','Content-Disposition':'inline','X-Content-Type-Options':'nosniff'}});
   });
  }
  if(!path.startsWith('/api/'))fail(404,'NOT_FOUND','Route not found.');
  const actor=await authenticate(request),{user,session}=actor;
  if(method==='GET'&&(path==='/api/auth/me'||path==='/api/profile'))return json(user);
  if(method==='POST'&&path==='/api/auth/logout'){await db.query('DELETE FROM sessions WHERE id=$1',[session.id]);return json({ok:true});}
  const issueResponse=await exchangeIssues.route({request,path,method,url,actor});if(issueResponse)return issueResponse;
  const moderationResponse=await moderation.route({request,path,method,url,actor});if(moderationResponse)return moderationResponse;
  if(method==='GET'&&path==='/api/activity/questions')return json(await activityQuestions(url,actor));
  if(method==='GET'&&path==='/api/guide/discovery')return json(await guideDiscovery(url,actor));
  if(method==='GET'&&path==='/api/admin/operations/questions')return json(await operationsQuestions(url,actor));
  if(method==='PATCH'&&path==='/api/profile') {
   const body=await readJson(request);fields(body,['current_country','current_city']);
   if(!Object.keys(body).length)fail(400,'VALIDATION','Provide a profile location.');
   const country='current_country'in body?text(body.current_country,'current_country',{optional:true,max:100}):user.current_country;
   const city='current_city'in body?text(body.current_city,'current_city',{optional:true,max:100}):user.current_city;
   moderation.assertText(body);
   return mutate(request,actor,body,false,async tx=>{
    const place=country&&city?selectedCity(country,city):null;
    if((country===null)!==(city===null))fail(400,'VALIDATION','Provide a country and city together, or clear both.');
    return {body:publicUser(await one(tx,'UPDATE users SET current_country=$2,current_city=$3 WHERE id=$1 RETURNING *',[user.id,place?.country??null,place?.city??null]))};
   });
  }
  if(method==='GET'&&path==='/api/guide/me')return json(await guideMetrics(db,user.id));
  if(method==='GET'&&path==='/api/guide/questions')return db.transaction(async tx=>{
   await moderation.lock(tx);await moderation.assertActive(tx,user);
   await helperApproved(tx,user.id);
   const qs=(await tx.query(`SELECT q.* FROM questions q
    WHERE q.status='open' AND q.escrow_state='held' AND q.user_id<>$1
    AND (q.expires_at IS NULL OR q.expires_at>now())
    AND EXISTS(SELECT 1 FROM helper_regions r WHERE r.helper_user_id=$1 AND ${regionMatchSql('$2')})
    ORDER BY q.created_at DESC,q.id DESC LIMIT 200 FOR SHARE OF q`,[user.id,regionAliases])).rows;
   const result=[];for(const q of await moderation.filterQuestions(tx,qs,user))result.push(await detail(tx,q,session,user));return json(result);
  });

  if(method==='GET'&&path==='/api/points')return json((await db.query('SELECT * FROM point_transactions WHERE user_id=$1 ORDER BY created_at DESC,id DESC LIMIT 500',[user.id])).rows);
  if(method==='GET'&&path==='/api/questions') {
   const status=url.searchParams.get('status');if(status)choice(status,'status',['open','assigned','answered','accepted','cancelled','expired','disputed','reported']);
   // Hold visibility stable through every nested read. A claim/private write uses
   // FOR UPDATE on the same question and cannot overtake this authorized read.
   return db.transaction(async tx=>{
    await moderation.lock(tx);await moderation.assertActive(tx,user);
    const qs=(await tx.query("SELECT * FROM questions WHERE (status='open' OR user_id=$1 OR assigned_helper_user_id=$1 OR $2::boolean) AND ($3::text IS NULL OR status=$3) ORDER BY created_at DESC,id DESC LIMIT 200 FOR SHARE",[user.id,user.is_admin,status])).rows;
    const result=[];for(const q of await moderation.filterQuestions(tx,qs,user))result.push(await detail(tx,q,session,user));return json(result);
   });
  }
  if(method==='POST'&&path==='/api/questions') {
   const b=await readJson(request);fields(b,['country','city','region_name','category','urgency','title','body','reward_points','latitude','longitude','images']);
   const country=text(b.country,'country',{max:100}),city=text(b.city,'city',{max:100}),region=text(b.region_name,'region_name',{optional:true,max:100});
   const category=choice(b.category,'category',['교통','번역','생활','쇼핑','식당','긴급도움','기타']),urgency=choice(b.urgency,'urgency',['보통','빠름','매우 급함']);
   const title=text(b.title,'title',{min:2,max:200}),body=text(b.body,'body',{min:10,max:10000}),reward=b.reward_points;
   if(!Number.isSafeInteger(reward)||reward<1||reward>1_000_000)fail(400,'VALIDATION','Reward must be an integer from 1 to 1000000.');
   const latitude=b.latitude??null,longitude=b.longitude??null;
   if((latitude===null)!==(longitude===null)||(latitude!==null&&(!Number.isFinite(latitude)||!Number.isFinite(longitude)||Math.abs(latitude)>90||Math.abs(longitude)>180)))fail(400,'VALIDATION','Provide valid latitude and longitude together.');
   if(b.images!==undefined&&(!Array.isArray(b.images)||b.images.length>5))fail(400,'INVALID_IMAGE','At most five images are allowed.');
   const images=[];for(const image of b.images??[])images.push(await imageInput(image));
   moderation.assertText(b);
   return mutate(request,actor,b,true,async(tx,written)=>{
    // Replay an already committed request before checking today's catalog.
    const place=selectedCity(country,city);
    const balance=await one(tx,'SELECT point_balance FROM users WHERE id=$1 FOR NO KEY UPDATE',[user.id]);
    if(balance.point_balance<reward)fail(409,'INSUFFICIENT_POINTS','Not enough mock points.');
    const id=randomId();await tx.query('INSERT INTO questions(id,user_id,country,city,region_name,category,urgency,title,body,reward_points,latitude,longitude) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)',[id,user.id,place.country,place.city,region,category,urgency,title,body,reward,latitude,longitude]);
    await tx.query('UPDATE users SET point_balance=point_balance-$2 WHERE id=$1',[user.id,reward]);await ledger(tx,user.id,'hold',-reward,id);
    for(const image of images){const imageId=randomId(),key=`${imageId}.${image.mime==='image/png'?'png':image.mime==='image/jpeg'?'jpg':'webp'}`;written.push(key);await storage.put(key,image.bytes);await tx.query('INSERT INTO question_images(id,question_id,storage_key,content_type,byte_length) VALUES($1,$2,$3,$4,$5)',[imageId,id,key,image.mime,image.bytes.length]);}
    return {body:{id},status:201};
   });
  }
  const match=/^\/api\/questions\/([^/]+)(?:\/(accept|cancel|comments|answers)(?:\/([^/]+)\/(accept))?)?$/.exec(path);
  if(match) {
   const id=uuid(match[1]),action=match[2];
   if(match[3] && action!=='answers')fail(404,'NOT_FOUND','Route not found.');
   if(method==='GET'&&!action)return db.transaction(async tx=>json(await detail(tx,await question(tx,id,user,'share'),session,user)));
   if(method!=='POST'||!action)fail(404,'NOT_FOUND','Route not found.');
   const b=await readJson(request);
   if(action==='accept') {
    fields(b,[]);return mutate(request,actor,b,false,async tx=>{
     const q=await question(tx,id,user,true);
     if(q.user_id===user.id)fail(403,'SELF_ANSWER','You cannot answer your own question.');
     await helperApproved(tx,user.id);
     if(q.status==='assigned'&&q.assigned_helper_user_id===user.id)return {ok:true};
     if(q.status!=='open'||q.escrow_state!=='held')fail(409,'QUESTION_UNAVAILABLE','Question is no longer open.');
     if(q.expires_at && new Date(q.expires_at).getTime()<=Date.now())fail(409,'QUESTION_EXPIRED','Question has expired. The owner can cancel for a full refund.');
     const region=await one(tx,`SELECT r.id FROM helper_regions r JOIN questions q ON q.id=$2 WHERE r.helper_user_id=$1 AND ${regionMatchSql('$3')} LIMIT 1`,[user.id,q.id,regionAliases]);
     if(!region)fail(403,'REGION_MISMATCH','This question is outside your approved regions.');
     await tx.query("UPDATE questions SET status='assigned',assigned_helper_user_id=$2,updated_at=now() WHERE id=$1",[id,user.id]);return {ok:true};
    });
   }
   if(action==='cancel') {
    fields(b,[]);return mutate(request,actor,b,true,async tx=>{
     const q=await question(tx,id,user,true,{allowHidden:true});if(q.user_id!==user.id)fail(403,'FORBIDDEN','Only the question owner can cancel.');
     if(q.status==='cancelled'&&q.escrow_state==='refunded')return {ok:true};
     if(q.status!=='open'||q.escrow_state!=='held')fail(409,'CANNOT_CANCEL','Only an open question can be cancelled.');
     await tx.query("UPDATE questions SET status='cancelled',escrow_state='refunded',updated_at=now() WHERE id=$1",[id]);
     await tx.query('UPDATE users SET point_balance=point_balance+$2 WHERE id=$1',[user.id,q.reward_points]);await ledger(tx,user.id,'refund',q.reward_points,id);return {ok:true};
    });
   }
   if(action==='comments') {
    fields(b,['body']);const body=text(b.body,'body',{max:600});moderation.assertText(b);return mutate(request,actor,b,false,async tx=>{
     const q=await question(tx,id,user,true);if(['cancelled','expired'].includes(q.status))fail(409,'QUESTION_CLOSED','Question is closed.');
     const commentId=randomId();await tx.query('INSERT INTO question_comments(id,question_id,user_id,body) VALUES($1,$2,$3,$4)',[commentId,id,user.id,body]);return {body:{id:commentId},status:201};
    });
   }
   if(action==='answers'&&!match[3]) {
    fields(b,['body','evidence_summary','verification_method','links']);
    const body=text(b.body,'body',{min:10,max:10000}),summary=text(b.evidence_summary,'evidence_summary',{max:3000}),verification=text(b.verification_method,'verification_method',{max:500});
    if(!Array.isArray(b.links)||b.links.length<1||b.links.length>10)fail(400,'EVIDENCE_REQUIRED','Provide 1–10 evidence URLs.');
    const links=b.links.map(link=>{if(!link||typeof link!=='object'||Array.isArray(link))fail(400,'VALIDATION','Invalid evidence.');fields(link,['url','title','description','source_type']);return {url:safeEvidenceUrl(link.url),title:text(link.title,'title',{optional:true,max:300}),description:text(link.description,'description',{optional:true,max:2000}),source_type:choice(link.source_type??'other','source_type',['official','map','transport','store','local_info','other'])};});
    moderation.assertText(b);
    return mutate(request,actor,b,true,async tx=>{
     const q=await question(tx,id,user,true);if(q.user_id===user.id)fail(403,'SELF_ANSWER','You cannot answer your own question.');
     if(q.assigned_helper_user_id!==user.id)fail(403,'FORBIDDEN','Only the assigned helper can answer.');
     await helperApproved(tx,user.id);
     if(q.status!=='assigned'||q.escrow_state!=='held')fail(409,'ANSWER_ALREADY_SUBMITTED','This question cannot receive another answer.');
     const answerId=randomId();await tx.query('INSERT INTO answers(id,question_id,helper_user_id,body,evidence_summary,verification_method) VALUES($1,$2,$3,$4,$5,$6)',[answerId,id,user.id,body,summary,verification]);
     for(const link of links)await tx.query('INSERT INTO answer_evidence_links(id,answer_id,url,title,description,source_type) VALUES($1,$2,$3,$4,$5,$6)',[randomId(),answerId,link.url,link.title,link.description,link.source_type]);
     await tx.query("UPDATE questions SET status='answered',updated_at=now() WHERE id=$1",[id]);return {body:{id:answerId},status:201};
    });
   }
   if(action==='answers'&&match[3]&&match[4]==='accept') {
    fields(b,[]);const answerId=uuid(match[3]);return mutate(request,actor,b,true,async tx=>{
     const q=await question(tx,id,user,true);if(q.user_id!==user.id)fail(403,'FORBIDDEN','Only the question owner can accept an answer.');
     const answer=await one(tx,'SELECT * FROM answers WHERE id=$1 AND question_id=$2 FOR UPDATE',[answerId,id]);if(!answer)fail(404,'NOT_FOUND','Answer not found.');
     await moderation.assertAnswerVisible(tx,answer,user);
     if(q.status==='accepted'&&q.accepted_answer_id===answerId&&answer.is_rewarded)return {ok:true};
     if(q.status!=='answered'||q.escrow_state!=='held'||answer.status!=='submitted'||answer.is_rewarded||answer.helper_user_id!==q.assigned_helper_user_id||answer.helper_user_id===user.id)fail(409,'CANNOT_ACCEPT','Answer cannot be accepted.');
     await tx.query("UPDATE answers SET status='accepted',is_rewarded=true,updated_at=now() WHERE id=$1",[answerId]);
     await tx.query("UPDATE questions SET status='accepted',accepted_answer_id=$2,escrow_state='paid',updated_at=now() WHERE id=$1",[id,answerId]);
     await tx.query('UPDATE users SET point_balance=point_balance+$2 WHERE id=$1',[answer.helper_user_id,q.reward_points]);await ledger(tx,answer.helper_user_id,'reward',q.reward_points,id,answerId);return {ok:true};
    });
   }
  }
  if(method==='GET'&&path==='/api/helper/application')return json(await one(db,'SELECT * FROM helper_applications WHERE user_id=$1',[user.id])??null);
  if(method==='GET'&&path==='/api/helper/regions')return json((await db.query('SELECT * FROM helper_regions WHERE helper_user_id=$1 ORDER BY country,city,region_name',[user.id])).rows);
  if(method==='POST'&&path==='/api/helper/application') {
   const b=await readJson(request);fields(b,['languages','regions','introduction','experience_description']);
   if(!Array.isArray(b.languages)||b.languages.length<1||b.languages.length>20)fail(400,'VALIDATION','Provide 1–20 languages.');
   const languages=[...new Set(b.languages.map(x=>text(x,'language',{max:100})))];
   if(!Array.isArray(b.regions)||b.regions.length<1||b.regions.length>20)fail(400,'VALIDATION','Provide 1–20 regions.');
   const regions=b.regions.map(r=>{if(!r||typeof r!=='object')fail(400,'VALIDATION','Invalid region.');fields(r,['country','city','region_name']);return {country:text(r.country,'country',{max:100}),city:text(r.city,'city',{max:100}),region_name:text(r.region_name,'region_name',{optional:true,max:100})};});
   const intro=text(b.introduction,'introduction',{min:10,max:5000}),experience=text(b.experience_description,'experience_description',{min:10,max:5000});
   moderation.assertText(b);
   return mutate(request,actor,b,false,async tx=>{
    const canonicalRegions=[...new Map(regions.map(region=>{
     const place=selectedCity(region.country,region.city);
     const canonical={country:place.country,city:place.city,region_name:region.region_name};
     return [`${place.id}:${region.region_name?.toLowerCase()??''}`,canonical];
    })).values()];
    await tx.query('SELECT id FROM users WHERE id=$1 FOR NO KEY UPDATE',[user.id]);
    const current=await one(tx,'SELECT * FROM helper_applications WHERE user_id=$1 FOR UPDATE',[user.id]);
    if(current&&current.status!=='rejected')fail(409,'APPLICATION_EXISTS','An application is already pending, approved, or suspended.');
    const id=current?.id??randomId();
    await tx.query("INSERT INTO helper_applications(id,user_id,languages,introduction,experience_description) VALUES($1,$2,$3,$4,$5) ON CONFLICT(user_id) DO UPDATE SET languages=$3,introduction=$4,experience_description=$5,status='pending',applied_at=now(),reviewed_at=null,reviewed_by=null,reject_reason=null",[id,user.id,languages,intro,experience]);
    await tx.query('DELETE FROM helper_regions WHERE helper_user_id=$1',[user.id]);
    for(const r of canonicalRegions)await tx.query('INSERT INTO helper_regions(id,helper_user_id,country,city,region_name) VALUES($1,$2,$3,$4,$5)',[randomId(),user.id,r.country,r.city,r.region_name]);
    return {body:{id},status:201};
   });
  }
  if(path.startsWith('/api/admin/')) {
   if(!user.is_admin)fail(403,'ADMIN_REQUIRED','Administrator access required.');
   if(method==='GET'&&path==='/api/admin/applications') {
    const apps=(await db.query('SELECT * FROM helper_applications ORDER BY applied_at DESC LIMIT 500')).rows,result=[];
    for(const app of apps)result.push({application:app,regions:(await db.query('SELECT * FROM helper_regions WHERE helper_user_id=$1',[app.user_id])).rows});return json(result);
   }
   const review=/^\/api\/admin\/applications\/([^/]+)\/review$/.exec(path);
   if(method==='POST'&&review) {
    const id=uuid(review[1]),b=await readJson(request);fields(b,['status','reject_reason']);const status=choice(b.status,'status',['approved','rejected','suspended']),reason=text(b.reject_reason,'reject_reason',{optional:status==='approved',max:2000});
    return mutate(request,actor,b,false,async tx=>{
     const app=await one(tx,'SELECT * FROM helper_applications WHERE id=$1 FOR UPDATE',[id]);if(!app)fail(404,'NOT_FOUND','Application not found.');
     if(app.status===status)return {ok:true};
     if((['approved','rejected'].includes(status)&&app.status!=='pending')||(status==='suspended'&&app.status!=='approved'))fail(409,'INVALID_REVIEW','Application is not eligible for that review.');
     await tx.query('UPDATE helper_applications SET status=$2,reviewed_at=now(),reviewed_by=$3,reject_reason=$4 WHERE id=$1',[id,status,user.id,reason]);return {ok:true};
    });
   }
  }
  fail(404,'NOT_FOUND','Route not found.');
 }
 return async function handle(request) {
  let response;const origin=request.headers.get('origin');
  const allowed=!origin||cfg.corsOrigins.includes(origin)||(!cfg.production&&/^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin));
  try {
   if(!allowed)fail(403,'ORIGIN_NOT_ALLOWED','This browser origin is not allowed.');
   response=request.method==='OPTIONS'?new Response(null,{status:204}):await route(request);
  } catch(error) {
   if(error instanceof ApiError)response=json({error:{code:error.code,message:error.message}},error.status);
   else if(error.code==='23505')response=json({error:{code:'CONFLICT',message:'This action was already performed or this account already exists.'}},409);
   else if(error.code==='23514'||error.code==='22P02'||error.code==='22003')response=json({error:{code:'VALIDATION',message:'Invalid data.'}},400);
   else {config.onError?.(error);response=json({error:{code:'INTERNAL_ERROR',message:'The request could not be completed.'}},500);}
  }
  response.headers.set('X-Content-Type-Options','nosniff');response.headers.set('Referrer-Policy','no-referrer');
  if(allowed&&origin){response.headers.set('Access-Control-Allow-Origin',origin);response.headers.set('Vary','Origin');}
  response.headers.set('Access-Control-Allow-Methods','GET, POST, PATCH, OPTIONS');response.headers.set('Access-Control-Allow-Headers','Authorization, Content-Type, Idempotency-Key');
  return response;
 };
}
