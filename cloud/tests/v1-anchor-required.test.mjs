import test from 'node:test';
import assert from 'node:assert/strict';
import {holdV1CommitFence,armV1CommitFence} from '../src/v1-commit-fence.mjs';
import {currentCapabilities,verifyDeploymentCompatibility} from '../src/deployment-compatibility.mjs';

test('armed V1 writers and arming cannot use a journal without an independent anchor',async()=>{
 let queried=false;
 const fence={snapshot:async()=>({writerFloor:1}),append:async()=>{},assertWritable:async()=>{throw Error('unexpected_assert');}};
 const client={query:async()=>{queried=true;throw Error('unexpected_query');}};
 await assert.rejects(holdV1CommitFence(client,fence),/deployment_anchor_required/);
 await assert.rejects(armV1CommitFence({pool:{},fence}),/deployment_anchor_required/);
 assert.equal(queried,false);
});

test('armed V1 traffic cannot open without an independent anchor even for an anchor-capable candidate',async()=>{
 let queried=false;
 const fence={snapshot:async()=>({schemaFloor:19,writerFloor:1,committed:[],pending:[],outcomes:[]})};
 await assert.rejects(verifyDeploymentCompatibility({fence,candidate:currentCapabilities,query:async()=>{queried=true;throw Error('unexpected_query');}}),/deployment_anchor_required/);
 assert.equal(queried,false);
});

test('an unanchored journal cannot arm or read an already armed V1 history',async()=>{
 const {mkdtemp,writeFile,readFile,rm}=await import('node:fs/promises'),{tmpdir}=await import('node:os'),{join}=await import('node:path'),{randomUUID}=await import('node:crypto');
 const {MigrationFence}=await import('../src/migration-fence.mjs');const dir=await mkdtemp(join(tmpdir(),'sr-anchor-required-'));
 try{
  const path=join(dir,'journal');await writeFile(path,'',{mode:0o600});const fence=new MigrationFence(path);
  const baseline={version:2,type:'V1_BASELINE',baselineID:randomUUID(),vaults:[]},floor={version:2,type:'V1_WRITER_FLOOR',writerProtocol:1};
  await fence.append(baseline);const before=await readFile(path);
  await assert.rejects(fence.append(floor),/deployment_anchor_required/);assert.deepEqual(await readFile(path),before);
  const armed=Buffer.concat([before,Buffer.from(JSON.stringify(floor)+'\n')]);await writeFile(path,armed);
  await assert.rejects(fence.snapshot(),/deployment_anchor_required/);
  await assert.rejects(fence.append(floor),/deployment_anchor_required/);
  assert.deepEqual(await readFile(path),armed);
 }finally{await rm(dir,{recursive:true,force:true});}
});
