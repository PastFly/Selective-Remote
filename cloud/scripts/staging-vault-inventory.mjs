import pg from 'pg';
import {isAbsolute} from 'node:path';
import {captureNonTestVaultSnapshot,verifyNonTestVaultSnapshot} from '../src/non-test-vault-snapshot.mjs';

const fail=code=>{throw Error('staging_inventory_'+code);};
const object=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
const exact=(value,keys)=>object(value)&&Object.keys(value).sort().join(',')===[...keys].sort().join(',');
const uuid=value=>typeof value==='string'&&/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value);
async function readInput(){
 if(process.stdin.isTTY)return Buffer.alloc(0);
 const chunks=[];let length=0;
 for await(const chunk of process.stdin){length+=chunk.length;if(length>65536)fail('input');chunks.push(chunk);}
 return Buffer.concat(chunks);
}
function scopeInput(bytes){
 let value;try{value=JSON.parse(bytes.toString('utf8'));}catch{fail('input');}
 if(!exact(value,['allowedNewVaults','allowedNewPersonalVaults'])||!Array.isArray(value.allowedNewVaults)||!Array.isArray(value.allowedNewPersonalVaults))fail('input');
 for(const entry of value.allowedNewVaults)if(!exact(entry,['teamID','vaultID','name'])||!uuid(entry.teamID)||!uuid(entry.vaultID)
  ||typeof entry.name!=='string'||!entry.name.startsWith('TEST-ONLY-CODEX-'))fail('input');
 for(const entry of value.allowedNewPersonalVaults)if(!exact(entry,['userID','vaultID'])||!uuid(entry.userID)||!uuid(entry.vaultID))fail('input');
 return value;
}
let client,begun=false;
try{
 // Validate the local operator scope before parsing stdin or contacting the DB.
 if(process.env.MIGRATION_ENVIRONMENT!=='staging')fail('environment');
 const [operation,path,...extra]=process.argv.slice(2);
 if(!['capture','verify'].includes(operation)||typeof path!=='string'||!isAbsolute(path)||extra.length)fail('arguments');
 const bytes=await readInput();
 if(operation==='capture'&&bytes.length)fail('input');
 const allowed=operation==='verify'?scopeInput(bytes):{};
 if(!process.env.DATABASE_URL)fail('database_required');
 client=new pg.Client({connectionString:process.env.DATABASE_URL,connectionTimeoutMillis:5000,query_timeout:30000});
 await client.connect();
 await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');begun=true;
 const query=(sql,values)=>client.query(sql,values);
 const result=operation==='capture'?await captureNonTestVaultSnapshot({query,path}):await verifyNonTestVaultSnapshot({query,path,...allowed});
 await client.query('COMMIT');begun=false;
 process.stdout.write(JSON.stringify(result)+'\n');
}catch(error){
 if(begun)await client.query('ROLLBACK').catch(()=>{});
 const code=/^(?:staging_inventory|non_test_snapshot)_[a-z_]+$/.test(error?.message??'')?error.message:'staging_inventory_failed';
 process.stderr.write(code+'\n');process.exitCode=1;
}finally{await client?.end().catch(()=>{});}
