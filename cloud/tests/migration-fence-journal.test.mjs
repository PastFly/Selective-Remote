import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp, readFile, writeFile, mkdir, rm, lstat, open as realOpen} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {MigrationFence} from '../src/migration-fence.mjs';
const id=()=>randomUUID(), hash=n=>String(n).repeat(64);
const legacy=()=>({teamID:id(),vaultID:id(),attemptID:id(),manifestHash:hash('a'),schemaFloor:19});
async function fixture(t,options={}){const dir=await mkdtemp(join(tmpdir(),'fence-journal-'));t.after(()=>rm(dir,{recursive:true,force:true}));const path=join(dir,'fence');await writeFile(path,'',{mode:0o600});return {dir,path,fence:new MigrationFence(path,options)};}
const journal=()=>import('../src/migration-fence-journal.mjs');
function pending(count=2,extra={}){const teamID=id();return {version:2,type:'PENDING_INTENT',intentID:id(),operationID:id(),kind:'PUBLICATION',schemaFloor:22,vaults:Array.from({length:count},()=>({teamID,vaultID:id(),generationID:id(),sequence:1,headerHash:hash('b'),manifestHash:hash('c')})).sort((a,b)=>a.vaultID<b.vaultID?-1:1),...extra};}
const terminal=(p,digest,type='CONFIRMED_COMMIT')=>({version:2,type,intentID:p.intentID,intentDigest:digest});

for(const method of ['append','intent']){
 test(`${method} refuses missing journal without creating file or retaining lock`,async t=>{
  const {fence,path}=await fixture(t);await rm(path);
  await assert.rejects(fence[method](method==='append'?pending(1):legacy()),{code:'ENOENT'});
  await assert.rejects(lstat(path),{code:'ENOENT'});await assert.rejects(lstat(path+'.lock'),{code:'ENOENT'});
 });
 test(`${method} refuses journal deleted after a successful retained-history read`,async t=>{
  const {fence,path}=await fixture(t),old=method==='append'?pending(1):legacy();
  await fence[method](old);const intent=(await fence.snapshot()).pending[0];
  await fence.append(terminal(intent,intent.intentDigest));
  assert.equal((await fence.snapshot()).committed.length,1);
  await rm(path);
  const next=method==='append'?{...old,intentID:id(),operationID:id(),vaults:old.vaults.map(v=>({...v,generationID:id(),sequence:2,headerHash:hash('d'),manifestHash:hash('e')}))}:old;
  await assert.rejects(fence[method](next),{code:'ENOENT'});
  await assert.rejects(lstat(path),{code:'ENOENT'});await assert.rejects(lstat(path+'.lock'),{code:'ENOENT'});
 });
}

test('legacy intent remains pending despite matching DB pointer until positive resolution',async t=>{
 const {fence}=await fixture(t),old=legacy();await fence.intent(old);
 await assert.rejects(fence.verify({schemaVersion:19,publications:[old]}),/deployment_fence_pending/);
});

test('pending multiVault intent blocks all traffic and one confirmation advances the entire set',async t=>{
 const {fence}=await fixture(t),{fenceIntentDigest}=await journal(),p=pending();
 await fence.append(p);const first=await fence.snapshot();assert.equal(first.committed.length,0);assert.equal(first.pending.length,1);
 await assert.rejects(fence.verify({schemaVersion:22,publications:p.vaults}),/deployment_fence_pending/);
 await fence.append(terminal(p,fenceIntentDigest(p)));const next=await fence.snapshot();
 assert.equal(next.pending.length,0);assert.deepEqual(next.committed,p.vaults.map(v=>({...v,schemaFloor:22})));
 assert.equal(await fence.verify({schemaVersion:22,publications:p.vaults}),true);
 await assert.rejects(fence.verify({schemaVersion:22,publications:[p.vaults[0]]}),/deployment_fence_mismatch/);
});

test('digest normalizes complete vault order and terminal cannot change any participant',async()=>{
 const {fenceIntentDigest,validateFenceEvent,reduceFenceEvents}=await journal(),p=pending();
 assert.equal(fenceIntentDigest(p),fenceIntentDigest({...p,vaults:[...p.vaults].reverse()}));
 assert.deepEqual(validateFenceEvent({...p,vaults:[...p.vaults].reverse()}),p);
 const altered={...p,vaults:p.vaults.slice(0,1)};
 assert.throws(()=>reduceFenceEvents([p,terminal(p,fenceIntentDigest(altered))]),/deployment_fence_conflict/);
 assert.throws(()=>reduceFenceEvents([p,{...terminal(p,fenceIntentDigest(p)),vaults:[p.vaults[0]]}]),/invalid_deployment_fence/);
});

test('abort preserves prior minima and schema floor while later pending cannot erase history',async()=>{
 const {fenceIntentDigest,reduceFenceEvents}=await journal(),p=pending(1,{kind:'MIGRATION',schemaFloor:20});
 const second={...p,intentID:id(),operationID:id(),kind:'PUBLICATION',schemaFloor:22,vaults:p.vaults.map(v=>({...v,generationID:id(),sequence:2,headerHash:hash('d')}))};
 const events=[p,terminal(p,fenceIntentDigest(p)),second];const waiting=reduceFenceEvents(events);
 assert.equal(waiting.schemaFloor,22);assert.equal(waiting.committed[0].sequence,1);
 const aborted=reduceFenceEvents([...events,terminal(second,fenceIntentDigest(second),'PROVEN_ABORT')]);
 assert.equal(aborted.schemaFloor,20);assert.equal(aborted.committed[0].sequence,1);assert.equal(aborted.pending.length,0);
});

test('outcome replay is idempotent but contradictory orphan or changed intent fails closed',async()=>{
 const {fenceIntentDigest,reduceFenceEvents}=await journal(),p=pending(),done=terminal(p,fenceIntentDigest(p));
 assert.deepEqual(reduceFenceEvents([p,done,p,done]),reduceFenceEvents([p,done]));
 for(const events of [[done],[p,done,{...done,type:'PROVEN_ABORT'}],[p,{...done,type:'PROVEN_ABORT'},done],[p,{...p,operationID:id()}]])
  assert.throws(()=>reduceFenceEvents(events),/deployment_fence_conflict/);
});

test('kind floors duplicate crossTeam malformed records are rejected before persistence',async t=>{
 const {fence,path}=await fixture(t),{validateFenceEvent}=await journal(),p=pending();await writeFile(path,'');
 const bad=[{...p,schemaFloor:20},{...p,version:3},{...p,type:'COMMITTED'},{...p,vaults:[p.vaults[0],p.vaults[0]]},
  {...p,vaults:[p.vaults[0],{...p.vaults[1],teamID:id()}]}, {...p,vaults:[]},{...p,unexpected:true},
  {...p,vaults:[{...p.vaults[0],sequence:'1'}]}, {...p,vaults:[{...p.vaults[0],sequence:0}]},
  {...p,vaults:[{...p.vaults[0],headerHash:'x'}]}, {...p,kind:'MIGRATION'},
  {...p,kind:'MIGRATION',schemaFloor:19,vaults:[p.vaults[0]]}];
 for(const event of bad){assert.throws(()=>validateFenceEvent(event),/invalid_deployment_fence/);await assert.rejects(fence.append(event),/invalid_deployment_fence/);assert.equal(await readFile(path,'utf8'),'');}
 const old=legacy();await fence.append({version:2,type:'PENDING_INTENT',intentID:id(),operationID:old.attemptID,kind:'MIGRATION',schemaFloor:19,vaults:[{teamID:old.teamID,vaultID:old.vaultID,attemptID:old.attemptID,manifestHash:old.manifestHash}]});
});

test('lower sequence same-sequence forks and generationID reuse cannot replace confirmed minima',async()=>{
 const {fenceIntentDigest,reduceFenceEvents}=await journal(),p=pending(1);p.vaults[0].sequence=3;
 const base=[p,terminal(p,fenceIntentDigest(p))];
 for(const change of [{sequence:2,generationID:id()},{headerHash:hash('d')},{manifestHash:hash('d')},{generationID:id()}, {sequence:4,headerHash:hash('d')}]){
  const next={...p,intentID:id(),operationID:id(),vaults:[{...p.vaults[0],...change}]};
  assert.throws(()=>reduceFenceEvents([...base,next]),/deployment_fence_conflict/);
 }
 const next={...p,intentID:id(),operationID:id(),vaults:[{...p.vaults[0],generationID:id(),sequence:4,headerHash:hash('d'),manifestHash:hash('e')}]};
 assert.equal(reduceFenceEvents([...base,next,terminal(next,fenceIntentDigest(next))]).committed[0].sequence,4);
});

test('legacy bytes are retained and unresolved old evidence can confirm but never abort',async t=>{
 const {fence,path}=await fixture(t),{fenceIntentDigest}=await journal(),old=legacy();
 const bytes=JSON.stringify(old)+'\n';await writeFile(path,bytes);const p=(await fence.snapshot()).pending[0];
 assert.equal(p.intentID,'legacy:'+fenceIntentDigest(old));assert.equal(p.operationID,old.attemptID);assert.equal(p.legacy,true);
 await assert.rejects(fence.append(terminal(p,p.intentDigest,'PROVEN_ABORT')),/deployment_fence_conflict/);
 assert.equal(await readFile(path,'utf8'),bytes);
 await fence.append(terminal(p,p.intentDigest));assert.equal((await readFile(path,'utf8')).startsWith(bytes),true);
 assert.equal(await fence.verify({schemaVersion:19,publications:[old]}),true);
});

for(const failure of ['file','directory'])test(`terminal ${failure} fsync failure blocks gate until exact replay reconfirms both barriers`,async t=>{
 const {dir,path}=await fixture(t),{fenceIntentDigest}=await journal(),p=pending();
 let armed=false,failed=false,fileSyncs=0,dirSyncs=0;
 const openFile=async(...args)=>{const h=await realOpen(...args),isDir=args[0]===dir;return new Proxy(h,{get(target,key){
  if(key==='sync')return async()=>{isDir?dirSyncs++:fileSyncs++;if(armed&&!failed&&isDir===(failure==='directory')){failed=true;throw Error('injected_fsync');}return target.sync();};
  if(key==='write')return (b,o,n,pos)=>target.write(b,o,Math.min(n,17),pos);
  const value=target[key];return typeof value==='function'?value.bind(target):value;
 }});};
 const fence=new MigrationFence(path,{openFile});await fence.append(p);armed=true;const done=terminal(p,fenceIntentDigest(p));
 await assert.rejects(fence.append(done),/injected_fsync/);const bytes=await readFile(path);
 await assert.rejects(fence.snapshot(),/deployment_fence_locked/);await assert.rejects(new MigrationFence(path).snapshot(),/deployment_fence_locked/);
 await assert.rejects(fence.append({...done,type:'PROVEN_ABORT'}),/deployment_fence_locked/);
 const before=[fileSyncs,dirSyncs];await fence.append(done);assert.ok(fileSyncs>before[0]);assert.ok(dirSyncs>before[1]);
 assert.equal((await readFile(path)).equals(bytes),true);assert.equal(await fence.verify({schemaVersion:22,publications:p.vaults}),true);
});

test('partial append is never truncated or exposed as valid history',async t=>{
 const {dir,path}=await fixture(t),p=pending();let writes=0;
 const openFile=async(...args)=>{const h=await realOpen(...args);return new Proxy(h,{get(target,key){if(key==='write')return async(b,o,n,pos)=>{if(++writes>1)throw Error('injected_write');return target.write(b,o,7,pos);};const value=target[key];return typeof value==='function'?value.bind(target):value;}});};
 const fence=new MigrationFence(path,{openFile});await assert.rejects(fence.append(p),/injected_write/);const bytes=await readFile(path);
 await assert.rejects(fence.snapshot(),/deployment_fence_locked/);await assert.rejects(fence.append(p),/corrupt_deployment_fence/);
 assert.equal((await readFile(path)).equals(bytes),true);await assert.rejects(new MigrationFence(path).snapshot(),/deployment_fence_locked/);
});

test('capacity guard fails before write and exact replay retains original full file',async t=>{
 const {fence,path}=await fixture(t),{FENCE_MAX_BYTES,fenceIntentDigest}=await journal(),p=pending();
 const line=JSON.stringify(p);await writeFile(path,line+' '.repeat(FENCE_MAX_BYTES-Buffer.byteLength(line)-1)+'\n');const bytes=await readFile(path);
 await assert.rejects(fence.append(terminal(p,fenceIntentDigest(p))),/deployment_fence_limit/);
 assert.equal((await readFile(path)).equals(bytes),true);await fence.append(p);assert.equal((await readFile(path)).equals(bytes),true);
 assert.equal((await fence.snapshot()).pending.length,1);
});

test('orphan lock torn tail and unknown journal record fail closed',async t=>{
 const {fence,path}=await fixture(t);await writeFile(path,'');await mkdir(path+'.lock');await assert.rejects(fence.snapshot(),/deployment_fence_locked/);
 await rm(path+'.lock',{recursive:true});await writeFile(path,JSON.stringify(pending()));await assert.rejects(fence.snapshot(),/corrupt_deployment_fence/);
 await writeFile(path,'{"version":500}\n');await assert.rejects(fence.snapshot(),/invalid_deployment_fence/);
});


test('UUID and hash fields reject coercible nonstrings before hashing or append',async()=>{
 const {validateFenceEvent,fenceIntentDigest}=await journal(),p=pending(1);
 for(const key of ['teamID','vaultID','generationID','headerHash','manifestHash']){
  const raw=p.vaults[0][key],bad={...p,vaults:[{...p.vaults[0],[key]:{toString:()=>raw}}]};
  assert.throws(()=>validateFenceEvent(bad),/invalid_deployment_fence/);
 }
 for(const key of ['intentID','operationID'])assert.throws(()=>validateFenceEvent({...p,[key]:{toString:()=>p[key]}}),/invalid_deployment_fence/);
 const done=terminal(p,fenceIntentDigest(p));
 for(const key of ['intentID','intentDigest'])assert.throws(()=>validateFenceEvent({...done,[key]:{toString:()=>done[key]}}),/invalid_deployment_fence/);
 assert.throws(()=>validateFenceEvent(pending(11)),/invalid_deployment_fence/);
});

test('concurrent unrelated appends retain both operations and overlapping intents conflict',async t=>{
 const {fence}=await fixture(t),a=pending(1),b=pending(1);
 await Promise.all([fence.append(a),fence.append(b)]);assert.equal((await fence.snapshot()).pending.length,2);
 await assert.rejects(fence.append({...a,intentID:id(),operationID:id()}),/deployment_fence_conflict/);
 assert.equal((await fence.snapshot()).pending.length,2);
});

test('concurrent exact recovery replays both succeed without releasing another replay lock',async t=>{
 const {path}=await fixture(t),{fenceIntentDigest}=await journal(),p=pending(1);let armed=false,failed=false,paused=false;
 let release,notify;const barrier=new Promise(r=>{release=r;}),entered=new Promise(r=>{notify=r;});
 const openFile=async(...args)=>{const h=await realOpen(...args);return new Proxy(h,{get(target,key){
  if(key==='sync')return async()=>{
   if(armed&&args[0]===path){if(!failed){failed=true;throw Error('injected_fsync');}if(!paused){paused=true;notify();await barrier;}}
   return target.sync();
  };
  const value=target[key];return typeof value==='function'?value.bind(target):value;
 }});};
 const fence=new MigrationFence(path,{openFile});await fence.append(p);armed=true;const done=terminal(p,fenceIntentDigest(p));
 await assert.rejects(fence.append(done),/injected_fsync/);
 const first=fence.append(done);await entered;const second=fence.append(done),both=Promise.allSettled([first,second]);
 await new Promise(r=>setTimeout(r,20));release();
 assert.deepEqual((await both).map(r=>r.status),['fulfilled','fulfilled']);
 assert.equal(await fence.verify({schemaVersion:22,publications:p.vaults}),true);
});

test('assertWritable checks existing protected storage and barriers without changing bytes',async t=>{
 const {fence,path}=await fixture(t);await writeFile(path,'');const before=await readFile(path);
 assert.equal(await fence.assertWritable(),true);assert.equal((await readFile(path)).equals(before),true);
 await fence.append(pending(1));await assert.rejects(fence.assertWritable(),/deployment_fence_pending/);
});

test('assertWritable refuses missing symlink readonly storage and barrier failures',async t=>{
 const {dir,path,fence}=await fixture(t);await rm(path);await assert.rejects(fence.assertWritable(),/ENOENT/);
 const {symlink}=await import('node:fs/promises');await writeFile(path,'');const link=join(dir,'link');await symlink(path,link);
 await assert.rejects(new MigrationFence(link).assertWritable());
 const readonly=new MigrationFence(path,{openFile:async(...args)=>{if(args[0]===path)throw Object.assign(Error('readonly'),{code:'EROFS'});return realOpen(...args);}});
 await assert.rejects(readonly.assertWritable(),/readonly/);
 for(const targetPath of [path,dir]){
  const blocked=new MigrationFence(path,{openFile:async(...args)=>{const h=await realOpen(...args);return new Proxy(h,{get(target,key){if(key==='sync'&&args[0]===targetPath)return async()=>{throw Error('injected_fsync');};const value=target[key];return typeof value==='function'?value.bind(target):value;}});}});
  await assert.rejects(blocked.assertWritable(),/injected_fsync/);assert.equal(await readFile(path,'utf8'),'');
 }
 await mkdir(path+'.lock');await assert.rejects(fence.assertWritable(),/deployment_fence_locked/);
});
