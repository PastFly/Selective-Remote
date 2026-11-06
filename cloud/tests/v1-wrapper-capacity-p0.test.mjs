import {syntheticAnchoredFence,syntheticV1Anchor} from './synthetic-v1-anchor-fixture.mjs';
import {fenceHistoryHead} from '../src/fence-history-head.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {MigrationFence} from '../src/migration-fence.mjs';

test('previous installed journal parser rejects wrapper batch before any mutation',async()=>{
 const {execFileSync}=await import('node:child_process');
 const source=execFileSync('git',['show','b31462894beef06677385ecab75740174bc3253f:cloud/src/migration-fence-journal.mjs'],{encoding:'utf8'});
 const old=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
 const event={version:2,type:'V1_WRAPPER_BATCH_PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),changes:[{vaultKind:'TEAM',ownerID:randomUUID(),vaultID:randomUUID(),revision:1,ciphertextHash:'a'.repeat(64),beforeEnvelopeHash:'b'.repeat(64),envelopeHash:'c'.repeat(64)}]};
 assert.throws(()=>old.validateFenceEvent(event),/invalid_deployment_fence/);
});

test('wrapper batch reserves sufficient space for its terminal record before admission',async()=>{
 const {FENCE_MAX_BYTES,fenceIntentDigest}=await import('../src/migration-fence-journal.mjs');const {readFile}=await import('node:fs/promises');
 const dir=await mkdtemp(join(tmpdir(),'sr-v1-wrapper-capacity-'));
 try{
  const file=join(dir,'journal');await writeFile(file,'',{mode:0o600});const fence=await syntheticAnchoredFence(file),owner=randomUUID(),vault=randomUUID();
  const original={vaultKind:'TEAM',ownerID:owner,vaultID:vault,revision:3,ciphertextHash:'a'.repeat(64),envelopeHash:'b'.repeat(64)};
  await fence.append({version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[original]});await fence.append({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1});
  const intent={version:2,type:'V1_WRAPPER_BATCH_PENDING_INTENT',intentID:randomUUID(),operationID:randomUUID(),changes:[{...original,beforeEnvelopeHash:original.envelopeHash,envelopeHash:'c'.repeat(64)}]};
  const terminal={version:2,type:'V1_CONFIRMED_COMMIT',intentID:intent.intentID,intentDigest:fenceIntentDigest(intent)};
  const prefix=await readFile(file),floor=Buffer.from(JSON.stringify({version:2,type:'V1_WRITER_FLOOR',writerProtocol:1})+' '.repeat(512)+'\n'),line=Buffer.byteLength(JSON.stringify(intent)+'\n'),end=Buffer.byteLength(JSON.stringify(terminal)+'\n');
  const fillTo=size=>{const count=Math.floor((size-prefix.length)/floor.length),base=Buffer.concat([prefix,Buffer.from(floor.toString().repeat(count))]);return Buffer.concat([base.subarray(0,-1),Buffer.from(' '.repeat(size-base.length)+'\n')]);};
  const blocked=fillTo(FENCE_MAX_BYTES-line-1);await writeFile(file,blocked);
  const blockedEvents=blocked.toString('utf8').trimEnd().split('\n').map(line=>JSON.parse(line));
  const blockedFence=new MigrationFence(file,{anchor:syntheticV1Anchor(fenceHistoryHead(blockedEvents))});
  await assert.rejects(blockedFence.append(intent),/deployment_fence_limit/);assert.deepEqual(await readFile(file),blocked);
  await writeFile(file,fillTo(FENCE_MAX_BYTES-line-end));
  const allowedBytes=await readFile(file),allowedEvents=allowedBytes.toString('utf8').trimEnd().split('\n').map(line=>JSON.parse(line));
  const allowedFence=new MigrationFence(file,{anchor:syntheticV1Anchor(fenceHistoryHead(allowedEvents))});
  await allowedFence.append(intent);await allowedFence.append(terminal);assert.equal((await allowedFence.snapshot()).v1Pending.length,0);
 }finally{await rm(dir,{recursive:true,force:true});}
});
