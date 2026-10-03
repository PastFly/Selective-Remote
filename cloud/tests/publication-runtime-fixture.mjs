// Only synthetic HTTP test databases use this explicit positive evidence. Never
// call this from startup/operator code: real activation writes its own journal.
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {randomUUID} from 'node:crypto';
import pg from 'pg';
import {MigrationFence} from '../src/migration-fence.mjs';
import {readActivePublications} from '../src/migration-compatibility.mjs';
export async function publicationRuntimeFixture(databaseURL) {
  const directory=await mkdtemp(join(tmpdir(),'synthetic-http-fence-'));
  const path=join(directory,'journal'),pool=new pg.Pool({connectionString:databaseURL,max:1});
  try {
    await writeFile(path,'',{mode:0o600});
    const fence=new MigrationFence(path);
    const rows=await readActivePublications((sql,values)=>pool.query(sql,values),22);
    for(const row of rows){
      if(row.sequence == null){
        const {teamID,vaultID,attemptID,manifestHash}=row;
        await fence.intent({teamID,vaultID,attemptID,manifestHash,schemaFloor:19});
      }else{
        const {teamID,vaultID,generationID,sequence,headerHash,manifestHash}=row;
        await fence.append({version:2,type:'PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),
          kind:'PUBLICATION',schemaFloor:22,vaults:[{teamID,vaultID,generationID,sequence,headerHash,manifestHash}]});
      }
      const pending=(await fence.snapshot()).pending[0];
      await fence.append({version:2,type:'CONFIRMED_COMMIT',intentID:pending.intentID,intentDigest:pending.intentDigest});
    }
    return {path,cleanup:()=>rm(directory,{recursive:true,force:true})};
  }catch(error){await rm(directory,{recursive:true,force:true});throw error;}
  finally{await pool.end();}
}

// Real HTTP suites need separate DBs: other suites deliberately corrupt active
// projections to test fail-closed behavior, which must also stop the controller.
export async function isolatedPublicationDatabase(databaseURL) {
  const base=new URL(databaseURL);
  if(!['127.0.0.1','localhost','[::1]'].includes(base.hostname)||!base.pathname.endsWith('_test'))throw Error('disposable_test_database_required');
  const name=`prc_http_${process.pid}_${randomUUID().replaceAll('-','')}_test`;
  const admin=new pg.Pool({connectionString:databaseURL,max:1});let pool,created=false;
  const cleanup=async()=>{await pool?.end();try{if(created)await admin.query(`DROP DATABASE "${name}" WITH (FORCE)`);}finally{await admin.end();}};
  try{
    await admin.query(`CREATE DATABASE "${name}" TEMPLATE template0`);created=true;base.pathname='/'+name;
    pool=new pg.Pool({connectionString:base.href});
    const {applyMigrations}=await import('../src/migrations.mjs');
    const {fileURLToPath}=await import('node:url');
    await applyMigrations(pool,fileURLToPath(new URL('../migrations/',import.meta.url)),{info(){}});
    return {pool,databaseURL:base.href,cleanup};
  }catch(error){await cleanup();throw error;}
}
