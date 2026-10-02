import {sign,verifySignature} from './crypto.mjs';

const pageSize=20;
const terminalStatuses=['accepted','cancelled','expired'];
const cursorPrefix='malaga-activity-v1:';
const cursorKeys=['v','user','role','view','created_at','id'];
const uuidPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const timestampPattern=/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;

function validTimestamp(value) {
 if(typeof value!=='string'||!timestampPattern.test(value)||value.startsWith('0000-'))return false;
 const parsed=new Date(value);
 return Number.isFinite(parsed.getTime())&&parsed.toISOString()===`${value.slice(0,23)}Z`;
}

/** Personal work lists deliberately use ordinary participant visibility even
 * for administrators. Moderation review remains in the existing admin routes.
 * No detail/media reads are needed to render or paginate an activity list. */
export function createActivity({db,moderation,secret,fail}) {
 function queryParameters(url) {
  const params=url.searchParams;
  for(const key of params.keys())if(!['role','view','cursor'].includes(key)||params.getAll(key).length!==1)
   fail(400,'INVALID_ACTIVITY_QUERY','Use one role, view, and optional activity cursor.');
  const role=params.get('role')??'traveler',view=params.get('view')??'active';
  if(!['traveler','guide'].includes(role)||!['active','history'].includes(view))
   fail(400,'INVALID_ACTIVITY_QUERY','Choose traveler or guide, and active or history.');
  return {role,view,cursor:params.get('cursor')};
 }
 async function readCursor(encoded,user,role,view) {
  if(encoded===null)return null;
  const invalid=()=>fail(400,'INVALID_ACTIVITY_CURSOR','This activity cursor is invalid. Refresh the list.');
  if(encoded.length>1024||!/^[-_A-Za-z0-9]+\.[-_A-Za-z0-9]{43}$/.test(encoded))return invalid();
  const [payload,signature]=encoded.split('.');
  if(Buffer.from(signature,'base64url').toString('base64url')!==signature)return invalid();
  if(!await verifySignature(secret,`${cursorPrefix}${payload}`,signature))return invalid();
  let cursor;
  try {
   const bytes=Buffer.from(payload,'base64url');
   if(bytes.toString('base64url')!==payload)return invalid();
   cursor=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  } catch { return invalid(); }
  if(!cursor||Array.isArray(cursor)||typeof cursor!=='object'||
   Object.keys(cursor).length!==cursorKeys.length||cursorKeys.some(key=>!Object.hasOwn(cursor,key))||
   cursor.v!==1||cursor.user!==user.id||cursor.role!==role||cursor.view!==view||
   !validTimestamp(cursor.created_at)||typeof cursor.id!=='string'||!uuidPattern.test(cursor.id))return invalid();
  return cursor;
 }
 async function nextCursor(row,user,role,view) {
  const payload=Buffer.from(JSON.stringify({v:1,user:user.id,role,view,created_at:row.created_at,id:row.id})).toString('base64url');
  return `${payload}.${await sign(secret,`${cursorPrefix}${payload}`)}`;
 }
 return async function activityQuestions(url,{user,session}) {
  const {role,view,cursor:encoded}=queryParameters(url);
  const cursor=await readCursor(encoded,user,role,view);
  return db.transaction(async tx=>{
   await moderation.lock(tx);
   // Keep the user -> session lock order used by password reset. Authentication
   // may have completed before a logout or expiry during the safety-gate wait.
   const current=(await tx.query('SELECT is_suspended FROM users WHERE id=$1 FOR SHARE',[user.id])).rows[0];
   if(!current)fail(401,'UNAUTHENTICATED','Your account is no longer available.');
   if(!(await tx.query('SELECT id FROM sessions WHERE id=$1 AND user_id=$2 AND expires_at>clock_timestamp() FOR SHARE',[session.id,user.id])).rows.length)
    fail(401,'UNAUTHENTICATED','Your session has expired. Sign in again.');
   if(current.is_suspended)fail(403,'ACCOUNT_SUSPENDED','This account is suspended. Account access and deletion remain available.');
   // This is the same hidden/suspended/bilateral-block rule as
   // moderation.filterQuestions for participants, applied before LIMIT so a
   // run of hidden records cannot empty a page or strand visible older work.
   // A compact page needs only one statement snapshot. Do not lock questions
   // after the user: answer acceptance locks question -> rewarded guide user.
   const scope=role==='traveler'?'q.user_id=$1':'q.assigned_helper_user_id=$1';
   const terminal=view==='history'?'q.status=ANY($2::text[])':'NOT(q.status=ANY($2::text[]))';
   const rows=(await tx.query(`SELECT q.id,q.user_id,q.assigned_helper_user_id,
    q.country,q.city,q.region_name,q.category,q.urgency,q.title,q.reward_points,q.status,
    to_char(q.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
    to_char(q.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS updated_at,
    q.expires_at
    FROM questions q WHERE ${scope} AND ${terminal} AND NOT q.moderation_hidden
    AND NOT EXISTS(SELECT 1 FROM users subject
     WHERE subject.id IN(q.user_id,q.assigned_helper_user_id) AND subject.id<>$1
     AND (subject.is_suspended OR EXISTS(SELECT 1 FROM user_blocks b
      WHERE (b.blocker_id=$1 AND b.blocked_id=subject.id) OR (b.blocked_id=$1 AND b.blocker_id=subject.id))))
    AND ($3::timestamptz IS NULL OR (q.created_at,q.id)<($3::timestamptz,$4::uuid))
    ORDER BY q.created_at DESC,q.id DESC LIMIT $5`,
    [user.id,terminalStatuses,cursor?.created_at??null,cursor?.id??null,pageSize+1])).rows;
   const items=rows.slice(0,pageSize);
   return {items,next_cursor:rows.length>pageSize?await nextCursor(items.at(-1),user,role,view):null};
  });
 };
}
