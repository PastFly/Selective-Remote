import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash,randomUUID} from 'node:crypto';
import {mkdtemp,readFile,writeFile,rm,lstat} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {MigrationFence} from '../src/migration-fence.mjs';
import {fenceIntentDigest,validateFenceEvent} from '../src/migration-fence-journal.mjs';

function head(events){let digest=createHash('sha256').update('selective-remote/fence-history/v1\0').digest();let i=0;
 for(const event of events){const n=Buffer.alloc(8);n.writeBigUInt64BE(BigInt(++i));digest=createHash('sha256').update('selective-remote/fence-history/v1\0').update(digest).update(n).update(JSON.stringify(validateFenceEvent(event))+'\n').digest();}
 return {position:i,digest:digest.toString('hex')};}
function pair(){const id=()=>randomUUID(),p={version:2,type:'PENDING_INTENT',intentID:id(),operationID:id(),kind:'PUBLICATION',schemaFloor:22,
 vaults:[{teamID:id(),vaultID:id(),generationID:id(),sequence:1,headerHash:'a'.repeat(64),manifestHash:'b'.repeat(64)}]};
 return [p,{version:2,type:'CONFIRMED_COMMIT',intentID:p.intentID,intentDigest:fenceIntentDigest(p)}];}
async function fixture(t){const dir=await mkdtemp(join(tmpdir(),'sr-anchored-retention-'));t.after(()=>rm(dir,{recursive:true,force:true}));const path=join(dir,'journal'),events=pair();const bytes=Buffer.from(events.map(e=>JSON.stringify(e)+'\n').join(''));await writeFile(path,bytes,{mode:0o600});return {path,events,bytes};}

for(const condition of ['absent','unavailable','mismatch'])test(`checkpoint rejects ${condition} high-water anchor without changing journal`,async t=>{
 const {path,events,bytes}=await fixture(t);const correct=head(events);
 let anchor=null;
 if(condition==='unavailable')anchor={read:async()=>{throw Error('anchor_unavailable');},advance:async()=>{throw Error('must_not_advance');}};
 if(condition==='mismatch')anchor={read:async()=>({...correct,digest:'a'.repeat(64)}),advance:async()=>{throw Error('must_not_advance');}};
 const fence=new MigrationFence(path,{anchor});
 const expected=condition==='absent'?/deployment_anchor_required/:condition==='unavailable'?/anchor_unavailable/:/deployment_anchor_mismatch/;
 await assert.rejects(fence.compact(),expected);assert.deepEqual(await readFile(path),bytes);
 await assert.rejects(lstat(path+'.lock'),{code:'ENOENT'});
});

test('checkpoint consults matching anchor while holding the writer lock and preserves it',async t=>{
 const {path,events}=await fixture(t),expected=head(events);let reads=0;
 const anchor={read:async()=>{assert.equal((await lstat(path+'.lock')).isDirectory(),true);reads++;return expected;},advance:async()=>{throw Error('checkpoint must not advance logical history');}};
 const fence=new MigrationFence(path,{anchor});await fence.compact();assert.ok(reads>=1);
 const marker=JSON.parse((await readFile(path,'utf8')).trim());assert.equal(marker.version,3);
 assert.deepEqual(anchor.read instanceof Function,true);
});

test('checkpoint rejects a corrupted archive even when anchor remains available',async t=>{
 const {path,events}=await fixture(t),expected=head(events),anchor={read:async()=>expected,advance:async()=>{throw Error('must_not_advance');}};
 const fence=new MigrationFence(path,{anchor}),checkpoint=await fence.compact();
 await writeFile(join(path+'.archives',checkpoint.archiveDigest),'tampered\n');
 await assert.rejects(fence.snapshot(),/corrupt_deployment_fence/);
});

test('checkpoint files remain readable only to their service group even with restrictive umask',async t=>{
 const {path,events}=await fixture(t),expected=head(events);
 const anchor={read:async()=>expected,advance:async()=>{throw Error('must_not_advance');}};
 const mask=process.umask(0o077);let checkpoint;
 try{checkpoint=await new MigrationFence(path,{anchor}).compact();}finally{process.umask(mask);}
 assert.equal((await lstat(path+'.archives')).mode&0o777,0o750);
 assert.equal((await lstat(join(path+'.archives',checkpoint.archiveDigest))).mode&0o777,0o640);
 assert.equal((await lstat(path)).mode&0o777,0o640);
});

for (const boundary of ['archive-sync','staged-checkpoint-sync']) test(`checkpoint ${boundary} failure retains lock and original committed history`,async t=>{
 const {open}=await import('node:fs/promises');
 const {path,events,bytes}=await fixture(t),expected=head(events);
 const anchor={read:async()=>expected,advance:async()=>{throw Error('must_not_advance');}};
 let injected=false;
 const openFile=async(...args)=>{
  const handle=await open(...args),name=String(args[0]);
  return new Proxy(handle,{get(target,key){
   if(key==='sync')return async()=>{
    const hit=boundary==='archive-sync' ? name.startsWith(path+'.archives/') : name.startsWith(path+'.checkpoint-');
    if(hit&&!injected){injected=true;throw Error('synthetic_checkpoint_sync_failure');}
    return target.sync();
   };
   const value=target[key];return typeof value==='function'?value.bind(target):value;
  }});
 };
 const fence=new MigrationFence(path,{anchor,openFile});
 await assert.rejects(fence.compact(),/synthetic_checkpoint_sync_failure/);
 assert.equal(injected,true);
 assert.deepEqual(await readFile(path),bytes);
 assert.equal((await lstat(path+'.lock')).isDirectory(),true);
 await assert.rejects(new MigrationFence(path,{anchor}).snapshot(),/deployment_fence_locked/);
 assert.deepEqual(await anchor.read(),expected);
});
