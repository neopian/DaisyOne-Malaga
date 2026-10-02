import {sign,verifySignature} from './crypto.mjs';
import {findCity,locationAliases} from './city-catalog.mjs';

const pageSize=20;
const cursorPrefix='malaga-operations-v1:';
const cursorKeys=['v','user','status','place','created_at','id'];
const uuidPattern=/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const timestampPattern=/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const aliases=JSON.stringify(locationAliases);

function validTimestamp(value) {
 if(typeof value!=='string'||!timestampPattern.test(value)||value.startsWith('0000-'))return false;
 const parsed=new Date(value);
 return Number.isFinite(parsed.getTime())&&parsed.toISOString()===`${value.slice(0,23)}Z`;
}

/** Operators must see unresolved obligations even when participant visibility
 * hides them. This read has its own current-admin gate and returns no content
 * bodies, media, participant profiles, or invented settlement/availability. */
export function createOperations({db,moderation,secret,fail}) {
 function queryParameters(url) {
  const params=url.searchParams;
  const invalid=()=>fail(400,'INVALID_OPERATIONS_QUERY','Use one status, an optional country and city together, and an optional operations cursor.');
  for(const key of params.keys())if(!['status','country','city','cursor'].includes(key)||params.getAll(key).length!==1)invalid();
  const status=params.get('status')??'open',country=params.get('country'),city=params.get('city');
  if(!['open','assigned','answered'].includes(status)||(country===null)!==(city===null))invalid();
  let place=null;
  if(country!==null) {
   if(!country.trim()||!city.trim()||country.length>100||city.length>100)invalid();
   place=findCity(country,city);
   if(!place)invalid();
  }
  return {status,place:place?.id??null,cursor:params.get('cursor')};
 }
 async function readCursor(encoded,user,status,place) {
  if(encoded===null)return null;
  const invalid=()=>fail(400,'INVALID_OPERATIONS_CURSOR','This operations cursor is invalid. Refresh the list.');
  if(encoded.length>1024||!/^[-_A-Za-z0-9]+\.[-_A-Za-z0-9]{43}$/.test(encoded))return invalid();
  const [payload,signature]=encoded.split('.');
  if(Buffer.from(signature,'base64url').toString('base64url')!==signature)return invalid();
  if(!await verifySignature(secret,`${cursorPrefix}${payload}`,signature))return invalid();
  let cursor;
  try {
   const bytes=Buffer.from(payload,'base64url');
   if(bytes.toString('base64url')!==payload)return invalid();
   cursor=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
  } catch {return invalid();}
  if(!cursor||Array.isArray(cursor)||typeof cursor!=='object'||
   Object.keys(cursor).length!==cursorKeys.length||cursorKeys.some(key=>!Object.hasOwn(cursor,key))||
   cursor.v!==1||cursor.user!==user.id||cursor.status!==status||cursor.place!==place||
   !validTimestamp(cursor.created_at)||typeof cursor.id!=='string'||!uuidPattern.test(cursor.id))return invalid();
  return cursor;
 }
 async function nextCursor(row,user,status,place) {
  const payload=Buffer.from(JSON.stringify({v:1,user:user.id,status,place,created_at:row.created_at,id:row.id})).toString('base64url');
  return `${payload}.${await sign(secret,`${cursorPrefix}${payload}`)}`;
 }
 return async function operationsQuestions(url,{user,session}) {
  return db.transaction(async tx=>{
   await moderation.lock(tx);
   // Authentication's earlier user snapshot is not an authorization decision.
   // Hold this row through the read, also serializing trusted SQL revocations.
   const current=(await tx.query('SELECT is_suspended,is_admin FROM users WHERE id=$1 FOR SHARE',[user.id])).rows[0];
   if(!current)fail(401,'UNAUTHENTICATED','Your account is no longer available.');
   // User -> session matches password reset; use the live clock after waits.
   if(!(await tx.query('SELECT id FROM sessions WHERE id=$1 AND user_id=$2 AND expires_at>clock_timestamp() FOR SHARE',[session.id,user.id])).rows.length)
    fail(401,'UNAUTHENTICATED','Your session has expired. Sign in again.');
   if(current.is_suspended)fail(403,'ACCOUNT_SUSPENDED','This account is suspended. Account access and deletion remain available.');
   if(!current.is_admin)fail(403,'ADMIN_REQUIRED','Administrator access required.');
   const {status,place,cursor:encoded}=queryParameters(url);
   const cursor=await readCursor(encoded,user,status,place);
   // Counts, page rows and flags share one PostgreSQL statement snapshot.
   // Repeat the geographic predicate so the page can use the status/time
   // index without materializing every unresolved question or its content.
   const result=(await tx.query(`WITH summary AS (
    SELECT count(*) FILTER(WHERE q.status='open')::int AS open_count,
     count(*) FILTER(WHERE q.status='assigned')::int AS assigned_count,
     count(*) FILTER(WHERE q.status='answered')::int AS answered_count
    FROM questions q WHERE q.status IN ('open','assigned','answered')
     AND ($2::text IS NULL OR location_identity(q.country,q.city,$3::jsonb)=$2)
   ), page AS (
    SELECT q.id,q.user_id,q.assigned_helper_user_id,q.country,q.city,q.region_name,
     q.category,q.urgency,q.title,q.reward_points,q.status,q.escrow_state,
     to_char(q.created_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS created_at,
     to_char(q.updated_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS updated_at,
     to_char(q.expires_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS expires_at,
     jsonb_build_object('question_hidden',q.moderation_hidden,
      'traveler_suspended',traveler.is_suspended,
      'guide_suspended',coalesce(guide.is_suspended,false),
      'guide_application_restricted',q.assigned_helper_user_id IS NOT NULL AND application.status IS DISTINCT FROM 'approved',
      'participants_blocked',EXISTS(SELECT 1 FROM user_blocks b
       WHERE (b.blocker_id=q.user_id AND b.blocked_id=q.assigned_helper_user_id)
        OR (b.blocked_id=q.user_id AND b.blocker_id=q.assigned_helper_user_id))) AS operational_flags
    FROM questions q JOIN users traveler ON traveler.id=q.user_id
     LEFT JOIN users guide ON guide.id=q.assigned_helper_user_id
     LEFT JOIN helper_applications application ON application.user_id=q.assigned_helper_user_id
    WHERE q.status=$1 AND ($2::text IS NULL OR location_identity(q.country,q.city,$3::jsonb)=$2)
     AND ($4::timestamptz IS NULL OR (q.created_at,q.id)>($4::timestamptz,$5::uuid))
    ORDER BY q.created_at,q.id LIMIT $6
   ) SELECT row_to_json(summary) AS summary,
    coalesce((SELECT jsonb_agg(to_jsonb(page) ORDER BY page.created_at,page.id) FROM page),'[]'::jsonb) AS items
    FROM summary`,[status,place,aliases,cursor?.created_at??null,cursor?.id??null,pageSize+1])).rows[0];
   const items=result.items.slice(0,pageSize);
   return {items,next_cursor:result.items.length>pageSize?await nextCursor(items.at(-1),user,status,place):null,summary:result.summary};
  });
 };
}
