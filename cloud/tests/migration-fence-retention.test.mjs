import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {mkdtemp,readFile,writeFile,rm,lstat,open as fsOpen} from 'node:fs/promises';
import {join,dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {MigrationFence} from '../src/migration-fence.mjs';
import {FENCE_MAX_BYTES,fenceIntentDigest,validateFenceEvent} from '../src/migration-fence-journal.mjs';

async function fixture(t,options={}) {
 const dir=await mkdtemp(join(tmpdir(),'sr-journal-retention-'));t.after(()=>rm(dir,{recursive:true,force:true}));
 const path=join(dir,'journal');await writeFile(path,'',{mode:0o600});return {dir,path,fence:new MigrationFence(path,options)};
}
function pair(){const id=()=>randomUUID(),p={version:2,type:'PENDING_INTENT',intentID:id(),operationID:id(),kind:'PUBLICATION',schemaFloor:22,
 vaults:[{teamID:id(),vaultID:id(),generationID:id(),sequence:1,headerHash:'a'.repeat(64),manifestHash:'b'.repeat(64)}]};
 return [p,{version:2,type:'CONFIRMED_COMMIT',intentID:p.intentID,intentDigest:fenceIntentDigest(p)}];}
const encode=events=>events.map(e=>JSON.stringify(e)+'\n').join('');
function logicalHead(events){let digest=createHash('sha256').update('selective-remote/fence-history/v1\0').digest();let i=0;
 for(const event of events){const n=Buffer.alloc(8);n.writeBigUInt64BE(BigInt(++i));digest=createHash('sha256').update('selective-remote/fence-history/v1\0').update(digest).update(n).update(JSON.stringify(validateFenceEvent(event))+'\n').digest();}
 return {position:i,digest:digest.toString('hex')};}
async function compact(fence){
 // Fixture anchor is deliberately in-memory; production uses an independently
 // durable, exclusively controlled high-water service.
 const expected=logicalHead(await fence.readRecords());
 const anchor={read:async()=>expected,advance:async()=>{throw Error('checkpoint_must_not_advance');}};
 return new MigrationFence(fence.path,{openFile:fence.openFile,anchor}).compact();
}

test('durable checkpoint preserves complete logical history and continues after physical journal fills',async t=>{
 const {path,fence}=await fixture(t),events=pair();let original='';
 const encoded=encode(events),copies=Math.floor(FENCE_MAX_BYTES/Buffer.byteLength(encoded));
 original=encoded.repeat(copies);await writeFile(path,original);
 const before=await fence.snapshot(),next=pair();
 await assert.rejects(fence.append(next[0]),/deployment_fence_limit/);
 const info=await compact(fence);
 assert.equal(info.originalBytes,Buffer.byteLength(original));
 assert.ok((await lstat(path)).size<1024);
 assert.deepEqual(await fence.snapshot(),before);
 assert.deepEqual(await fence.readRecords(),Array.from({length:copies},()=>events).flat());
 const marker=JSON.parse((await readFile(path,'utf8')).trim());
 assert.equal(marker.version,3);
 assert.throws(()=>validateFenceEvent(marker),/invalid_deployment_fence/,'old parser must fail closed');
 await fence.append(next[0]);await fence.append(next[1]);
 assert.equal((await fence.snapshot()).committed.length,2);
 const reopened=new MigrationFence(path);
 assert.deepEqual(await reopened.snapshot(),await fence.snapshot());
});

test('checkpoint refuses pending work and never discards original bytes',async t=>{
 const {path,fence}=await fixture(t),[pending]=pair();await fence.append(pending);const before=await readFile(path);
 await assert.rejects(compact(fence),/deployment_fence_pending/);
 assert.deepEqual(await readFile(path),before);
});

test('checkpoint refuses missing or modified archived history',async t=>{
 const {path,fence}=await fixture(t);for(const e of pair())await fence.append(e);
 const checkpoint=await compact(fence);const archive=join(path+'.archives',checkpoint.archiveDigest);
 await writeFile(archive,'tampered\n');
 await assert.rejects(fence.snapshot(),/corrupt_deployment_fence/);
 await rm(archive);await assert.rejects(fence.snapshot(),/corrupt_deployment_fence/);
});

test('failure at final durable directory barrier retains lock and both old and new data for reviewed recovery',async t=>{
 const {path}=await fixture(t);const events=pair();for(const event of events)await new MigrationFence(path).append(event);
 let armed=true,dirSyncs=0;
 const openFile=async(...args)=>{const h=await fsOpen(...args);return new Proxy(h,{get(target,key){
  if(key==='sync')return async()=>{if(armed&&args[0]===dirname(path)&&++dirSyncs===2)throw Error('injected_parent_fsync');return target.sync();};
  const value=target[key];return typeof value==='function'?value.bind(target):value;
 }});};
 const fence=new MigrationFence(path,{openFile});await assert.rejects(compact(fence),/injected_parent_fsync/);armed=false;
 await assert.rejects(fence.snapshot(),/deployment_fence_locked/);
 const marker=JSON.parse((await readFile(path,'utf8')).trim());
 assert.equal(marker.version,3);
 const archive=await readFile(join(path+'.archives',marker.archiveDigest));
 assert.equal(createHash('sha256').update(archive).digest('hex'),marker.archiveDigest);
 assert.deepEqual(archive,Buffer.from(encode(events)));
});

for(const mutation of ['append','checkpoint'])test(`snapshot detects concurrent ${mutation} even when the writer lock has already cleared`,async t=>{
 const {path}=await fixture(t);const writer=new MigrationFence(path);for(const e of pair())await writer.append(e);
 let release,notify,paused=false;const entered=new Promise(r=>{notify=r;}),resume=new Promise(r=>{release=r;});
 const openFile=async(...args)=>{const h=await fsOpen(...args);return new Proxy(h,{get(target,key){
  if(key==='readFile'&&args[0]===path)return async(...rest)=>{const bytes=await target.readFile(...rest);if(!paused){paused=true;notify();await resume;}return bytes;};
  const value=target[key];return typeof value==='function'?value.bind(target):value;
 }});};
 const reader=new MigrationFence(path,{openFile}),waiting=reader.snapshot();await entered;
 if(mutation==='append'){for(const e of pair())await writer.append(e);}else await compact(writer);
 release();await assert.rejects(waiting,/deployment_fence_changed/);
 assert.ok((await writer.snapshot()).committed.length>=1);
});

test('repeated checkpoints preserve the entire ordered event sequence and replay conflicts',async t=>{
 const {path,fence}=await fixture(t),first=pair(),second=pair(),third=pair();
 for(const event of first)await fence.append(event);const a=await compact(fence);
 for(const event of second)await fence.append(event);const b=await compact(fence);
 for(const event of third)await fence.append(event);
 assert.notEqual(a.archiveDigest,b.archiveDigest);
 assert.deepEqual(await fence.readRecords(),[...first,...second,...third]);
 assert.equal((await fence.snapshot()).committed.length,3);
 await assert.rejects(fence.append({...first[0],operationID:randomUUID()}),/deployment_fence_conflict/);
 assert.deepEqual(await new MigrationFence(path).readRecords(),[...first,...second,...third]);
 await writeFile(join(path+'.archives',a.archiveDigest),'damaged\n');
 await assert.rejects(fence.snapshot(),/corrupt_deployment_fence/);
});

test('staged checkpoint fsync failure retains lock and original journal until reviewed recovery',async t=>{
 const {path}=await fixture(t),events=pair();for(const e of events)await new MigrationFence(path).append(e);
 const original=await readFile(path);let fired=false;
 const openFile=async(...args)=>{const h=await fsOpen(...args);return new Proxy(h,{get(target,key){
  if(key==='sync'&&args[0].startsWith(path+'.checkpoint-'))return async()=>{fired=true;throw Error('injected_checkpoint_fsync');};
  const value=target[key];return typeof value==='function'?value.bind(target):value;
 }});};
 const fence=new MigrationFence(path,{openFile});await assert.rejects(compact(fence),/injected_checkpoint_fsync/);
 assert.equal(fired,true);assert.deepEqual(await readFile(path),original);
 await assert.rejects(fence.snapshot(),/deployment_fence_locked/);
});

for(const phase of ['before-rename','after-rename'])test(`SIGKILL ${phase} leaves history recoverable with exclusive reviewed unlock`,async t=>{
 const {path}=await fixture(t),events=pair(),seed=new MigrationFence(path);for(const event of events)await seed.append(event);
 const expected=await readFile(path),moduleURL=new URL('../src/migration-fence.mjs',import.meta.url).href;
 const {spawn}=await import('node:child_process');
 const script=`import {open} from 'node:fs/promises';import {dirname} from 'node:path';import {MigrationFence} from ${JSON.stringify(moduleURL)};
 const path=process.argv[1],phase=process.argv[2],anchor={read:async()=>JSON.parse(process.argv[3]),advance:async()=>{throw Error('unexpected_advance');}};let parentSyncs=0;
 const openFile=async(...args)=>{const h=await open(...args);return new Proxy(h,{get(target,key){
 if(key==='sync')return async()=>{if((phase==='before-rename'&&args[0].startsWith(path+'.checkpoint-'))||(phase==='after-rename'&&args[0]===dirname(path)&&++parentSyncs===2))process.kill(process.pid,'SIGKILL');return target.sync();};
 const v=target[key];return typeof v==='function'?v.bind(target):v;}});};
 await new MigrationFence(path,{openFile,anchor}).compact();`;
 const child=spawn(process.execPath,['--input-type=module','-e',script,path,phase,JSON.stringify(logicalHead(events))],{stdio:['ignore','ignore','pipe']});let stderr='';child.stderr.on('data',s=>stderr+=s);
 const result=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',(code,signal)=>resolve({code,signal}));});
 assert.equal(result.signal,'SIGKILL',stderr);await assert.rejects(new MigrationFence(path).snapshot(),/deployment_fence_locked/);
 const actual=await readFile(path);
 if(phase==='before-rename')assert.deepEqual(actual,expected);
 else {const marker=JSON.parse(actual.toString());const archive=await readFile(join(path+'.archives',marker.archiveDigest));
  assert.equal(createHash('sha256').update(archive).digest('hex'),marker.archiveDigest);assert.deepEqual(archive,expected);}
 // This test owns the only writer and has checked exact retained bytes. Live
 // recovery additionally requires independently anchored history and a drain.
 const {rmdir}=await import('node:fs/promises');await rmdir(path+'.lock');
 const dir=await fsOpen(dirname(path),'r');try{await dir.sync();}finally{await dir.close();}
 const recovered=new MigrationFence(path);assert.deepEqual(await recovered.readRecords(),events);
 for(const event of pair())await recovered.append(event);assert.equal((await recovered.snapshot()).committed.length,2);
});

test('V1 revisions and operation replay protection survive a checkpoint',async t=>{
 const {path,fence}=await fixture(t),id=()=>randomUUID();
 const baseline={version:2,type:'V1_BASELINE',baselineID:id(),vaults:[]},floor={version:2,type:'V1_WRITER_FLOOR',writerProtocol:1};
 const p={version:2,type:'V1_PENDING_INTENT',intentID:id(),operationID:id(),vaultKind:'PERSONAL',ownerID:id(),vaultID:id(),baseRevision:0,revision:1,ciphertextHash:'a'.repeat(64),envelopeHash:'b'.repeat(64)};
 const done={version:2,type:'V1_CONFIRMED_COMMIT',intentID:p.intentID,intentDigest:fenceIntentDigest(p)};
 for(const e of [baseline,floor,p,done])await fence.append(e);await compact(fence);
 const reopened=new MigrationFence(path),after=await reopened.snapshot();assert.equal(after.writerFloor,1);assert.equal(after.v1Committed[0].revision,1);
 const repeated={...p,intentID:id(),baseRevision:1,revision:2};await assert.rejects(reopened.append(repeated),/deployment_fence_conflict/);
 const next={...repeated,operationID:id()},nextDone={version:2,type:'V1_CONFIRMED_COMMIT',intentID:next.intentID,intentDigest:fenceIntentDigest(next)};
 await reopened.append(next);await reopened.append(nextDone);assert.equal((await reopened.snapshot()).v1Committed[0].revision,2);
});

test('logical external high-water digest is unchanged by repeated archive checkpoints',async t=>{
 const {fence}=await fixture(t);for(const e of pair())await fence.append(e);
 const head=events=>{let digest=createHash('sha256').update('selective-remote/fence-history/v1\0').digest();let i=0;
  for(const event of events){const n=Buffer.alloc(8);n.writeBigUInt64BE(BigInt(++i));digest=createHash('sha256').update('selective-remote/fence-history/v1\0').update(digest).update(n).update(JSON.stringify(validateFenceEvent(event))+'\n').digest();}
  return {position:i,digest:digest.toString('hex')};};
 const before=head(await fence.readRecords());await compact(fence);assert.deepEqual(head(await fence.readRecords()),before);
 for(const e of pair())await fence.append(e);const advanced=head(await fence.readRecords());assert.ok(advanced.position>before.position);
 await compact(fence);assert.deepEqual(head(await fence.readRecords()),advanced);
});

test('31 archived segments retain exact order and reject a missing middle segment',async t=>{
 const {path,fence}=await fixture(t),all=[],digests=[];
 for(let n=0;n<31;n++){const events=pair();all.push(...events);for(const e of events)await fence.append(e);digests.push((await compact(fence)).archiveDigest);}
 assert.deepEqual(await fence.readRecords(),all);
 await rm(join(path+'.archives',digests[15]));await assert.rejects(fence.snapshot(),/corrupt_deployment_fence/);
});
