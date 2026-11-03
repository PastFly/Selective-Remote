import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {spawn} from 'node:child_process';
import {fenceIntentDigest,validateFenceEvent} from '../src/migration-fence-journal.mjs';

const moduleURL=new URL('../src/migration-fence.mjs',import.meta.url).href;
function head(events){let digest=createHash('sha256').update('selective-remote/fence-history/v1\0').digest();let i=0;
 for(const event of events){const n=Buffer.alloc(8);n.writeBigUInt64BE(BigInt(++i));digest=createHash('sha256').update('selective-remote/fence-history/v1\0').update(digest).update(n).update(JSON.stringify(validateFenceEvent(event))+'\n').digest();}
 return {position:i,digest:digest.toString('hex')};}

async function isolatedSnapshot(path,{expectSuccess=false}={}){
 const code=`import {MigrationFence} from ${JSON.stringify(moduleURL)};try{await new MigrationFence(process.argv[1]).snapshot();process.exit(${expectSuccess?0:9});}catch(e){if(!${expectSuccess}&&(e.message==='deployment_fence_history_limit'||e.message==='invalid_deployment_fence'))process.exit(0);console.error(e.message);process.exit(10);}`;
 const child=spawn('/bin/sh',['-c','ulimit -c 0; exec "$@"','sr-retention-bound',process.execPath,'--max-old-space-size=96','--input-type=module','-e',code,path],{stdio:['ignore','ignore','pipe']});
 let stderr='';child.stderr.on('data',data=>stderr+=data);
 const outcome=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',(code,signal)=>resolve({code,signal}));});
 return {...outcome,stderr};
}

test('oversized retained history fails closed before process exhausts 96 MiB heap',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'sr-bound-'));t.after(()=>rm(dir,{recursive:true,force:true}));
 const path=join(dir,'journal'),archiveDir=path+'.archives';await mkdir(archiveDir);
 const id=()=>randomUUID(),p={version:2,type:'PENDING_INTENT',intentID:id(),operationID:id(),kind:'PUBLICATION',schemaFloor:22,vaults:[{teamID:id(),vaultID:id(),generationID:id(),sequence:1,headerHash:'a'.repeat(64),manifestHash:'b'.repeat(64)}]};
 const done={version:2,type:'CONFIRMED_COMMIT',intentID:p.intentID,intentDigest:fenceIntentDigest(p)},pair=JSON.stringify(p)+'\n'+JSON.stringify(done)+'\n';
 const repeats=Math.floor((4*1024*1024-150)/Buffer.byteLength(pair));let prefix='';
 for(let i=0;i<20;i++){const bytes=Buffer.from(prefix+pair.repeat(repeats)),digest=createHash('sha256').update(bytes).digest('hex');await writeFile(join(archiveDir,digest),bytes);prefix=JSON.stringify({version:3,type:'ARCHIVE_CHECKPOINT',archiveDigest:digest})+'\n';}
 await writeFile(path,prefix);const result=await isolatedSnapshot(path);
 assert.equal(result.signal,null,result.stderr);assert.equal(result.code,0,result.stderr);
});

test('many tiny invalid records fail closed before 96 MiB heap exhaustion',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'sr-invalid-bound-'));t.after(()=>rm(dir,{recursive:true,force:true}));const path=join(dir,'journal');
 await writeFile(path,'{}\n'.repeat(1_300_000));const result=await isolatedSnapshot(path);
 assert.equal(result.signal,null,result.stderr);assert.equal(result.code,0,result.stderr);
});

test('admission reserves event slots for pending terminal outcomes before appending',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'sr-event-bound-'));t.after(()=>rm(dir,{recursive:true,force:true}));const path=join(dir,'journal');
 const {MigrationFence,FENCE_MAX_REPLAY_RECORDS}=await import('../src/migration-fence.mjs');
 const floor={version:2,type:'V1_WRITER_FLOOR',writerProtocol:1},before=Buffer.from((JSON.stringify(floor)+'\n').repeat(FENCE_MAX_REPLAY_RECORDS-1));await writeFile(path,before);
 const id=()=>randomUUID(),p={version:2,type:'PENDING_INTENT',intentID:id(),operationID:id(),kind:'PUBLICATION',schemaFloor:22,vaults:[{teamID:id(),vaultID:id(),generationID:id(),sequence:1,headerHash:'a'.repeat(64),manifestHash:'b'.repeat(64)}]};
 const anchor={read:async()=>head(Array(FENCE_MAX_REPLAY_RECORDS-1).fill(floor)),advance:async()=>{throw Error('unexpected_advance');}};
 await assert.rejects(new MigrationFence(path,{anchor}).append(p),/deployment_fence_history_limit/);
 assert.deepEqual(await (await import('node:fs/promises')).readFile(path),before);
});

test('checkpoint refuses before adding a marker which would exceed event replay capacity',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'sr-checkpoint-bound-'));t.after(()=>rm(dir,{recursive:true,force:true}));const path=join(dir,'journal');
 const {MigrationFence,FENCE_MAX_REPLAY_RECORDS}=await import('../src/migration-fence.mjs');
 const floor={version:2,type:'V1_WRITER_FLOOR',writerProtocol:1},before=Buffer.from((JSON.stringify(floor)+'\n').repeat(FENCE_MAX_REPLAY_RECORDS));await writeFile(path,before);
 const expected=head(Array(FENCE_MAX_REPLAY_RECORDS).fill(floor));
 const anchor={read:async()=>expected,advance:async()=>{throw Error('unexpected_advance');}};
 await assert.rejects(new MigrationFence(path,{anchor}).compact(),/deployment_fence_history_limit/);
 assert.deepEqual(await (await import('node:fs/promises')).readFile(path),before);
});

test('terminal byte reservation covers archived and active history before dispatch',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'sr-byte-bound-'));t.after(()=>rm(dir,{recursive:true,force:true}));
 const {MigrationFence,FENCE_MAX_REPLAY_BYTES}=await import('../src/migration-fence.mjs'),path=join(dir,'journal'),archiveDir=path+'.archives';await mkdir(archiveDir);
 const id=()=>randomUUID(),teamID=id(),pending={version:2,type:'PENDING_INTENT',intentID:id(),operationID:id(),kind:'PUBLICATION',schemaFloor:22,
  vaults:Array.from({length:10},()=>({teamID,vaultID:id(),generationID:id(),sequence:1,headerHash:'a'.repeat(64),manifestHash:'b'.repeat(64)})).sort((a,b)=>a.vaultID.localeCompare(b.vaultID))};
 const done={version:2,type:'CONFIRMED_COMMIT',intentID:pending.intentID,intentDigest:fenceIntentDigest(pending)},pair=JSON.stringify(pending)+'\n'+JSON.stringify(done)+'\n';
 const floor=JSON.stringify({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1})+'\n';
 const fill=target=>{const count=Math.floor(target/Buffer.byteLength(pair));const rest=target-count*Buffer.byteLength(pair);return pair.repeat(count)+floor.repeat(Math.floor(rest/Buffer.byteLength(floor)));};
 const archived=Buffer.from(fill(4*1024*1024-512)),digest=createHash('sha256').update(archived).digest('hex');await writeFile(join(archiveDir,digest),archived);
 const marker=JSON.stringify({version:3,type:'ARCHIVE_CHECKPOINT',archiveDigest:digest})+'\n';
 const active=Buffer.from(marker+fill(4*1024*1024-512-Buffer.byteLength(marker)));await writeFile(path,active);
 const events=(archived.toString('utf8')+active.toString('utf8').slice(marker.length)).trimEnd().split('\n').map(line=>JSON.parse(line)),expected=head(events),anchor={read:async()=>expected,advance:async()=>{throw Error('unexpected_advance');}};
 const checkpoint=await new MigrationFence(path,{anchor}).compact();assert.ok(checkpoint.archiveDigest);
 const before=await (await import('node:fs/promises')).readFile(path);
 assert.ok(FENCE_MAX_REPLAY_BYTES-archived.length-active.length-before.length<Buffer.byteLength(pair));
 const next={...pending,intentID:id(),operationID:id(),vaults:pending.vaults.map(v=>({...v,teamID:id(),vaultID:id(),generationID:id()}))};
 const sameTeam=id();next.vaults=next.vaults.map(v=>({...v,teamID:sameTeam})).sort((a,b)=>a.vaultID.localeCompare(b.vaultID));
 await assert.rejects(new MigrationFence(path,{anchor}).append(next),/deployment_fence_history_limit/);
 assert.deepEqual(await (await import('node:fs/promises')).readFile(path),before);
});

test('nearly 8 MiB valid retained history remains readable with 96 MiB heap',async t=>{
 const dir=await mkdtemp(join(tmpdir(),'sr-near-bound-'));t.after(()=>rm(dir,{recursive:true,force:true}));
 const path=join(dir,'journal'),archiveDir=path+'.archives';await mkdir(archiveDir);
 const id=()=>randomUUID(),teamID=id(),p={version:2,type:'PENDING_INTENT',intentID:id(),operationID:id(),kind:'PUBLICATION',schemaFloor:22,
 vaults:Array.from({length:10},()=>({teamID,vaultID:id(),generationID:id(),sequence:1,headerHash:'a'.repeat(64),manifestHash:'b'.repeat(64)})).sort((a,b)=>a.vaultID.localeCompare(b.vaultID))};
 const done={version:2,type:'CONFIRMED_COMMIT',intentID:p.intentID,intentDigest:fenceIntentDigest(p)},pair=JSON.stringify(p)+'\n'+JSON.stringify(done)+'\n';
 const repeats=Math.floor((4*1024*1024-200)/Buffer.byteLength(pair)),old=Buffer.from(pair.repeat(repeats));
 const digest=createHash('sha256').update(old).digest('hex');await writeFile(join(archiveDir,digest),old);
 const marker=JSON.stringify({version:3,type:'ARCHIVE_CHECKPOINT',archiveDigest:digest})+'\n';await writeFile(path,marker+pair.repeat(repeats));
 const result=await isolatedSnapshot(path,{expectSuccess:true});assert.equal(result.signal,null,result.stderr);assert.equal(result.code,0,result.stderr);
});
