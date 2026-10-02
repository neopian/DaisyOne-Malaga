import {createDatabase,migrate} from './db.mjs';
const db=await createDatabase();
try {await migrate(db);console.log('PostgreSQL migrations applied.');} finally {await db.close();}
