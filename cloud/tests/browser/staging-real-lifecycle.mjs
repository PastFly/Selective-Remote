// Real HTTPS only; no intercepted responses, seeded accounts, or exported keys.
import {mkdir,writeFile,rename,rm} from 'node:fs/promises';
import {join,isAbsolute,dirname} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createInterface} from 'node:readline/promises';
import {validateRunConfig,readProtectedJSON,redactedEvidence,createOperatorBridge,assertProtectedDirectory,createProtectedRunDirectory} from '../../scripts/staging-publication-acceptance.mjs';

const EDGE='/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge';
async function save(path,value){const next=path+'.next';await writeFile(next,JSON.stringify(value)+'\n',{mode:0o600,flag:'wx'});await rename(next,path);}

// One payload builder is exercised by Browser crypto and native importer tests.
// Installation returns no records, so runtime plaintext stays inside the page.
export function stagingV1Records({installOnly=false}={}){
 const create=()=>{
  const forwardingID=crypto.randomUUID();
  // Same Codable shape as the native exporter: IndependentPortForward,
  // TerminalTabConnection.custom and PortForwardRule.local, encoded as the
  // exporter's base64url UTF-8 JSON configuration. No connection runs.
  const forwarding={id:forwardingID,connection:{kind:'custom',host:'synthetic.invalid',username:'synthetic',port:22},
   rule:{id:forwardingID,name:'TEST-ONLY-CODEX Forwarding',kind:'local',bindAddress:'127.0.0.1',sourcePort:19090,destinationHost:'127.0.0.1',destinationPort:19091}};
  return [
   {id:crypto.randomUUID(),type:'host',data:{title:'TEST-ONLY-CODEX Host',address:'synthetic.invalid',connectionType:'ssh',port:22,username:'synthetic',folder:'Acceptance/Nested'}},
   {id:crypto.randomUUID(),type:'credential',data:{title:'TEST-ONLY-CODEX Credential',username:'synthetic',secret:crypto.randomUUID()}},
   {id:crypto.randomUUID(),type:'snippet',data:{title:'TEST-ONLY-CODEX Snippet',body:'printf test-only',folder:'Acceptance/Nested'}},
   {id:forwardingID,type:'forwarding',data:{title:forwarding.rule.name,destination:'127.0.0.1:19091',kind:'local',configuration:btoa(JSON.stringify(forwarding)).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'')}},
  ];
 };
 if(installOnly){globalThis.__prcCreateV1Records=create;return;}
 return create();
}

// Serialized by Playwright into the real staging page. Private values stay in
// this closure and production IndexedDB repositories; only public results return.
export async function installBrowserLifecycle({origin,runID,email,moduleHashes}){
 if(location.origin!==origin)throw Error('real_origin_required');
 for(const [path,expected]of Object.entries(moduleHashes)){
  const response=await fetch(path,{cache:'no-store',credentials:'same-origin'});
  if(!response.ok)throw Error('deployed_module_unavailable');
  const digest=[...new Uint8Array(await crypto.subtle.digest('SHA-256',await response.arrayBuffer()))].map(b=>b.toString(16).padStart(2,'0')).join('');
  if(digest!==expected)throw Error('deployed_module_mismatch');
 }
 const [sync,keys,team,trust,flow,migration,publication]=await Promise.all([
  import('/vault-sync.js'),import('/team-vault-crypto.js'),import('/team-vault-sync.js'),import('/device-trust-v1.js'),
  import('/device-trust-flow.js'),import('/vault-v2-migration.js'),import('/vault-publication-client.js')]);
 const client=sync.createAuthenticatedVaultClient({fetchValue:(path,options)=>fetch(path,options)});
 const user=await client.restoreSession();
 if(user.email.toLowerCase()!==email.toLowerCase())throw Error('test_account_mismatch');
 const identity=await keys.createIndexedDBTeamDeviceRepository().load(client.deviceID());
 if(!identity)throw Error('product_device_setup_required');
 const ownTrust=trust.createIndexedDBDeviceTrustRepository(),repository=publication.createIndexedDBPublicationRepository();
 const trustFlow=flow.createBrowserDeviceTrustFlow({client,repository:ownTrust,endpoint:origin,accountID:user.id,identity});
 const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('selective-remote-real-'+runID,1);r.onupgradeneeded=()=>r.result.createObjectStore('run');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(Error('run_storage_failed'));});
 async function storage(key,value){return new Promise((resolve,reject)=>{
  const tx=db.transaction('run',arguments.length===2?'readwrite':'readonly'),store=tx.objectStore('run');
  const request=arguments.length===2?store.put(value,key):store.get(key);let result;
  request.onsuccess=()=>{result=request.result;};tx.oncomplete=()=>resolve(result);tx.onerror=tx.onabort=()=>reject(Error('run_storage_failed'));
 });}
 async function actor(){
  const fresh=await client.restoreSession();
  if(fresh.id!==user.id||fresh.email.toLowerCase()!==email.toLowerCase()||client.deviceID()!==identity.deviceID)throw Error('test_account_changed');
  const state=await trustFlow.status();
  if(state.state!=='CUSTODIAN'||!state.root||!state.pin)throw Error('owner_product_trust_setup_required');
  return state;
 }
 async function scoped(value){
  await actor();
  if(value.actorUserID!==user.id||value.actorDeviceID!==identity.deviceID||!['populated','empty'].some(k=>value.name===`TEST-ONLY-CODEX-${runID}-${k}`))throw Error('run_scope_mismatch');
  const saved=await storage('created');
  if(!saved||saved.teamID!==value.teamID||!saved.vaults.some(v=>v.vaultID===value.vaultID&&v.attemptID===value.attemptID&&v.name===value.name))throw Error('run_scope_mismatch');
  const actual=(await client.listSharedVaults(value.teamID)).find(v=>v.id===value.vaultID);
  if(!actual||actual.name!==value.name)throw Error('run_scope_mismatch');
  return {teamID:value.teamID,vaultID:value.vaultID,attemptID:value.attemptID,actorUserID:user.id,actorDeviceID:identity.deviceID,schemaVersion:2,capability:'resource_acl_v2'};
 }
 async function checkpointKey(scope){
  const keyID='key:'+scope.vaultID,existing=await storage(keyID);
  if(existing){
   if(!existing.protector||!existing.wrapped||!existing.nonce)throw Error('checkpoint_protection_lost');
   return new Uint8Array(await crypto.subtle.decrypt({name:'AES-GCM',iv:existing.nonce,additionalData:new TextEncoder().encode(scope.attemptID)},existing.protector,existing.wrapped));
  }
  if(await storage('migration:'+scope.vaultID))throw Error('checkpoint_protection_lost');
  const key=crypto.getRandomValues(new Uint8Array(32)),nonce=crypto.getRandomValues(new Uint8Array(12));
  const protector=await crypto.subtle.generateKey({name:'AES-GCM',length:256},false,['encrypt','decrypt']);
  const wrapped=await crypto.subtle.encrypt({name:'AES-GCM',iv:nonce,additionalData:new TextEncoder().encode(scope.attemptID)},protector,key);
  await storage(keyID,{protector,nonce,wrapped});return key;
 }
 globalThis.__prcLifecycle=async(command,arg={})=>{
  if(command==='identity'){
   const state=await actor();return {accountID:user.id,deviceID:identity.deviceID,rootFingerprint:state.pin.rootFingerprint,checkpointDigest:state.pin.checkpointDigest,publicPin:state.pin};
  }
  if(command==='bootstrap'){
   await actor();if(await storage('created'))throw Error('bootstrap_already_recorded');
   const createdTeam=await client.createTeam({name:`TEST-ONLY-CODEX-${runID}-team`,idempotencyKey:`prc:${runID}:team`});
   const created={teamID:createdTeam.id,actorUserID:user.id,actorDeviceID:identity.deviceID,vaults:[]};
   // Persist every actual created ID immediately; partial work is never replayed
   // as a fresh successful bootstrap or silently replaced after a failed phase.
   await storage('created',created);
   for(const kind of ['populated','empty']){
    const name=`TEST-ONLY-CODEX-${runID}-${kind}`,vault=await client.createSharedVault({teamID:created.teamID,name,idempotencyKey:`prc:${runID}:${kind}`});
    const item={vaultID:vault.id,name,attemptID:crypto.randomUUID()};created.vaults.push(item);await storage('created',created);
    const scope={type:'team',teamID:created.teamID,vaultID:vault.id},controller=team.createTeamVaultController({repository:team.createIndexedDBTeamVaultRepository(scope),identity,scope});
    await team.synchronizeTeamVault({client,controller,role:'owner'});
    if(kind==='populated')for(const record of globalThis.__prcCreateV1Records())await controller.upsert(record);
    await team.synchronizeTeamVault({client,controller,role:'owner'});
    const remote=await client.getTeamVault(scope),state=await controller.syncState(),cached=await team.createIndexedDBTeamVaultRepository(scope).load();
    if(state.dirty||remote.revision!==state.serverRevision||controller.document().records.length!==(kind==='populated'?4:0))throw Error('legacy_roundtrip_failed');
    if(['ciphertext','nonce','authTag','contentHash'].some(key=>remote[key]!==cached.envelope[key]))throw Error('legacy_roundtrip_failed');
    controller.lock();await controller.unlock();
    const records=await Promise.all(controller.document().records.map(async record=>({id:record.id,type:record.type,digest:await migration.migrationHash(record)})));
    await storage('expected:'+vault.id,{records,count:records.length});controller.lock();
   }
   const invite=await client.inviteTeamMember({teamID:created.teamID,email:arg.memberEmail,role:'editor',idempotencyKey:`prc:${runID}:invite`});
   return {...created,invitationID:invite.id};
  }
  if(command==='join-check'){
   await actor();if(!(await client.listTeams()).some(t=>t.id===arg.teamID&&t.name===`TEST-ONLY-CODEX-${runID}-team`))throw Error('owner_invitation_acceptance_pending');return {accountID:user.id,deviceID:identity.deviceID,teamID:arg.teamID};
  }
  if(command==='pin-peer'){
   await actor();if(arg.pin.endpoint!==origin||arg.pin.accountID===user.id)throw Error('peer_pin_invalid');
   await repository.savePinIfAbsent(origin,arg.teamID,arg.pin);return {rootFingerprint:arg.pin.rootFingerprint};
  }
  if(command==='prepare'){
   const input=await scoped(arg),state=await actor(),scope={teamID:arg.teamID,vaultID:arg.vaultID};
   const teamScope={type:'team',...scope};
   const controller=team.createTeamVaultController({repository:team.createIndexedDBTeamVaultRepository(teamScope),identity,scope:teamScope});
   await team.synchronizeTeamVault({client,controller,role:'owner'});
   const local=await controller.syncState();if(local.dirty)throw Error('legacy_dirty');
   const document=controller.document(),preview=await globalThis.__prcOperator({operation:'preview',input});
   if(preview.sourceRevision!==local.serverRevision)throw Error('migration_source_changed');
   const migrationScope={...scope,attemptID:arg.attemptID,sourceRevision:preview.sourceRevision,sourceHash:preview.sourceHash,snapshotHash:preview.snapshotHash,policyVersion:preview.policyVersion};
   let saved=await storage('migration:'+arg.vaultID);
   if(saved&&JSON.stringify(saved.scope)!==JSON.stringify(migrationScope))throw Error('migration_source_changed');
   const key=await checkpointKey(arg);
   try{
    const persistCheckpoint=async checkpoint=>{saved={...saved,scope:migrationScope,checkpoint};await storage('migration:'+arg.vaultID,saved);};
    const inventory=await migration.prepareMigrationInventory({document,scope:migrationScope,checkpointKey:key,checkpoint:saved?.checkpoint,persistCheckpoint});
    const started=await globalThis.__prcOperator({operation:'start',input:{...input,resources:inventory.resources}});
    if(JSON.stringify(started.scope)!==JSON.stringify(migrationScope)){
     if(migration.canonicalMigrationJSON(started.scope)!==migration.canonicalMigrationJSON(migrationScope))throw Error('migration_scope_changed');
    }
    const pinnedTrust={loadPin:async(endpoint,account)=>account===user.id?ownTrust.loadPin(endpoint,account):repository.loadPin(endpoint,scope.teamID,account),
     advancePin:async(old,next)=>old.accountID===user.id?ownTrust.advancePin(old,next):repository.advancePin(origin,scope.teamID,old,next)};
    const self=preview.snapshot.devices.find(d=>d.accountID===user.id&&d.deviceID===identity.deviceID);
    if(!self)throw Error('self_recipient_missing');
    const out=await migration.prepareLegacyMigration({document,scope:started.scope,policy:started.policy,recipientTargets:(resource,part)=>started.recipients[resource.id][part],
     pinnedTrust,root:state.root,identity,deviceID:identity.deviceID,endpoint:origin,checkpointKey:key,checkpoint:inventory.checkpoint,persistCheckpoint,
     readerPublication:{publisherAccountID:user.id,publisherKeyVersion:self.certificate.payload.keyVersion,custodianDeviceIDs:[identity.deviceID],custodianTargets:[self],
      verifyIdentityReservations:resources=>globalThis.__prcOperator({operation:'verify-identities',input:{...input,resources}})}});
    for(const object of out.objects)await globalThis.__prcOperator({operation:'upload',input,object,checkpoint:out.checkpoint});
    await globalThis.__prcOperator({operation:'upload-reader',input,projection:out.readerProjection,sidecar:out.administrativeSidecar,checkpoint:out.checkpoint});
    const manifestHash=await migration.migrationHash(out.manifest);
    const ready=await globalThis.__prcOperator({operation:'validate',input,manifest:out.manifest});
    if(ready.state!=='V2_READY'||ready.manifestHash!==manifestHash)throw Error('migration_ready_readback_invalid');
    await storage('migration:'+arg.vaultID,{...saved,manifestHash,headerHash:await publicationHeaderHash(out.readerProjection),resources:out.resources});
    return {vaultID:arg.vaultID,attemptID:arg.attemptID,manifestHash,count:out.resources.length};
   }finally{key.fill(0);controller.lock();}
  }
  if(command==='activate'){
   const input=await scoped(arg),saved=await storage('migration:'+arg.vaultID);
   if(!saved?.manifestHash)throw Error('prepared_migration_required');
   const result=await globalThis.__prcOperator({operation:'activate',input,manifestHash:saved.manifestHash});
   if(result.state!=='V2_ACTIVE'||result.manifestHash!==saved.manifestHash)throw Error('activation_readback_invalid');
   return {vaultID:arg.vaultID,attemptID:arg.attemptID,manifestHash:saved.manifestHash};
  }
  if(command==='read'){
   const input=await scoped(arg),saved=await storage('migration:'+arg.vaultID),expected=await storage('expected:'+arg.vaultID);
   if(!saved?.manifestHash||!expected)throw Error('prepared_migration_required');
   const deviceKeyVersion=await publication.resolvePublicationDeviceKeyVersion({client,repository:ownTrust,identity,sessionIdentity:client.publicationIdentity(origin)});
   const reader=publication.createVaultPublicationClient({transport:client.publicationTransport(),identity:()=>client.publicationIdentity(origin),scope:input,
    privateKey:identity.privateKey,publicKey:identity.publicKey,deviceKeyVersion,ownTrustRepository:ownTrust,publisherTrustRepository:repository,repository,
    subscribeIdentityChange:listener=>client.subscribePublicationIdentity(listener)});
   try{
    await reader.load();const view=reader.view();
    if(view.stale||view.header.payload.generationID!==arg.attemptID||view.headerHash!==saved.headerHash||view.models.length!==saved.resources.length)throw Error('publication_real_readback_failed');
    const ids=new Set(view.models.map(m=>m.resourceID));if(expected.records.some(record=>!ids.has(record.id)))throw Error('resource_identity_changed');
    for(const resource of saved.resources)if(view.models.find(m=>m.resourceID===resource.id)?.parentFolderID!==resource.parentFolderID)throw Error('resource_parent_changed');
    for(const expectedRecord of expected.records){
     const model=expectedRecord.type==='credential'?await reader.revealSecret(expectedRecord.id):view.models.find(m=>m.resourceID===expectedRecord.id);
     if(await migration.migrationHash(model.record)!==expectedRecord.digest)throw Error('resource_plaintext_mismatch');
    }
    // Real product rendering, without reading or exporting decrypted DOM text.
    let container=document.querySelector('#prc-real-publication');if(!container){container=document.createElement('section');container.id='prc-real-publication';document.body.append(container);}
    publication.renderPublishedVault({documentValue:document,container,client:reader});
    return {vaultID:arg.vaultID,generationID:view.header.payload.generationID,headerHash:view.headerHash,sequence:view.header.payload.sequence,count:view.models.length};
   }catch(error){reader.dispose();throw error;}
  }
  throw Error('unknown_real_phase');
 };
 async function publicationHeaderHash(projection){const api=await import('/vault-publication-v1.js');return api.publicationHash('header',projection.header);}
}

export async function runStagingBrowserLifecycle({configPath,runDirectory,phase}){
 if(!['bootstrap','prepare','activate','read'].includes(phase)||!isAbsolute(runDirectory))throw Error('invalid_real_phase');
 const config=validateRunConfig(await readProtectedJSON(configPath));
 if(phase==='bootstrap'){
  runDirectory=await createProtectedRunDirectory(runDirectory);await save(join(runDirectory,'owner.json'),{version:1,runID:config.runID,sourceSHA:config.expectedSourceSHA});
 }else{
  await assertProtectedDirectory(dirname(runDirectory));await assertProtectedDirectory(runDirectory);
  const marker=await readProtectedJSON(join(runDirectory,'owner.json'));
  if(marker.runID!==config.runID||marker.sourceSHA!==config.expectedSourceSHA)throw Error('fresh_run_profile_required');
 }
 const lock=join(runDirectory,'runner.lock');await mkdir(lock,{mode:0o700});
 const contexts=[],terminal=createInterface({input:process.stdin,output:process.stdout});
 const evidence=phase==='bootstrap'?[]:(await readProtectedJSON(join(runDirectory,'evidence.json'))).map(redactedEvidence);
 const emit=async value=>{const checked=redactedEvidence(value);evidence.push(checked);process.stdout.write(JSON.stringify(checked)+'\n');await save(join(runDirectory,'evidence.json'),evidence);};
 const pause=async text=>{await emit({phase:'owner_input_pending'});await terminal.question(text+' Press Enter only after completing it; never enter passwords or mail tokens here.\n');};
 try{
  if(!process.env.PLAYWRIGHT_MODULE||process.env.CHROMIUM_PATH&&process.env.CHROMIUM_PATH!==EDGE)throw Error('headed_edge_required');
  const {chromium}=await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  const pages=[],registered=[];
  for(let index=0;index<(phase==='bootstrap'?2:1);index++){
   const profile=join(runDirectory,'edge-'+index);if(phase==='bootstrap')await mkdir(profile,{mode:0o700});
   await assertProtectedDirectory(profile);
   const context=await chromium.launchPersistentContext(profile,{executablePath:EDGE,headless:false,serviceWorkers:'block',acceptDownloads:false});contexts.push(context);
   await context.route('**/*',route=>{const url=new URL(route.request().url());return url.origin===config.origin?route.continue():route.abort();});
   const page=await context.newPage();
   if(phase==='bootstrap')page.on('response',async response=>{
    // The registration response has only verificationRequired. Never inspect
    // its credential-bearing request, login response, or any verification URL.
    if(response.url()!==config.origin+'/v1/auth/register'||response.status()<200||response.status()>=300)return;
    try{const result=await response.json();if(result?.verificationRequired===true&&Object.keys(result).length===1)registered[index]=true;}catch{}
   });
   await page.goto(config.origin,{waitUntil:'domcontentloaded'});pages.push(page);
  }
  await pause('Use the existing app UI in these isolated windows to register/verify/login and establish signed device trust for the configured test accounts.');
  if(phase==='bootstrap'&&![0,1].every(index=>registered[index]===true))throw Error('fresh_registration_not_observed');
  for(let index=0;index<pages.length;index++){
   await pages[index].evaluate(stagingV1Records,{installOnly:true});
   await pages[index].evaluate(installBrowserLifecycle,{...config,email:config.emails[index]});
  }
  const owner=await pages[0].evaluate(()=>globalThis.__prcLifecycle('identity'));await emit({phase:'owner_identity_verified',...owner});
  if(phase==='bootstrap'){
   const member=await pages[1].evaluate(()=>globalThis.__prcLifecycle('identity'));await emit({phase:'member_identity_verified',...member});
   const created=await pages[0].evaluate(memberEmail=>globalThis.__prcLifecycle('bootstrap',{memberEmail}),config.emails[1]);
   await save(join(runDirectory,'scope.json'),{...created,owner,member});
   for(const vault of created.vaults)await emit({phase:'legacy_created',teamID:created.teamID,...vault});
   await pause('Accept the genuine Team invitation in the second account app UI.');
   await pages[1].evaluate(teamID=>globalThis.__prcLifecycle('join-check',{teamID}),created.teamID);
   await emit({phase:'team_invitation_accepted',teamID:created.teamID,invitationID:created.invitationID});
   await emit({phase:'operator_allowlist_and_baseline_pending'});return;
  }
  const created=await readProtectedJSON(join(runDirectory,'scope.json'));
  if(created.actorUserID!==owner.accountID||created.actorDeviceID!==owner.deviceID)throw Error('test_account_changed');
  if(phase==='prepare'){
   await emit({phase:'peer_fingerprint_review',accountID:created.member.accountID,rootFingerprint:created.member.rootFingerprint,checkpointDigest:created.member.checkpointDigest});
   await pause('Compare the displayed public root/checkpoint fingerprint with the second test account device. Continue only when it matches.');
   await pages[0].evaluate(arg=>globalThis.__prcLifecycle('pin-peer',arg),{teamID:created.teamID,pin:created.member.publicPin});
  }
  if(phase==='activate')await pause('Root must have installed the reviewed exact manifest policy, controller identity and verified backup/isolated restore. The operator guard will verify them; this prompt cannot grant activation.');
  let bridge=null;
  await pages[0].exposeFunction('__prcOperator',request=>{if(!bridge)throw Error('operator_scope');return bridge(request);});
  for(const vault of created.vaults){
   const scope={...vault,teamID:created.teamID,actorUserID:created.actorUserID,actorDeviceID:created.actorDeviceID};
   bridge=createOperatorBridge({config,scope,activation:phase==='activate'});
   const result=await pages[0].evaluate(({phase,scope})=>globalThis.__prcLifecycle(phase,scope),{phase,scope});
   await emit({phase:phase==='prepare'?'migration_prepared':phase==='activate'?'migration_activated':'publication_decrypted',...result});
  }
  if(phase==='read')await pause('Inspect the real rendered publication. This is not yet second-device, revoke/rotation, restart or full lifecycle acceptance.');
 }catch(error){await emit({phase:'stopped_without_acceptance'});throw Error('real_phase_failed');}
 finally{terminal.close();for(const context of contexts)await context.close();await rm(lock,{recursive:true});}
}
