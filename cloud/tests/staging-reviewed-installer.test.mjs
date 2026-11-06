import assert from 'node:assert/strict';
import test from 'node:test';
import {runReviewedInstallation} from '../scripts/staging-reviewed-installer.mjs';
const h=c=>c.repeat(64),sha=c=>c.repeat(40);
const identity={sourceSHA:sha('a'),tree:sha('b'),imageDigest:'sha256:'+h('c'),controllerDigest:h('d')};
const plan=()=>({version:1,environment:'staging',runID:'run-1',sourceSHA:identity.sourceSHA,tree:identity.tree,ref:'refs/heads/codex/staging-controller-fence',
 backupDirectory:'/var/backups/selective-remote',composeFiles:['compose.yaml','compose.443-only.yaml','compose.small-host.yaml','compose.publication-fence.yaml','compose.postgres-bind.yaml'],
 expected:{sourceSHA:sha('e'),tree:sha('f'),envDigest:h('a'),imageDigest:'sha256:'+h('b'),schema:12},reviewedIdentity:identity,
 storage:{POSTGRES_DATA_MOUNT_ROOT:'/var/lib/postgresql',POSTGRES_DATA_HOST_PATH:'/var/lib/postgresql/selective-remote',POSTGRES_DATA_EXPECTED_SOURCE:'/dev/mapper/vg0-lv_pgdata',POSTGRES_DATA_EXPECTED_FSTYPE:'ext4',POSTGRES_DATA_UID:'70',POSTGRES_DATA_GID:'70'}});
const facts=p=>({...p.expected,clean:true,controllerExists:false,stateExists:false,rootFreeBytes:2*1024**3,platform:'linux',arch:'x64',nodeVersion:'v22.18.0'});
async function fixture(phase,changes={}){
 const p={...plan(),...changes.plan},stages=[];
 const result=runReviewedInstallation({phase,plan:p,dryRun:changes.dryRun??false,runCommand:async({stage})=>{
  stages.push(stage);if(stage==='candidate-ref')return changes.ref??{sourceSHA:p.sourceSHA,tree:p.tree};
  if(stage==='inspect')return {...facts(p),...changes.facts};
  if(stage==='prepared')return {identity,...changes.prepared};
  if(stage==='backup-proof')return {verified:true,baselineVerified:true,...changes.backup};
  if(stage===changes.fail)throw Error('synthetic_failure');
 }});return {result,stages};
}
test('changed source/env/image/schema, existing state and wrong scope deny before any host write',async()=>{
 for(const changed of [{sourceSHA:sha('0')},{tree:sha('0')},{envDigest:h('0')},{imageDigest:'sha256:'+h('0')},{schema:22},{clean:false},{controllerExists:true},{stateExists:true},{rootFreeBytes:1},{platform:'darwin'},{arch:'arm64'},{nodeVersion:'v22.19.0'}]){
  const f=await fixture('prepare',{facts:changed});await assert.rejects(f.result);assert.deepEqual(f.stages,['inspect']);
 }
 const f=await fixture('prepare',{plan:{environment:'production'}});await assert.rejects(f.result);assert.deepEqual(f.stages,[]);
});
test('install rejects changed prepared identity or missing verified backup before mutation',async()=>{
 for(const change of [{prepared:{identity:{...identity,imageDigest:'sha256:'+h('0')}}},{prepared:{identity:{...identity,controllerDigest:h('0')}}},{backup:{verified:false}},{backup:{baselineVerified:false}}]){
  const f=await fixture('install',change);await assert.rejects(f.result);assert.ok(!f.stages.includes('install'));assert.ok(!f.stages.includes('activate-controller'));
 }
});
test('dry-run revalidates prerequisites but performs no installation or traffic mutation',async()=>{
 const f=await fixture('install',{dryRun:true});const result=await f.result;assert.equal(result.dryRun,true);
 assert.deepEqual(f.stages,['inspect','prepared','backup-proof']);
});
test('failure after quiescing or installation leaves traffic closed, never restores live state',async()=>{
 for(const [phase,fail] of [['backup','backup'],['install','activate-controller'],['install','acceptance']]){
  const f=await fixture(phase,{fail});await assert.rejects(f.result,/synthetic_failure/);
  assert.equal(f.stages.at(-1),'keep-closed');assert.ok(!f.stages.some(stage=>/rollback|restore-live|erase/.test(stage)));
 }
});

test('changed public candidate ref/tree denies prepare before creating its run directory',async()=>{
 for(const ref of [{sourceSHA:sha('0'),tree:identity.tree},{sourceSHA:identity.sourceSHA,tree:sha('0')}]){
  const f=await fixture('prepare',{ref});await assert.rejects(f.result,/candidate_source/);assert.deepEqual(f.stages,['inspect','candidate-ref']);
 }
});
