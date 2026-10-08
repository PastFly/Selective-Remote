// Real HTTPS only; no intercepted responses, seeded accounts, or exported keys.
import {mkdir,writeFile,rename,rm,lstat} from 'node:fs/promises';
import {join,isAbsolute,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createInterface} from 'node:readline/promises';
import {randomUUID,createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {canonicalMigrationJSON} from '../../public/vault-v2-migration.js';
import {validateRunConfig,readProtectedJSON,redactedEvidence,createOperatorBridge,assertProtectedDirectory,createProtectedRunDirectory,validateOperatorProof,validateOrdinaryBaseline,validateNegativeInvariantProof} from '../../scripts/staging-publication-acceptance.mjs';

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

// This function is serialized into the actual page. Only public results cross
// the Playwright boundary; all keys, legacy bodies and records stay here.
export async function installBrowserLifecycle({origin,runID,email,moduleHashes}){
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
  if(command==='bootstrap'){
   await actor(true);if(await storage('created'))fail('bootstrap_already_recorded');
   const createdTeam=await client.createTeam({name:`TEST-ONLY-CODEX-${runID}-team`,idempotencyKey:`prc:${runID}:team`});
   const created={teamID:createdTeam.id,actorUserID:user.id,actorDeviceID:identity.deviceID,vaults:[]};await storage('created',created);
   for(const kind of ['populated','empty']){
    const name=`TEST-ONLY-CODEX-${runID}-${kind}`,vault=await client.createSharedVault({teamID:created.teamID,name,idempotencyKey:`prc:${runID}:${kind}`}),item={vaultID:vault.id,name,attemptID:crypto.randomUUID()};
    created.vaults.push(item);await storage('created',created);
    const scope={type:'team',teamID:created.teamID,vaultID:vault.id},controller=team.createTeamVaultController({repository:team.createIndexedDBTeamVaultRepository(scope),identity,scope});
    try{
     await team.synchronizeTeamVault({client,controller,role:'owner'});if(kind==='populated')for(const r of globalThis.__prcCreateV1Records())await controller.upsert(r);
     await team.synchronizeTeamVault({client,controller,role:'owner'});
     const remote=await client.getTeamVault(scope),state=await controller.syncState(),cached=await team.createIndexedDBTeamVaultRepository(scope).load();
     if(state.dirty||remote.revision!==state.serverRevision||controller.document().records.length!==(kind==='populated'?4:0)||['ciphertext','nonce','authTag','contentHash'].some(k=>remote[k]!==cached.envelope[k]))fail('legacy_roundtrip_failed');
     await storage('legacy:'+vault.id,{envelope:cached.envelope,wrapper:remote.wrapper,keyGeneration:remote.keyGeneration,revision:remote.revision});
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
  ||!Number.isSafeInteger(value.pid)||value.pid<1||!['first','resume'].includes(value.phase)||!status.includes(value.status)
  ||!strictKeys(value.publicKey,['kty','crv','x','y','ext','key_ops'])||value.publicKey.kty!=='EC'||value.publicKey.crv!=='P-256'||value.publicKey.ext!==true||!Array.isArray(value.publicKey.key_ops)||value.publicKey.key_ops.length
  ||!['x','y'].every(k=>typeof value.publicKey[k]==='string'&&/^[A-Za-z0-9_-]{43}$/.test(value.publicKey[k]))||!digestPattern.test(value.publicKeyFingerprint)
  ||!strictKeys(value.binary,['executablePath','executableSHA256','testBundlePath','testBundleSHA256'])||!['executableSHA256','testBundleSHA256'].every(k=>digestPattern.test(value.binary[k]))
  ||!['executablePath','testBundlePath'].every(k=>typeof value.binary[k]==='string'&&isAbsolute(value.binary[k]))
  ||!strictKeys(value.counts,['hosts','snippets','credentials','forwardings','folders'])||Object.values(value.counts).some(n=>!Number.isSafeInteger(n)||n<0)
  ||!['offlineVerified','networkReloadVerified'].every(k=>typeof value[k]==='boolean')||!Number.isSafeInteger(value.secretsVerified)||value.secretsVerified<0
  ||!Number.isSafeInteger(value.sequence)||value.sequence<1||!idPattern.test(value.generationID)||!digestPattern.test(value.headerHash)||!digestPattern.test(value.manifestSHA256)
  ||value.acceptedAttemptID!==''&&!idPattern.test(value.acceptedAttemptID)||value.previousProcessID!==''&&!idPattern.test(value.previousProcessID))throw Error('native_public_mismatch');
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

export async function runStagingBrowserLifecycle({configPath,runDirectory,phase}){
 const config=validateRunConfig(await readProtectedJSON(configPath)),mode=process.env.TEST_SESSION_MODE;
 if(!isAbsolute(runDirectory))throw Error('invalid_real_phase');
 let existing=false;try{await lstat(runDirectory);existing=true;}catch(error){if(error.code!=='ENOENT')throw error;}
 if(phase==='bootstrap'&&!existing){
  validateLifecyclePhase(phase,mode,[]);runDirectory=await createProtectedRunDirectory(runDirectory);
  await save(join(runDirectory,'owner.json'),{version:1,runID:config.runID,sourceSHA:config.expectedSourceSHA});
  await save(join(runDirectory,'journal.json'),{version:1,completed:[],pending:null,processes:[]});await save(join(runDirectory,'evidence.json'),[]);
 }else{
  await assertProtectedDirectory(dirname(runDirectory));await assertProtectedDirectory(runDirectory);const marker=await readProtectedJSON(join(runDirectory,'owner.json'));
  if(marker.version!==1||marker.runID!==config.runID||marker.sourceSHA!==config.expectedSourceSHA)throw Error('fresh_run_profile_required');
 }
 const journal=await readProtectedJSON(join(runDirectory,'journal.json')),pendingResume=journal.pending?.phase===phase;
 if(phase==='bootstrap'&&existing&&!pendingResume)throw Error('incomplete_bootstrap_requires_operator_recovery');
 validateLifecyclePhase(phase,mode,journal.completed,{pendingResume});
 const lock=join(runDirectory,'runner.lock');await acquireLifecycleLock(lock);
 const contexts=[],terminal=createInterface({input:process.stdin,output:process.stdout}),launchNonce=randomUUID(),processID=randomUUID(),evidence=(await readProtectedJSON(join(runDirectory,'evidence.json'))).map(redactedEvidence);
 const emit=async value=>{const checked=redactedEvidence(value);evidence.push(checked);process.stdout.write(JSON.stringify(checked)+'\n');await save(join(runDirectory,'evidence.json'),evidence);};
 const persist=()=>save(join(runDirectory,'journal.json'),journal);
 const pause=async text=>{await emit({phase:'owner_input_pending',outcome:'PENDING'});await terminal.question(text+' Press Enter after the visible GUI/action is complete. Never enter credentials here.\n');};
 let baseline;
 const checkpoint=async(result={})=>{
  if(!baseline)baseline=validateOrdinaryBaseline(await readProtectedJSON(join(runDirectory,'baseline.json')));
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
  const proof=await readProtectedJSON(join(runDirectory,`operator-proof-${pending.checkpointID}-${launchNonce}.json`));validateOperatorProof(proof,pending,baseline);
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
  const pages=[],registered=[],{indexes,authenticated}=lifecycleBrowserPlan(phase,pendingResume);
  for(const index of indexes){
   const profile=join(runDirectory,'edge-'+index);if(!pendingResume&&(phase==='bootstrap'||phase==='enroll'&&index===2))try{await mkdir(profile,{mode:0o700});}catch(error){if(error.code!=='EEXIST'||phase==='bootstrap')throw error;await assertProtectedDirectory(profile);}
   const browser=await launchLifecycleBrowser({chromium,profile});contexts.push(browser);await emit({phase:'process_started',pid:browser.pid,processID,launchNonce,outcome:'PASS'});
   const context=browser.context;await context.route('**/*',route=>{const url=new URL(route.request().url());return url.origin===config.origin&&(phase!=='restart-offline'||!url.pathname.startsWith('/v1/'))?route.continue():route.abort();});
   const page=await context.newPage();pages[index]=page;
   if(phase==='bootstrap')page.on('response',async response=>{if(response.url()===config.origin+'/v1/auth/register'&&response.ok()){try{const v=await response.json();if(v?.verificationRequired===true&&Object.keys(v).length===1)registered[index]=true;}catch{}}});
   await page.goto(config.origin,{waitUntil:'domcontentloaded'});
   if(phase==='bootstrap'&&!pendingResume){
    const anonymous=await page.evaluate(async()=>{const r=await fetch('/v1/me',{credentials:'same-origin',cache:'no-store'});return r.status===401;});if(!anonymous)throw Error('fresh_anonymous_session_required');
   }
  }
  await emit({phase:'session_gate',testSessionMode:mode,browserOrigin:config.origin,localhost:'NO',fileURL:'NO',apiMode:'REAL_STAGING',...(phase==='restart-offline'?{}:{authSession:phase==='bootstrap'&&!pendingResume?'ANONYMOUS':'REAL_STAGING'}),launchNonce,outcome:'PASS'});
  if(phase==='bootstrap'&&!pendingResume){
   await pause('Root must place the original protected baseline.json in this run directory before any registration.');baseline=validateOrdinaryBaseline(await readProtectedJSON(join(runDirectory,'baseline.json')));journal.baseline=baseline;await persist();
   await pause('Register/verify/login in the two fresh isolated app windows, and establish each account signed first-device trust. Password input only in app GUI.');
   if(![0,1].every(i=>registered[i]===true))throw Error('fresh_registration_not_observed');
  }else if(phase==='enroll'&&!pendingResume)await pause('Sign into the secondary TEST account in the third isolated app window; do not create a new account/root. Native onboarding proceeds through its separate isolated GUI.');
  const invoke=(index,command,arg={})=>pages[index].evaluate(({command,arg})=>globalThis.__prcLifecycle(command,arg),{command,arg});
  if(phase==='restart-offline'){
   const last=journal.processes.at(-1);if(!last||last.processID===processID||last.pids.some(pid=>contexts.some(c=>c.pid===pid)))throw Error('separate_browser_process_required');
   for(const i of authenticated){
    const enrollment=state.enrollments[i];await pages[i].evaluate(installBrowserOfflineLifecycle,{origin:config.origin,runID:config.runID,enrollment,launchNonce});
    for(const v of state.vaults.filter(v=>i===0||v.name.endsWith('-populated'))){const result=await pages[i].evaluate(arg=>globalThis.__prcOffline(arg),{...v,teamID:state.teamID,current:state.current[v.vaultID],expected:state.expected[v.vaultID]});await emit({phase:'offline_history_verified',...result,outcome:'PASS'});}
   }
  }else{
   for(const i of authenticated){
    await pages[i].evaluate(stagingV1Records,{installOnly:true});
    await pages[i].evaluate(installBrowserLifecycle,{...config,email:config.emails[i===0?0:1]});
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
    const owner=await invoke(0,'identity',{custodian:true}),member=await invoke(1,'identity',{custodian:true}),created=await invoke(0,'bootstrap',{memberEmail:config.emails[1]});state={...created,owner,member,expected:{},current:{},activeVaultIDs:[],enrollments:{}};await saveState();
    await pause('Accept the genuine Team invitation in the secondary account app window.');
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
  journal.completed.push(phase);journal.processes.push({phase,processID,launchNonce,pids:contexts.map(c=>c.pid)});await persist();await emit({phase:'phase_completed',outcome:'PASS',launchNonce,processID});
 }catch(error){await emit({phase:'stopped_without_acceptance',outcome:'DENIED',launchNonce});throw Error('real_phase_failed');}
 finally{terminal.close();for(const context of contexts){await context.close();await emit({phase:'process_closed',pid:context.pid,processID,launchNonce,outcome:'PASS'});}await rm(lock,{recursive:true});}
}
