import pg from 'pg';
import { readFile, readdir } from 'node:fs/promises';
const migrationDirectory = new URL('../migrations/',import.meta.url);
export async function createDatabase({ connectionString = process.env.DATABASE_URL, schema } = {}) {
 if(!connectionString) throw new Error('DATABASE_URL is required. Use self-hosted PostgreSQL; no Supabase URL/key.');
 if(schema && !/^[a-z_][a-z0-9_]*$/.test(schema)) throw new Error('Invalid schema');
 const pool = new pg.Pool({connectionString,max:10, ...(schema ? {options:`-c search_path=${schema}`} : {})});
 return {query:(...args)=>pool.query(...args), transaction:async fn=>{
  const client=await pool.connect();
  try {await client.query('BEGIN');const result=await fn(client);await client.query('COMMIT');return result;}
  catch(error){await client.query('ROLLBACK');throw error;} finally{client.release();}
 },close:()=>pool.end(),engine:'postgres'};
}
export async function assertMigrated(db) {
 const expected=(await readdir(migrationDirectory)).filter(n=>n.endsWith('.sql'));
 let applied;try{applied=new Set((await db.query('SELECT name FROM schema_migrations')).rows.map(row=>row.name));}
 catch{throw new Error('Database is not initialized. Run npm run migrate before starting the API.');}
 const pending=expected.filter(name=>!applied.has(name));
 if(pending.length)throw new Error(`Pending database migrations: ${pending.join(', ')}. Run npm run migrate.`);
}
export async function migrate(db) {
 await db.query('CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())');
 for(const name of (await readdir(migrationDirectory)).filter(n=>n.endsWith('.sql')).sort()) {
  await db.transaction(async tx=>{
   await tx.query('LOCK TABLE schema_migrations IN EXCLUSIVE MODE');
   if((await tx.query('SELECT name FROM schema_migrations WHERE name=$1',[name])).rows.length) return;
   await tx.query(await readFile(new URL(name,migrationDirectory),'utf8'));
   await tx.query('INSERT INTO schema_migrations(name) VALUES ($1)',[name]);
  });
 }
}
