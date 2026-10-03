import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { defaultMigrationPolicy } from '../src/migration-policy.mjs';
import {
  validateWholePublicationRequest, deriveWholePublicationPlan,
  WholePublicationPreviewTokens,
} from '../src/whole-publication-policy.mjs';

const uuid=randomUUID;
const hash='a'.repeat(64);
function fixture({vaults=1,resources=1,devices=1,kind='HOST',custodians=1}={}) {
  const teamID=uuid(),member={id:uuid(),userID:uuid(),epoch:1,role:'owner'};
  const targets=Array.from({length:devices},()=>({membershipID:member.id,membershipEpoch:1,accountID:member.userID,deviceID:uuid()}));
  const current=[],snapshots={},selected=[];
  for(let n=0;n<vaults;n++) {
    const vaultID=uuid(),items=Array.from({length:resources},(_,sourceOrdinal)=>({id:uuid(),kind,parentFolderID:null,sourceOrdinal}));
    const snapshot={teamID,vaultID,memberships:[member],devices:targets,groups:[],edges:[],raw:{securityVersion:1}};
    const policy=defaultMigrationPolicy({resources:items,snapshot});
    const custodianDeviceIDs=targets.slice(0,custodians).map(d=>d.deviceID).sort();
    current.push({teamID,vaultID,generationID:uuid(),sequence:1,headerHash:hash,resources:items,policy,custodianDeviceIDs});
    snapshots[vaultID]={current:snapshot,successor:structuredClone(snapshot)};
    selected.push({vaultID,resources:items,policy,contentChanges:[],custodianDeviceIDs});
  }
  return {request:{version:1,teamID,operationID:uuid(),vaults:selected,groupMutation:null},current,snapshots,actorRole:'owner'};
}
const clone=structuredClone;
const derive=f=>deriveWholePublicationPlan(f);

test('requires every ACTIVE Vault exactly once, including logically unchanged Vaults',()=>{
  const f=fixture({vaults:2});
  assert.equal(validateWholePublicationRequest(f.request,f.current).vaults.length,2);
  for(const vaults of [[],[f.request.vaults[0]],[f.request.vaults[0],f.request.vaults[0]]])
    assert.throws(()=>validateWholePublicationRequest({...f.request,vaults},f.current),/publication_participating_vaults/);
  const foreign=clone(f.request);foreign.teamID=uuid();
  assert.throws(()=>validateWholePublicationRequest(foreign,f.current),/publication_scope_mismatch/);
});
test('canonical intent is stable across list order and does not mutate caller input',async()=>{
  const f=fixture({vaults:2,resources:2}),original=JSON.stringify(f);
  const first=await derive(f),reordered=clone(f);
  reordered.request.vaults.reverse();reordered.current.reverse();
  for(const v of reordered.request.vaults){v.resources.reverse();v.policy.reverse();}
  assert.equal((await derive(reordered)).requestHash,first.requestHash);
  assert.equal((await derive(reordered)).readSetHash,first.readSetHash);
  assert.equal(JSON.stringify(f),original);
});
test('enforces exact content-part intentions; plaintext and foreign or duplicate part IDs rejected',()=>{
  const f=fixture({kind:'CREDENTIAL'}),r=f.request.vaults[0].resources[0];
  f.request.vaults[0].contentChanges=[{resourceID:r.id,part:'SECRET'}];
  validateWholePublicationRequest(f.request,f.current);
  for(const change of [{resourceID:r.id,part:'GENERAL'},{resourceID:uuid(),part:'SECRET'},{resourceID:r.id,part:'SECRET',plaintext:'hidden'}]){
    const request=clone(f.request);request.vaults[0].contentChanges=[change];
    assert.throws(()=>validateWholePublicationRequest(request,f.current),/invalid_publication_request/);
  }
  f.request.vaults[0].contentChanges.push(f.request.vaults[0].contentChanges[0]);
  assert.throws(()=>validateWholePublicationRequest(f.request,f.current),/invalid_publication_request/);
});
test('permanent resource identity cannot move across Vaults, change kind or duplicate within Team',()=>{
  const f=fixture({vaults:2});
  const request=clone(f.request);request.vaults[1].resources=[request.vaults[0].resources[0]];
  assert.throws(()=>validateWholePublicationRequest(request,f.current),/resource_id_collision/);
  const changed=clone(f.request);changed.vaults[0].resources[0].kind='SNIPPET';
  assert.throws(()=>validateWholePublicationRequest(changed,f.current),/resource_id_collision/);
});
test('Team group intent is exact, epoch-bound and never acquires Vault ownership',()=>{
  const f=fixture(),groupID=uuid(),m=f.snapshots[f.current[0].vaultID].current.memberships[0];
  for(const groupMutation of [
    {action:'CREATE',groupID,name:'Operators'},
    {action:'RENAME',groupID,name:'New name'},
    {action:'DELETE',groupID},
    ...['ADD_MEMBER','REMOVE_MEMBER'].map(action=>({action,groupID,userID:m.userID,membershipID:m.id,membershipEpoch:1})),
  ])assert.deepEqual(validateWholePublicationRequest({...f.request,groupMutation},f.current).groupMutation,groupMutation);
  for(const groupMutation of [{action:'DELETE',groupID,vaultID:f.current[0].vaultID},{action:'CREATE',groupID,name:' hidden '},
    {action:'ADD_MEMBER',groupID,userID:m.userID,membershipID:m.id,membershipEpoch:0},{action:'TRANSFER',groupID}])
    assert.throws(()=>validateWholePublicationRequest({...f.request,groupMutation},f.current),/invalid_publication_request/);
});
test('Credential Edit without Reveal and broken Folder graph fail before encryption',async()=>{
  const f=fixture({kind:'CREDENTIAL'});f.request.vaults[0].policy[0].mask=4;
  await assert.rejects(derive(f),/credential_edit_requires_reveal/);
  const g=fixture();g.request.vaults[0].resources[0].parentFolderID=uuid();
  assert.throws(()=>validateWholePublicationRequest(g.request,g.current),/invalid_migration_resources/);
});
test('Team Owner/Admin ceiling remains the existing one; Editor and Viewer cannot publish',async()=>{
  const f=fixture();await derive(f);await derive({...f,actorRole:'admin'});
  for(const actorRole of ['editor','viewer','unknown'])await assert.rejects(derive({...f,actorRole}),/team_access_denied/);
});
test('custody is explicit predecessor/admitted device scope and sidecar wrappers count',async()=>{
  const f=fixture({resources:2,devices:2,custodians:1}),plan=await derive(f);
  assert.deepEqual(plan.counts,{vaults:1,resources:2,parts:3,wrappers:5});
  for(const list of [[],[uuid()],[f.request.vaults[0].custodianDeviceIDs[0],f.request.vaults[0].custodianDeviceIDs[0]]]){
    const bad=clone(f);bad.request.vaults[0].custodianDeviceIDs=list;
    await assert.rejects(derive(bad),/publication_custodian_unavailable/);
  }
  const newcomer=f.snapshots[f.current[0].vaultID].successor.devices[1].deviceID;
  const bad=clone(f);bad.request.vaults[0].custodianDeviceIDs=[newcomer];
  await assert.rejects(derive(bad),/publication_custodian_unavailable/);
});
test('bounds whole operation at 10/11 Vaults with safe counts and no payload in errors',async()=>{
  assert.equal((await derive(fixture({vaults:10}))).counts.vaults,10);
  const f=fixture({vaults:11});
  await assert.rejects(derive(f),e=>e.code==='publication_limit'&&e.counts.vaults===11&&!JSON.stringify(e).includes(f.current[0].resources[0].id));
});
test('bounds live resources including Folders at 1000/1001 across all Vaults',async()=>{
  assert.equal((await derive(fixture({resources:1000}))).counts.resources,1000);
  await assert.rejects(derive(fixture({vaults:2,resources:501})),e=>e.code==='publication_limit'&&e.counts.resources===1002);
  await assert.rejects(derive(fixture({resources:1001})),e=>e.code==='publication_limit'&&e.counts.resources===1001);
});
test('bounds complete ordinary and custody wrappers at 10000/10001',async()=>{
  assert.equal((await derive(fixture({resources:999,devices:10,custodians:10}))).counts.wrappers,10000);
  await assert.rejects(derive(fixture({resources:1000,devices:10,custodians:1})),e=>e.code==='publication_limit'&&e.counts.wrappers===10001);
});
test('bounds evaluator work even when resource and wrapper counts remain inside their limits',async()=>{
  const f=fixture({resources:1000});
  const vaultID=f.current[0].vaultID;
  const pair=f.snapshots[vaultID];
  const additional=Array.from({length:9},()=>({id:uuid(),userID:uuid(),epoch:1,role:'viewer'}));
  pair.current.memberships.push(...additional);
  pair.successor.memberships.push(...structuredClone(additional));
  const original=structuredClone(f.current[0].policy);
  f.current[0].policy=original.slice(0,-1);f.request.vaults[0].policy=structuredClone(f.current[0].policy);
  assert.equal((await derive(f)).counts.wrappers,1000); // exactly 20,000,000 evaluation cells
  f.current[0].policy.push(original.at(-1));
  await assert.rejects(derive(f),e=>e.code==='publication_limit'&&e.counts.evaluationCells===20010000
    &&Object.keys(e.counts).length===1&&!JSON.stringify(e).includes(vaultID));
});
test('missing devices, foreign snapshots, absent snapshot or revoked custody fail closed',async()=>{
  const f=fixture(),vault=f.current[0].vaultID;
  for(const mutate of [g=>delete g.snapshots[vault],g=>g.snapshots[vault].successor.teamID=uuid(),g=>g.snapshots[vault].successor.devices=[]]){
    const g=clone(f);mutate(g);await assert.rejects(derive(g));
  }
});
test('same effective access through another path yields no false revocation delta',async()=>{
  const f=fixture(),v=f.current[0],s=f.snapshots[v.vaultID],member=s.current.memberships[0];
  member.role='viewer';s.successor.memberships[0].role='viewer';
  const group=uuid(),other=uuid();
  for(const snapshot of [s.current,s.successor]) {
    snapshot.groups=[{id:group},{id:other}];
    snapshot.edges=[group,other].map(groupID=>({groupID,userID:member.userID,membershipID:member.id,membershipEpoch:1}));
  }
  const make=principalID=>({id:uuid(),teamID:f.request.teamID,vaultID:v.vaultID,principalKind:'GROUP',principalID,targetKind:'RESOURCE',targetID:v.resources[0].id,mask:1,revokedAt:null});
  v.policy=[make(group),make(other)];f.request.vaults[0].policy=[v.policy[1]];
  const plan=await derive(f);assert.deepEqual(plan.effectiveDeltas,[]);
  f.request.vaults[0].policy=[];
  const revoked=await derive(f);assert.equal(revoked.effectiveDeltas.length,1);
  assert.deepEqual([revoked.effectiveDeltas[0].beforeMask,revoked.effectiveDeltas[0].afterMask],[1,0]);
});
test('new trust device changes successor and exact crypto recipient commitment',async()=>{
  const f=fixture(),first=await derive(f),second=clone(f),s=second.snapshots[f.current[0].vaultID].successor;
  s.devices.push({...s.devices[0],deviceID:uuid()});s.raw.securityVersion=2;
  const next=await derive(second);assert.equal(first.requestHash,next.requestHash);
  assert.notEqual(first.successorHash,next.successorHash);assert.notEqual(first.recipientHash,next.recipientHash);
});

function binding() {
  return {version:1,teamID:uuid(),operationID:uuid(),actorAccountID:uuid(),sessionID:uuid(),actorDeviceID:uuid(),keyVersion:1,
    requestHash:hash,readSetHash:hash,successorHash:hash,policyHash:hash,recipientHash:hash,
    effectiveAt:'2026-10-02T00:00:00Z',rowsHash:hash,rowCount:2,
    predecessors:[{vaultID:uuid(),generationID:uuid(),sequence:1,headerHash:hash}],counts:{vaults:1,resources:1,parts:2,wrappers:2}};
}
test('preview requires configured 32-byte secret, valid bound identities and <=5 minute lifetime',()=>{
  for(const secret of [undefined,'short'])assert.throws(()=>new WholePublicationPreviewTokens({secret}),/publication_unavailable/);
  for(const ttlMS of [0,-1,300001])assert.throws(()=>new WholePublicationPreviewTokens({secret:'x'.repeat(32),ttlMS}),/publication_unavailable/);
  const tokens=new WholePublicationPreviewTokens({secret:'x'.repeat(32),clock:()=>1000});
  const b=binding();assert.throws(()=>tokens.issue({...b,sessionID:'not-a-session'}),/invalid_publication_request/);
});
test('signed consent verifies exact binding and expires without unsigned fallback',()=>{
  let now=1000;const tokens=new WholePublicationPreviewTokens({secret:'x'.repeat(32),clock:()=>now,ttlMS:5000}),b=binding();
  const token=tokens.issue(b);assert.equal(tokens.open(token,b).expiresAt,6000);
  for(const field of ['teamID','operationID','actorAccountID','sessionID','actorDeviceID'])
    assert.throws(()=>tokens.open(token,{...b,[field]:uuid()}),/preview_invalidated/);
  for(const field of ['requestHash','readSetHash','successorHash','policyHash','recipientHash'])
    assert.throws(()=>tokens.open(token,{...b,[field]:'b'.repeat(64)}),/preview_invalidated/);
  assert.throws(()=>tokens.open(token,{...b,keyVersion:2}),/preview_invalidated/);
  assert.throws(()=>tokens.open(token,{...b,counts:{...b.counts,wrappers:3}}),/preview_invalidated/);
  assert.throws(()=>tokens.open(token,{...b,predecessors:[{...b.predecessors[0],sequence:2}]}),/preview_invalidated/);
  for(const bad of [token.split('.')[0],token+'.extra','',null,token.slice(0,-1)+(token.endsWith('a')?'b':'a')])
    assert.throws(()=>tokens.open(bad,b),/preview_invalidated/);
  now=6000;assert.throws(()=>tokens.open(token,b),/preview_expired/);
});
test('rotation and process restart invalidate outstanding consent even with same configured secret',()=>{
  const a=new WholePublicationPreviewTokens({secret:'x'.repeat(32),clock:()=>1000}),b=binding(),token=a.issue(b);
  for(const secret of ['x'.repeat(32),'y'.repeat(32)])
    assert.throws(()=>new WholePublicationPreviewTokens({secret,clock:()=>1000}).open(token,b),/preview_invalidated/);
});
