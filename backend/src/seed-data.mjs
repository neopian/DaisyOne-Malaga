import {randomId,hashPassword} from './crypto.mjs';
import {findCity} from './city-catalog.mjs';

/** Explicit development/demo only. Does not reset existing users, credentials, or balances. */
export async function seedDevelopment(db,{enabled=false,production=false}={}) {
 if(!enabled||production)throw new Error('Development seed is disabled; set ALLOW_DEV_SEED=true outside production.');
 const passwordHash=await hashPassword('daisy-dev-1234'),accounts=[
  ['questioner1@example.com','질문자1',false],['questioner2@example.com','질문자2',false],['questioner3@example.com','질문자3',false],
  ['answerer1@example.com','답변자1',true],['answerer2@example.com','답변자2',true],['admin@example.com','개발 관리자',false,true],
  ['guide-europe@example.com','유럽 데모 가이드',true,false,[['United Kingdom','London'],['France','Paris'],['Italy','Rome']]],
  ['guide-us@example.com','미국 데모 가이드',true,false,[['United States','New York'],['United States','Los Angeles'],['United States','San Francisco']]]
 ];
 const seeded=[];
 for(const [email,name,helper,admin=false,regions=[['Spain','Málaga']]] of accounts)await db.transaction(async tx=>{
  if((await tx.query('SELECT id FROM users WHERE email=$1',[email])).rows.length){seeded.push({email,created:false});return;}
  const location=findCity(...regions[0]);
  const id=randomId();await tx.query('INSERT INTO users(id,email,name,point_balance,is_admin,current_country,current_city) VALUES($1,$2,$3,1000,$4,$5,$6)',[id,email,name,admin,location.country,location.city]);
  await tx.query('INSERT INTO auth_credentials(user_id,password_hash) VALUES($1,$2)',[id,passwordHash]);
  await tx.query("INSERT INTO point_transactions(id,user_id,type,amount) VALUES($1,$2,'charge_mock',1000)",[randomId(),id]);
  if(helper){
   await tx.query("INSERT INTO helper_applications(id,user_id,status,languages,introduction,experience_description,reviewed_at) VALUES($1,$2,'approved',$3,$4,$5,now())",[randomId(),id,['한국어','English'],'합성 개발용 가이드 계정입니다. 실제 가이드 활동이나 응답 가능 여부를 뜻하지 않습니다.','가상 포인트와 답변 채택 이력 검증용 시나리오입니다.']);
   for(const [country,city] of regions) {
    const place=findCity(country,city);
    await tx.query('INSERT INTO helper_regions(id,helper_user_id,country,city) VALUES($1,$2,$3,$4)',[randomId(),id,place.country,place.city]);
   }
  }
  seeded.push({email,created:true});
 });
 return seeded;
}
