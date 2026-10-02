import {sign,verifySignature} from './crypto.mjs';

const pageSize=20;
const cursorPrefix='malaga-guide-discovery-v1:';
const cursorKeys=['v','user','created_at','id'];
const uuidPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const timestampPattern=/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;

function validTimestamp(value) {
 if(typeof value!=='string'||!timestampPattern.test(value)||value.startsWith('0000-'))return false;
 const parsed=new Date(value);
 return Number.isFinite(parsed.getTime())&&parsed.toISOString()===`${value.slice(0,23)}Z`;
}

/** Discovery is a current, compact view of claimable work, not a reservation.
 * Claim and discovery receive the same approval gate and geographic predicate.
 * The cursor is only a position; it never grants approval or freezes regions. */
export function createGuideDiscovery({db,moderation,secret,fail,helperApproved,regionMatchSql,regionAliases}) {
 function queryParameters(url) {
  const params=url.searchParams;
  for(const key of params.keys())if(key!=='cursor'||params.getAll(key).length!==1)
   fail(400,'INVALID_DISCOVERY_QUERY','Use only one optional discovery cursor.');
  return params.get('cursor');
 }
 async function readCursor(encoded,user) {
  if(encoded===null)return null;
  const invalid=()=>fail(400,'INVALID_DISCOVERY_CURSOR','This discovery cursor is invalid. Refresh the list.');
  if(encoded.length>1024||!/^[-_A-Za-z0-9]+\.[-_A-Za-z0-9]{43}$/.test(encoded))return invalid();
  const [payload,signature]=encoded.split('.');
  if(Buffer.from(signature,'base64url').toString('base64url')!==signature||
   !await verifySignature(secret,`${cursorPrefix}${payload}`,signature))return invalid();
  let cursor;
  try {
   const bytes=Buffer.from(payload,'base64url');
   if(bytes.toString('base64url')!==payload)return invalid();
   cursor=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  } catch {return invalid();}
  if(!cursor||Array.isArray(cursor)||typeof cursor!=='object'||
   Object.keys(cursor).length!==cursorKeys.length||cursorKeys.some(key=>!Object.hasOwn(cursor,key))||
   cursor.v!==1||cursor.user!==user.id||!validTimestamp(cursor.created_at)||
   typeof cursor.id!=='string'||!uuidPattern.test(cursor.id))return invalid();
  return cursor;
 }
 async function nextCursor(row,user) {
  const payload=Buffer.from(JSON.stringify({v:1,user:user.id,created_at:row.created_at,id:row.id})).toString('base64url');
  return `${payload}.${await sign(secret,`${cursorPrefix}${payload}`)}`;
 }
 return async function guideDiscovery(url,{user,session}) {
  return db.transaction(async tx=>{
   await moderation.lock(tx);
   // Do not authorize from authentication's earlier snapshot. Keep account and
   // approval stable until this read completes, including trusted SQL changes.
   const current=(await tx.query('SELECT is_suspended FROM users WHERE id=$1 FOR SHARE',[user.id])).rows[0];
   if(!current)fail(401,'UNAUTHENTICATED','Your account is no longer available.');
   // User -> session agrees with password reset; a logout/expiry while waiting
   // for the safety gate must not retain authentication's earlier authority.
   if(!(await tx.query('SELECT id FROM sessions WHERE id=$1 AND user_id=$2 AND expires_at>clock_timestamp() FOR SHARE',[session.id,user.id])).rows.length)
    fail(401,'UNAUTHENTICATED','Your session has expired. Sign in again.');
   if(current.is_suspended)fail(403,'ACCOUNT_SUSPENDED','This account is suspended. Account access and deletion remain available.');
   await helperApproved(tx,user.id);
   const cursor=await readCursor(queryParameters(url),user);
   // Ordinary participant visibility applies to administrators here too. All
   // eligibility and visibility predicates run before LIMIT, not after paging.
   const rows=(await tx.query(`SELECT q.id,q.user_id,q.assigned_helper_user_id,
    q.country,q.city,q.region_name,q.category,q.urgency,q.title,q.reward_points,q.status,
    to_char(q.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
    to_char(q.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS updated_at,
    to_char(q.expires_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS expires_at
    FROM questions q WHERE q.status='open' AND q.escrow_state='held'
    AND q.user_id<>$1 AND q.assigned_helper_user_id IS NULL
    AND (q.expires_at IS NULL OR q.expires_at>statement_timestamp()) AND NOT q.moderation_hidden
    AND NOT EXISTS(SELECT 1 FROM users subject WHERE subject.id=q.user_id
     AND (subject.is_suspended OR EXISTS(SELECT 1 FROM user_blocks b
      WHERE (b.blocker_id=$1 AND b.blocked_id=subject.id) OR (b.blocked_id=$1 AND b.blocker_id=subject.id))))
    AND EXISTS(SELECT 1 FROM helper_regions r WHERE r.helper_user_id=$1 AND ${regionMatchSql('$2')})
    AND ($3::timestamptz IS NULL OR (q.created_at,q.id)<($3::timestamptz,$4::uuid))
    ORDER BY q.created_at DESC,q.id DESC LIMIT $5 FOR SHARE OF q`,
    [user.id,regionAliases,cursor?.created_at??null,cursor?.id??null,pageSize+1])).rows;
   const items=rows.slice(0,pageSize);
   return {items,next_cursor:rows.length>pageSize?await nextCursor(items.at(-1),user):null};
  });
 };
}
