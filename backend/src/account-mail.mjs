import {mkdir,writeFile,unlink,access} from 'node:fs/promises';
import {constants} from 'node:fs';
import {resolve,join,isAbsolute} from 'node:path';
import {spawn} from 'node:child_process';
import {unseal} from './crypto.mjs';

const syntheticAddress=email=>/@(?:example\.(?:com|net|org)|[^@]+\.(?:test|invalid))$/i.test(email);
export function loadMailConfig(env,production) {
 const mode=env.MAIL_MODE??'disabled';
 if(!['disabled','local_sink','sendmail'].includes(mode))throw new Error('MAIL_MODE must be disabled, local_sink, or sendmail.');
 if(production&&mode!=='sendmail')throw new Error('Production requires explicitly configured sendmail account delivery.');
 const verificationPolicy=env.EMAIL_VERIFICATION_POLICY??(production?null:'optional');
 if(!['optional','required_for_contributions'].includes(verificationPolicy))throw new Error('Set EMAIL_VERIFICATION_POLICY to optional or required_for_contributions.');
 let actionUrl;
 if(mode!=='disabled') {
  if(!env.ACCOUNT_ACTION_URL)throw new Error('ACCOUNT_ACTION_URL is required when mail is enabled.');
  try{actionUrl=new URL(env.ACCOUNT_ACTION_URL);}catch{throw new Error('ACCOUNT_ACTION_URL must be an absolute app URL.');}
  if(!['http:','https:'].includes(actionUrl.protocol)||actionUrl.username||actionUrl.password||actionUrl.search||actionUrl.hash)throw new Error('ACCOUNT_ACTION_URL requires HTTP(S), no credentials/query/fragment.');
  if(production&&actionUrl.protocol!=='https:')throw new Error('Production ACCOUNT_ACTION_URL requires HTTPS.');
 }
 const from=env.MAIL_FROM;
 if(mode==='sendmail'&&(!from||! /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(from)))throw new Error('MAIL_FROM must be a plain valid mailbox for sendmail.');
 const executable=env.SENDMAIL_PATH??'/usr/sbin/sendmail';
 if(mode==='sendmail'&&!isAbsolute(executable))throw new Error('SENDMAIL_PATH must be absolute.');
 return {mailMode:mode,mailFrom:from,mailSinkDirectory:env.MAIL_SINK_DIR??'./data/mail-sink',sendmailPath:executable,accountActionUrl:actionUrl?.href,emailVerificationPolicy:verificationPolicy};
}

/** In-process sink is useful in tests; rejects every non-synthetic address. */
export function createMemoryMailSink() {
 const messages=[];
 return {mode:'local_sink',messages,send:async message=>{if(!syntheticAddress(message.to))throw new Error('Local sink permits synthetic addresses only.');if(!messages.some(m=>m.id===message.id))messages.push({...message});},remove:async id=>{const index=messages.findIndex(m=>m.id===id);if(index>=0)messages.splice(index,1);}};
}
export async function createMailTransport(config) {
 if(config.mailMode==='disabled')return {mode:'disabled'};
 if(config.mailMode==='local_sink') {
  if(config.production)throw new Error('A local mail sink cannot run in production.');
  const directory=resolve(config.mailSinkDirectory);await mkdir(directory,{recursive:true,mode:0o700});
  return {mode:'local_sink',send:async message=>{
   if(!syntheticAddress(message.to))throw new Error('Local sink permits synthetic addresses only.');
   await writeFile(join(directory,`${message.id}.json`),JSON.stringify(message,null,2),{mode:0o600});
  },remove:async id=>{try{await unlink(join(directory,`${id}.json`));}catch(error){if(error.code!=='ENOENT')throw error;}}};
 }
 await access(config.sendmailPath,constants.X_OK);
 return {mode:'sendmail',send:message=>new Promise((resolve,reject)=>{
  // No shell, no recipient-controlled options or headers. Local MTA owns TLS,
  // relay auth, queueing, bounce handling, and actual remote delivery.
  if(!/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(message.to))return reject(new Error('Invalid destination.'));
  const child=spawn(config.sendmailPath,['-i','-t'],{stdio:['pipe','ignore','ignore']});
  const timer=setTimeout(()=>{child.kill();reject(new Error('Mail transport timed out.'));},15_000);timer.unref();
  child.once('error',error=>{clearTimeout(timer);reject(error);});
  child.once('close',code=>{clearTimeout(timer);code===0?resolve():reject(new Error('Mail transport did not accept the message.'));});
  child.stdin.on('error',()=>{});
  child.stdin.end(`From: ${config.mailFrom}\nTo: ${message.to}\nSubject: ${message.purpose==='verify_email'?'Verify your email':'Reset your password'}\nMessage-ID: <${message.id}@account.local>\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n${message.text}\n`);
 })};
}

export async function drainAccountMail({db,mail,secret,onError=()=>{},limit=20}) {
 if(!mail?.send)return;
 for(let i=0;i<limit;i++) {
  const found=await db.transaction(async tx=>{
   await tx.query('SELECT pg_advisory_xact_lock_shared(73284129)');
   await tx.query('DELETE FROM account_mail_outbox WHERE expires_at<=now()');
   const row=(await tx.query('SELECT * FROM account_mail_outbox WHERE available_at<=now() ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1')).rows[0];
   if(!row)return false;
   try {
    const message=await unseal(secret,row.encrypted_message,`account-mail:${row.id}`);
    await mail.send(message);
    await tx.query('INSERT INTO account_mail_deliveries(id,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING',[row.id,row.user_id]);
    await tx.query('DELETE FROM account_mail_outbox WHERE id=$1',[row.id]);
   } catch(error) {
    onError(error);
    await tx.query("UPDATE account_mail_outbox SET attempts=attempts+1,available_at=now()+interval '1 minute' * LEAST(60,power(2,LEAST(attempts,6))) WHERE id=$1",[row.id]);
   }
   return true;
  });
  if(!found)break;
 }
}
