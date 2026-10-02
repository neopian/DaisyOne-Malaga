import {createDatabase} from './db.mjs';
import {seedDevelopment} from './seed-data.mjs';
if(process.env.NODE_ENV==='production'||process.env.ALLOW_DEV_SEED!=='true')throw new Error('Use ALLOW_DEV_SEED=true only in an isolated development database.');
const db=await createDatabase();
try{console.log(await seedDevelopment(db,{enabled:true}));}finally{await db.close();}
