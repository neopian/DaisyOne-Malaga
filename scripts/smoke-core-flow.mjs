// Real HTTP + real PostgreSQL smoke journey. Isolated local synthetic data only.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
const base = process.env.API_BASE_URL ?? 'http://127.0.0.1:8080/api';
const url = new URL(base);
if (!['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)) {
  throw new Error('This synthetic smoke script only runs against a loopback development API.');
}
const call = async (path, {token, body, key, method = body === undefined ? 'GET' : 'POST'} = {}) => {
  const response = await fetch(`${base}${path}`, {method, headers: {
    ...(token ? {Authorization:`Bearer ${token}`} : {}),
    ...(body !== undefined ? {'Content-Type':'application/json'} : {}),
    ...(key ? {'Idempotency-Key':key} : {})
  }, ...(body !== undefined ? {body: JSON.stringify(body)} : {})});
  return {status: response.status, body: await response.json()};
};
const login = async email => {
  const result = await call('/auth/login', {body:{email,password:'daisy-dev-1234'},key:randomUUID()});
  assert.equal(result.status, 200);return result.body;
};
assert.deepEqual((await call('/health')).body, {ok:true,database:'postgres',mock_points:true});
const owner = await login('questioner1@example.com');
const helper = await login('answerer1@example.com');
const other = await login('questioner2@example.com');
const guideBefore = (await call('/guide/me',{token:helper.token})).body;
const questionBody = {
  country:'스페인',city:'말라가',region_name:'Centro',category:'교통',urgency:'보통',
  title:'개발 테스트 질문',body:'이 질문은 HTTP 통합 검증을 위한 가상 테스트 데이터입니다.',
  reward_points:25,latitude:36.7213,longitude:-4.4214
};
const createKey = randomUUID();
const created = await call('/questions',{token:owner.token,body:questionBody,key:createKey});
assert.equal(created.status,201);const id = created.body.id;
const retry = await call('/questions',{token:owner.token,body:questionBody,key:createKey});
assert.equal(retry.status,201);assert.equal(retry.body.id,id);
assert.equal((await call('/guide/questions',{token:helper.token})).body.some(q=>q.id===id),true);
assert.equal((await call(`/questions/${id}/accept`,{token:owner.token,body:{},key:randomUUID()})).status,403);
assert.equal((await call(`/questions/${id}/accept`,{token:helper.token,body:{},key:randomUUID()})).status,200);
assert.equal((await call(`/questions/${id}/cancel`,{token:owner.token,body:{},key:randomUUID()})).status,409);
const answer = await call(`/questions/${id}/answers`,{token:helper.token,key:randomUUID(),body:{
  body:'실제 여행 안내가 아닌, 근거 링크 및 보상 동작을 확인하는 테스트 답변입니다.',
  evidence_summary:'테스트용 근거 필드입니다.',verification_method:'개발 검증',
  links:[{url:'https://example.com/',source_type:'other',title:'테스트 링크'}]
}});
assert.equal(answer.status,201);
const accept = `/questions/${id}/answers/${answer.body.id}/accept`;
assert.equal((await call(accept,{token:other.token,body:{},key:randomUUID()})).status,404);
const rewardKey=randomUUID();
assert.equal((await call(accept,{token:owner.token,body:{},key:rewardKey})).status,200);
assert.equal((await call(accept,{token:owner.token,body:{},key:rewardKey})).status,200);
assert.equal((await call(accept,{token:owner.token,body:{},key:randomUUID()})).status,200);
const detail = (await call(`/questions/${id}`,{token:owner.token})).body;
assert.equal(detail.status,'accepted');assert.equal(detail.answers[0].is_rewarded,true);
const ledger = (await call('/points',{token:helper.token})).body;
assert.equal(ledger.filter(row=>row.question_id===id&&row.type==='reward').length,1);
assert.equal((await call('/profile',{token:owner.token})).body.point_balance,owner.user.point_balance-25);
assert.equal((await call('/profile',{token:helper.token})).body.point_balance,helper.user.point_balance+25);
const guideAfter = (await call('/guide/me',{token:helper.token})).body;
assert.equal(guideAfter.accepted_answer_count,guideBefore.accepted_answer_count+1);
assert.equal(guideAfter.earned_mock_points,guideBefore.earned_mock_points+25);
assert.equal(guideAfter.pending_mock_points,guideBefore.pending_mock_points);
assert.equal(detail.assigned_helper.accepted_answer_count,guideAfter.accepted_answer_count);
assert.equal(detail.assigned_helper.email,undefined);
const cancelQuestion = await call('/questions',{token:owner.token,body:questionBody,key:randomUUID()});
const cancelPath = `/questions/${cancelQuestion.body.id}/cancel`;
assert.equal((await call(cancelPath,{token:owner.token,body:{},key:randomUUID()})).status,200);
assert.equal((await call(cancelPath,{token:owner.token,body:{},key:randomUUID()})).status,200);
assert.equal((await call('/profile',{token:owner.token})).body.point_balance,owner.user.point_balance-25);
const ownerLedger = (await call('/points',{token:owner.token})).body;
assert.equal(ownerLedger.filter(row=>row.question_id===cancelQuestion.body.id&&row.type==='refund').length,1);
assert.equal((await call('/auth/logout',{token:owner.token,body:{}})).status,200);
assert.equal((await call('/profile',{token:owner.token})).status,401);
console.log('PASS: real HTTP/PostgreSQL login → create/retry → self-claim denied → helper claim → answer → reward/retry → ledger → cancel/refund/retry → logout revocation');
