import {randomId,sign,verifySignature} from './crypto.mjs';

const pageSize=20;
const cursorPrefix='malaga-exchange-issues-v1:';
const cursorKeys=['v','user','view','status','created_at','id'];
const uuidPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const timestampPattern=/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const timestamp=column=>`to_char(${column} AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;
const ownColumns=`i.id,i.question_id,CASE WHEN q.user_id=i.reporter_id THEN 'traveler' ELSE 'guide' END AS role,
 i.reason,i.details,i.status,${timestamp('i.created_at')} AS created_at,${timestamp('i.reviewed_at')} AS reviewed_at`;

// Both list and direct lookup share participant, eligibility and redaction rules.
const eligibleSelection=`SELECT q.id AS question_id,CASE WHEN q.user_id=$1 THEN 'traveler' ELSE 'guide' END AS role,
     CASE WHEN visible.content_available THEN q.title ELSE NULL END AS title,visible.content_available,
     q.status,${timestamp('q.created_at')} AS created_at,${timestamp('q.updated_at')} AS updated_at,i.id AS own_issue_id
     FROM questions q JOIN users other ON other.id=CASE WHEN q.user_id=$1 THEN q.assigned_helper_user_id ELSE q.user_id END
     CROSS JOIN LATERAL (SELECT NOT(q.moderation_hidden OR other.is_suspended OR EXISTS(
      SELECT 1 FROM user_blocks b WHERE (b.blocker_id=$1 AND b.blocked_id=other.id) OR (b.blocked_id=$1 AND b.blocker_id=other.id))) AS content_available) visible
     LEFT JOIN exchange_issues i ON i.question_id=q.id AND i.reporter_id=$1
     WHERE (q.user_id=$1 OR q.assigned_helper_user_id=$1) AND q.assigned_helper_user_id IS NOT NULL
      AND q.status IN ('assigned','answered') AND q.escrow_state='held'`;

function validTimestamp(value) {
 if(typeof value!=='string'||!timestampPattern.test(value)||value.startsWith('0000-'))return false;
 const parsed=new Date(value);
 return Number.isFinite(parsed.getTime())&&parsed.toISOString()===`${value.slice(0,23)}Z`;
}

/** Recording/reviewing an issue never settles, cancels, reassigns, hides or
 * suspends anything. Private intake remains reachable for hidden obligations. */
export function createExchangeIssues({db,moderation,secret,fail,json,one,readJson,fields,text,choice,uuid,mutate}) {
 function optionalText(value,name) {
  if(typeof value==='string'&&value.includes('\0'))fail(400,'VALIDATION',`${name} cannot contain null characters.`);
  return text(typeof value==='string'?value.trim():value,name,{optional:true,max:1000});
 }
 async function liveActor(tx,actor,{admin=false,write=false}={}) {
  // User before session agrees with password-reset's user -> sessions order.
  // Intake locks its question first, agreeing with acceptance's question -> user.
  const current=await one(tx,`SELECT is_admin,is_suspended FROM users WHERE id=$1 FOR ${write?'NO KEY UPDATE':'SHARE'}`,[actor.user.id]);
  if(!current)fail(401,'UNAUTHENTICATED','Your account is no longer available.');
  // now() is transaction start; gate/resource waits may outlive a session.
  if(!await one(tx,'SELECT id FROM sessions WHERE id=$1 AND user_id=$2 AND expires_at>clock_timestamp() FOR SHARE',[actor.session.id,actor.user.id]))fail(401,'UNAUTHENTICATED','Your session has expired. Sign in again.');
  if(current.is_suspended)fail(403,'ACCOUNT_SUSPENDED','This account is suspended. Account access and deletion remain available.');
  if(admin&&!current.is_admin)fail(403,'ADMIN_REQUIRED','Administrator access required.');
 }
 async function participant(tx,actor,questionId) {
  const q=await one(tx,'SELECT id,user_id,assigned_helper_user_id,status,escrow_state FROM questions WHERE id=$1 FOR SHARE',[questionId]);
  if(!q||![q.user_id,q.assigned_helper_user_id].includes(actor.user.id))fail(404,'NOT_FOUND','Exchange not found.');
  await liveActor(tx,actor,{write:true});
  return q;
 }
 function queryParameters(url,view) {
  const allowed=view==='admin'?['status','cursor']:['cursor'];
  for(const key of url.searchParams.keys())if(!allowed.includes(key)||url.searchParams.getAll(key).length!==1)
   fail(400,'INVALID_EXCHANGE_ISSUES_QUERY','Use only the supported status and cursor parameters.');
  const status=view==='admin'?(url.searchParams.get('status')??'open'):null;
  if(view==='admin'&&!['open','reviewed'].includes(status))fail(400,'INVALID_EXCHANGE_ISSUES_QUERY','Choose open or reviewed.');
  return {status,encoded:url.searchParams.get('cursor')};
 }
 async function readCursor(encoded,user,view,status) {
  if(encoded===null)return null;
  const invalid=()=>fail(400,'INVALID_EXCHANGE_ISSUES_CURSOR','This issue cursor is invalid. Refresh the list.');
  if(encoded.length>1024||!/^[-_A-Za-z0-9]+\.[-_A-Za-z0-9]{43}$/.test(encoded))return invalid();
  const [payload,signature]=encoded.split('.');
  if(Buffer.from(signature,'base64url').toString('base64url')!==signature||!await verifySignature(secret,`${cursorPrefix}${payload}`,signature))return invalid();
  let cursor;
  try {
   const bytes=Buffer.from(payload,'base64url');
   if(bytes.toString('base64url')!==payload)return invalid();
   cursor=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  } catch {return invalid();}
  if(!cursor||Array.isArray(cursor)||typeof cursor!=='object'||Object.keys(cursor).length!==cursorKeys.length||
   cursorKeys.some(key=>!Object.hasOwn(cursor,key))||cursor.v!==1||cursor.user!==user.id||cursor.view!==view||cursor.status!==status||
   !validTimestamp(cursor.created_at)||typeof cursor.id!=='string'||!uuidPattern.test(cursor.id))return invalid();
  return cursor;
 }
 async function page(rows,user,view,status) {
  const items=rows.slice(0,pageSize);let next_cursor=null;
  if(rows.length>pageSize) {
   const last=items.at(-1),payload=Buffer.from(JSON.stringify({v:1,user:user.id,view,status,created_at:last.created_at,id:last.id??last.question_id})).toString('base64url');
   next_cursor=`${payload}.${await sign(secret,`${cursorPrefix}${payload}`)}`;
  }
  return json({items,next_cursor});
 }
 async function list(url,actor,view) {
  return db.transaction(async tx=>{
   await moderation.lock(tx);await liveActor(tx,actor,{admin:view==='admin'});
   const {status,encoded}=queryParameters(url,view),cursor=await readCursor(encoded,actor.user,view,status);
   let rows;
   if(view==='eligible') {
    rows=(await tx.query(`${eligibleSelection}
      AND ($2::timestamptz IS NULL OR (q.created_at,q.id)>($2::timestamptz,$3::uuid))
     ORDER BY q.created_at,q.id LIMIT $4`,[actor.user.id,cursor?.created_at??null,cursor?.id??null,pageSize+1])).rows;
   } else {
    rows=(await tx.query(`SELECT ${ownColumns}${view==='admin'?',i.reporter_id,i.other_participant_id,i.reviewed_by,i.review_note':''}
     FROM exchange_issues i JOIN questions q ON q.id=i.question_id
     WHERE ${view==='admin'?'i.status=$1':'i.reporter_id=$1'}
      AND ($2::timestamptz IS NULL OR (i.created_at,i.id)${view==='own'?'<':'>'}($2::timestamptz,$3::uuid))
     ORDER BY i.created_at ${view==='own'?'DESC':'ASC'},i.id ${view==='own'?'DESC':'ASC'} LIMIT $4`,[view==='admin'?status:actor.user.id,cursor?.created_at??null,cursor?.id??null,pageSize+1])).rows;
   }
   return page(rows,actor.user,view,status);
  });
 }
 async function exportOwn(tx,userId,{statsOnly=false}={}) {
  const selections={
   exchange_issues:`SELECT ${ownColumns} FROM exchange_issues i JOIN questions q ON q.id=i.question_id WHERE i.reporter_id=$1 ORDER BY i.created_at,i.id`,
   exchange_issue_reviews:'SELECT id AS issue_id,question_id,review_note,reviewed_at FROM exchange_issues WHERE reviewed_by=$1 ORDER BY reviewed_at,id',
  };
  const result={};
  for(const [name,sql] of Object.entries(selections))result[name]=statsOnly?
   await one(tx,`SELECT count(*)::int AS count,coalesce(sum(octet_length(row_to_json(export_row)::text)),0)::bigint AS bytes FROM (${sql.replace(/ ORDER BY .+$/,'')}) export_row`,[userId]):
   (await tx.query(sql,[userId])).rows;
  return result;
 }
 async function eraseOwn(tx,userId) {
  await tx.query('UPDATE exchange_issues SET review_note=NULL WHERE reviewed_by=$1',[userId]);
 }
 async function route({request,path,method,url,actor}) {
  if(method==='GET'&&path==='/api/exchange-issues/eligible')return list(url,actor,'eligible');
  if(method==='GET'&&path==='/api/exchange-issues')return list(url,actor,'own');
  if(method==='GET'&&path==='/api/admin/exchange-issues')return list(url,actor,'admin');
  const eligibleDetail=/^\/api\/exchange-issues\/eligible\/([^/]+)$/.exec(path);
  if(method==='GET'&&eligibleDetail)return db.transaction(async tx=>{
   await moderation.lock(tx);await liveActor(tx,actor);
   if([...url.searchParams.keys()].length)fail(400,'INVALID_EXCHANGE_ISSUES_QUERY','This eligible exchange lookup does not accept query parameters.');
   const id=uuid(eligibleDetail[1]).toLowerCase();
   const item=await one(tx,`${eligibleSelection} AND q.id=$2`,[actor.user.id,id]);
   if(!item)fail(404,'NOT_FOUND','Eligible exchange not found.');
   return json(item);
  });
  const ownDetail=/^\/api\/exchange-issues\/([^/]+)$/.exec(path);
  if(method==='GET'&&ownDetail)return db.transaction(async tx=>{
   await moderation.lock(tx);await liveActor(tx,actor);
   if([...url.searchParams.keys()].length)fail(400,'INVALID_EXCHANGE_ISSUES_QUERY','This issue detail does not accept query parameters.');
   const id=uuid(ownDetail[1]).toLowerCase();
   const issue=await one(tx,`SELECT ${ownColumns} FROM exchange_issues i JOIN questions q ON q.id=i.question_id WHERE i.id=$1 AND i.reporter_id=$2`,[id,actor.user.id]);
   if(!issue)fail(404,'NOT_FOUND','Issue record not found.');
   return json(issue);
  });
  if(method==='POST'&&path==='/api/exchange-issues') {
   const body=await readJson(request,{maximum:8192});fields(body,['question_id','reason','details']);
   const questionId=uuid(body.question_id??'').toLowerCase(),reason=choice(body.reason,'reason',['waiting_for_response','answer_problem','cannot_continue','other']),details=optionalText(body.details,'details');
   let q;
   return mutate(request,actor,body,true,async tx=>{
    const existing=await one(tx,'SELECT id,reason,details FROM exchange_issues WHERE question_id=$1 AND reporter_id=$2',[questionId,actor.user.id]);
    if(existing) {
     if(existing.reason!==reason||existing.details!==details)fail(409,'ISSUE_ALREADY_EXISTS','You already recorded an issue for this exchange. Existing text cannot be replaced.');
     return {body:{id:existing.id}};
    }
    if(!q.assigned_helper_user_id||!['assigned','answered'].includes(q.status)||q.escrow_state!=='held')fail(409,'EXCHANGE_NOT_ELIGIBLE','Only assigned or answered exchanges with held points accept a new issue record.');
    const count=await one(tx,"SELECT count(*)::int AS n FROM exchange_issues WHERE reporter_id=$1 AND created_at>now()-interval '24 hours'",[actor.user.id]);
    if(count.n>=30)fail(429,'ISSUE_LIMIT','The daily issue record limit has been reached.');
    const id=randomId(),other=q.user_id===actor.user.id?q.assigned_helper_user_id:q.user_id;
    await tx.query('INSERT INTO exchange_issues(id,question_id,reporter_id,other_participant_id,reason,details) VALUES($1,$2,$3,$4,$5,$6)',[id,questionId,actor.user.id,other,reason,details]);
    return {body:{id},status:201};
   },{authorize:async tx=>{q=await participant(tx,actor,questionId);}});
  }
  const review=/^\/api\/admin\/exchange-issues\/([^/]+)\/review$/.exec(path);
  if(method==='POST'&&review) {
   if(!actor.user.is_admin)fail(403,'ADMIN_REQUIRED','Administrator access required.');
   const id=uuid(review[1]).toLowerCase(),body=await readJson(request,{maximum:8192});fields(body,['note']);
   const note=optionalText(body.note,'note');
   return mutate(request,actor,body,true,async tx=>{
    const issue=await one(tx,'SELECT status,reviewed_by,review_note FROM exchange_issues WHERE id=$1 FOR UPDATE',[id]);
    if(!issue)fail(404,'NOT_FOUND','Issue record not found.');
    if(issue.status==='reviewed') {
     if(issue.reviewed_by!==actor.user.id||issue.review_note!==note)fail(409,'ISSUE_ALREADY_REVIEWED','This issue already has a review. The first review cannot be replaced.');
     return {ok:true};
    }
    await tx.query("UPDATE exchange_issues SET status='reviewed',reviewed_at=now(),reviewed_by=$2,review_note=$3 WHERE id=$1",[id,actor.user.id,note]);
    return {ok:true};
   },{authorize:tx=>liveActor(tx,actor,{admin:true})});
  }
  return null;
 }
 return {route,exportOwn,eraseOwn};
}
