import {randomId} from './crypto.mjs';

// Literal phrase matching is a configurable first layer, not semantic or image
// moderation. Do not represent these deliberately narrow defaults as complete.
export const defaultTextFilterTerms=Object.freeze(['i will kill you','i will murder you']);
const normalize=value=>value.normalize('NFKC').toLowerCase().replace(/[\u200B-\u200D\u2060\uFEFF]/g,'').replace(/\s+/g,' ').trim();
export function createTextFilter(terms=defaultTextFilterTerms) {
 if(!Array.isArray(terms)||terms.length>500||terms.some(t=>typeof t!=='string'||!normalize(t)||t.length>100))throw new Error('textFilterTerms must be an array of up to 500 nonempty phrases, each at most 100 characters.');
 const phrases=[...new Set(terms.map(normalize))];
 function check(value) {
  if(typeof value==='string')return phrases.some(phrase=>normalize(value).includes(phrase));
  if(Array.isArray(value))return value.some(check);
  if(value&&typeof value==='object')return Object.entries(value).some(([key,item])=>!['password','email','data_base64'].includes(key)&&check(item));
  return false;
 }
 return check;
}

/** Shared safety gate serializes block/hide/suspension/deletion against reads and
 * writes. Acquire BEFORE question/user locks, never upgrade shared to exclusive.
 * The account lifecycle module uses this exact gate for permanent deletion. */
export async function moderationLock(tx,write=false) {
 await tx.query(write?'SELECT pg_advisory_xact_lock(73284129)':'SELECT pg_advisory_xact_lock_shared(73284129)');
}

export function createModeration({db,cfg,fail,json,one,readJson,fields,text,choice,uuid,mutate}) {
 const rejectsText=createTextFilter(cfg.textFilterTerms);
 const lock=moderationLock;
 function assertText(value){if(rejectsText(value))fail(422,'CONTENT_REJECTED','This text cannot be posted. Edit it to follow the community safety rules.');}
 async function assertActive(tx,user) {
  const current=await one(tx,'SELECT is_suspended FROM users WHERE id=$1',[user.id]);
  if(!current)fail(401,'UNAUTHENTICATED','Your account is no longer available.');
  if(current.is_suspended)fail(403,'ACCOUNT_SUSPENDED','This account is suspended. Account access and deletion remain available.');
 }
 async function blocked(tx,viewerId,subjectIds) {
  const ids=[...new Set(subjectIds.filter(Boolean))].filter(id=>id!==viewerId);
  if(!ids.length)return new Set();
  const rows=(await tx.query(`SELECT id FROM users WHERE id=ANY($2::uuid[]) AND (is_suspended OR EXISTS(
   SELECT 1 FROM user_blocks b WHERE (b.blocker_id=$1 AND b.blocked_id=users.id) OR (b.blocked_id=$1 AND b.blocker_id=users.id)))`,[viewerId,ids])).rows;
  return new Set(rows.map(row=>row.id));
 }
 async function filterQuestions(tx,questions,user) {
  if(user.is_admin)return questions;
  const denied=await blocked(tx,user.id,questions.flatMap(q=>[q.user_id,q.assigned_helper_user_id]));
  return questions.filter(q=>!q.moderation_hidden&&!denied.has(q.user_id)&&!denied.has(q.assigned_helper_user_id));
 }
 async function assertQuestionVisible(tx,q,user) {
  if(!(await filterQuestions(tx,[q],user)).length)fail(404,'NOT_FOUND','Question not found.');
 }
 async function filterDetail(tx,q,{answers,comments,assignedHelper},user) {
  if(user.is_admin)return {answers,comments,assignedHelper,accepted_answer_id:q.accepted_answer_id};
  const denied=await blocked(tx,user.id,[...answers.map(a=>a.helper_user_id),...comments.map(c=>c.user_id),assignedHelper?.id]);
  const visibleAnswers=answers.filter(a=>!a.moderation_hidden&&!denied.has(a.helper_user_id));
  return {answers:visibleAnswers,comments:comments.filter(c=>!c.moderation_hidden&&!denied.has(c.user_id)),
   assignedHelper:assignedHelper&&!denied.has(assignedHelper.id)?assignedHelper:null,
   accepted_answer_id:visibleAnswers.some(a=>a.id===q.accepted_answer_id)?q.accepted_answer_id:null};
 }
 async function assertAnswerVisible(tx,answer,user) {
  if(!user.is_admin&&(answer.moderation_hidden||(await blocked(tx,user.id,[answer.helper_user_id])).size))fail(404,'NOT_FOUND','Answer not found.');
 }
 function normallyVisible(q,user){return q.status==='open'||q.user_id===user.id||q.assigned_helper_user_id===user.id||user.is_admin;}
 async function target(tx,type,id,user) {
  if(type==='user') {
   const row=await one(tx,'SELECT id,name,is_suspended FROM users WHERE id=$1',[id]);
   if(!row)fail(404,'NOT_FOUND','User not found.');
   return {subject:row.id,row};
  }
  const table=type==='question'?'questions':type==='answer'?'answers':'question_comments';
  const row=await one(tx,`SELECT * FROM ${table} WHERE id=$1`,[id]);
  if(!row)fail(404,'NOT_FOUND','Content not found.');
  const q=type==='question'?row:await one(tx,'SELECT * FROM questions WHERE id=$1',[row.question_id]);
  if(!q||!normallyVisible(q,user))fail(404,'NOT_FOUND','Content not found.');
  await assertQuestionVisible(tx,q,user);
  const subject=type==='answer'?row.helper_user_id:row.user_id;
  if(!user.is_admin&&(row.moderation_hidden||(await blocked(tx,user.id,[subject])).size))fail(404,'NOT_FOUND','Content not found.');
  return {subject,row,q};
 }
 async function admin(tx,user) {
  await assertActive(tx,user);
  if(!(await one(tx,'SELECT is_admin FROM users WHERE id=$1',[user.id]))?.is_admin)fail(403,'ADMIN_REQUIRED','Administrator access required.');
 }
 async function targetContext(tx,report) {
  if(report.target_type==='user')return one(tx,'SELECT id,name,is_suspended FROM users WHERE id=$1',[report.subject_user_id]);
  if(report.target_type==='question')return one(tx,'SELECT id,user_id,title,body,status,moderation_hidden FROM questions WHERE id=$1',[report.target_id]);
  if(report.target_type==='answer')return one(tx,'SELECT id,question_id,helper_user_id,body,evidence_summary,verification_method,moderation_hidden FROM answers WHERE id=$1',[report.target_id]);
  return one(tx,'SELECT id,question_id,user_id,body,moderation_hidden FROM question_comments WHERE id=$1',[report.target_id]);
 }
 async function exportOwn(tx,userId,{statsOnly=false}={}) {
  const queries={reports:'SELECT id,target_type,target_id,reason,details,status,created_at,reviewed_at FROM content_reports WHERE reporter_id=$1 ORDER BY created_at,id',blocks:'SELECT blocked_id AS blocked_user_id,created_at FROM user_blocks WHERE blocker_id=$1 ORDER BY created_at,blocked_id',moderation_notes:'SELECT report_id,action,note,created_at FROM moderation_actions WHERE reviewer_id=$1 ORDER BY created_at,id'};
  const result={};for(const [name,sql] of Object.entries(queries))result[name]=statsOnly?
   (await tx.query(`SELECT count(*)::int AS count,coalesce(sum(octet_length(row_to_json(export_row)::text)),0)::bigint AS bytes FROM (${sql.replace(/ ORDER BY .+$/,'')}) export_row`,[userId])).rows[0]:
   (await tx.query(sql,[userId])).rows;
  return result;
 }
 async function eraseOwn(tx,userId) {
  // An unrelated action may remain as non-content history, but a deleted
  // reviewer's free-text note must not become a hidden personal-data copy.
  await tx.query('UPDATE moderation_actions SET note=NULL WHERE reviewer_id=$1',[userId]);
 }
 async function route({request,path,method,url,actor}) {
  const {user}=actor;
  if(method==='POST'&&path==='/api/reports') {
   const b=await readJson(request);fields(b,['target_type','target_id','reason','details']);
   const type=choice(b.target_type,'target_type',['question','answer','comment','user']),id=uuid(b.target_id??'');
   const reason=choice(b.reason,'reason',['harassment','hate','sexual','violence','spam','privacy','other']),details=text(b.details,'details',{optional:true,max:1000});
   return mutate(request,actor,b,true,async tx=>{
    // Account row lock bounds concurrent distinct reports from the same actor.
    await tx.query('SELECT id FROM users WHERE id=$1 FOR NO KEY UPDATE',[user.id]);
    const existing=await one(tx,'SELECT id,status FROM content_reports WHERE reporter_id=$1 AND target_type=$2 AND target_id=$3',[user.id,type,id]);
    if(existing)return {body:existing};
    const item=await target(tx,type,id,user);
    if(item.subject===user.id)fail(400,'SELF_REPORT','You cannot report your own content or account.');
    const count=await one(tx,"SELECT count(*)::int AS n FROM content_reports WHERE reporter_id=$1 AND created_at>now()-interval '24 hours'",[user.id]);
    if(count.n>=30)fail(429,'REPORT_LIMIT','The daily report limit has been reached.');
    const reportId=randomId();await tx.query(`INSERT INTO content_reports(id,reporter_id,subject_user_id,target_type,target_id,question_id,answer_id,comment_id,reason,details)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,[reportId,user.id,item.subject,type,id,type==='question'?id:null,type==='answer'?id:null,type==='comment'?id:null,reason,details]);
    return {body:{id:reportId,status:'open'},status:201};
   });
  }
  if(method==='GET'&&path==='/api/blocks')return db.transaction(async tx=>{
   await lock(tx);await assertActive(tx,user);
   return json((await tx.query('SELECT b.blocked_id AS blocked_user_id,u.name,b.created_at FROM user_blocks b JOIN users u ON u.id=b.blocked_id WHERE b.blocker_id=$1 ORDER BY b.created_at DESC,b.blocked_id LIMIT 500',[user.id])).rows);
  });
  const block=/^\/api\/blocks\/([^/]+)(?:\/(unblock))?$/.exec(path);
  if(method==='POST'&&block) {
   const id=uuid(block[1]),b=await readJson(request);fields(b,[]);
   if(id===user.id)fail(400,'SELF_BLOCK','You cannot block yourself.');
   return mutate(request,actor,b,true,async tx=>{
    if(!await one(tx,'SELECT id FROM users WHERE id=$1',[id]))fail(404,'NOT_FOUND','User not found.');
    if(block[2])await tx.query('DELETE FROM user_blocks WHERE blocker_id=$1 AND blocked_id=$2',[user.id,id]);
    else {
     const existing=await one(tx,'SELECT blocked_id FROM user_blocks WHERE blocker_id=$1 AND blocked_id=$2',[user.id,id]);
     if(!existing) {
      const count=await one(tx,'SELECT count(*)::int AS n FROM user_blocks WHERE blocker_id=$1',[user.id]);
      if(count.n>=500)fail(409,'BLOCK_LIMIT','The block list limit has been reached.');
      await tx.query('INSERT INTO user_blocks(blocker_id,blocked_id) VALUES($1,$2) ON CONFLICT DO NOTHING',[user.id,id]);
     }
    }
    return {ok:true};
   },{safetyWrite:true});
  }
  if(method==='GET'&&path==='/api/admin/reports') {
   const status=choice(url.searchParams.get('status')??'open','status',['open','reviewed']);
   return db.transaction(async tx=>{
    await lock(tx);await admin(tx,user);
    const reports=(await tx.query('SELECT * FROM content_reports WHERE status=$1 ORDER BY created_at,id LIMIT 200',[status])).rows;
    const result=[];for(const report of reports)result.push({...report,target:await targetContext(tx,report),actions:(await tx.query('SELECT id,reviewer_id,action,note,created_at FROM moderation_actions WHERE report_id=$1 ORDER BY created_at,id',[report.id])).rows});
    return json(result);
   });
  }
  const review=/^\/api\/admin\/reports\/([^/]+)\/review$/.exec(path);
  if(method==='POST'&&review) {
   // Reject non-admin payloads before parsing report IDs or operational notes.
   if(!user.is_admin)fail(403,'ADMIN_REQUIRED','Administrator access required.');
   const id=uuid(review[1]),b=await readJson(request);fields(b,['action','note']);
   const action=choice(b.action,'action',['dismiss','hide','restore','suspend','reinstate']),note=text(b.note,'note',{optional:true,max:1000});
   return mutate(request,actor,b,true,async tx=>{
    await admin(tx,user);
    const report=await one(tx,'SELECT * FROM content_reports WHERE id=$1 FOR UPDATE',[id]);if(!report)fail(404,'NOT_FOUND','Report not found.');
    let changed=false;
    if(['hide','restore'].includes(action)) {
     if(report.target_type==='user')fail(400,'INVALID_REVIEW','Use suspend or reinstate for a user report.');
     const table=report.target_type==='question'?'questions':report.target_type==='answer'?'answers':'question_comments';
     changed=(await tx.query(`UPDATE ${table} SET moderation_hidden=$2 WHERE id=$1 AND moderation_hidden IS DISTINCT FROM $2 RETURNING id`,[report.target_id,action==='hide'])).rows.length>0;
    } else if(['suspend','reinstate'].includes(action)) {
     const subject=await one(tx,'SELECT id,is_admin FROM users WHERE id=$1 FOR NO KEY UPDATE',[report.subject_user_id]);
     if(!subject)fail(404,'NOT_FOUND','User not found.');
     if(subject.is_admin||subject.id===user.id)fail(403,'PROTECTED_ACCOUNT','Administrator accounts require trusted operator review.');
     changed=(await tx.query('UPDATE users SET is_suspended=$2 WHERE id=$1 AND is_suspended IS DISTINCT FROM $2 RETURNING id',[subject.id,action==='suspend'])).rows.length>0;
    }
    // Repeat the same reviewed action safely without duplicate audit rows. A
    // different action remains an explicit reversible review with a fresh key.
    const previous=await one(tx,'SELECT action,note FROM moderation_actions WHERE report_id=$1 ORDER BY created_at DESC,id DESC LIMIT 1',[id]);
    if(changed||!previous||previous.action!==action||previous.note!==note)await tx.query('INSERT INTO moderation_actions(id,report_id,reviewer_id,action,note) VALUES($1,$2,$3,$4,$5)',[randomId(),id,user.id,action,note]);
    await tx.query("UPDATE content_reports SET status='reviewed',reviewed_at=now() WHERE id=$1",[id]);
    return {ok:true};
   },{safetyWrite:true});
  }
  return null;
 }
 return {lock,assertText,assertActive,filterQuestions,assertQuestionVisible,filterDetail,assertAnswerVisible,exportOwn,eraseOwn,route};
}
