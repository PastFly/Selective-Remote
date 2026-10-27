// Real HTTPS only; no intercepted responses, seeded accounts, or exported keys.
import {mkdir,writeFile,rename,rm,lstat} from 'node:fs/promises';
import {join,isAbsolute,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createInterface} from 'node:readline/promises';
import {randomUUID,createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {canonicalMigrationJSON} from '../../public/vault-v2-migration.js';
import {lifecycleFailure,lifecycleDiagnosticCodes,diagnosticRequestAllowed,continuationLoginRequestAllowed,inspectBrowserLifecycleDiagnostic,validateDiagnosticRun,runSequentialDiagnosticProfiles} from '../../scripts/staging-lifecycle-diagnostics.mjs';
import {validateRunConfig,readProtectedJSON,redactedEvidence,createOperatorBridge,assertProtectedDirectory,createProtectedRunDirectory,validateOperatorProof,validateOrdinaryBaseline,validateNegativeInvariantProof} from '../../scripts/staging-publication-acceptance.mjs';
import {readContinuationLink,createContinuationRequest,validateContinuationProof,claimContinuation,assertContinuationClaim,assertContinuationRunBaseline,assertContinuationUnclaimed,acquireUnclaimedLifecycleLock,writeContinuationExclusive,runContinuationReadiness,assertContinuationIdentity,continuationEvidenceClass} from '../../scripts/staging-bootstrap-continuation.mjs';
import {readRecoveryLink,createRecoveryRequest,validateRecoveryProof,claimRecovery,assertRecoveryClaim,assertRecoveryUnclaimed,recoveryEvidenceClass} from '../../scripts/staging-partial-bootstrap-recovery.mjs';

import {readInitializedRecoveryLink,createInitializedRecoveryRequest,validateInitializedRecoveryProof,claimInitializedRecovery,assertInitializedRecoveryClaim,assertInitializedRecoveryUnclaimed,initializedRecoveryEvidenceClass} from '../../scripts/staging-initialized-bootstrap-recovery.mjs';

import {readUploadedContinuationLink,createUploadedContinuationRequest,validateUploadedContinuationProof,claimUploadedContinuation,assertUploadedContinuationClaim,assertUploadedContinuationUnclaimed,uploadedContinuationEvidenceClass,assertUploadedInterval} from '../../scripts/staging-uploaded-bootstrap-continuation.mjs';

const EDGE='/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge';
async function save(path,value){const next=path+'.next-'+randomUUID();await writeFile(next,JSON.stringify(value)+'\n',{mode:0o600,flag:'wx'});await rename(next,path);}

// One payload builder is exercised by Browser crypto and native importer tests.
// Installation returns no records, so runtime plaintext stays inside the page.
export function stagingV1Records({installOnly=false}={}){
 const create=()=>{
  const forwardingID=crypto.randomUUID(),nativeJSON=value=>JSON.stringify(value,(_,item)=>item&&typeof item==='object'&&!Array.isArray(item)?Object.fromEntries(Object.keys(item).sort().map(key=>[key,item[key]])):item);
  // Same Codable shape as the native exporter: IndependentPortForward,
  // TerminalTabConnection.custom and PortForwardRule.local, encoded as the
  // exporter's base64url UTF-8 JSON configuration. No connection runs.
  const forwarding={id:forwardingID,connection:{kind:'custom',host:'synthetic.invalid',username:'synthetic',port:22},
   rule:{id:forwardingID,name:'TEST-ONLY-CODEX Forwarding',kind:'local',bindAddress:'127.0.0.1',sourcePort:19090,destinationHost:'127.0.0.1',destinationPort:19091}};
  return [
   {id:crypto.randomUUID(),type:'host',data:{title:'TEST-ONLY-CODEX Host',address:'synthetic.invalid',connectionType:'ssh',port:22,username:'synthetic',folder:'Acceptance/Nested'}},
   {id:crypto.randomUUID(),type:'credential',data:{title:'TEST-ONLY-CODEX Credential',username:'synthetic',secret:crypto.randomUUID()}},
   {id:crypto.randomUUID(),type:'snippet',data:{title:'TEST-ONLY-CODEX Snippet',body:'printf test-only',folder:'Acceptance/Nested'}},
   {id:forwardingID,type:'forwarding',data:{title:forwarding.rule.name,destination:'127.0.0.1:19091',kind:'local',configuration:btoa(nativeJSON(forwarding)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'')}},
  ];
 };
 if(installOnly){globalThis.__prcCreateV1Records=create;return;}
 return create();
}

// Serialized with the lifecycle. Recovery is deliberately limited to the one
// empty V1 object left before the first upload, never a generic retry/reset.
export async function stagingPartialBootstrapGuard({installOnly=false,...options}={}){
 const inspect=async({client,team,identity,userID,runID,partial,storage})=>{
  const fail=()=>{throw Error('partial_bootstrap_changed');},canonical=value=>JSON.stringify(value,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);
  const created=partial?.created,saved=await storage('created'),item=created?.vaults?.[0];
  if(!created||created.actorUserID!==userID||created.actorDeviceID!==identity.deviceID||created.vaults.length!==1
   ||item?.name!==`TEST-ONLY-CODEX-${runID}-populated`||canonical(saved)!==canonical(created))fail();
  const current=(await client.listTeams()).find(t=>t.id===created.teamID);
  if(!current||current.name!==`TEST-ONLY-CODEX-${runID}-team`||current.role!=='owner'
   ||current.membershipID!==partial.membershipID||current.membershipEpoch!==partial.membershipEpoch)fail();
  const vaults=await client.listSharedVaults(created.teamID);
  if(vaults.length!==1||vaults[0].id!==item.vaultID||vaults[0].name!==item.name)fail();
  if((await client.getTeamDeviceAdmissionPolicy(created.teamID)).automaticDeviceAdmission!==true)fail();
  const scope={type:'team',teamID:created.teamID,vaultID:item.vaultID},remote=await client.getTeamVault(scope);
  if(remote.revision!==0||remote.keyGeneration!==1||remote.rotationRequired!==false
   ||['envelopeVersion','ciphertext','nonce','authTag','contentHash','wrapper'].some(k=>remote[k]!==null))fail();
  if(await team.createIndexedDBTeamVaultRepository(scope).load()||await storage('legacy:'+item.vaultID)||await storage('expected:'+item.vaultID))fail();
  return structuredClone(saved);
 };
 if(installOnly){globalThis.__prcInspectPartialBootstrap=inspect;return;}
 return inspect(options);
}

// Read/decrypt only. The same guard runs again at the mutation boundary.
export async function stagingInitializedBootstrapGuard({installOnly=false,...options}={}){
 const inspect=async({client,team,keys,trust,pin,origin,identity,userID,runID,initialized,storage,observationOnly=false})=>{
  const fail=()=>{throw Error('initialized_bootstrap_changed');};
  const canonical=value=>JSON.stringify(value,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);
  const equal=(a,b)=>canonical(a)===canonical(b),digest=async value=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(canonical(value))))].map(b=>b.toString(16).padStart(2,'0')).join('');
  const created=initialized?.created,item=created?.vaults?.[0],saved=await storage('created');
  if(!created||created.actorUserID!==userID||created.actorDeviceID!==identity.deviceID||created.vaults.length!==1||item?.name!==`TEST-ONLY-CODEX-${runID}-populated`||!equal(saved,created))fail();
  const current=(await client.listTeams()).find(t=>t.id===created.teamID),scope={type:'team',teamID:created.teamID,vaultID:item.vaultID};
  if(!current||current.name!==`TEST-ONLY-CODEX-${runID}-team`||current.role!=='owner'||current.membershipID!==initialized.membershipID||current.membershipEpoch!==1||initialized.membershipEpoch!==1)fail();
  const vaults=await client.listSharedVaults(created.teamID);if(vaults.length!==1||vaults[0].id!==item.vaultID||vaults[0].name!==item.name||(await client.getTeamDeviceAdmissionPolicy(created.teamID)).automaticDeviceAdmission!==true)fail();
  const members=await client.listTeamMembers(created.teamID);
  if(members.length!==1||members[0].id!==initialized.membershipID||members[0].epoch!==1||members[0].userID!==userID||members[0].role!=='owner'||(await client.listTeamInvitations(created.teamID)).length)fail();
  const expectedTrust=initialized.ownerTrust,snapshot=await client.deviceTrustSnapshot();
  if(expectedTrust.accountID!==userID||expectedTrust.deviceID!==identity.deviceID||expectedTrust.publicKeyFingerprint!==await keys.teamDevicePublicKeyFingerprint(identity.publicKey)||pin?.rootFingerprint!==expectedTrust.rootFingerprint||snapshot.state!=='ROOT_PUBLISHED'||snapshot.rootFingerprint!==expectedTrust.rootFingerprint||snapshot.custodianDeviceID!==identity.deviceID)fail();
  const directory=await trust.verifySignedDeviceDirectory({rootPublicKey:snapshot.rootPublicKey,checkpoint:snapshot.checkpoint,accountID:userID});
  const next=trust.advancePinnedTrust(pin,{endpoint:origin,accountID:userID,rootFingerprint:snapshot.rootFingerprint,highWater:directory.version,checkpointDigest:directory.checkpointDigest});
  const entry=snapshot.checkpoint.payload.entries.find(v=>v.deviceID===identity.deviceID),certificate=snapshot.certificates.find(v=>v.payload?.deviceID===identity.deviceID&&v.payload.keyVersion===entry?.keyVersion);
  if(!certificate||await digest(snapshot.checkpoint)!==expectedTrust.signedDirectorySHA256||await digest(certificate)!==expectedTrust.certificateSHA256)fail();
  const verified=await trust.verifyDeviceForWrapping({rootPublicKey:snapshot.rootPublicKey,certificate,checkpoint:snapshot.checkpoint,trust:next,expectedDeviceID:identity.deviceID});
  if(!equal(verified.publicKey,identity.publicKey))fail();
  const recipients=(await client.listTeamKeyDevices(scope)).devices,tuples=rows=>rows.map(({membershipID,membershipEpoch,deviceID})=>({membershipID,membershipEpoch,deviceID})).sort((a,b)=>a.deviceID.localeCompare(b.deviceID));
  if(!recipients.every(r=>r.hasWrapper===true)||!equal(tuples(recipients),tuples(initialized.requiredRecipients)))fail();
  const remote=await client.getTeamVault(scope),cached=await team.createIndexedDBTeamVaultRepository(scope).load();
  if(remote.revision!==1||remote.keyGeneration!==1||remote.rotationRequired!==false||remote.envelopeVersion!==1||!remote.wrapper||!cached||cached.deviceID!==identity.deviceID||cached.localRevision!==1||cached.serverRevision!==1||cached.syncedLocalRevision!==1||cached.keyGeneration!==1||!equal(cached.scope,scope))fail();
  const envelope={baseRevision:0,keyGeneration:1,envelopeVersion:remote.envelopeVersion,ciphertext:remote.ciphertext,nonce:remote.nonce,authTag:remote.authTag,contentHash:remote.contentHash};
  const wrapper=initialized.wrappers.find(v=>v.deviceID===identity.deviceID);
  if(!wrapper||await digest(envelope)!==initialized.envelopeSHA256||await digest(remote.wrapper)!==wrapper.wrapperSHA256||!equal(cached.envelope,envelope)||!equal(cached.wrapper,remote.wrapper)||remote.wrapper.membershipID!==initialized.membershipID||remote.wrapper.membershipEpoch!==1)fail();
  if(await storage('legacy:'+item.vaultID)||await storage('expected:'+item.vaultID))fail();
  const key=await keys.unwrapTeamVaultKeyForDevice({privateKey:identity.privateKey,wrapper:remote.wrapper,...scope,keyGeneration:1,deviceID:identity.deviceID});
  const document=await keys.decryptTeamVaultPayload({vaultKey:key,envelope,scope});
  const empty=d=>d&&Object.keys(d).sort().join(',')==='records,schemaVersion,tombstones'&&d.schemaVersion===1&&Array.isArray(d.records)&&d.records.length===0&&Array.isArray(d.tombstones)&&d.tombstones.length===0;
  if(!empty(document))fail();
  const controller=team.createTeamVaultController({repository:team.createIndexedDBTeamVaultRepository(scope),identity,scope});
  try{const local=await controller.unlock(),state=await controller.syncState();if(!empty(local)||!equal(local,document)||state.dirty||state.serverRevision!==1)fail();}finally{controller.lock();}
  if(observationOnly)return {observedAt:new Date().toISOString(),teamID:scope.teamID,vaultID:scope.vaultID,accountID:userID,deviceID:identity.deviceID,membershipID:current.membershipID,membershipEpoch:current.membershipEpoch,serverRevision:remote.revision,localRevision:cached.localRevision,syncedLocalRevision:cached.syncedLocalRevision,keyGeneration:remote.keyGeneration,envelopeSHA256:await digest(envelope),ownWrapperSHA256:await digest(remote.wrapper),requiredRecipients:tuples(recipients),rootFingerprint:snapshot.rootFingerprint,signedDirectorySHA256:await digest(snapshot.checkpoint),certificateSHA256:await digest(certificate),emptyCounts:{records:document.records.length,tombstones:document.tombstones.length,vectorClock:Object.keys(document.vectorClock??{}).length}};
  return structuredClone(saved);
 };
 if(installOnly){globalThis.__prcInspectInitializedBootstrap=inspect;return;}
 return inspect(options);
}

export async function stagingUploadedBootstrapContinuation({installOnly=false,...options}={}){
 const run=async({client,team,keys,trust,pin,origin,identity,userID,runID,uploaded:initialized,expectedFixture,interval,storage,memberEmail,inspectOnly=false,verifyLegacy=globalThis.__prcVerifyLegacyRoundtrip})=>{
  const fail=()=>{throw Error('uploaded_bootstrap_changed');};
  const canonical=value=>JSON.stringify(value,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);
  const equal=(a,b)=>canonical(a)===canonical(b),digest=async value=>[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(canonical(value))))].map(b=>b.toString(16).padStart(2,'0')).join('');
  const checkTime=()=>{const now=new Date().toISOString();if(!interval||!Number.isFinite(Date.parse(interval.startsAt))||!Number.isFinite(Date.parse(interval.endsAt))||now<interval.startsAt||now>=interval.endsAt)throw Error('uploaded_authorization_expired');};
  checkTime();let stageCreated=structuredClone(initialized.created),emptyRevision=0,invitationID=null;
  const inspect=async()=>{
  checkTime();
  const created=initialized?.created,item=created?.vaults?.[0],saved=await storage('created');
  if(!created||created.actorUserID!==userID||created.actorDeviceID!==identity.deviceID||created.vaults.length!==1||item?.name!==`TEST-ONLY-CODEX-${runID}-populated`||!equal(saved,stageCreated))fail();
  const current=(await client.listTeams()).find(t=>t.id===created.teamID),scope={type:'team',teamID:created.teamID,vaultID:item.vaultID};
  if((await client.listTeams()).filter(t=>t.role==='owner').length!==1||!current||current.name!==`TEST-ONLY-CODEX-${runID}-team`||current.role!=='owner'||current.membershipID!==initialized.membershipID||current.membershipEpoch!==1||initialized.membershipEpoch!==1)fail();
  const vaults=await client.listSharedVaults(created.teamID);if(vaults.length!==stageCreated.vaults.length||!stageCreated.vaults.every(v=>vaults.some(a=>a.id===v.vaultID&&a.name===v.name))||(await client.getTeamDeviceAdmissionPolicy(created.teamID)).automaticDeviceAdmission!==true)fail();
  const members=await client.listTeamMembers(created.teamID);
  if(members.length!==1||members[0].id!==initialized.membershipID||members[0].epoch!==1||members[0].userID!==userID||members[0].role!=='owner')fail();
  const invitations=await client.listTeamInvitations(created.teamID);if(invitationID?invitations.length!==1||invitations[0].id!==invitationID:invitations.length!==0)fail();
  if(stageCreated.vaults.length===2){const e=await client.getTeamVault({type:'team',teamID:created.teamID,vaultID:stageCreated.vaults[1].vaultID});if(e.revision!==emptyRevision||e.keyGeneration!==1||e.rotationRequired!==false||emptyRevision===0&&['envelopeVersion','ciphertext','nonce','authTag','contentHash','wrapper'].some(k=>e[k]!==null))fail();}
  const expectedTrust=initialized.ownerTrust,snapshot=await client.deviceTrustSnapshot();
  if(expectedTrust.accountID!==userID||expectedTrust.deviceID!==identity.deviceID||expectedTrust.publicKeyFingerprint!==await keys.teamDevicePublicKeyFingerprint(identity.publicKey)||pin?.rootFingerprint!==expectedTrust.rootFingerprint||snapshot.state!=='ROOT_PUBLISHED'||snapshot.rootFingerprint!==expectedTrust.rootFingerprint||snapshot.custodianDeviceID!==identity.deviceID)fail();
  const directory=await trust.verifySignedDeviceDirectory({rootPublicKey:snapshot.rootPublicKey,checkpoint:snapshot.checkpoint,accountID:userID});
  const next=trust.advancePinnedTrust(pin,{endpoint:origin,accountID:userID,rootFingerprint:snapshot.rootFingerprint,highWater:directory.version,checkpointDigest:directory.checkpointDigest});
  const entry=snapshot.checkpoint.payload.entries.find(v=>v.deviceID===identity.deviceID),certificate=snapshot.certificates.find(v=>v.payload?.deviceID===identity.deviceID&&v.payload.keyVersion===entry?.keyVersion);
  if(!certificate||await digest(snapshot.checkpoint)!==expectedTrust.signedDirectorySHA256||await digest(certificate)!==expectedTrust.certificateSHA256)fail();
  const verified=await trust.verifyDeviceForWrapping({rootPublicKey:snapshot.rootPublicKey,certificate,checkpoint:snapshot.checkpoint,trust:next,expectedDeviceID:identity.deviceID});
  if(!equal(verified.publicKey,identity.publicKey))fail();
  const recipients=(await client.listTeamKeyDevices(scope)).devices,tuples=rows=>rows.map(({membershipID,membershipEpoch,deviceID})=>({membershipID,membershipEpoch,deviceID})).sort((a,b)=>a.deviceID.localeCompare(b.deviceID));
  if(!recipients.every(r=>r.hasWrapper===true)||!equal(tuples(recipients),tuples(initialized.requiredRecipients)))fail();
  const remote=await client.getTeamVault(scope),cached=await team.createIndexedDBTeamVaultRepository(scope).load();
  if(remote.revision!==2||remote.keyGeneration!==1||remote.rotationRequired!==false||remote.envelopeVersion!==1||!remote.wrapper||!cached||cached.deviceID!==identity.deviceID||cached.localRevision!==5||cached.serverRevision!==2||cached.syncedLocalRevision!==5||cached.keyGeneration!==1||!equal(cached.scope,scope))fail();
  const envelope={baseRevision:1,keyGeneration:1,envelopeVersion:remote.envelopeVersion,ciphertext:remote.ciphertext,nonce:remote.nonce,authTag:remote.authTag,contentHash:remote.contentHash};
  const wrapper=initialized.wrappers.find(v=>v.deviceID===identity.deviceID);
  if(!wrapper||await digest(envelope)!==initialized.envelopeSHA256||await digest(remote.wrapper)!==wrapper.wrapperSHA256||!equal(cached.wrapper,remote.wrapper)||remote.wrapper.membershipID!==initialized.membershipID||remote.wrapper.membershipEpoch!==1)fail();

  const key=await keys.unwrapTeamVaultKeyForDevice({privateKey:identity.privateKey,wrapper:remote.wrapper,...scope,keyGeneration:1,deviceID:identity.deviceID});
  const document=await keys.decryptTeamVaultPayload({vaultKey:key,envelope,scope});
  const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
  if(!document||Object.keys(document).sort().join(',')!=='records,schemaVersion,tombstones'||document.schemaVersion!==1||document.records.length!==4||document.tombstones.length||expectedFixture.shapeVersion!==1||await digest(document)!==expectedFixture.documentSHA256)fail();
  const bindings=await Promise.all(document.records.map(async r=>({id:r.id,type:r.type,canonicalSHA256:await digest(r)})));bindings.sort((a,b)=>a.id.localeCompare(b.id));
  if(!equal(bindings,expectedFixture.records)||new Set(bindings.map(r=>r.id)).size!==4||!equal(bindings.map(r=>r.type).sort(),['credential','forwarding','host','snippet']))fail();
  for(const r of document.records){
   if(!uuid.test(r.id)||!equal(r.version,{[identity.deviceID]:1}))fail();
   let expected;
   if(r.type==='host')expected={title:'TEST-ONLY-CODEX Host',address:'synthetic.invalid',connectionType:'ssh',port:22,username:'synthetic',folder:'Acceptance/Nested'};
   if(r.type==='credential'){if(!uuid.test(r.data.secret))fail();expected={title:'TEST-ONLY-CODEX Credential',username:'synthetic',secret:r.data.secret};}
   if(r.type==='snippet')expected={title:'TEST-ONLY-CODEX Snippet',body:'printf test-only',folder:'Acceptance/Nested'};
   if(r.type==='forwarding'){
    const config={id:r.id,connection:{kind:'custom',host:'synthetic.invalid',username:'synthetic',port:22},rule:{id:r.id,name:'TEST-ONLY-CODEX Forwarding',kind:'local',bindAddress:'127.0.0.1',sourcePort:19090,destinationHost:'127.0.0.1',destinationPort:19091}};
    expected={title:'TEST-ONLY-CODEX Forwarding',destination:'127.0.0.1:19091',kind:'local',configuration:btoa(canonical(config)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'')};
   }
   if(!equal(r.data,expected))fail();
  }
  const controller=team.createTeamVaultController({repository:team.createIndexedDBTeamVaultRepository(scope),identity,scope});
  try{
   const local=await controller.unlock(),state=await controller.syncState();if(!equal(local,document)||state.dirty||state.serverRevision!==2)fail();
   const legacy=await verifyLegacy({team,identity,scope,controller,cached,remote,expectedRecordCount:4});
   const records=bindings.map(r=>({id:r.id,type:r.type,digest:r.canonicalSHA256})),secrets=[];
   for(const r of document.records.filter(r=>r.type==='credential'))secrets.push({resourceID:r.id,sha256:[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(r.data.secret)))].map(b=>b.toString(16).padStart(2,'0')).join('')});
   checkTime();return {legacy,expected:{records,secrets}};
  }finally{controller.lock();}
  };
  const first=await inspect(),populatedID=initialized.created.vaults[0].vaultID;
  if(await storage('legacy:'+populatedID)||await storage('expected:'+populatedID))fail();
  checkTime();if(inspectOnly)return {documentSHA256:expectedFixture.documentSHA256,serverRevision:2,localRevision:5};
  await storage('legacy:'+populatedID,first.legacy);checkTime();await storage('expected:'+populatedID,first.expected);
  await inspect();checkTime();
  const name=`TEST-ONLY-CODEX-${runID}-empty`,vault=await client.createSharedVault({teamID:stageCreated.teamID,name,idempotencyKey:`prc:${runID}:empty`});
  stageCreated.vaults.push({vaultID:vault.id,name,attemptID:crypto.randomUUID()});await storage('created',stageCreated);checkTime();
  const scope={type:'team',teamID:stageCreated.teamID,vaultID:vault.id},emptyRepository=team.createIndexedDBTeamVaultRepository(scope);if(await emptyRepository.load())fail();checkTime();
  const controller=team.createTeamVaultController({repository:emptyRepository,identity,scope});
  // The ordinary product initializer is the only writer. No populated controller
  // mutation method or upload is reachable through this transport.
  let putCount=0;
  const emptyClient={session:()=>client.session(),getTeamVault:async s=>{if(!equal(s,scope))fail();return client.getTeamVault(s);},listTeamKeyDevices:async s=>{if(!equal(s,scope))fail();return client.listTeamKeyDevices(s);},putTeamVault:async(s,envelope,key)=>{if(!equal(s,scope)||putCount||envelope.baseRevision!==0||envelope.keyGeneration!==1)fail();await inspect();checkTime();putCount++;return client.putTeamVault(s,envelope,key);}};
  try{
   await inspect();checkTime();const result=await team.synchronizeTeamVault({client:emptyClient,controller,role:'owner'});checkTime();
   if(result.status!=='initialized'||result.revision!==1||putCount!==1)fail();emptyRevision=1;
   const remote=await client.getTeamVault(scope),cached=await team.createIndexedDBTeamVaultRepository(scope).load();
   const legacy=await verifyLegacy({team,identity,scope,controller,cached,remote,expectedRecordCount:0});checkTime();
   await storage('legacy:'+vault.id,legacy);checkTime();await storage('expected:'+vault.id,{records:[],secrets:[]});
  }finally{controller.lock();}
  await inspect();checkTime();const invite=await client.inviteTeamMember({teamID:stageCreated.teamID,email:memberEmail,role:'editor',idempotencyKey:`prc:${runID}:invite`});invitationID=invite.id;
  await inspect();checkTime();return {...stageCreated,invitationID};
 };
 if(installOnly){globalThis.__prcContinueUploadedBootstrap=run;return;}
 return run(options);
}


// Preclaim page setup deliberately avoids lifecycle/IndexedDB repository creation.
// Existing records are read with readonly transactions; missing databases abort
// upgrades. Dependencies are injectable only for local tests, like diagnostics.
export async function inspectUploadedBrowser({origin,runID,email,moduleHashes,uploaded,expectedFixture,interval,account,failureCodes},dependencies=null){
 try{
  let client,team,keys,trust,readRecord;
  if(dependencies)({client,team,keys,trust,readRecord}=dependencies);
  else{
   if(location.origin!==origin||location.protocol!=='https:')throw Error('real_origin_required');
   for(const [path,expected]of Object.entries(moduleHashes)){
    const response=await fetch(path,{cache:'no-store',credentials:'same-origin'});if(!response.ok)throw Error('deployed_module_unavailable');
    const actual=[...new Uint8Array(await crypto.subtle.digest('SHA-256',await response.arrayBuffer()))].map(b=>b.toString(16).padStart(2,'0')).join('');if(actual!==expected)throw Error('deployed_module_mismatch');
   }
   const sync=await import('/vault-sync.js');team=await import('/team-vault-sync.js');keys=await import('/team-vault-crypto.js');trust=await import('/device-trust-v1.js');
   client=sync.createAuthenticatedVaultClient({fetchValue:async(path,options={})=>{const url=new URL(path,origin);if((options.method??'GET')!=='GET'||url.origin!==origin)throw Error('readonly_storage_required');return fetch(url,options);}});
   readRecord=async(name,store,key)=>{
    if(typeof indexedDB.databases!=='function')throw Error('readonly_storage_required');
    if(!(await indexedDB.databases()).some(db=>db.name===name))return null;
    const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(name);r.onupgradeneeded=()=>{r.transaction.abort();reject(Error('readonly_storage_required'));};r.onsuccess=()=>resolve(r.result);r.onerror=r.onblocked=()=>reject(Error('readonly_storage_required'));});
    try{return await new Promise((resolve,reject)=>{const tx=db.transaction(store,'readonly'),r=tx.objectStore(store).get(key);let value;r.onsuccess=()=>{value=r.result??null;};tx.oncomplete=()=>resolve(value);tx.onerror=tx.onabort=()=>reject(Error('readonly_storage_required'));});}finally{db.close();}
   };
  }
  const user=await client.restoreSession(),deviceID=client.deviceID();
  if(user.id!==account.accountID||user.email.toLowerCase()!==email.toLowerCase()||deviceID!==account.deviceID)throw Error('preserved_identity_changed');
  const identity=await readRecord('selective-remote-cloud','local-vault','team-device-key:'+deviceID);
  if(!identity||identity.deviceID!==deviceID||await keys.teamDevicePublicKeyFingerprint(identity.publicKey)!==account.publicKeyFingerprint)throw Error('preserved_identity_changed');
  const recordKey=origin+'|'+user.id,pin=await readRecord('selective-remote-device-trust-v1','records','pin:'+recordKey),root=await readRecord('selective-remote-device-trust-v1','records','root:'+recordKey),snapshot=await client.deviceTrustSnapshot();
  if(!pin||!root||pin.rootFingerprint!==account.rootFingerprint||root.accountID!==user.id||root.endpoint!==origin||root.publicKey!==snapshot.rootPublicKey)throw Error('product_trust_required');
  const readonlyTeam={...team,createIndexedDBTeamVaultRepository:scope=>({load:()=>readRecord('selective-remote-cloud','local-vault',`team-vault:${scope.teamID}:${scope.vaultID}`),save:async()=>{throw Error('readonly_storage_required');},remove:async()=>{throw Error('readonly_storage_required');}})};
  const storage=async function(key){if(arguments.length!==1)throw Error('readonly_storage_required');return readRecord('selective-remote-real-'+runID,'run',key);};
  const result=await globalThis.__prcContinueUploadedBootstrap({client,team:readonlyTeam,keys,trust,pin,origin,identity,userID:user.id,runID,uploaded,expectedFixture,interval,storage,inspectOnly:true});
  return {outcome:'PASS',...result};
 }catch(error){return {outcome:'DENIED',failureCode:failureCodes.includes(error?.message)?error.message:'unknown_failure'};}
}

// This ordering is shared by the actual admission and production-crypto tests.
export async function inspectThenClaimUploaded({interval,inspect,claim}){
 assertUploadedInterval(interval);await inspect();assertUploadedInterval(interval);return claim();
}

// Separate encryptions use fresh nonces; verify authenticated content, not ciphertext equality.
export async function stagingLegacyRoundtripGuard({installOnly=false,...options}={}){
 const verify=async({team,identity,scope,controller,cached,remote,expectedRecordCount})=>{
  const fail=()=>{throw Error('legacy_roundtrip_failed');},canonical=value=>JSON.stringify(value,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v),equal=(a,b)=>canonical(a)===canonical(b);
  let local,downloaded;
  try{
   const state=await controller.syncState(),document=controller.document();
   if(![0,4].includes(expectedRecordCount)||state.dirty||!cached||!remote||!equal(controller.scope,scope)||!equal(cached.scope,scope)||!equal(remote.scope,scope)
    ||remote.id!==scope.vaultID||remote.teamID!==scope.teamID||cached.deviceID!==identity.deviceID||remote.rotationRequired!==false
    ||remote.revision!==state.serverRevision||cached.serverRevision!==state.serverRevision||remote.keyGeneration!==state.keyGeneration||cached.keyGeneration!==state.keyGeneration
    ||cached.localRevision!==state.localRevision||cached.syncedLocalRevision!==cached.localRevision||!equal(cached.wrapper,remote.wrapper)||document.records.length!==expectedRecordCount)fail();
   const memory=initial=>{let value=structuredClone(initial);return {load:async()=>structuredClone(value),save:async next=>{value=structuredClone(next);}};};
   local=team.createTeamVaultController({repository:memory(cached),identity,scope});
   downloaded=team.createTeamVaultController({repository:memory(null),identity,scope});
   if(!equal(await local.unlock(),document)||!equal(await downloaded.importRemote(remote),document)
    ||!equal(await controller.syncState(),state)||!equal(controller.document(),document))fail();
   return {envelope:{baseRevision:remote.revision-1,keyGeneration:remote.keyGeneration,envelopeVersion:remote.envelopeVersion,ciphertext:remote.ciphertext,nonce:remote.nonce,authTag:remote.authTag,contentHash:remote.contentHash},wrapper:structuredClone(remote.wrapper),keyGeneration:remote.keyGeneration,revision:remote.revision};
  }catch{fail();}finally{local?.lock();downloaded?.lock();}
 };
 if(installOnly){globalThis.__prcVerifyLegacyRoundtrip=verify;return;}
 return verify(options);
}

export async function invokeLifecycleCommand(page,command,arg={}){
 // Classify in the page before the browser transport adds its prefix/stack.
 // Unknown messages never cross this boundary as diagnostic content.
 const result=await page.evaluate(async({command,arg,failureCodes})=>{
  try{return {ok:true,value:await globalThis.__prcLifecycle(command,arg)};}
  catch(error){return {ok:false,failureCode:failureCodes.includes(error?.message)?error.message:'unknown_failure'};}
 },{command,arg,failureCodes:lifecycleDiagnosticCodes});
 if(result?.ok!==true)throw Error(lifecycleDiagnosticCodes.includes(result?.failureCode)?result.failureCode:'unknown_failure');
 return result.value;
}

// Human pauses consume the same immutable window; returning from a prompt is
// never new authorization.
export async function waitForLifecycleOperator(terminal,text,interval=null){
 if(interval)assertUploadedInterval(interval);
 const answer=await terminal.question(text);
 if(interval)assertUploadedInterval(interval);
 return answer;
}

export async function openContinuationLoginPage(profile,origin,interval=null){
 await profile.context.unroute('**/*');
 await profile.context.route('**/*',route=>{if(interval&&!['GET','HEAD','OPTIONS'].includes(route.request().method())){try{assertUploadedInterval(interval);}catch{return route.abort();}}return continuationLoginRequestAllowed(route.request().url(),route.request().method(),origin)?route.continue():route.abort();});
 await profile.page.goto(origin,{waitUntil:'domcontentloaded'});
}

export async function openLifecycleExecutionPage(context,origin){
 for(const restored of context.pages())await restored.close();
 const page=await context.newPage();
 // Same-origin cookies/modules remain real; app startup must not race fixtures.
 await page.goto(origin+'/healthz',{waitUntil:'domcontentloaded'});
 return page;
}

// This function is serialized into the actual page. Only public results cross
// the Playwright boundary; all keys, legacy bodies and records stay here.
export async function installBrowserLifecycle({origin,runID,email,moduleHashes,uploadedInterval=null}){
 if(location.origin!==origin||location.protocol!=='https:')throw Error('real_origin_required');
 for(const [path,expected] of Object.entries(moduleHashes)){
  const response=await fetch(path,{cache:'no-store',credentials:'same-origin'});
  if(!response.ok)throw Error('deployed_module_unavailable');
  const actual=[...new Uint8Array(await crypto.subtle.digest('SHA-256',await response.arrayBuffer()))].map(b=>b.toString(16).padStart(2,'0')).join('');
  if(actual!==expected)throw Error('deployed_module_mismatch');
 }
 const [sync,keys,team,trust,flow,migration,publication,whole,wholeClient,format]=await Promise.all([
  import('/vault-sync.js'),import('/team-vault-crypto.js'),import('/team-vault-sync.js'),import('/device-trust-v1.js'),import('/device-trust-flow.js'),
  import('/vault-v2-migration.js'),import('/vault-publication-client.js'),import('/whole-publication-flow.js'),import('/whole-publication-client.js'),import('/vault-publication-v1.js')]);
 const equal=(a,b)=>migration.canonicalMigrationJSON(a)===migration.canonicalMigrationJSON(b),fail=code=>{throw Error(code);};
 let lastAuthorization=null,dropCommit=false,dropped=false,failReadback=false;
 const client=sync.createAuthenticatedVaultClient({fetchValue:async(path,options={})=>{
  if(uploadedInterval&&!['GET','HEAD','OPTIONS'].includes((options.method??'GET').toUpperCase())){const now=new Date().toISOString();if(now<uploadedInterval.startsAt||now>=uploadedInterval.endsAt)fail('uploaded_authorization_expired');}
  const headers=new Headers(options.headers);if(headers.has('authorization'))lastAuthorization=headers.get('authorization');
  const response=await fetch(path,options);
  if(dropCommit&&/\/publication\/operations\/[^/]+\/commit$/.test(path)&&response.ok){dropCommit=false;dropped=true;await response.arrayBuffer();throw new TypeError('deliberately_lost_actual_response');}
  if(failReadback&&/\/readback\//.test(path)&&response.ok){failReadback=false;await response.arrayBuffer();throw new TypeError('deliberately_failed_actual_refresh');}
  return response;
 }});
 const user=await client.restoreSession();if(user.email.toLowerCase()!==email.toLowerCase())fail('test_account_mismatch');
 const identityRepository=keys.createIndexedDBTeamDeviceRepository(),identity=await identityRepository.load(client.deviceID());
 if(!identity)fail('product_device_setup_required');
 const ownTrust=trust.createIndexedDBDeviceTrustRepository(),repository=publication.createIndexedDBPublicationRepository();
 const trustFlow=flow.createBrowserDeviceTrustFlow({client,repository:ownTrust,endpoint:origin,accountID:user.id,identity,identityRepository});
 const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('selective-remote-real-'+runID,1);r.onupgradeneeded=()=>r.result.createObjectStore('run');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(Error('run_storage_failed'));});
 async function storage(key,value){const writing=arguments.length===2;return new Promise((resolve,reject)=>{
  const tx=db.transaction('run',writing?'readwrite':'readonly'),store=tx.objectStore('run'),request=writing?store.put(value,key):store.get(key);let result;
  request.onsuccess=()=>{result=request.result;};tx.oncomplete=()=>resolve(result);tx.onerror=tx.onabort=()=>reject(Error('run_storage_failed'));
 });}
 async function actor(custodian=false){
  const fresh=await client.restoreSession();
  if(fresh.id!==user.id||fresh.email.toLowerCase()!==email.toLowerCase()||client.deviceID()!==identity.deviceID)fail('test_account_changed');
  const state=await trustFlow.status();
  if(!['CUSTODIAN','CERTIFIED'].includes(state.state)||!state.pin||custodian&&(state.state!=='CUSTODIAN'||!state.root))fail('product_trust_required');return state;
 }
 async function ownerScope(value){
  await actor(true);const saved=await storage('created');
  if(!saved||saved.actorUserID!==user.id||saved.actorDeviceID!==identity.deviceID||value.teamID!==saved.teamID
   ||!saved.vaults.some(v=>v.vaultID===value.vaultID&&v.attemptID===value.attemptID&&v.name===value.name))fail('run_scope_mismatch');
  const current=(await client.listSharedVaults(value.teamID)).find(v=>v.id===value.vaultID);
  if(current){if(current.name!==value.name)fail('run_scope_mismatch');}
  else{
   // V1 inventory intentionally omits ACTIVE V2 Vaults. Confirm the exact
   // saved creation tuple through the authenticated current publication set.
   const active=await client.wholePublicationTransport(value.teamID).context();
   if(!active.current.some(v=>v.vaultID===value.vaultID)){
    const candidate=await storage('migration:'+value.vaultID),membership=(await client.listTeams()).find(t=>t.id===value.teamID&&t.name===`TEST-ONLY-CODEX-${runID}-team`);
    if(!membership||candidate?.scope?.teamID!==value.teamID||candidate.scope.vaultID!==value.vaultID||candidate.scope.attemptID!==value.attemptID)fail('run_scope_mismatch');
   }
  }
  return {teamID:value.teamID,vaultID:value.vaultID,attemptID:value.attemptID,actorUserID:user.id,actorDeviceID:identity.deviceID,schemaVersion:2,capability:'resource_acl_v2'};
 }
 async function recipientScope(arg){
  await actor();const enrollment=await storage('enrolled');
  if(!enrollment||!equal(enrollment,arg.enrollment)||enrollment.accountID!==user.id||enrollment.deviceID!==identity.deviceID
   ||enrollment.teamID!==arg.teamID||!enrollment.vaults.some(v=>v.vaultID===arg.vaultID&&v.name===arg.name))fail('recipient_scope_mismatch');
  const current=(await client.listTeams()).find(t=>t.id===arg.teamID&&t.name===`TEST-ONLY-CODEX-${runID}-team`);
  if(!current||current.membershipID!==enrollment.membershipID||current.membershipEpoch!==enrollment.membershipEpoch)fail('recipient_membership_changed');
  return {teamID:arg.teamID,vaultID:arg.vaultID};
 }
 const pinnedTrust=teamID=>({loadPin:async(endpoint,account)=>account===user.id?ownTrust.loadPin(endpoint,account):repository.loadPin(endpoint,teamID,account),
  advancePin:async(old,next)=>old.accountID===user.id?ownTrust.advancePin(old,next):repository.advancePin(origin,teamID,old,next)});
 async function checkpointKey(scope){
  const keyID='key:'+scope.vaultID,existing=await storage(keyID);
  if(existing){if(!existing.protector||!existing.wrapped||!existing.nonce)fail('checkpoint_protection_lost');return new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv:existing.nonce,additionalData:new TextEncoder().encode(scope.attemptID)},existing.protector,existing.wrapped));}
  if(await storage('migration:'+scope.vaultID))fail('checkpoint_protection_lost');
  const key=crypto.getRandomValues(new Uint8Array(32)),nonce=crypto.getRandomValues(new Uint8Array(12)),protector=await crypto.subtle.generateKey({name:'AES-GCM',length:256},false,['encrypt','decrypt']);
  const wrapped=await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:new TextEncoder().encode(scope.attemptID)},protector,key);await storage(keyID,{protector,nonce,wrapped});return key;
 }
 async function expectedFor(vaultID,resources){
  const expected=await storage('expected:'+vaultID);if(!expected)fail('expected_source_missing');
  return {...expected,resources:resources.map(r=>({id:r.id,kind:r.kind,parentFolderID:r.parentFolderID})),counts:Object.fromEntries(['hosts','snippets','credentials','forwardings','folders'].map((name,i)=>[name,resources.filter(r=>r.kind===['HOST','SNIPPET','CREDENTIAL','FORWARDING','FOLDER'][i]).length]))};
 }
 async function readerFor(arg){
  const scope=await recipientScope(arg),deviceKeyVersion=await publication.resolvePublicationDeviceKeyVersion({client,repository:ownTrust,identity,sessionIdentity:client.publicationIdentity(origin)});
  return publication.createVaultPublicationClient({transport:client.publicationTransport(),identity:()=>client.publicationIdentity(origin),scope,
   privateKey:identity.privateKey,publicKey:identity.publicKey,deviceKeyVersion,ownTrustRepository:ownTrust,publisherTrustRepository:repository,repository,
   subscribeIdentityChange:listener=>client.subscribePublicationIdentity(listener)});
 }
 async function read(arg,{offline=false,deny=false}={}){
  const reader=await readerFor(arg);let kept=false;
  try{
   if(deny){try{await reader.load();}catch(error){if(!['publication_repair_required','publication_rotation_required','authentication_required','device_trust_revoked','publication_access_denied','team_device_not_admitted'].includes(error.message))throw error;return {outcome:'DENIED',checkCount:1};}fail('expected_read_denial');}
   if(offline)await reader.loadStaleCache();else await reader.load();const view=reader.view(),expected=arg.expected;
   if(!expected||view.stale!==offline||view.header.payload.generationID!==arg.current.generationID||view.headerHash!==arg.current.headerHash||view.header.payload.sequence!==arg.current.sequence||view.models.length!==expected.resources.length)fail('publication_real_readback_failed');
   for(const r of expected.resources){const model=view.models.find(m=>m.resourceID===r.id);if(!model||model.parentFolderID!==r.parentFolderID)fail('resource_identity_or_parent_changed');}
   let secrets=0;
   for(const r of expected.records){
    const model=r.type==='credential'?(offline?null:await reader.revealSecret(r.id)):view.models.find(m=>m.resourceID===r.id);
    if(offline&&r.type==='credential')continue;
    if(!model||await migration.migrationHash(model.record)!==r.digest)fail('resource_plaintext_mismatch');if(r.type==='credential')secrets++;
   }
   if(!offline){let container=document.querySelector('#prc-real-publication');if(!container){container=document.createElement('section');container.id='prc-real-publication';document.body.append(container);}publication.renderPublishedVault({documentValue:document,container,client:reader});kept=true;}
   await storage('read:'+arg.vaultID,{current:arg.current,accountID:user.id,deviceID:identity.deviceID,offline});
   return {vaultID:arg.vaultID,generationID:arg.current.generationID,headerHash:arg.current.headerHash,sequence:arg.current.sequence,count:view.models.length,offlineVerified:offline,networkReloadVerified:!offline,secretVerified:!offline&&secrets===expected.secrets.length};
  }finally{if(!kept)reader.dispose();}
 }
 async function driverFor(arg){
  await ownerScope(arg);
  const transport=client.wholePublicationTransport(arg.teamID),original=transport.context;
  transport.context=async options=>{const value=await original(options);const actual=value.current.map(v=>v.vaultID).sort();
   if(!equal(actual,[...arg.activeVaultIDs].sort()))fail('all_active_scope_mismatch');return value;};
  const driver=whole.createWholePublicationAccessDriver({transport,sessionIdentity:()=>({...client.publicationIdentity(origin),selection:runID,teamID:arg.teamID,vaultID:arg.vaultID}),
   checkpointRepository:wholeClient.createIndexedDBWholePublicationRepository(),publicationRepository:repository,
   getLocalKeys:async value=>({root:await ownTrust.loadRoot(value.endpoint,value.accountID),identity,pinnedTrust:pinnedTrust(arg.teamID)})});
  await driver.getContext(arg);return {driver,transport};
 }
 async function commitStep(command,arg,draft,{lose=false,refresh=false,predecessor=null}={}){
  const done=await storage('step:'+command);if(done)return done;
  const {driver,transport}=await driverFor(arg);
  try{
   let receipt;
   if(driver.pendingOperationID)receipt=await driver.resumePrepared(arg);
   else{
    if(predecessor){const current=(await transport.context()).current.find(v=>v.vaultID===arg.vaultID);if(!current||!['generationID','sequence','headerHash'].every(k=>current[k]===predecessor[k]))fail('transformation_predecessor_changed');}
    const approved=await driver.preview(arg,draft);await storage('intent:'+command,{operationID:approved.request.operationID});
    dropCommit=lose;failReadback=refresh;
    try{receipt=await driver.commit(arg,approved);}catch(error){
     if(!['publication_network_unavailable','publication_readback_required','publication_commit_unknown'].includes(error.message))throw error;
     if(!lose&&!refresh)throw error;
     await driver.getContext(arg);receipt=await driver.resumePrepared(arg);
    }
   }
   const intent=await storage('intent:'+command);
   if(!receipt||intent&&receipt.operationID!==intent.operationID||!equal(receipt.vaults.map(v=>v.vaultID).sort(),[...arg.activeVaultIDs].sort()))fail('whole_receipt_scope_mismatch');
   for(const v of receipt.vaults){const back=await transport.readback(receipt.operationID,v.vaultID);if(back.headerHash!==v.headerHash||back.header.payload.generationID!==v.generationID||back.header.payload.sequence!==v.sequence)fail('whole_readback_mismatch');}
   const result={receipt,operationID:receipt.operationID,allVaults:true,...(lose?{responseDiscarded:dropped}:{}),...(refresh?{refreshRecovered:!failReadback}:{})};
   if(lose&&!dropped&&!(await storage('lost:'+command)))fail('actual_response_not_discarded');
   if(lose)await storage('lost:'+command,true);
   await storage('step:'+command,result);return result;
  }finally{dropCommit=false;failReadback=false;driver.dispose();}
 }
 const resourceExpectations=rows=>rows.map(({id,kind,parentFolderID})=>({id,kind,parentFolderID})).sort((a,b)=>a.id.localeCompare(b.id));
 function verifyTransformation(intent,record,resources){
  if(!equal(record,intent.expectedRecord)||!equal(resourceExpectations(resources),intent.expectedResources))fail('transformation_result_mismatch');
 }
 // Pure assertion exposed in this isolated acceptance page so fixture negatives
 // exercise exactly the assertion used before expected history can advance.
 globalThis.__prcVerifyTransformation=verifyTransformation;
 async function transformationIntent(command,arg,value){
  const name='transformation:'+command,binding=migration.canonicalMigrationJSON({command,teamID:arg.teamID,vaultID:arg.vaultID,attemptID:arg.attemptID});
  if(arguments.length===3){
   const protector=await crypto.subtle.generateKey({name:'AES-GCM',length:256},false,['encrypt','decrypt']),nonce=crypto.getRandomValues(new Uint8Array(12));
   const ciphertext=await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:new TextEncoder().encode(binding)},protector,new TextEncoder().encode(migration.canonicalMigrationJSON(value)));
   await storage(name,{binding,protector,nonce,ciphertext});return value;
  }
  const saved=await storage(name);if(!saved)return null;
  if(saved.binding!==binding||!saved.protector||!saved.nonce||!saved.ciphertext)fail('transformation_protection_lost');
  return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:saved.nonce,additionalData:new TextEncoder().encode(binding)},saved.protector,saved.ciphertext)));
 }
 let pendingApproval=null;
 globalThis.__prcLifecycle=async(command,arg={})=>{
  if(command==='identity'){
   const state=await actor(arg.custodian===true);return {accountID:user.id,deviceID:identity.deviceID,publicKey:identity.publicKey,publicKeyFingerprint:await keys.teamDevicePublicKeyFingerprint(identity.publicKey),publicPin:state.pin};
  }
  if(command==='untrusted-identity')return {accountID:user.id,deviceID:identity.deviceID,publicKey:identity.publicKey,publicKeyFingerprint:await keys.teamDevicePublicKeyFingerprint(identity.publicKey)};
  if(command==='pair'){await trustFlow.pair({trustedFingerprint:arg.rootFingerprint,trustedCheckpointDigest:arg.checkpointDigest});return {deviceID:identity.deviceID};}
  if(command==='request-approval'){await trustFlow.requestApproval();return {deviceID:identity.deviceID};}
  if(command==='start-approval'){
   await actor(true);const request=(await client.deviceTrustRequests()).find(r=>r.deviceID===arg.deviceID);
   if(!request||!equal(request.publicKey,arg.publicKey)||await keys.teamDevicePublicKeyFingerprint(request.publicKey)!==arg.publicKeyFingerprint)fail('approval_public_identity_mismatch');
   pendingApproval=await trustFlow.startApproval(request,arg.publicKeyFingerprint);return {deviceID:arg.deviceID,requestID:pendingApproval.requestID};
  }
  if(command==='answer-challenge'){
   const request=(await client.deviceTrustRequests()).find(r=>r.deviceID===identity.deviceID);if(!request)fail('challenge_missing');await trustFlow.answerRequestChallenge(request);return {deviceID:identity.deviceID};
  }
  if(command==='finish-approval'){if(!pendingApproval||pendingApproval.deviceID!==arg.deviceID)fail('approval_memory_lost');await trustFlow.finishApproval(pendingApproval);pendingApproval=null;return {deviceID:arg.deviceID};}
  if(command==='inspect-initialized-bootstrap'){
   const state=await actor(true);return globalThis.__prcInspectInitializedBootstrap({client,team,keys,trust,pin:state.pin,origin,identity,userID:user.id,runID,initialized:arg.initialized,storage,observationOnly:true});
  }
  if(command==='continue-uploaded-bootstrap'){const state=await actor(true);return globalThis.__prcContinueUploadedBootstrap({client,team,keys,trust,pin:state.pin,origin,identity,userID:user.id,runID,storage,...arg});}
  if(command==='bootstrap'||command==='recover-bootstrap'||command==='recover-initialized-bootstrap'){
   const actorState=await actor(true);let created;
   const initialized=command==='recover-initialized-bootstrap';
   const inspectInitialized=async()=>{
    const now=new Date().toISOString();if(now<arg.interval?.startsAt||now>=arg.interval?.endsAt)fail('initialized_bootstrap_changed');
    return globalThis.__prcInspectInitializedBootstrap({client,team,keys,trust,pin:actorState.pin,origin,identity,userID:user.id,runID,initialized:arg.initialized,storage});
   };
   if(initialized)created=await inspectInitialized();
   else if(command==='recover-bootstrap')created=await globalThis.__prcInspectPartialBootstrap({client,team,identity,userID:user.id,runID,partial:arg.partial,storage});
   else{
    if(await storage('created'))fail('bootstrap_already_recorded');
    const createdTeam=await client.createTeam({name:`TEST-ONLY-CODEX-${runID}-team`,idempotencyKey:`prc:${runID}:team`});
    created={teamID:createdTeam.id,actorUserID:user.id,actorDeviceID:identity.deviceID,vaults:[]};await storage('created',created);
   }
   for(const kind of ['populated','empty']){
    const name=`TEST-ONLY-CODEX-${runID}-${kind}`;let item;
    if((command==='recover-bootstrap'||initialized)&&kind==='populated')item=created.vaults[0];
    else{const vault=await client.createSharedVault({teamID:created.teamID,name,idempotencyKey:`prc:${runID}:${kind}`});item={vaultID:vault.id,name,attemptID:crypto.randomUUID()};created.vaults.push(item);await storage('created',created);}
    const vault={id:item.vaultID};
    const scope={type:'team',teamID:created.teamID,vaultID:vault.id},controller=team.createTeamVaultController({repository:team.createIndexedDBTeamVaultRepository(scope),identity,scope});
    try{
     if(initialized&&kind==='populated'){await controller.unlock();await inspectInitialized();}
     else await team.synchronizeTeamVault({client,controller,role:'owner'});
     if(kind==='populated')for(const r of globalThis.__prcCreateV1Records())await controller.upsert(r);
     await team.synchronizeTeamVault({client,controller,role:'owner'});
     const remote=await client.getTeamVault(scope),cached=await team.createIndexedDBTeamVaultRepository(scope).load();
     const legacy=await globalThis.__prcVerifyLegacyRoundtrip({team,identity,scope,controller,cached,remote,expectedRecordCount:kind==='populated'?4:0});
     await storage('legacy:'+vault.id,legacy);
     const document=controller.document(),records=await Promise.all(document.records.map(async r=>({id:r.id,type:r.type,digest:await migration.migrationHash(r)}))),secrets=[];
     for(const r of document.records.filter(r=>r.type==='credential'))secrets.push({resourceID:r.id,sha256:[...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(r.data.secret)))].map(b=>b.toString(16).padStart(2,'0')).join('')});
     await storage('expected:'+vault.id,{records,secrets});
    }finally{controller.lock();}
   }
   const invite=await client.inviteTeamMember({teamID:created.teamID,email:arg.memberEmail,role:'editor',idempotencyKey:`prc:${runID}:invite`});return {...created,invitationID:invite.id};
  }
  if(command==='join-check'){
   await actor();const current=(await client.listTeams()).find(t=>t.id===arg.teamID&&t.name===`TEST-ONLY-CODEX-${runID}-team`);if(!current)fail('real_invitation_acceptance_pending');
   return {accountID:user.id,deviceID:identity.deviceID,membershipID:current.membershipID,membershipEpoch:current.membershipEpoch};
  }
  if(command==='enroll-reader'){
   const current=await globalThis.__prcLifecycle('join-check',arg);
   if(current.accountID!==arg.accountID||current.deviceID!==arg.deviceID||current.membershipID!==arg.membershipID||current.membershipEpoch!==arg.membershipEpoch||arg.vaults.length!==2)fail('recipient_scope_mismatch');
   for(const v of arg.vaults)if(!['empty','populated'].some(k=>v.name===`TEST-ONLY-CODEX-${runID}-${k}`))fail('recipient_scope_mismatch');
   await storage('enrolled',arg);return {deviceID:identity.deviceID};
  }
  if(command==='pin-peer'){
   await actor();if(arg.pin.endpoint!==origin||arg.pin.accountID===user.id||!arg.confirmed)fail('peer_pin_invalid');
   const enrolled=await storage('enrolled'),created=await storage('created');if(arg.teamID!==(created?.teamID??enrolled?.teamID))fail('run_scope_mismatch');
   await repository.savePinIfAbsent(origin,arg.teamID,arg.pin);return {rootFingerprint:arg.pin.rootFingerprint};
  }
  if(command==='admit'){
   await actor(true);const saved=await storage('created');if(!saved||saved.teamID!==arg.teamID||arg.accountID===user.id)fail('run_scope_mismatch');
   const member=(await client.listTeamMembers(arg.teamID)).find(m=>m.userID===arg.accountID);
   if(!member||member.id!==arg.membershipID||member.epoch!==arg.membershipEpoch)fail('membership_epoch_changed');
   if(await keys.teamDevicePublicKeyFingerprint(arg.publicKey)!==arg.publicKeyFingerprint)fail('admission_key_changed');
   await client.admitTeamMembershipDevice({teamID:arg.teamID,membershipID:member.id,deviceID:arg.deviceID,publicKey:arg.publicKey,idempotencyKey:`prc:${runID}:admit:${arg.deviceID}`});
   const admitted=(await client.listTeamMembershipDevices({teamID:arg.teamID,membershipID:member.id})).find(d=>d.id===arg.deviceID);
   if(!admitted?.admitted||!admitted.accountKeyApproved||!equal(admitted.publicKey,arg.publicKey))fail('admission_readback_failed');
   const result={accountID:arg.accountID,deviceID:arg.deviceID,membershipID:member.id,membershipEpoch:member.epoch,publicKey:admitted.publicKey,admitted:true};await storage('admitted:'+arg.deviceID,result);return result;
  }
  if(command==='prepare'){
   const input=await ownerScope(arg),state=await actor(true),scope={teamID:arg.teamID,vaultID:arg.vaultID};
   for(const deviceID of arg.requiredDeviceIDs){const a=await storage('admitted:'+deviceID);if(!a?.admitted)fail('before_migration_admission_required');}
   const completed=await storage('migration:'+arg.vaultID);if(completed?.manifestHash&&completed.current&&completed.expected)return {vaultID:arg.vaultID,attemptID:arg.attemptID,manifestHash:completed.manifestHash,current:completed.current,expected:completed.expected};
   const teamScope={type:'team',...scope},controller=team.createTeamVaultController({repository:team.createIndexedDBTeamVaultRepository(teamScope),identity,scope:teamScope});
   await team.synchronizeTeamVault({client,controller,role:'owner'});const local=await controller.syncState();if(local.dirty)fail('legacy_dirty');
   const document=controller.document(),preview=await globalThis.__prcOperator({operation:'preview',input});if(preview.sourceRevision!==local.serverRevision)fail('migration_source_changed');
   const migrationScope={...scope,attemptID:arg.attemptID,sourceRevision:preview.sourceRevision,sourceHash:preview.sourceHash,snapshotHash:preview.snapshotHash,policyVersion:preview.policyVersion};let saved=await storage('migration:'+arg.vaultID);
   if(saved&&!equal(saved.scope,migrationScope))fail('migration_source_changed');const key=await checkpointKey(arg);
   try{
    const persistCheckpoint=async checkpoint=>{saved={...saved,scope:migrationScope,checkpoint};await storage('migration:'+arg.vaultID,saved);};
    const inventory=await migration.prepareMigrationInventory({document,scope:migrationScope,checkpointKey:key,checkpoint:saved?.checkpoint,persistCheckpoint});
    const policy=saved?.policy??[];
    if(arg.groupID&&!saved?.policy){
     const owner=preview.snapshot.memberships.find(m=>m.userID===user.id||m.accountID===user.id),member=preview.snapshot.memberships.find(m=>m.id===arg.member.membershipID);
     if(!owner||!member||(member.epoch??member.membershipEpoch)!==arg.member.membershipEpoch)fail('migration_membership_changed');
     for(const r of inventory.resources){
      const targetKind=r.kind==='FOLDER'?'FOLDER':'RESOURCE',targetID=r.id;
      for(const [principalKind,principalID,mask,m] of [['USER',user.id,({HOST:13,SNIPPET:13,CREDENTIAL:15,FORWARDING:9,FOLDER:33})[r.kind],owner],['GROUP',arg.groupID,r.kind==='CREDENTIAL'?3:1,null],['USER',arg.member.accountID,r.kind==='CREDENTIAL'?3:1,member]]){
       policy.push({id:crypto.randomUUID(),teamID:scope.teamID,vaultID:scope.vaultID,principalKind,principalID,targetKind,targetID,mask,revokedAt:null,...(m?{membershipID:m.id,membershipEpoch:m.epoch??m.membershipEpoch}:{})});
      }
     }
     saved={...saved,policy};await storage('migration:'+arg.vaultID,saved);
    }
    const started=await globalThis.__prcOperator({operation:'start',input:{...input,resources:inventory.resources,...(arg.groupID?{policy}:{})}});
    if(!equal(started.scope,migrationScope))fail('migration_scope_changed');
    const self=preview.snapshot.devices.find(d=>d.accountID===user.id&&d.deviceID===identity.deviceID);if(!self)fail('self_recipient_missing');
    const out=await migration.prepareLegacyMigration({document,scope:started.scope,policy:started.policy,recipientTargets:(resource,part)=>started.recipients[resource.id][part],pinnedTrust:pinnedTrust(scope.teamID),root:state.root,identity,deviceID:identity.deviceID,endpoint:origin,checkpointKey:key,checkpoint:inventory.checkpoint,persistCheckpoint,
     readerPublication:{publisherAccountID:user.id,publisherKeyVersion:self.certificate.payload.keyVersion,custodianDeviceIDs:[identity.deviceID],custodianTargets:[self],verifyIdentityReservations:resources=>globalThis.__prcOperator({operation:'verify-identities',input:{...input,resources}})}});
    for(const object of out.objects)await globalThis.__prcOperator({operation:'upload',input,object,checkpoint:out.checkpoint});
    await globalThis.__prcOperator({operation:'upload-reader',input,projection:out.readerProjection,sidecar:out.administrativeSidecar,checkpoint:out.checkpoint});
    const manifestHash=await migration.migrationHash(out.manifest),ready=await globalThis.__prcOperator({operation:'validate',input,manifest:out.manifest});if(ready.state!=='V2_READY'||ready.manifestHash!==manifestHash)fail('migration_ready_readback_invalid');
    const header=out.readerProjection.header,headerHash=await format.publicationHash('header',header),current={vaultID:arg.vaultID,generationID:header.payload.generationID,sequence:header.payload.sequence,headerHash},expected=await expectedFor(arg.vaultID,out.resources);await storage('migration:'+arg.vaultID,{...saved,manifestHash,headerHash,resources:out.resources,current,expected});
    return {vaultID:arg.vaultID,attemptID:arg.attemptID,manifestHash,current,expected};
   }finally{key.fill(0);controller.lock();}
  }
  if(command==='activate'){
   const input=await ownerScope(arg),saved=await storage('migration:'+arg.vaultID);if(!saved?.manifestHash)fail('prepared_migration_required');
   const result=await globalThis.__prcOperator({operation:'activate',input,manifestHash:saved.manifestHash});if(result.state!=='V2_ACTIVE'||result.manifestHash!==saved.manifestHash)fail('activation_readback_invalid');return {vaultID:arg.vaultID,attemptID:arg.attemptID,manifestHash:saved.manifestHash};
  }
  if(command==='current'){
   const {driver,transport}=await driverFor(arg);try{const context=await transport.context();return {current:context.current.map(({vaultID,generationID,sequence,headerHash})=>({vaultID,generationID,sequence,headerHash})),groups:driver.groups().rows.map(({id,name})=>({id,name})),edges:driver.groupMembers(arg.groupID??'').rows};}finally{driver.dispose();}
  }
  if(command==='read')return read(arg);
  if(command==='offline')return read(arg,{offline:true});
  if(command==='repair-required')return read(arg,{deny:true});
  if(command==='group-create')return commitStep(command,arg,{type:'GROUP_CREATE',name:`TEST-ONLY-CODEX-${runID}-group`});
  if(command==='group-member-add')return commitStep(command,arg,{type:'GROUP_MEMBER_ADD',groupID:arg.groupID,targetMembershipID:arg.member.membershipID});
  if(command==='inspect'){
   const {driver}=await driverFor(arg);try{
    const r=arg.expected.records.find(r=>r.type==='credential'),value=await driver.effective(arg,r.id,arg.member.accountID,arg.member.deviceID);
    const paths=value.policyEffective.paths;
    if(value.policyEffective.policyMask!==3||!paths.some(p=>p.principalKind==='GROUP')||arg.direct&&!paths.some(p=>p.principalKind==='USER')||!arg.direct&&paths.some(p=>p.principalKind==='USER'))fail('effective_paths_mismatch');
    await driver.whoHas(arg,r.id);await driver.resourcesByPrincipal(arg,'GROUP',arg.groupID);await driver.listDevices(arg,arg.member.accountID);
    return {effectiveMask:3,pathCount:paths.length};
   }finally{driver.dispose();}
  }
  if(command==='recipient-negatives'){
   await recipientScope(arg);let count=0;
   const transport=client.publicationTransport(),r=arg.expected.records.find(r=>r.type==='credential');
   for(const query of [{generationID:arg.current.generationID,headerHash:arg.current.headerHash,inspection:'effective',resourceID:r.id,subjectUserID:user.id,subjectDeviceID:identity.deviceID},
    {generationID:crypto.randomUUID(),headerHash:arg.current.headerHash,inspection:'effective',resourceID:r.id,subjectUserID:user.id,subjectDeviceID:identity.deviceID}]){
    try{await transport.inspection(arg,query);}catch(error){if(![403,409].includes(error.status))throw error;count++;continue;}fail('recipient_administrative_inspection_allowed');
   }
   // Wrong generation cannot be repaired by silently accepting a fresh header.
   try{await transport.part(arg,{generationID:crypto.randomUUID(),headerHash:arg.current.headerHash,resourceID:r.id,part:'SECRET'});}catch(error){if(![403,409].includes(error.status))throw error;count++;}
   if(count!==3)fail('recipient_generation_negative_failed');return {outcome:'DENIED',checkCount:count};
  }
  if(command==='alternate-revoke'){
   const done=await storage('step:'+command);if(done)return done;
   const {driver}=await driverFor(arg);let grant,version;
   try{const r=arg.expected.records.find(r=>r.type==='credential');grant=driver.grants(arg).rows.find(p=>p.principal_kind==='USER'&&p.principal_id===arg.member.accountID&&p.target_id===r.id);version=grant?.version;}finally{driver.dispose();}
   if(!grant)fail('redundant_grant_missing');return commitStep(command,arg,{type:'GRANT_REVOKE',grantID:grant.id,expectedVersion:version});
  }
  if(['secret-deny','secret-restore'].includes(command)){
   const done=await storage('step:'+command);if(done)return done;
   const {driver}=await driverFor(arg);let grant;
   try{const r=arg.expected.records.find(r=>r.type==='credential');grant=driver.grants(arg).rows.find(p=>p.principal_kind==='GROUP'&&p.principal_id===arg.groupID&&p.target_id===r.id);}finally{driver.dispose();}
   if(!grant)fail('credential_group_grant_missing');return commitStep(command,arg,{type:'GRANT_CHANGE',grantID:grant.id,expectedVersion:grant.version,permissionMask:command==='secret-deny'?1:3});
  }
  if(command==='secret-denied'){
   const reader=await readerFor(arg),r=arg.expected.records.find(r=>r.type==='credential');
   try{
    await reader.load();const view=reader.view();if(view.headerHash!==arg.current.headerHash||view.header.payload.generationID!==arg.current.generationID||!view.models.some(m=>m.resourceID===r.id))fail('credential_meta_missing');
    let denied=0;try{await reader.revealSecret(r.id);}catch(error){if(error.message!=='publication_secret_unavailable')throw error;denied++;}
    try{await client.publicationTransport().part(arg,{generationID:arg.current.generationID,headerHash:arg.current.headerHash,resourceID:r.id,part:'SECRET'});}catch(error){if(error.status!==403)throw error;denied++;}
    if(denied!==2)fail('credential_secret_not_denied');return {outcome:'DENIED',checkCount:denied};
   }finally{reader.dispose();}
  }
  if(['move','edit'].includes(command)){
   const done=await storage('step:'+command);if(done?.expected)return done;
   let intent=await transformationIntent(command,arg);
   if(!intent){
    if(done)fail('transformation_intent_missing');
    const {driver,transport}=await driverFor(arg);
    try{
     const rows=driver.resources(arg).rows,resource=rows.find(r=>r.kind==='HOST'),beforeResources=resourceExpectations(rows),beforeExpected=await storage('expected:'+arg.vaultID);
     if(!resource||!equal(beforeResources,resourceExpectations(arg.expected.resources)))fail('transformation_baseline_mismatch');
     const beforeRecord=await driver.readRecord({...arg,resourceID:resource.id}),source=beforeExpected?.records.find(r=>r.id===resource.id);
     if(!source||source.digest!==await migration.migrationHash(beforeRecord))fail('transformation_baseline_mismatch');
     const expectedRecord={...beforeRecord,data:{...beforeRecord.data,...(command==='move'?{folder:''}:{title:'TEST-ONLY-CODEX Updated Host'})}},expectedResources=beforeResources.map(r=>r.id===resource.id&&command==='move'?{...r,parentFolderID:null}:r);
     const draft=command==='move'?{type:'RESOURCE_MOVE',resourceID:resource.id,newParentFolderID:null,expectedResourceVersion:resource.version}:{type:'RESOURCE_EDIT',resourceID:resource.id,record:expectedRecord};
     const current=(await transport.context()).current.find(v=>v.vaultID===arg.vaultID),predecessor={generationID:current.generationID,sequence:current.sequence,headerHash:current.headerHash};
     intent=await transformationIntent(command,arg,{resourceID:resource.id,beforeRecord,beforeResources,beforeExpected,expectedRecord,expectedResources,draft,predecessor});
    }finally{driver.dispose();}
   }
   const result=done??await commitStep(command,arg,intent.draft,{predecessor:intent.predecessor}),{driver:verified}=await driverFor(arg);
   try{verifyTransformation(intent,await verified.readRecord({...arg,resourceID:intent.resourceID}),verified.resources(arg).rows);}finally{verified.dispose();}
   // Advance only to the independently intended output, never an observed one.
   const expected={...intent.beforeExpected,records:intent.beforeExpected.records.map(r=>r.id===intent.resourceID?{...r,digest:null}:r)};
   expected.records.find(r=>r.id===intent.resourceID).digest=await migration.migrationHash(intent.expectedRecord);await storage('expected:'+arg.vaultID,expected);
   result.expected=await expectedFor(arg.vaultID,intent.expectedResources);result.current=(await globalThis.__prcLifecycle('current',arg)).current;await storage('step:'+command,result);return result;
  }
  if(command==='rotate')return commitStep(command,arg,{changes:[]});
  if(command==='lost-response')return commitStep(command,arg,{changes:[]},{lose:true});
  if(command==='refresh-recovery')return commitStep(command,arg,{changes:[]},{refresh:true});
  if(command==='stale-race'){
   const done=await storage('step:'+command);if(done)return done;
   const a=await driverFor(arg),b=await driverFor(arg);
   try{
    // Both previews are captured from the same predecessor; only one commits.
    const first=await a.driver.preview(arg,{changes:[]}),stale=await b.driver.preview(arg,{changes:[]});
    const receipt=await a.driver.commit(arg,first);let denied=false;
    try{await b.driver.commit(arg,stale);}catch(error){if(!['publication_stale','publication_context_changed','publication_snapshot_changed','publication_predecessor_changed','publication_token_stale','preview_invalidated'].includes(error.message))throw error;denied=true;}
    if(!denied)fail('racing_preview_committed_twice');const result={receipt,operationID:receipt.operationID,allVaults:equal(receipt.vaults.map(v=>v.vaultID).sort(),[...arg.activeVaultIDs].sort()),checkCount:1};await storage('step:'+command,result);return result;
   }finally{a.driver.dispose();b.driver.dispose();}
  }
  if(command==='retain-revoked-probes'){
   await recipientScope(arg);const t=client.publicationTransport(),header=await t.header(arg);const query={generationID:header.header.payload.generationID,headerHash:header.headerHash};
   const directory=await t.directory(arg,query),r=arg.expected.records.find(r=>r.type==='credential');
   await storage('revoked-probe',{authorization:lastAuthorization,scope:{teamID:arg.teamID,vaultID:arg.vaultID},query,resourceID:r.id,directory});return {deviceID:identity.deviceID};
  }
  if(command==='revoke-device'){
   await actor(true);if(arg.deviceID===identity.deviceID||arg.accountID!==user.id)fail('noncustodian_revoke_scope');
   const done=await storage('step:'+command);if(done)return done;await trustFlow.revokeDevice(arg.deviceID);const result={deviceID:arg.deviceID};await storage('step:'+command,result);return result;
  }
  if(command==='revoked-probes'){
   const saved=await storage('revoked-probe');if(!saved)fail('revoked_probe_missing');let count=0;
   const headers={'X-Vault-Schema-Version':'2','X-Vault-Capability':'resource_acl_v2','X-Publication-Version':'1',...(saved.authorization?{Authorization:saved.authorization}:{})};
   const base=`/v1/teams/${saved.scope.teamID}/vaults/${saved.scope.vaultID}`,pin=new URLSearchParams(saved.query);
   for(const path of ['/publication/header','/publication/directory?'+pin,`/publication/resources/${saved.resourceID}/parts/SECRET?${pin}`,'/key-devices']){
    const response=await fetch(base+path,{headers,credentials:'same-origin',cache:'no-store'});const value=await response.json();if(![401,403,409].includes(response.status)||typeof value.error!=='string')fail('revoked_access_not_denied');count++;
   }return {outcome:'DENIED',checkCount:count,deviceID:identity.deviceID};
  }
  if(command==='protocol-negatives'){
   await ownerScope(arg);const saved=await storage('legacy:'+arg.vaultID);if(!saved?.wrapper||!saved.envelope)fail('legacy_probe_body_missing');
   const base=`/v1/teams/${arg.teamID}/vaults/${arg.vaultID}`,auth=lastAuthorization?{Authorization:lastAuthorization}:{},cap={'X-Vault-Schema-Version':'2','X-Vault-Capability':'resource_acl_v2','X-Publication-Version':'1'};let count=0;
   for(const headers of [{},{'X-Vault-Schema-Version':'1'},{'X-Vault-Schema-Version':'2'},{...cap,'X-Vault-Capability':'wrong'},{...cap,'X-Publication-Version':'2'},...Object.keys(cap).map(key=>Object.fromEntries(Object.entries(cap).filter(([k])=>k!==key)))]){
    for(const [path,method,body] of [['','GET',null],['','PUT',saved.envelope],['/key-devices','GET',null],['/wrappers','POST',{keyGeneration:saved.keyGeneration,wrapper:saved.wrapper}],['/publication/header','GET',null]]){
     const response=await fetch(base+path,{method,headers:{...auth,...headers,'Content-Type':'application/json','Idempotency-Key':crypto.randomUUID()},credentials:'same-origin',cache:'no-store',...(body?{body:JSON.stringify(body)}:{})});
     const value=await response.json();if(![403,409,426].includes(response.status)||typeof value.error!=='string')fail('legacy_or_capability_probe_not_denied');count++;
    }
   }return {outcome:'DENIED',checkCount:count};
  }
  fail('unknown_real_phase');
 };
}

// Offline cache verification intentionally never constructs an authenticated
// client or requests /v1. The production reader validates cached signed state,
// local key ownership, publisher pin and durable high-water itself.
export async function installBrowserOfflineLifecycle({origin,runID,enrollment,launchNonce}){
 if(location.origin!==origin)throw Error('offline_origin_mismatch');
 const keys=await import('/team-vault-crypto.js'),publication=await import('/vault-publication-client.js'),trust=await import('/device-trust-v1.js');
 const identity=await keys.createIndexedDBTeamDeviceRepository().load(enrollment.deviceID);if(!identity)throw Error('offline_identity_missing');
 const request=indexedDB.open('selective-remote-real-'+runID,1),db=await new Promise((resolve,reject)=>{request.onsuccess=()=>resolve(request.result);request.onerror=reject;});
 const saved=await new Promise((resolve,reject)=>{const r=db.transaction('run').objectStore('run').get('enrolled');r.onsuccess=()=>resolve(r.result);r.onerror=reject;});
 if(JSON.stringify(saved)!==JSON.stringify(enrollment))throw Error('offline_enrollment_changed');
 const session={endpoint:origin,accountID:enrollment.accountID,deviceID:enrollment.deviceID,sessionEpoch:'offline:'+launchNonce},repository=publication.createIndexedDBPublicationRepository();
 globalThis.__prcOffline=async arg=>{
  if(arg.teamID!==enrollment.teamID||!enrollment.vaults.some(v=>v.vaultID===arg.vaultID&&v.name===arg.name))throw Error('offline_scope_mismatch');
  const reader=publication.createVaultPublicationClient({transport:{},identity:()=>session,scope:{teamID:arg.teamID,vaultID:arg.vaultID},privateKey:identity.privateKey,publicKey:identity.publicKey,deviceKeyVersion:null,
   ownTrustRepository:trust.createIndexedDBDeviceTrustRepository(),publisherTrustRepository:repository,repository});
  try{
   await reader.loadStaleCache();const view=reader.view(),water=await repository.loadHighWater({endpoint:origin,accountID:enrollment.accountID,deviceID:enrollment.deviceID,teamID:arg.teamID,vaultID:arg.vaultID});
   if(!view.stale||view.headerHash!==arg.current.headerHash||view.header.payload.generationID!==arg.current.generationID||view.header.payload.sequence!==arg.current.sequence||water?.sequence!==arg.current.sequence||water.hash!==arg.current.headerHash||view.models.length!==arg.expected.resources.length)throw Error('offline_current_history_mismatch');
   for(const r of arg.expected.resources){const model=view.models.find(m=>m.resourceID===r.id);if(!model||model.parentFolderID!==r.parentFolderID)throw Error('offline_identity_changed');}
   return {accountID:session.accountID,deviceID:session.deviceID,vaultID:arg.vaultID,headerHash:view.headerHash,sequence:water.sequence,offlineVerified:true};
  }finally{reader.dispose();db.close();}
 };
}

export const lifecyclePhases=['bootstrap','enroll','empty-prepare','empty-activate','group-create','group-member-add','populated-prepare','populated-activate','materialize','alternate-revoke','secret-deny','secret-restore','move','edit','stale-race','lost-response','refresh-recovery','revoke-device','rotate','protocol-before','protocol-negatives','restart-offline','restart-read'];
export function validateLifecyclePhase(phase,mode,completed,{pendingResume=false}={}){
 const index=lifecyclePhases.indexOf(phase);
 if(index<0||mode!==(phase==='bootstrap'&&!pendingResume?'FRESH_ANONYMOUS':'PRESERVE_TRUSTED_STATE')||!Array.isArray(completed)||completed.some((p,i)=>p!==lifecyclePhases[i])||completed.length!==index)throw Error('invalid_real_phase_or_session_mode');return phase;
}
export function checkpointDigest(value){
 const {launchNonce,...semantic}=value;return createHash('sha256').update(canonicalMigrationJSON(semantic)).digest('hex');
}
export function lifecycleBrowserPlan(phase,pendingResume=false){
 if(!lifecyclePhases.includes(phase))throw Error('invalid_real_phase');
 const indexes=phase==='revoke-device'&&pendingResume?[0,1]:phase==='bootstrap'?[0,1]:phase==='enroll'?[0,1,2]:['materialize','alternate-revoke','secret-deny','secret-restore','move','edit','refresh-recovery','revoke-device','rotate','restart-read'].includes(phase)?[0,1,2]:phase==='restart-offline'?[0,1]:[0];
 return {indexes,authenticated:indexes.filter(i=>!(i===2&&['rotate','restart-read'].includes(phase)))};
}
export function renewLifecycleCheckpoint(journal,phase,launchNonce){
 const pending=journal.pending;
 if(!pending||pending.phase!==phase||!idPattern.test(launchNonce)||!idPattern.test(pending.launchNonce)||!idPattern.test(pending.checkpointID))throw Error('pending_checkpoint_phase_mismatch');
 const semantic=Object.fromEntries(['version','runID','origin','sourceSHA','phase','checkpointID','publicState'].map(k=>[k,pending[k]]));
 if(checkpointDigest(semantic)!==pending.checkpointSHA256)throw Error('pending_checkpoint_semantic_mismatch');
 if(pending.launchNonce!==launchNonce){journal.renewals??=[];journal.renewals.push({checkpointID:pending.checkpointID,previousLaunchNonce:pending.launchNonce,launchNonce});pending.launchNonce=launchNonce;}
 return pending;
}
const idPattern=/^[a-f0-9]{8}-[a-f0-9]{4}-[1-8][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/,digestPattern=/^[a-f0-9]{64}$/;
const strictKeys=(value,keys)=>value&&typeof value==='object'&&!Array.isArray(value)&&Object.keys(value).sort().join(',')===[...keys].sort().join(',');
export function validateNativePublic(value,{runID,accountID,teamID,vaultID,status}){
 value=structuredClone(value);
 // Swift Codable UUIDs may use uppercase; accept canonical UUID spelling in
 // either case, then keep the Browser/operator tuple consistently lowercase.
 for(const k of ['accountID','teamID','vaultID','deviceID','launchNonce','processID','previousProcessID','generationID','acceptedAttemptID'])if(typeof value?.[k]==='string')value[k]=value[k].toLowerCase();
 if(typeof value?.ownPin?.accountID==='string')value.ownPin.accountID=value.ownPin.accountID.toLowerCase();
 const fields='formatVersion,nativeGuiTestHost,productGuiAcceptance,runID,phase,launchNonce,pid,processID,previousProcessID,accountID,teamID,vaultID,deviceID,generationID,publicKey,publicKeyFingerprint,status,sequence,headerHash,manifestSHA256,acceptedAttemptID,counts,binary,ownPin,offlineVerified,networkReloadVerified,secretsVerified'.split(',');
 if(!strictKeys(value,fields)||value.formatVersion!==2||value.nativeGuiTestHost!==true||value.productGuiAcceptance!==false||value.runID!=='TEST-ONLY-CODEX-'+runID
  ||value.accountID!==accountID||value.teamID!==teamID||value.vaultID!==vaultID||!idPattern.test(value.deviceID)||!idPattern.test(value.launchNonce)||!idPattern.test(value.processID)
  ||!Number.isSafeInteger(value.pid)||value.pid<1||!['first','resume','recover'].includes(value.phase)||!status.includes(value.status)
  ||!strictKeys(value.publicKey,['kty','crv','x','y','ext','key_ops'])||value.publicKey.kty!=='EC'||value.publicKey.crv!=='P-256'||value.publicKey.ext!==true||!Array.isArray(value.publicKey.key_ops)||value.publicKey.key_ops.length
  ||!['x','y'].every(k=>typeof value.publicKey[k]==='string'&&/^[A-Za-z0-9_-]{43}$/.test(value.publicKey[k]))||!/^[a-f0-9]{4}(?:-[a-f0-9]{4}){15}$/.test(value.publicKeyFingerprint)
  ||!strictKeys(value.binary,['executablePath','executableSHA256','testBundlePath','testBundleSHA256'])||!['executableSHA256','testBundleSHA256'].every(k=>digestPattern.test(value.binary[k]))
  ||!['executablePath','testBundlePath'].every(k=>typeof value.binary[k]==='string'&&isAbsolute(value.binary[k]))
  ||!strictKeys(value.counts,['hosts','snippets','credentials','forwardings','folders'])||Object.values(value.counts).some(n=>!Number.isSafeInteger(n)||n<0)
  ||!['offlineVerified','networkReloadVerified'].every(k=>typeof value[k]==='boolean')||!Number.isSafeInteger(value.secretsVerified)||value.secretsVerified<0
  ||!Number.isSafeInteger(value.sequence)||value.sequence<1||!idPattern.test(value.generationID)||!digestPattern.test(value.headerHash)||!digestPattern.test(value.manifestSHA256)
  ||value.acceptedAttemptID!==''&&!idPattern.test(value.acceptedAttemptID)||value.previousProcessID!==''&&!idPattern.test(value.previousProcessID))throw Error('native_public_mismatch');
 // Match the production native/Browser domain-separated P-256 key fingerprint.
 const fingerprint=createHash('sha256').update(`selective-remote/team-device-key/v1\0${value.publicKey.x}\0${value.publicKey.y}`).digest('hex').match(/.{4}/g).join('-');
 if(value.publicKeyFingerprint!==fingerprint)throw Error('native_public_mismatch');
 if(value.ownPin!==null&&(!strictKeys(value.ownPin,['accountID','rootFingerprint','highWater','checkpointDigest'])||value.ownPin.accountID!==accountID||!digestPattern.test(value.ownPin.rootFingerprint)||!Number.isSafeInteger(value.ownPin.highWater)||value.ownPin.highWater<1||!/^[A-Za-z0-9_-]{43}$/.test(value.ownPin.checkpointDigest)))throw Error('native_pin_mismatch');
 if(['MATERIALIZED','PASS'].includes(value.status)&&(!value.networkReloadVerified||!idPattern.test(value.acceptedAttemptID)||!value.ownPin))throw Error('native_acceptance_missing');
 return structuredClone(value);
}

export async function installRevokedBrowserProbes({origin,runID,accountID,deviceID,teamID,vaultID,current}){
 if(location.origin!==origin)throw Error('revoked_origin_mismatch');
 const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('selective-remote-real-'+runID,1);r.onsuccess=()=>resolve(r.result);r.onerror=reject;}),read=key=>new Promise((resolve,reject)=>{const r=db.transaction('run').objectStore('run').get(key);r.onsuccess=()=>resolve(r.result);r.onerror=reject;});
 const enrolled=await read('enrolled'),saved=await read('revoked-probe');
 if(enrolled?.accountID!==accountID||enrolled.deviceID!==deviceID||enrolled.teamID!==teamID||!saved||saved.scope.teamID!==teamID||saved.scope.vaultID!==vaultID)throw Error('revoked_scope_changed');
 const cap={'X-Vault-Schema-Version':'2','X-Vault-Capability':'resource_acl_v2','X-Publication-Version':'1',...(saved.authorization?{Authorization:saved.authorization}:{})},base=`/v1/teams/${teamID}/vaults/${vaultID}`,pin=new URLSearchParams({generationID:current.generationID,headerHash:current.headerHash});let count=0;
 for(const path of ['/v1/me',base+'/publication/header',base+'/publication/directory?'+pin,base+`/publication/resources/${saved.resourceID}/parts/SECRET?${pin}`,base+'/key-devices']){
  const response=await fetch(path,{headers:cap,credentials:'same-origin',cache:'no-store'}),value=await response.json();if(![401,403,409].includes(response.status)||typeof value.error!=='string')throw Error('revoked_restart_access_not_denied');count++;
 }db.close();return {deviceID,checkCount:count,outcome:'DENIED'};
}

// Owning the actual executable child gives independently observable process
// exits/PIDs. Reopening another context in the same browser cannot pass restart.
export async function launchLifecycleBrowser({chromium,profile,headless=false}){
 await assertProtectedDirectory(profile);
 const socket=createServer();await new Promise((resolve,reject)=>{socket.once('error',reject);socket.listen(0,'127.0.0.1',resolve);});const port=socket.address().port;await new Promise(resolve=>socket.close(resolve));
 const child=spawn(EDGE,[`--user-data-dir=${profile}`,`--remote-debugging-port=${port}`,'--remote-debugging-address=127.0.0.1','--no-first-run','--no-default-browser-check',...(headless?['--headless=new']:[]),'about:blank'],{stdio:'ignore'});
 const exited=new Promise(resolve=>{child.once('exit',(code,signal)=>resolve({code,signal}));child.once('error',()=>resolve({code:1,signal:null}));});let browser;
 try{
  for(let i=0;i<100;i++){
   if(child.exitCode!==null)throw Error('browser_process_failed');
   try{browser=await chromium.connectOverCDP(`http://127.0.0.1:${port}`);break;}catch{await new Promise(resolve=>setTimeout(resolve,100));}
  }
  if(!browser)throw Error('browser_start_timeout');const context=browser.contexts()[0];if(!context)throw Error('browser_context_missing');
  return {context,pid:child.pid,async close(){try{await context.close();await browser.close();}finally{child.kill('SIGTERM');await exited;}}};
 }catch(error){child.kill('SIGTERM');await exited;throw error;}
}

export async function acquireLifecycleLock(path){
 for(let attempt=0;attempt<2;attempt++){
  try{await mkdir(path,{mode:0o700});await save(join(path,'owner.json'),{version:1,pid:process.pid,processID:randomUUID()});return;}
  catch(error){if(error.code!=='EEXIST')throw error;}
  const old=await readProtectedJSON(join(path,'owner.json'));
  if(!strictKeys(old,['version','pid','processID'])||old.version!==1||!Number.isSafeInteger(old.pid)||old.pid<1||!idPattern.test(old.processID))throw Error('runner_lock_invalid');
  try{process.kill(old.pid,0);}catch(error){if(error.code==='ESRCH'){await rm(path,{recursive:true});continue;}throw error;}
  throw Error('runner_already_active');
 }
 throw Error('runner_lock_unresolved');
}

// Separate, opt-in diagnostics for an interrupted pre-Team bootstrap. This never
// repairs the original registration receipt or advances its journal/checkpoint.
export async function diagnoseStagingBrowserLifecycle({configPath,runDirectory}){
 const config=validateRunConfig(await readProtectedJSON(configPath));
 if(!isAbsolute(runDirectory))throw Error('diagnostic_run_mismatch');
 await assertContinuationUnclaimed(runDirectory);
 await assertProtectedDirectory(dirname(runDirectory));await assertProtectedDirectory(runDirectory);
 const marker=await readProtectedJSON(join(runDirectory,'owner.json')),journal=await readProtectedJSON(join(runDirectory,'journal.json'));
 const baseline=validateOrdinaryBaseline(await readProtectedJSON(join(runDirectory,'baseline.json'))),prior=(await readProtectedJSON(join(runDirectory,'evidence.json'))).map(redactedEvidence);
 const previousLaunchNonce=validateDiagnosticRun({config,mode:process.env.TEST_SESSION_MODE,marker,journal,baseline,evidence:prior});
 // No directory creation or profile replacement is permitted on this path.
 const profiles=[join(runDirectory,'edge-0'),join(runDirectory,'edge-1')];for(const profile of profiles)await assertProtectedDirectory(profile);
 try{await lstat(join(runDirectory,'scope.json'));throw Error('diagnostic_run_mismatch');}catch(error){if(error.code!=='ENOENT')throw error;}
 if(!process.env.PLAYWRIGHT_MODULE||process.env.CHROMIUM_PATH&&process.env.CHROMIUM_PATH!==EDGE)throw Error('headed_edge_required');
 const lock=await acquireUnclaimedLifecycleLock(runDirectory,acquireLifecycleLock);
 const launchNonce=randomUUID(),processID=randomUUID(),events=[],contexts=new Map(),terminal=createInterface({input:process.stdin,output:process.stdout});
 const metadata={evidenceClass:'DIAGNOSTIC_ONLY_NO_ACCEPTANCE',runID:config.runID,expectedSourceSHA:config.expectedSourceSHA,launchNonce,processID,previousLaunchNonce};
 const output=join(runDirectory,'diagnostic-'+launchNonce+'.json');let stage='diagnostic_preflight',index;
 const emit=async event=>{const safe=redactedEvidence({...metadata,...event});events.push(safe);await save(output,events);process.stdout.write(JSON.stringify(safe)+'\n');};
 const readonlyRoute=route=>diagnosticRequestAllowed(route.request().url(),route.request().method(),config.origin)?route.continue():route.abort();
 const stopController=new AbortController();let quitRequested=false;
 const stop=()=>{quitRequested=true;stopController.abort();};process.once('SIGINT',stop);terminal.on('SIGINT',stop);
 const prompt=async i=>{
  for(;;){
   if(quitRequested)return 'quit';
   try{
    const answer=(await terminal.question(`Only TEST profile ${i} is open. Do not register again. Owner: sign into this profile's expected test account if needed; Devices → Device trust → acknowledge root-loss consequences → account password → Create trust root. Enter rechecks this same profile; type quit or press Ctrl-C to close. Never enter credentials here.\n`,{signal:stopController.signal})).trim().toLowerCase();
    if(['q','quit','exit'].includes(answer)){quitRequested=true;return 'quit';}
    if(answer==='')return 'recheck';
   }catch(error){if(quitRequested||error.name==='AbortError'||error.code==='ERR_USE_AFTER_CLOSE'){quitRequested=true;return 'quit';}throw error;}
  }
 };
 const close=async(profile,i)=>{try{await profile.browser.close();}finally{contexts.delete(i);}await emit({phase:'process_closed',browserIndex:i,pid:profile.browser.pid,outcome:'PASS'});};
 try{
  const {chromium}=await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  await emit({phase:'diagnostic_started',stage,outcome:'NOT_RUN',testSessionMode:'PRESERVE_TRUSTED_STATE'});
  const result=await runSequentialDiagnosticProfiles({
   open:async i=>{
    index=i;stage='browser_launch';if(quitRequested)throw Error('diagnostic_cancelled');
    const browser=await launchLifecycleBrowser({chromium,profile:profiles[i]}),profile={browser,page:null};contexts.set(i,profile);
    await browser.context.route('**/*',readonlyRoute);
    for(const oldPage of browser.context.pages())await oldPage.close();
    profile.page=await browser.context.newPage();await emit({phase:'process_started',browserIndex:i,pid:browser.pid,outcome:'PASS'});return profile;
   },
   inspect:async({browser,page},i,count)=>{
    index=i;stage=count?'diagnostic_recheck':'diagnostic_modules';let result;
    try{
     await browser.context.unroute('**/*');await browser.context.route('**/*',readonlyRoute);
     await page.goto(config.origin+'/healthz',{waitUntil:'domcontentloaded'});
     result=await page.evaluate(inspectBrowserLifecycleDiagnostic,{origin:config.origin,email:config.emails[i],approvedEmails:config.emails,moduleHashes:config.moduleHashes,failureCodes:lifecycleDiagnosticCodes});
    }catch(error){result={outcome:'DENIED',accountMatch:'unknown',...lifecycleFailure({stage,index:i,error})};}
    await emit({phase:'diagnostic_metadata',browserIndex:i,count,...result});return result;
   },
   showGUI:async({browser,page},i)=>{
    index=i;stage='owner_trust_setup';await emit({phase:'owner_trust_setup_pending',browserIndex:i,stage,outcome:'PENDING'});
    try{
     await browser.context.unroute('**/*');await browser.context.route('**/*',route=>new URL(route.request().url()).origin===config.origin?route.continue():route.abort());
     await page.goto(config.origin,{waitUntil:'domcontentloaded'});
    }catch(error){await emit({phase:'diagnostic_gui_pending',outcome:'DENIED',...lifecycleFailure({stage,index:i,error})});}
   },prompt,close,
  });
  await emit({phase:result.quit?'diagnostic_cancelled':'diagnostic_completed',outcome:'NOT_RUN'});
 }catch(error){
  await emit({phase:'diagnostic_stopped',outcome:'DENIED',...lifecycleFailure({stage,index,error})});
  // An unexpected diagnostic failure is not permission to close the Owner's active
  // test window. Keep it available until the Owner explicitly quits or interrupts.
  while(contexts.size&&!quitRequested)await prompt(index??0);
  throw Error('real_diagnostic_failed');
 }finally{
  process.removeListener('SIGINT',stop);terminal.off('SIGINT',stop);terminal.close();
  if(quitRequested)for(const[i,profile]of contexts)await close(profile,i);
  await rm(lock,{recursive:true});
 }
}

async function exists(path){try{await lstat(path);return true;}catch(error){if(error.code==='ENOENT')return false;throw error;}}

// Linked runs reuse only the two original profiles. All phases hold their original
// lock as well as the new run lock, and never rewrite the failed run's evidence.
export async function runStagingBrowserLifecycle({configPath,runDirectory,phase}){
 if(phase==='diagnose-bootstrap')return diagnoseStagingBrowserLifecycle({configPath,runDirectory});
 const uploaded=await exists(join(runDirectory,'uploaded-continuation.json'));
 if(uploaded){
  if(process.env.TEST_SESSION_MODE!=='PRESERVE_TRUSTED_STATE'||await exists(join(runDirectory,'continuation.json'))||await exists(join(runDirectory,'recovery.json'))||await exists(join(runDirectory,'initialized-recovery.json')))throw Error('uploaded_continuation_preserved_session_required');
  const config=validateRunConfig(await readProtectedJSON(configPath)),before=await readUploadedContinuationLink({config,configPath,runDirectory}),locks=[];
  assertUploadedInterval(before.successor.binding.interval);
  try{
   for(const directory of before.lockDirectories.slice(0,-1)){const lock=join(directory,'runner.lock');await acquireLifecycleLock(lock);locks.push(lock);}
   const link=await readUploadedContinuationLink({config,configPath,runDirectory});if(link.manifestSHA256!==before.manifestSHA256)throw Error('uploaded_continuation_history_changed');
   const starting=phase==='continue-uploaded-bootstrap';if(!starting&&phase==='bootstrap')throw Error('uploaded_continuation_no_replay');let admission;
   if(starting)await assertUploadedContinuationUnclaimed(link);else{admission=await assertUploadedContinuationClaim({link,runDirectory});await assertContinuationRunBaseline({link,runDirectory});}
   assertUploadedInterval(link.successor.binding.interval);
   return await runLifecycleCore({configPath,runDirectory,phase:starting?'bootstrap':phase,recovery:{link,starting,admission,uploaded:true}});
  }finally{for(const lock of locks.reverse())await rm(lock,{recursive:true});}
 }
 if(phase==='continue-uploaded-bootstrap')throw Error('uploaded_continuation_manifest_required');
 const initialized=await exists(join(runDirectory,'initialized-recovery.json'));
 if(initialized){
  if(process.env.TEST_SESSION_MODE!=='PRESERVE_TRUSTED_STATE'||await exists(join(runDirectory,'continuation.json'))||await exists(join(runDirectory,'recovery.json')))throw Error('initialized_recovery_preserved_session_required');
  const config=validateRunConfig(await readProtectedJSON(configPath)),before=await readInitializedRecoveryLink({config,configPath,runDirectory}),locks=[];
  try{
   for(const directory of before.lockDirectories.slice(0,-1)){const lock=join(directory,'runner.lock');await acquireLifecycleLock(lock);locks.push(lock);}
   const link=await readInitializedRecoveryLink({config,configPath,runDirectory});if(link.manifestSHA256!==before.manifestSHA256)throw Error('initialized_recovery_history_changed');
   const starting=phase==='recover-initialized-bootstrap';let admission;
   if(starting)await assertInitializedRecoveryUnclaimed(link);else{admission=await assertInitializedRecoveryClaim({link,runDirectory});await assertContinuationRunBaseline({link,runDirectory});}
   return await runLifecycleCore({configPath,runDirectory,phase:starting?'bootstrap':phase,recovery:{link,starting,admission,initialized:true}});
  }finally{for(const lock of locks.reverse())await rm(lock,{recursive:true});}
 }
 if(phase==='recover-initialized-bootstrap')throw Error('initialized_recovery_manifest_required');
 const recovering=await exists(join(runDirectory,'recovery.json'));
 if(recovering){
  if(process.env.TEST_SESSION_MODE!=='PRESERVE_TRUSTED_STATE'||await exists(join(runDirectory,'continuation.json')))throw Error('recovery_preserved_session_required');
  const config=validateRunConfig(await readProtectedJSON(configPath)),before=await readRecoveryLink({config,configPath,runDirectory}),locks=[];
  try{
   for(const directory of [before.originalRunDirectory,before.predecessorDirectory]){const lock=join(directory,'runner.lock');await acquireLifecycleLock(lock);locks.push(lock);}
   const link=await readRecoveryLink({config,configPath,runDirectory});if(link.manifestSHA256!==before.manifestSHA256)throw Error('recovery_predecessor_changed');
   const starting=phase==='recover-bootstrap';let admission;
   if(starting)await assertRecoveryUnclaimed(link);else{admission=await assertRecoveryClaim({link,runDirectory});await assertContinuationRunBaseline({link,runDirectory});}
   return await runLifecycleCore({configPath,runDirectory,phase:starting?'bootstrap':phase,recovery:{link,starting,admission}});
  }finally{for(const lock of locks.reverse())await rm(lock,{recursive:true});}
 }
 if(phase==='recover-bootstrap')throw Error('recovery_manifest_required');
 const linked=await exists(join(runDirectory,'continuation.json'));
 if(!linked){if(phase==='continue-bootstrap')throw Error('continuation_manifest_required');return runLifecycleCore({configPath,runDirectory,phase});}
 if(process.env.TEST_SESSION_MODE!=='PRESERVE_TRUSTED_STATE')throw Error('continuation_preserved_session_required');
 const config=validateRunConfig(await readProtectedJSON(configPath)),before=await readContinuationLink({config,configPath,runDirectory}),lock=join(before.manifest.originalRunDirectory,'runner.lock');
 await acquireLifecycleLock(lock);
 try{
  const link=await readContinuationLink({config,configPath,runDirectory});if(link.manifestSHA256!==before.manifestSHA256)throw Error('continuation_original_changed');
  const starting=phase==='continue-bootstrap';let admission;
  if(starting)await assertContinuationUnclaimed(link.manifest.originalRunDirectory);else{admission=await assertContinuationClaim({link,runDirectory});await assertContinuationRunBaseline({link,runDirectory});}
  return await runLifecycleCore({configPath,runDirectory,phase:starting?'bootstrap':phase,continuation:{link,starting,admission}});
 }finally{await rm(lock,{recursive:true});}
}

async function admitContinuation({config,configPath,runDirectory,link,chromium,terminal,emit,pause,launchNonce,processID,recovery=false}){
 const uploaded=recovery==='uploaded',initialized=recovery==='initialized',evidenceClass=uploaded?uploadedContinuationEvidenceClass:initialized?initializedRecoveryEvidenceClass:recovery?recoveryEvidenceClass:continuationEvidenceClass,prefix=uploaded?'uploaded-continuation':initialized?'initialized-recovery':recovery?'recovery':'continuation',previousLaunchNonce=recovery?link.admission.request.launchNonce:link.originalLaunchNonce;
 const checkTime=()=>{if(uploaded)assertUploadedInterval(link.successor.binding.interval);};
 checkTime();
 const readonly=async profile=>{
  await profile.context.unroute('**/*');await profile.context.route('**/*',route=>diagnosticRequestAllowed(route.request().url(),route.request().method(),config.origin)?route.continue():route.abort());
 };
 const identities=await runContinuationReadiness({
  open:async index=>{const browser=await launchLifecycleBrowser({chromium,profile:link.profiles[index]});try{await readonly(browser);for(const p of browser.context.pages())await p.close();browser.page=await browser.context.newPage();await emit({phase:'process_started',browserIndex:index,pid:browser.pid,processID,launchNonce,outcome:'PASS'});return browser;}catch(error){await browser.close();throw error;}},
  inspect:async(profile,index)=>{await readonly(profile);await profile.page.goto(config.origin+'/healthz',{waitUntil:'domcontentloaded'});const result=await profile.page.evaluate(inspectBrowserLifecycleDiagnostic,{...config,email:config.emails[index],approvedEmails:config.emails,failureCodes:lifecycleDiagnosticCodes});await emit({phase:'continuation_readiness',browserIndex:index,launchNonce,...result});return result;},
  showGUI:profile=>openContinuationLoginPage(profile,config.origin,uploaded?link.successor.binding.interval:null),
  prompt:async index=>{await emit({phase:'owner_input_pending',browserIndex:index,outcome:'PENDING'});const answer=await waitForLifecycleOperator(terminal,`Existing TEST profile ${index}: sign into its approved account using its existing trusted device identity. Do not register or change device trust. Enter rechecks; q quits. Never type credentials here.\n`,uploaded?link.successor.binding.interval:null);checkTime();return /^(q|quit|exit)$/i.test(answer.trim())?'quit':'recheck';},
  close:async(profile,index)=>{await profile.close();await emit({phase:'process_closed',browserIndex:index,pid:profile.pid,processID,launchNonce,outcome:'PASS'});},
 });
 const request=(uploaded?createUploadedContinuationRequest:initialized?createInitializedRecoveryRequest:recovery?createRecoveryRequest:createContinuationRequest)({config,link,launchNonce,processID,identities});
 await writeContinuationExclusive(join(runDirectory,prefix+'-request-'+launchNonce+'.json'),request);
 await emit({phase:prefix+'_operator_proof_pending',evidenceClass,runID:config.runID,expectedSourceSHA:config.expectedSourceSHA,previousLaunchNonce,launchNonce,checkpointID:request.checkpointID,checkpointSHA256:request.checkpointSHA256,outcome:'PENDING'});
 await pause('Root must publish the exact protected '+prefix+'-proof-'+launchNonce+'.json from fresh read-only server verification against the unchanged linked ordinary snapshot and approved interval. Recovery also requires the exact retained partial graph and actual same-device sign-in admission/audit. Never copy expected hashes as observations or claim an observed registration response.');
 const proof=await readProtectedJSON(join(runDirectory,prefix+'-proof-'+launchNonce+'.json'));(uploaded?validateUploadedContinuationProof:initialized?validateInitializedRecoveryProof:recovery?validateRecoveryProof:validateContinuationProof)(proof,request,link.baseline);
 const current=await(uploaded?readUploadedContinuationLink:initialized?readInitializedRecoveryLink:recovery?readRecoveryLink:readContinuationLink)({config,configPath,runDirectory});if(current.manifestSHA256!==link.manifestSHA256||current.configSHA256!==link.configSHA256)throw Error(prefix+'_original_changed');
 if(uploaded){
  await inspectThenClaimUploaded({interval:current.successor.binding.interval,inspect:async()=>{
   const browser=await launchLifecycleBrowser({chromium,profile:current.profiles[0]});
   try{
    await browser.context.route('**/*',route=>route.request().method()==='GET'&&new URL(route.request().url()).origin===config.origin?route.continue():route.abort());
    const page=await openLifecycleExecutionPage(browser.context,config.origin);
    await emit({phase:'process_started',browserIndex:0,pid:browser.pid,processID,launchNonce,outcome:'PASS'});
    await page.evaluate(stagingLegacyRoundtripGuard,{installOnly:true});await page.evaluate(stagingUploadedBootstrapContinuation,{installOnly:true});
    const result=await page.evaluate(inspectUploadedBrowser,{...config,email:config.emails[0],uploaded:proof.uploaded,expectedFixture:request.expectedFixture,interval:request.successorBaseline.interval,account:request.accounts[0],failureCodes:lifecycleDiagnosticCodes});
    if(result.outcome!=='PASS')throw Error(lifecycleDiagnosticCodes.includes(result.failureCode)?result.failureCode:'unknown_failure');
    checkTime();await emit({phase:'uploaded_preclaim_browser_verified',evidenceClass,launchNonce,sha256:request.checkpointSHA256,outcome:'PASS'});
   }finally{await browser.close();await emit({phase:'process_closed',browserIndex:0,pid:browser.pid,processID,launchNonce,outcome:'PASS'});}
  },claim:()=>claimUploadedContinuation({link:current,request,proof,runDirectory})});
 }else await(initialized?claimInitializedRecovery:recovery?claimRecovery:claimContinuation)({link:current,request,proof,runDirectory});
 checkTime();
 await emit({phase:uploaded?'uploaded_bootstrap_admitted':initialized?'initialized_empty_bootstrap_admitted':recovery?'partial_bootstrap_admitted':'continuation_registration_admitted',evidenceClass,runID:config.runID,expectedSourceSHA:config.expectedSourceSHA,previousLaunchNonce,launchNonce,sha256:request.checkpointSHA256,outcome:'PASS'});
 return {request,proof};
}

async function runLifecycleCore({configPath,runDirectory,phase,continuation=null,recovery=null}){
 const config=validateRunConfig(await readProtectedJSON(configPath)),mode=process.env.TEST_SESSION_MODE;
 const linked=continuation??recovery,recoveryStart=recovery?.starting===true,continuationStart=continuation?.starting===true||recoveryStart;let continuationAdmission=linked?.admission;
 const linkedEvidenceClass=recovery?.uploaded?uploadedContinuationEvidenceClass:recovery?.initialized?initializedRecoveryEvidenceClass:recovery?recoveryEvidenceClass:continuationEvidenceClass;
 if(!isAbsolute(runDirectory))throw Error('invalid_real_phase');
 let existing=false;try{await lstat(runDirectory);existing=true;}catch(error){if(error.code!=='ENOENT')throw error;}
 if(continuationStart){
  for(const name of ['owner.json','journal.json','evidence.json','baseline.json','scope.json','continuation-admission.json','recovery-admission.json','initialized-recovery-admission.json','uploaded-continuation-admission.json'])if(await exists(join(runDirectory,name)))throw Error('continuation_fresh_link_required');
  if(config.approvedVaultIDs.length)throw Error('continuation_partial_scope');
  await writeContinuationExclusive(join(runDirectory,'owner.json'),{version:1,runID:config.runID,sourceSHA:config.expectedSourceSHA});
  await writeContinuationExclusive(join(runDirectory,'baseline.json'),linked.link.baseline);
  await writeContinuationExclusive(join(runDirectory,'journal.json'),{version:1,completed:[],pending:null,processes:[],baseline:linked.link.baseline});await writeContinuationExclusive(join(runDirectory,'evidence.json'),[]);
 }else if(phase==='bootstrap'&&!existing){
  validateLifecyclePhase(phase,mode,[]);runDirectory=await createProtectedRunDirectory(runDirectory);
  await save(join(runDirectory,'owner.json'),{version:1,runID:config.runID,sourceSHA:config.expectedSourceSHA});
  await save(join(runDirectory,'journal.json'),{version:1,completed:[],pending:null,processes:[]});await save(join(runDirectory,'evidence.json'),[]);
 }else{
  await assertProtectedDirectory(dirname(runDirectory));await assertProtectedDirectory(runDirectory);const marker=await readProtectedJSON(join(runDirectory,'owner.json'));
  if(marker.version!==1||marker.runID!==config.runID||marker.sourceSHA!==config.expectedSourceSHA)throw Error('fresh_run_profile_required');
 }
 const journal=await readProtectedJSON(join(runDirectory,'journal.json')),pendingResume=journal.pending?.phase===phase;
 if(phase==='bootstrap'&&existing&&!pendingResume&&!continuationStart)throw Error('incomplete_bootstrap_requires_operator_recovery');
 if(!continuationStart)validateLifecyclePhase(phase,mode,journal.completed,{pendingResume});
 const lock=join(runDirectory,'runner.lock');await acquireLifecycleLock(lock);
 const contexts=[],terminal=createInterface({input:process.stdin,output:process.stdout}),launchNonce=randomUUID(),processID=randomUUID(),evidence=(await readProtectedJSON(join(runDirectory,'evidence.json'))).map(redactedEvidence);
 const emit=async value=>{const checked=redactedEvidence(value);evidence.push(checked);process.stdout.write(JSON.stringify(checked)+'\n');await save(join(runDirectory,'evidence.json'),evidence);};
 const persist=()=>save(join(runDirectory,'journal.json'),journal);
 const checkTime=()=>{if(recovery?.uploaded)assertUploadedInterval(recovery.link.successor.binding.interval);};
 const pause=async text=>{checkTime();await emit({phase:'owner_input_pending',outcome:'PENDING'});await waitForLifecycleOperator(terminal,text+' Press Enter after the visible GUI/action is complete. Never enter credentials here.\n',recovery?.uploaded?recovery.link.successor.binding.interval:null);checkTime();};
 let baseline,diagnosticStage='lifecycle_operation',diagnosticIndex;
 const checkpoint=async(result={})=>{
  if(!baseline)baseline=validateOrdinaryBaseline(await readProtectedJSON(join(runDirectory,'baseline.json')));
  if(linked&&canonicalMigrationJSON(baseline)!==canonicalMigrationJSON(linked.link.baseline))throw Error('continuation_baseline_changed');
  if(!journal.baseline||canonicalMigrationJSON(journal.baseline)!==canonicalMigrationJSON(baseline))throw Error('original_baseline_changed');
  let pending=journal.pending;
  if(!pending){
   const publicState={teamID:state?.teamID??null,vaults:(state?.vaults??[]).map(v=>({vaultID:v.vaultID,attemptID:v.attemptID,current:state?.current?.[v.vaultID]??null,prepared:state?.prepared?.[v.vaultID]??null})),native:state?.nativeCurrent??null,operationID:result.operationID??null,expectedDeltaCount:phase==='alternate-revoke'?0:null};
   const checkpointID=randomUUID(),body={version:1,runID:config.runID,origin:config.origin,sourceSHA:config.expectedSourceSHA,launchNonce,phase,checkpointID,publicState};
   pending={...body,checkpointSHA256:checkpointDigest(body),operationID:publicState.operationID,expectedDeltaCount:publicState.expectedDeltaCount};journal.pending=pending;await persist();
  }
  renewLifecycleCheckpoint(journal,phase,launchNonce);await persist();
  await save(join(runDirectory,'pending-checkpoint.json'),pending);
  await emit({phase:'operator_checkpoint_pending',checkpointID:pending.checkpointID,checkpointSHA256:pending.checkpointSHA256,launchNonce,outcome:'PENDING'});
  await pause('Root must run the actual ordinary-data verifier and required exact-operation outbox query, then create the exclusive protected proof for this checkpoint. Protocol BEFORE/AFTER also requires the bound negative-invariant sidecar; BEFORE capture must precede any protocol probes.');
  const proof=await readProtectedJSON(join(runDirectory,`operator-proof-${pending.checkpointID}-${launchNonce}.json`));validateOperatorProof(proof,pending,baseline);checkTime();
  if(['protocol-before','protocol-negatives'].includes(phase)){
   const negative=await readProtectedJSON(join(runDirectory,`negative-invariant-${pending.checkpointID}-${launchNonce}.json`));
   validateNegativeInvariantProof(negative,pending,phase==='protocol-before'?'BEFORE':'AFTER',journal.negativeBefore??null);
   if(phase==='protocol-before')journal.negativeBefore=negative;
  }
  await emit({phase:'operator_checkpoint_verified',checkpointID:pending.checkpointID,checkpointSHA256:pending.checkpointSHA256,launchNonce,ordinaryUnchanged:true,outcome:'PASS',...(proof.outbox??{})});journal.pending=null;await persist();
 };
 let state=phase==='bootstrap'&&!pendingResume?null:await readProtectedJSON(join(runDirectory,'scope.json'));
 try{
  if(!process.env.PLAYWRIGHT_MODULE||process.env.CHROMIUM_PATH&&process.env.CHROMIUM_PATH!==EDGE)throw Error('headed_edge_required');
  const {chromium}=await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  if(continuationStart)continuationAdmission=await admitContinuation({config,configPath,runDirectory,link:linked.link,chromium,terminal,emit,pause,launchNonce,processID,recovery:recoveryStart?(recovery.uploaded?'uploaded':recovery.initialized?'initialized':true):false});
  const pages=[],guiPages=[],registered=[],{indexes,authenticated}=lifecycleBrowserPlan(phase,pendingResume);
  for(const index of indexes){
   diagnosticStage='browser_launch';diagnosticIndex=index;
   const profile=linked&&index<2?linked.link.profiles[index]:join(runDirectory,'edge-'+index);if(!pendingResume&&(!linked&&phase==='bootstrap'||phase==='enroll'&&index===2))try{await mkdir(profile,{mode:0o700});}catch(error){if(error.code!=='EEXIST'||phase==='bootstrap')throw error;await assertProtectedDirectory(profile);}
   const browser=await launchLifecycleBrowser({chromium,profile});contexts.push(browser);await emit({phase:'process_started',pid:browser.pid,processID,launchNonce,outcome:'PASS'});
   const context=browser.context;await context.route('**/*',route=>{const url=new URL(route.request().url());if(recovery?.uploaded&&!['GET','HEAD','OPTIONS'].includes(route.request().method())){try{checkTime();}catch{return route.abort();}}return url.origin===config.origin&&(phase!=='restart-offline'||!url.pathname.startsWith('/v1/'))?route.continue():route.abort();});
   const page=await openLifecycleExecutionPage(context,config.origin);pages[index]=page;
   if(phase==='bootstrap'&&!pendingResume&&!continuationStart){
    const anonymous=await page.evaluate(async()=>{const r=await fetch('/v1/me',{credentials:'same-origin',cache:'no-store'});return r.status===401;});if(!anonymous)throw Error('fresh_anonymous_session_required');
   }
   if(!pendingResume&&(phase==='bootstrap'&&!continuationStart||phase==='enroll'&&index===2)){
    const gui=await context.newPage();guiPages.push(gui);
    if(phase==='bootstrap')gui.on('response',async response=>{if(response.url()===config.origin+'/v1/auth/register'&&response.ok()){try{const v=await response.json();if(v?.verificationRequired===true&&Object.keys(v).length===1)registered[index]=true;}catch{}}});
    await gui.goto(config.origin,{waitUntil:'domcontentloaded'});
   }
  }
  await emit({phase:'session_gate',testSessionMode:mode,browserOrigin:config.origin,localhost:'NO',fileURL:'NO',apiMode:'REAL_STAGING',...(phase==='restart-offline'?{}:{authSession:phase==='bootstrap'&&!pendingResume&&!continuationStart?'ANONYMOUS':'REAL_STAGING'}),launchNonce,outcome:'PASS',...(linked?{evidenceClass:linkedEvidenceClass}:{})});
  if(phase==='bootstrap'&&!pendingResume&&!continuationStart){
   await pause('Root must place the original protected baseline.json in this run directory before any registration.');baseline=validateOrdinaryBaseline(await readProtectedJSON(join(runDirectory,'baseline.json')));journal.baseline=baseline;await persist();
   diagnosticStage='owner_registration';diagnosticIndex=undefined;
   await pause('Register/verify/login in the two fresh isolated app windows, and establish each account signed first-device trust. Password input only in app GUI.');
   diagnosticStage='bootstrap_registration_observation';
   if(![0,1].every(i=>registered[i]===true))throw Error('fresh_registration_not_observed');
  }else if(phase==='enroll'&&!pendingResume)await pause('Sign into the secondary TEST account in the third isolated app window; do not create a new account/root. Native onboarding proceeds through its separate isolated GUI.');
  for(const gui of guiPages)await gui.close();
  const invoke=(index,command,arg={})=>invokeLifecycleCommand(pages[index],command,arg);
  if(phase==='restart-offline'){
   const last=journal.processes.at(-1);if(!last||last.processID===processID||last.pids.some(pid=>contexts.some(c=>c.pid===pid)))throw Error('separate_browser_process_required');
   for(const i of authenticated){
    const enrollment=state.enrollments[i];await pages[i].evaluate(installBrowserOfflineLifecycle,{origin:config.origin,runID:config.runID,enrollment,launchNonce});
    for(const v of state.vaults.filter(v=>i===0||v.name.endsWith('-populated'))){const result=await pages[i].evaluate(arg=>globalThis.__prcOffline(arg),{...v,teamID:state.teamID,current:state.current[v.vaultID],expected:state.expected[v.vaultID]});await emit({phase:'offline_history_verified',...result,outcome:'PASS'});}
   }
  }else{
   for(const i of authenticated){
    diagnosticStage='browser_fixture_install';diagnosticIndex=i;
    await pages[i].evaluate(stagingV1Records,{installOnly:true});
    await pages[i].evaluate(stagingLegacyRoundtripGuard,{installOnly:true});
    await pages[i].evaluate(stagingPartialBootstrapGuard,{installOnly:true});
    if(recovery?.uploaded)await pages[i].evaluate(stagingUploadedBootstrapContinuation,{installOnly:true});
    if(recovery?.initialized)await pages[i].evaluate(stagingInitializedBootstrapGuard,{installOnly:true});
    diagnosticStage='browser_lifecycle_install';
    await pages[i].evaluate(installBrowserLifecycle,{...config,email:config.emails[i===0?0:1],...(recovery?.uploaded?{uploadedInterval:recovery.link.successor.binding.interval}:{})});
    if(phase!=='bootstrap'&&!(phase==='enroll'&&i===2)){
     const actual=await invoke(i,'identity',{custodian:i<2}),expected=i===0?state.owner:i===1?state.member:state.extra;
     if(actual.accountID!==expected.accountID||actual.deviceID!==expected.deviceID||actual.publicKeyFingerprint!==expected.publicKeyFingerprint||actual.publicPin.rootFingerprint!==expected.publicPin.rootFingerprint)throw Error('preserved_identity_changed');
    }
   }
   const populated=()=>state.vaults.find(v=>v.name.endsWith('-populated')),empty=()=>state.vaults.find(v=>v.name.endsWith('-empty'));
   const scope=v=>({...v,teamID:state.teamID,activeVaultIDs:phase.startsWith('group-')?[empty().vaultID]:state.activeVaultIDs,member:state.member,groupID:state.groupID,expected:state.expected?.[v.vaultID]});
   const enrollArg=i=>({...state.enrollments[i],teamID:state.teamID,vaults:state.vaults});
   const readAll=async()=>{for(const i of authenticated)for(const v of state.vaults.filter(v=>i===0||v.name.endsWith('-populated'))){const result=await invoke(i,'read',{...v,teamID:state.teamID,enrollment:enrollArg(i),current:state.current[v.vaultID],expected:state.expected[v.vaultID]});await emit({phase:'publication_decrypted',...result,accountID:state.enrollments[i].accountID,deviceID:state.enrollments[i].deviceID,outcome:'PASS'});}};
   const nativeGate=async()=>{
    await pause('Root updates native public generation/count/digest expectations; native performs fresh production HTTPS load and allowed SECRET checks. Copy exact current native public v2 metadata to native-public.json.');
    const v=populated(),expected=state.expected[v.vaultID],current=state.current[v.vaultID],native=validateNativePublic(await readProtectedJSON(join(runDirectory,'native-public.json')),{runID:config.runID,accountID:state.member.accountID,teamID:state.teamID,vaultID:v.vaultID,status:['MATERIALIZED','PASS']});
    if(native.deviceID!==state.native.deviceID||native.publicKeyFingerprint!==state.native.publicKeyFingerprint||native.generationID!==current.generationID||native.sequence!==current.sequence||native.headerHash!==current.headerHash||native.secretsVerified!==expected.secrets.length||canonicalMigrationJSON(native.counts)!==canonicalMigrationJSON(expected.counts)||native.ownPin.rootFingerprint!==state.member.publicPin.rootFingerprint)throw Error('native_current_materialization_missing');
    state.nativeCurrent={deviceID:native.deviceID,generationID:native.generationID,sequence:native.sequence,headerHash:native.headerHash,launchNonce:native.launchNonce,processID:native.processID,manifestSHA256:native.manifestSHA256};
    await save(join(runDirectory,'scope.json'),state);await emit({phase:'native_materialized',deviceID:native.deviceID,generationID:native.generationID,sequence:native.sequence,headerHash:native.headerHash,outcome:'PASS'});
   };
   const saveState=()=>save(join(runDirectory,'scope.json'),state);
   const applyReceipt=async result=>{for(const v of result.receipt.vaults)state.current[v.vaultID]=v;if(result.expected)state.expected[populated().vaultID]=result.expected;await saveState();await emit({phase:'whole_publication_committed',operationID:result.operationID,allVaults:result.allVaults,...(result.responseDiscarded===undefined?{}:{responseDiscarded:result.responseDiscarded}),...(result.refreshRecovered===undefined?{}:{refreshRecovered:result.refreshRecovered}),outcome:'PASS'});};
   let result={};
   if(pendingResume){await checkpoint({operationID:journal.pending.operationID});
   }else if(phase==='bootstrap'){
    diagnosticStage='owner_identity';diagnosticIndex=0;const owner=await invoke(0,'identity',{custodian:true});
    diagnosticStage='member_identity';diagnosticIndex=1;const member=await invoke(1,'identity',{custodian:true});
    if(continuationStart){assertContinuationIdentity(owner,continuationAdmission.request.accounts[0]);assertContinuationIdentity(member,continuationAdmission.request.accounts[1]);}
    diagnosticStage='team_bootstrap';diagnosticIndex=0;
    if(recoveryStart&&recovery.initialized){const observation=await invoke(0,'inspect-initialized-bootstrap',{initialized:continuationAdmission.proof.initialized});await writeContinuationExclusive(join(runDirectory,'initialized-browser-observation-'+launchNonce+'.json'),{version:1,evidenceClass:initializedRecoveryEvidenceClass,launchNonce,processID,checkpointSHA256:continuationAdmission.request.checkpointSHA256,observation});await emit({phase:'initialized_empty_browser_verified',evidenceClass:initializedRecoveryEvidenceClass,sha256:continuationAdmission.request.checkpointSHA256,outcome:'PASS'});}
    const created=await invoke(0,recoveryStart?(recovery.uploaded?'continue-uploaded-bootstrap':recovery.initialized?'recover-initialized-bootstrap':'recover-bootstrap'):'bootstrap',{memberEmail:config.emails[1],...(recoveryStart?(recovery.uploaded?{uploaded:continuationAdmission.proof.uploaded,expectedFixture:continuationAdmission.request.expectedFixture,interval:continuationAdmission.request.successorBaseline.interval}:recovery.initialized?{initialized:continuationAdmission.proof.initialized,interval:continuationAdmission.request.successorBaseline.interval}:{partial:recovery.link.partial}):{})});state={...created,owner,member,expected:{},current:{},activeVaultIDs:[],enrollments:{}};await saveState();
    diagnosticStage='lifecycle_operation';diagnosticIndex=undefined;
    const invitationGUI=await contexts[1].context.newPage();
    try{await invitationGUI.goto(config.origin,{waitUntil:'domcontentloaded'});await pause('Accept the genuine Team invitation in the secondary account app window.');}
    finally{await invitationGUI.close();}
    Object.assign(state.member,await invoke(1,'join-check',{teamID:state.teamID}));Object.assign(state.owner,await invoke(0,'join-check',{teamID:state.teamID}));await saveState();
    for(const i of [0,1]){const who=i===0?state.owner:state.member;state.enrollments[i]={accountID:who.accountID,deviceID:who.deviceID,membershipID:who.membershipID,membershipEpoch:who.membershipEpoch,teamID:state.teamID,vaults:state.vaults};await invoke(i,'enroll-reader',enrollArg(i));}await saveState();await checkpoint();
   }else if(phase==='enroll'){
    const extra=await invoke(2,'untrusted-identity');if(extra.accountID!==state.member.accountID||extra.deviceID===state.member.deviceID)throw Error('extra_device_account_mismatch');
    await pause('Independently compare secondary custodian public root/checkpoint and extra Browser key fingerprint in both visible windows.');
    const freshMember=await invoke(1,'identity',{custodian:true});await invoke(2,'pair',freshMember.publicPin);await invoke(2,'request-approval');await invoke(1,'start-approval',extra);await invoke(2,'answer-challenge');await invoke(1,'finish-approval',extra);state.extra=await invoke(2,'identity');
    Object.assign(state.extra,await invoke(2,'join-check',{teamID:state.teamID}));
    const nativeScope={runID:config.runID,accountID:state.member.accountID,teamID:state.teamID,vaultID:populated().vaultID};
    await pause('Native GUI must reach APPROVAL_REQUESTED; root copies exact public v2 metadata to protected native-public.json in this run directory.');
    let native=validateNativePublic(await readProtectedJSON(join(runDirectory,'native-public.json')),{...nativeScope,status:['APPROVAL_REQUESTED']});
    await pause('Compare actual native public-key fingerprint independently in native and secondary custodian GUI.');await invoke(1,'start-approval',native);
    await pause('Native GUI answers the actual possession challenge; copy current public v2 metadata again.');native=validateNativePublic(await readProtectedJSON(join(runDirectory,'native-public.json')),{...nativeScope,status:['CHALLENGE_ANSWERED']});await invoke(1,'finish-approval',native);
    const admission=[];
    for(const who of [state.member,state.extra,native])admission.push(await invoke(0,'admit',{...who,teamID:state.teamID,accountID:state.member.accountID,membershipID:state.member.membershipID,membershipEpoch:state.member.membershipEpoch}));
    state.native={deviceID:native.deviceID,publicKey:native.publicKey,publicKeyFingerprint:native.publicKeyFingerprint,launchNonce:native.launchNonce,processID:native.processID};state.requiredDeviceIDs=admission.map(d=>d.deviceID);
    const nativeAdmission=admission.find(d=>d.deviceID===native.deviceID),publicAdmission={source:'BROWSER_CUSTODIAN_HTTPS_ADMISSION_READBACK',runID:native.runID,accountID:state.member.accountID,teamID:state.teamID,vaultID:populated().vaultID,membershipID:state.member.membershipID,membershipEpoch:state.member.membershipEpoch,deviceID:native.deviceID,publicKey:native.publicKey};
    const admissionDigest=createHash('sha256').update(JSON.stringify(nativeAdmission)+'\n').digest('hex');await save(join(runDirectory,'native-admission-readback.json'),nativeAdmission);await save(join(runDirectory,'native-admission.json'),{...publicAdmission,browserEvidenceSHA256:admissionDigest});await emit({phase:'native_admitted',deviceID:native.deviceID,sha256:admissionDigest,outcome:'PASS'});
    state.enrollments[2]={accountID:state.extra.accountID,deviceID:state.extra.deviceID,membershipID:state.member.membershipID,membershipEpoch:state.member.membershipEpoch,teamID:state.teamID,vaults:state.vaults};await invoke(2,'enroll-reader',enrollArg(2));
    await pause('Confirm owner publisher root/checkpoint on every recipient and secondary root/checkpoint on Owner. Root copies native-admission.json to native admission.json; native records expectation before proceeding.');
    const ownerPin=(await invoke(0,'identity',{custodian:true})).publicPin,memberPin=(await invoke(1,'identity',{custodian:true})).publicPin;
    await invoke(0,'pin-peer',{teamID:state.teamID,pin:memberPin,confirmed:true});for(const i of [1,2])await invoke(i,'pin-peer',{teamID:state.teamID,pin:ownerPin,confirmed:true});
    await pause('Copy native public metadata after Record admission expectation.');
    const recorded=validateNativePublic(await readProtectedJSON(join(runDirectory,'native-public.json')),{...nativeScope,status:['TEAM_ADMISSION_EXPECTATION_RECORDED']});if(recorded.deviceID!==state.native.deviceID||recorded.publicKeyFingerprint!==state.native.publicKeyFingerprint)throw Error('native_admission_expectation_changed');
    await saveState();await checkpoint();
   }else if(phase.endsWith('-prepare')){
    const v=phase.startsWith('empty-')?empty():populated();let bridge=createOperatorBridge({config,scope:{...v,teamID:state.teamID,actorUserID:state.owner.accountID,actorDeviceID:state.owner.deviceID}});
    await pages[0].exposeFunction('__prcOperator',request=>bridge(request));result=await invoke(0,'prepare',{...scope(v),requiredDeviceIDs:state.requiredDeviceIDs,...(phase.startsWith('empty-')?{groupID:null}:{})});state.expected[v.vaultID]=result.expected;state.prepared??={};state.prepared[v.vaultID]=result.current;await saveState();await checkpoint();
   }else if(phase.endsWith('-activate')){
    const v=phase.startsWith('empty-')?empty():populated();await pause('Root reviewed the exact manifest and installed activation/backup/restore/controller prerequisites. Existing operator guard remains final authority.');
    const bridge=createOperatorBridge({config,scope:{...v,teamID:state.teamID,actorUserID:state.owner.accountID,actorDeviceID:state.owner.deviceID},activation:true});await pages[0].exposeFunction('__prcOperator',request=>bridge(request));result=await invoke(0,'activate',scope(v));state.activeVaultIDs=[...new Set([...state.activeVaultIDs,v.vaultID])];state.current[v.vaultID]=state.prepared[v.vaultID];await saveState();await checkpoint();
   }else if(phase.startsWith('group-')){
    result=await invoke(0,phase,scope(empty()));await applyReceipt(result);const actual=await invoke(0,'current',scope(empty()));
    const group=actual.groups.filter(g=>g.name===`TEST-ONLY-CODEX-${config.runID}-group`);if(group.length!==1)throw Error('group_readback_failed');state.groupID=group[0].id;
    if(phase==='group-member-add'){const current=await invoke(0,'current',scope(empty()));if(!current.edges.some(e=>e.membershipID===state.member.membershipID&&e.membershipEpoch===state.member.membershipEpoch))throw Error('group_edge_readback_failed');}await saveState();await checkpoint(result);
   }else if(phase==='materialize'){
    const actual=await invoke(0,'current',scope(populated()));for(const v of actual.current)state.current[v.vaultID]=v;await saveState();await readAll();
    for(const i of [1,2])await emit({phase:'recipient_negative_denied',...await invoke(i,'recipient-negatives',{...populated(),teamID:state.teamID,enrollment:enrollArg(i),current:state.current[populated().vaultID],expected:state.expected[populated().vaultID]}),outcome:'DENIED'});
    await nativeGate();await emit({phase:'effective_paths_verified',...await invoke(0,'inspect',{...scope(populated()),direct:true}),outcome:'PASS'});await checkpoint();
   }else if(['alternate-revoke','secret-deny','secret-restore','move','edit','stale-race','lost-response','refresh-recovery','rotate'].includes(phase)){
    result=await invoke(0,phase,scope(populated()));await applyReceipt(result);
    if(phase==='alternate-revoke')await emit({phase:'effective_paths_verified',...await invoke(0,'inspect',{...scope(populated()),direct:false}),outcome:'PASS'});
    if(phase==='secret-deny')for(const i of [1,2])await emit({phase:'credential_secret_denied',...await invoke(i,'secret-denied',{...populated(),teamID:state.teamID,enrollment:enrollArg(i),current:state.current[populated().vaultID],expected:state.expected[populated().vaultID]}),outcome:'DENIED'});
    if(['alternate-revoke','secret-restore','move','edit','refresh-recovery','rotate'].includes(phase)){await readAll();await nativeGate();}
    if(phase==='rotate')await emit({phase:'revoked_successor_denied',...await pages[2].evaluate(installRevokedBrowserProbes,{origin:config.origin,runID:config.runID,accountID:state.extra.accountID,deviceID:state.extra.deviceID,teamID:state.teamID,vaultID:populated().vaultID,current:state.current[populated().vaultID]}),outcome:'DENIED'});await checkpoint(result);
   }else if(phase==='revoke-device'){
    const v=populated();await invoke(2,'retain-revoked-probes',{...v,teamID:state.teamID,enrollment:enrollArg(2),expected:state.expected[v.vaultID]});
    result=await invoke(1,'revoke-device',{deviceID:state.extra.deviceID,accountID:state.member.accountID});await emit({phase:'revoked_device_denied',...await invoke(2,'revoked-probes'),outcome:'DENIED'});
    await invoke(0,'repair-required',{...v,teamID:state.teamID,enrollment:enrollArg(0),expected:state.expected[v.vaultID],current:state.current[v.vaultID]});await checkpoint();
   }else if(phase==='protocol-before'){
    await checkpoint();
   }else if(phase==='protocol-negatives'){
    if(!journal.negativeBefore)throw Error('negative_before_observation_required');
    const before=await invoke(0,'current',scope(populated()));for(const v of state.vaults)await emit({phase:'legacy_protocol_denied',...await invoke(0,'protocol-negatives',scope(v)),outcome:'DENIED'});
    const after=await invoke(0,'current',scope(populated()));if(canonicalMigrationJSON(before.current)!==canonicalMigrationJSON(after.current))throw Error('rejected_request_mutated_publication');await checkpoint();
   }else if(phase==='restart-read'){
    await readAll();await nativeGate();await emit({phase:'revoked_restart_denied',...await pages[2].evaluate(installRevokedBrowserProbes,{origin:config.origin,runID:config.runID,accountID:state.extra.accountID,deviceID:state.extra.deviceID,teamID:state.teamID,vaultID:populated().vaultID,current:state.current[populated().vaultID]}),outcome:'DENIED'});await pause('Root completes native separate-process offline/HTTPS gate on exact current generation and independent server reload/older isolated restore/fence checks. These are separate evidence, never Browser PASS.');await checkpoint();
   }else throw Error('unhandled_phase');
  }
  checkTime();journal.completed.push(phase);journal.processes.push({phase,processID,launchNonce,pids:contexts.map(c=>c.pid)});await persist();checkTime();await emit({phase:'phase_completed',outcome:'PASS',launchNonce,processID,...(linked?{evidenceClass:linkedEvidenceClass}:{})});
 }catch(error){await emit({phase:'stopped_without_acceptance',outcome:'DENIED',launchNonce,...lifecycleFailure({stage:diagnosticStage,index:diagnosticIndex,error})});throw Error('real_phase_failed');}
 finally{terminal.close();for(const context of contexts){await context.close();await emit({phase:'process_closed',pid:context.pid,processID,launchNonce,outcome:'PASS'});}await rm(lock,{recursive:true});}
}
