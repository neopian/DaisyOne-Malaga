import {randomId,randomToken,sha256,sign,seal,hashPassword,verifyPassword,toBase64} from './crypto.mjs';
import {consumeRateLimit} from './rate-limits.mjs';

export const accountSafetyLock=async(tx,exclusive=false)=>tx.query(`SELECT pg_advisory_xact_lock${exclusive?'':'_shared'}(73284129)`);
const stable=value=>Array.isArray(value)?`[${value.map(stable)}]`:value&&typeof value==='object'?`{${Object.keys(value).sort().map(key=>`${JSON.stringify(key)}:${stable(value[key])}`)}}`:JSON.stringify(value);
const dummyPassword='pbkdf2_sha256$600000$AAAAAAAAAAAAAAAAAAAAAA==$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const genericMail={accepted:true,message:'If this address can receive account mail, instructions have been queued.'};

/** Jobs retain random filenames/opaque receipt hashes only, never account PII. */
export async function cleanDeletedAccountFiles({db,storage,mail,onError=()=>{},id,limit=20}) {
 const attempted=[];
 for(let i=0;i<limit;i++) {
  const result=await db.transaction(async tx=>{
   const row=(await tx.query(`SELECT * FROM account_deletion_jobs WHERE completed_at IS NULL${id?' AND id=$1':' AND id<>ALL($1::uuid[])'} ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1`,id?[id]:[attempted])).rows[0];
   if(!row)return null;
   const remainingFiles=row.storage_keys.slice(100),remainingMail=row.mail_ids.slice(100);
   for(const key of row.storage_keys.slice(0,100))try{await storage.delete(key);}catch(error){remainingFiles.push(key);onError(error);}
   for(const mailId of row.mail_ids.slice(0,100))try{await mail?.remove?.(mailId);}catch(error){remainingMail.push(mailId);onError(error);}
   const complete=!remainingFiles.length&&!remainingMail.length;
   await tx.query('UPDATE account_deletion_jobs SET storage_keys=$2,mail_ids=$3,completed_at=CASE WHEN $4 THEN now() ELSE NULL END WHERE id=$1',[row.id,remainingFiles,remainingMail,complete]);
   return {complete,id:row.id};
  });
  if(!result||id)break;attempted.push(result.id);
 }
}

export function createAccountLifecycle({db,storage,cfg,fail,json,one,readJson,fields,text,publicUser,authenticate,authRate}) {
 let moderation;
 const mail=cfg.mail??{mode:'disabled'};
 const hash=value=>sign(cfg.imageSigningSecret,`account:${value}`);
 async function rate(request,purpose,maximum=20) {
  await authRate(request);
  const scope=`account:ip:${purpose}:${request.headers.get('x-daisy-client-ip')??'local'}`;
  if(!await consumeRateLimit(db,{secret:cfg.imageSigningSecret,scope,maximum}))fail(429,'RATE_LIMIT','Too many attempts. Try again later.');
 }
 function password(value) {if(typeof value!=='string'||value.length<8||value.length>128)fail(400,'VALIDATION','Password must contain 8–128 characters.');return value;}
 function token(value) {if(typeof value!=='string'||! /^[A-Za-z0-9_-]{43}$/.test(value))fail(400,'INVALID_OR_EXPIRED_TOKEN','This code is invalid, expired, or already used.');return value;}
 function key(request,required=false) {
  const value=request.headers.get('idempotency-key');
  if(required&&!value)fail(400,'IDEMPOTENCY_KEY_REQUIRED','Send a unique Idempotency-Key and reuse it when retrying.');
  if(value&&! /^[A-Za-z0-9_.:-]{8,128}$/.test(value))fail(400,'INVALID_IDEMPOTENCY_KEY','Idempotency-Key must contain 8–128 safe characters.');return value;
 }
 async function liveSession(tx,actor) {
  const row=await one(tx,'SELECT u.* FROM users u JOIN sessions s ON s.user_id=u.id WHERE s.id=$1 AND s.user_id=$2 AND s.expires_at>now()',[actor.session.id,actor.user.id]);
  if(!row)fail(401,'UNAUTHENTICATED','Your session has expired. Sign in again.');return row;
 }
 async function reauthenticate(tx,actor,secret) {
  const user=await liveSession(tx,actor);
  const credentials=await one(tx,'SELECT password_hash FROM auth_credentials WHERE user_id=$1',[user.id]);
  if(!await verifyPassword(secret,credentials?.password_hash??dummyPassword))fail(403,'REAUTHENTICATION_FAILED','The current password is incorrect.');
  return user;
 }
 async function withRetry(tx,request,body,scope,userId,operation) {
  const requestKey=key(request),scopeHash=await hash(scope),fingerprint=await hash(`${request.method}:${new URL(request.url).pathname}:${stable(body)}`);
  if(requestKey) {
   const inserted=await tx.query("INSERT INTO account_requests(scope_hash,key,fingerprint,user_id,expires_at) VALUES($1,$2,$3,$4,now()+interval '24 hours') ON CONFLICT DO NOTHING RETURNING key",[scopeHash,requestKey,fingerprint,userId]);
   const existing=await one(tx,'SELECT * FROM account_requests WHERE scope_hash=$1 AND key=$2 FOR UPDATE',[scopeHash,requestKey]);
   if(existing.fingerprint!==fingerprint)fail(409,'IDEMPOTENCY_CONFLICT','This key was already used for a different request.');
   if(!inserted.rows.length) {
    if(new Date(existing.expires_at)<=new Date())fail(409,'AUTH_RETRY_EXPIRED','Begin a new request.');
    return {body:existing.response_body,status:existing.response_status};
   }
  }
  const result=await operation();
  if(requestKey)await tx.query('UPDATE account_requests SET response_body=$3::jsonb,response_status=$4 WHERE scope_hash=$1 AND key=$2',[scopeHash,requestKey,JSON.stringify(result.body),result.status??200]);
  return result;
 }
 async function issue(tx,user,purpose) {
  if(!user||purpose==='verify_email'&&user.email_verified_at)return;
  // Account-specific throttling is deliberately silent, so recovery cannot
  // reveal registered addresses through response codes or resend behavior.
  const recent=await one(tx,"SELECT id FROM account_tokens WHERE user_id=$1 AND purpose=$2 AND created_at>now()-interval '1 minute' LIMIT 1",[user.id,purpose]);
  if(recent)return;
  await tx.query('UPDATE account_tokens SET consumed_at=now() WHERE user_id=$1 AND purpose=$2 AND consumed_at IS NULL',[user.id,purpose]);
  await tx.query('DELETE FROM account_mail_outbox WHERE user_id=$1 AND purpose=$2',[user.id,purpose]);
  const raw=randomToken(),tokenId=randomId(),mailId=randomId(),expiry=new Date(Date.now()+(purpose==='verify_email'?24*3600_000:30*60_000)).toISOString();
  await tx.query('INSERT INTO account_tokens(id,user_id,purpose,token_hash,expires_at) VALUES($1,$2,$3,$4,$5)',[tokenId,user.id,purpose,await sha256(raw),expiry]);
  const url=new URL(cfg.accountActionUrl??'http://localhost/account');
  // Fragments do not enter server access logs or HTTP Referer values.
  url.hash=new URLSearchParams({action:purpose,token:raw}).toString();
  const message={id:mailId,to:user.email,purpose,token:raw,expires_at:expiry,text:`${purpose==='verify_email'?'Verify your email address':'Reset your password'} using this code:\n\n${raw}\n\n${url.href}\n\nExpires: ${expiry}\nIgnore this message if you did not request it.`};
  await tx.query('INSERT INTO account_mail_outbox(id,user_id,purpose,encrypted_message,expires_at) VALUES($1,$2,$3,$4,$5)',[mailId,user.id,purpose,await seal(cfg.imageSigningSecret,message,`account-mail:${mailId}`),expiry]);
  // Track a possible sink artifact BEFORE dispatch. If the sink accepts bytes
  // but the dispatch transaction crashes, deletion still knows its filename.
  await tx.query('INSERT INTO account_mail_deliveries(id,user_id) VALUES($1,$2)',[mailId,user.id]);
 }
 async function requestMail(request,path,body) {
  if(!mail.send||mail.mode==='disabled')fail(503,'MAIL_UNAVAILABLE','Account email is unavailable. Contact the service operator.');
  const verify=path.endsWith('/email-verification/request');fields(body,verify?[]:['email']);
  const actor=verify?await authenticate(request):null;
  const email=verify?actor.user.email:text(body.email,'email',{max:254}).toLowerCase();
  if(! /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(email))fail(400,'VALIDATION','Enter a valid email address.');
  await rate(request,'mail',20);
  const result=await db.transaction(async tx=>{
   await accountSafetyLock(tx);
   if(actor)await liveSession(tx,actor);
   const user=await one(tx,'SELECT * FROM users WHERE email=$1 FOR NO KEY UPDATE',[email]);
   return withRetry(tx,request,body,`request:${verify}:${email}`,user?.id??null,async()=>{await issue(tx,user,verify?'verify_email':'reset_password');return {body:genericMail,status:202};});
  });
  return json(result.body,result.status);
 }
 async function confirm(request,path,body) {
  const verify=path.endsWith('/email-verification/confirm');fields(body,verify?['token']:['token','password']);
  const tokenHash=await sha256(token(body.token)),actor=verify?await authenticate(request):null;
  if(!verify)password(body.password);
  await rate(request,'confirm',30);
  const newHash=verify?null:await hashPassword(body.password);
  const result=await db.transaction(async tx=>{
   await accountSafetyLock(tx);
   if(actor)await liveSession(tx,actor);
   const candidate=await one(tx,'SELECT t.user_id,u.email FROM account_tokens t JOIN users u ON u.id=t.user_id WHERE t.token_hash=$1',[tokenHash]);
   if(candidate)await tx.query('SELECT pg_advisory_xact_lock(73284130,hashtext($1))',[candidate.email]);
   return withRetry(tx,request,body,`confirm:${verify}:${tokenHash}:${actor?.user.id??''}`,candidate?.user_id??null,async()=>{
    if(!candidate)fail(400,'INVALID_OR_EXPIRED_TOKEN','This code is invalid, expired, or already used.');
    // Consistent user-before-token lock order serializes resend/reset/login.
    const user=await one(tx,'SELECT * FROM users WHERE id=$1 FOR NO KEY UPDATE',[candidate.user_id]);
    const row=await one(tx,'SELECT * FROM account_tokens WHERE token_hash=$1 FOR UPDATE',[tokenHash]);
    if(!user||!row||row.purpose!==(verify?'verify_email':'reset_password')||row.consumed_at||new Date(row.expires_at)<=new Date()||verify&&row.user_id!==actor.user.id)fail(400,'INVALID_OR_EXPIRED_TOKEN','This code is invalid, expired, or already used.');
    await tx.query('UPDATE account_tokens SET consumed_at=now() WHERE user_id=$1 AND purpose=$2 AND consumed_at IS NULL',[user.id,row.purpose]);
    await tx.query('DELETE FROM account_mail_outbox WHERE user_id=$1 AND purpose=$2',[user.id,row.purpose]);
    if(verify) {
     const updated=await one(tx,'UPDATE users SET email_verified_at=coalesce(email_verified_at,now()) WHERE id=$1 RETURNING email_verified_at',[user.id]);
     return {body:{ok:true,email_verified_at:updated.email_verified_at},status:200};
    }
    await tx.query('UPDATE auth_credentials SET password_hash=$2 WHERE user_id=$1',[user.id,newHash]);
    await tx.query('DELETE FROM sessions WHERE user_id=$1',[user.id]);
    await tx.query('DELETE FROM auth_idempotency_keys WHERE email=$1',[user.email]);
    return {body:{ok:true},status:200};
   });
  });return json(result.body,result.status);
 }
 async function exportAccount(request,body) {
  fields(body,['password','include_images']);password(body.password);
  if(body.include_images!==undefined&&typeof body.include_images!=='boolean')fail(400,'VALIDATION','include_images must be true or false.');
  const includeImages=body.include_images??true;
  await rate(request,'reauth',10);const actor=await authenticate(request);
  return db.transaction(async tx=>{
   await tx.query('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ');await accountSafetyLock(tx);
   const user=await reauthenticate(tx,actor,body.password);
   const rows=async(sql,params=[user.id])=>(await tx.query(sql,params)).rows;
   const selections={questions:'SELECT * FROM questions WHERE user_id=$1 ORDER BY created_at,id',answers:'SELECT * FROM answers WHERE helper_user_id=$1 ORDER BY created_at,id',comments:'SELECT * FROM question_comments WHERE user_id=$1 ORDER BY created_at,id',evidence_links:'SELECT l.* FROM answer_evidence_links l JOIN answers a ON a.id=l.answer_id WHERE a.helper_user_id=$1 ORDER BY l.created_at,l.id',images:'SELECT i.* FROM question_images i JOIN questions q ON q.id=i.question_id WHERE q.user_id=$1 ORDER BY i.id',helper_applications:'SELECT id,status,languages,introduction,experience_description,applied_at,reviewed_at,reject_reason FROM helper_applications WHERE user_id=$1',helper_reviews:'SELECT id AS application_id,status,reject_reason,reviewed_at FROM helper_applications WHERE reviewed_by=$1 ORDER BY reviewed_at,id',helper_regions:'SELECT * FROM helper_regions WHERE helper_user_id=$1',point_transactions:'SELECT * FROM point_transactions WHERE user_id=$1 ORDER BY created_at,id',sessions:'SELECT created_at,expires_at FROM sessions WHERE user_id=$1 ORDER BY created_at'};
   // Aggregate sizes in PostgreSQL before materializing rows or reading files.
   // JSON lengths count decompressed/escaped text, not compressed TOAST bytes.
   let totalRows=0,totalBytes=65536;
   const addStats=stats=>{totalRows+=Number(stats.count);totalBytes+=Number(stats.bytes)+32*Number(stats.count);};
   for(const sql of Object.values(selections))addStats(await one(tx,`SELECT count(*)::int AS count,coalesce(sum(octet_length(row_to_json(export_row)::text)),0)::bigint AS bytes FROM (${sql.replace(/ ORDER BY .+$/,'')}) export_row`,[user.id]));
   if(moderation)for(const stats of Object.values(await moderation.exportOwn(tx,user.id,{statsOnly:true})))addStats(stats);
   if(includeImages){const size=await one(tx,'SELECT coalesce(sum(4*ceil(i.byte_length::numeric/3)),0)::bigint AS bytes FROM question_images i JOIN questions q ON q.id=i.question_id WHERE q.user_id=$1',[user.id]);totalBytes+=Number(size.bytes);}
   if(totalRows>10000||totalBytes>25*1024*1024)fail(413,'EXPORT_TOO_LARGE',includeImages?'This export exceeds the safe size limit. Retry without image bytes; no data has been exported.':'This account exceeds the safe export limit. Contact the service operator for a complete export; no data has been exported.');
   const images=await rows(selections.images);
   const exportedImages=[];
   for(const image of images){const {storage_key,...metadata}=image;exportedImages.push({...metadata,...(includeImages?{data_base64:toBase64(await storage.get(storage_key))}:{})});}
   const payload={format_version:1,exported_at:new Date().toISOString(),export_options:{include_images:includeImages,images_included:includeImages?images.length:0},profile:publicUser(user),images:exportedImages};
   for(const [name,sql] of Object.entries(selections))if(name!=='images')payload[name]=await rows(sql);
   if(moderation)Object.assign(payload,await moderation.exportOwn(tx,user.id));
   const response=json(payload);response.headers.set('Content-Disposition','attachment; filename="account-data.json"');return response;
  });
 }
 async function deletionReceipt(request,body) {
  const requestKey=key(request,true),bearer=/^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get('authorization')??'');
  if(!bearer)fail(401,'UNAUTHENTICATED','Sign in to continue.');
  const sessionHash=await sha256(bearer[1]);
  return {receipt:await hash(`delete:${sessionHash}:${requestKey}`),fingerprint:await hash(`delete:${stable(body)}`),sessionHash};
 }
 async function deleteAccount(request,body) {
  fields(body,['password','confirmation']);password(body.password);if(body.confirmation!=='DELETE')fail(400,'DELETION_CONFIRMATION_REQUIRED','Confirm account deletion by entering DELETE.');
  const {receipt,fingerprint,sessionHash}=await deletionReceipt(request,body);
  const existing=await one(db,'SELECT * FROM account_deletion_jobs WHERE receipt_hash=$1 AND retry_expires_at>now()',[receipt]);
  if(existing&&existing.fingerprint!==fingerprint)fail(409,'IDEMPOTENCY_CONFLICT','This deletion key was used for a different request.');
  let jobId=existing?.id;
  if(!existing) {
   await rate(request,'reauth',10);
   jobId=await db.transaction(async tx=>{
    await accountSafetyLock(tx,true);
    const replay=await one(tx,'SELECT * FROM account_deletion_jobs WHERE receipt_hash=$1 AND retry_expires_at>now()',[receipt]);
    if(replay){if(replay.fingerprint!==fingerprint)fail(409,'IDEMPOTENCY_CONFLICT','This deletion key was used for a different request.');return replay.id;}
    const session=await one(tx,'SELECT id,user_id FROM sessions WHERE token_hash=$1 AND expires_at>now()',[sessionHash]);
    if(!session)fail(401,'UNAUTHENTICATED','Your session has expired. Sign in again.');
    const actor={session,user:{id:session.user_id}};
    const user=await reauthenticate(tx,actor,body.password);
    const owned=(await tx.query('SELECT id FROM questions WHERE user_id=$1 ORDER BY id FOR UPDATE',[user.id])).rows.map(q=>q.id);
    const assigned=(await tx.query('SELECT * FROM questions WHERE assigned_helper_user_id=$1 AND user_id<>$1 ORDER BY id FOR UPDATE',[user.id])).rows;
    for(const q of assigned)if(q.escrow_state==='held') {
     await tx.query("UPDATE questions SET status='cancelled',escrow_state='refunded',updated_at=now() WHERE id=$1",[q.id]);
     await tx.query('UPDATE users SET point_balance=point_balance+$2 WHERE id=$1',[q.user_id,q.reward_points]);
     await tx.query("INSERT INTO point_transactions(id,user_id,question_id,type,amount) VALUES($1,$2,$3,'refund',$4)",[randomId(),q.user_id,q.id,q.reward_points]);
    }
    const answerIds=(await tx.query('SELECT id FROM answers WHERE helper_user_id=$1 OR question_id=ANY($2::uuid[])',[user.id,owned])).rows.map(a=>a.id);
    const storageKeys=(await tx.query('SELECT storage_key FROM question_images WHERE question_id=ANY($1::uuid[])',[owned])).rows.map(image=>image.storage_key);
    const mailIds=(await tx.query('SELECT id FROM account_mail_deliveries WHERE user_id=$1 UNION SELECT id FROM account_mail_outbox WHERE user_id=$1',[user.id])).rows.map(message=>message.id);
    const id=randomId();await tx.query("INSERT INTO account_deletion_jobs(id,receipt_hash,fingerprint,storage_keys,mail_ids,retry_expires_at) VALUES($1,$2,$3,$4,$5,now()+interval '24 hours')",[id,receipt,fingerprint,storageKeys,mailIds]);
    // Preserve surviving users' exact balances/ledger amounts, detaching erased
    // content IDs. Accepted rewards stay paid; deletion never pays them again.
    await tx.query('UPDATE questions SET accepted_answer_id=NULL WHERE accepted_answer_id=ANY($1::uuid[])',[answerIds]);
    await tx.query('UPDATE point_transactions SET answer_id=NULL WHERE answer_id=ANY($1::uuid[])',[answerIds]);
    await tx.query('UPDATE point_transactions SET question_id=NULL WHERE question_id=ANY($1::uuid[])',[owned]);
    await tx.query('DELETE FROM answer_evidence_links WHERE answer_id=ANY($1::uuid[])',[answerIds]);
    await tx.query('DELETE FROM answers WHERE id=ANY($1::uuid[])',[answerIds]);
    await tx.query('DELETE FROM question_comments WHERE user_id=$1 OR question_id=ANY($2::uuid[])',[user.id,owned]);
    await tx.query('DELETE FROM question_images WHERE question_id=ANY($1::uuid[])',[owned]);
    await tx.query('DELETE FROM questions WHERE id=ANY($1::uuid[])',[owned]);
    await tx.query('UPDATE questions SET assigned_helper_user_id=NULL WHERE assigned_helper_user_id=$1',[user.id]);
    await tx.query('UPDATE helper_applications SET reviewed_by=NULL,reject_reason=NULL WHERE reviewed_by=$1',[user.id]);
    await tx.query('DELETE FROM helper_applications WHERE user_id=$1',[user.id]);await tx.query('DELETE FROM helper_regions WHERE helper_user_id=$1',[user.id]);
    await tx.query('DELETE FROM point_transactions WHERE user_id=$1',[user.id]);await tx.query('DELETE FROM idempotency_keys WHERE user_id=$1',[user.id]);
    await tx.query('DELETE FROM auth_idempotency_keys WHERE email=$1',[user.email]);
    await moderation?.eraseOwn(tx,user.id);
    await tx.query('DELETE FROM users WHERE id=$1',[user.id]);return id;
   });
  }
  await cleanDeletedAccountFiles({db,storage,mail,id:jobId,onError:cfg.onError});
  const job=await one(db,'SELECT completed_at FROM account_deletion_jobs WHERE id=$1',[jobId]);
  return job?.completed_at?json({ok:true,account_deleted:true,status:'deleted'}):json({ok:true,account_deleted:true,status:'cleanup_pending',message:'Your account is deleted and images are inaccessible. Private file removal is pending server cleanup.'},202);
 }
 return {setModeration:value=>{moderation=value;},route:async(request,path,method)=>{
  if(method!=='POST')return null;
  if(!['/api/auth/email-verification/request','/api/auth/email-verification/confirm','/api/auth/password-reset/request','/api/auth/password-reset/confirm','/api/account/export','/api/account/delete'].includes(path))return null;
  const body=await readJson(request);
  if(path.endsWith('/request'))return requestMail(request,path,body);
  if(path.endsWith('/confirm'))return confirm(request,path,body);
  if(path==='/api/account/export')return exportAccount(request,body);
  return deleteAccount(request,body);
 }};
}
