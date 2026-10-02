// Actual app editor, AccessManager, authenticated adapters, WebCrypto and IndexedDB;
// the scoped server here is synthetic. PostgreSQL/HTTP acceptance is a separate gate.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { pathToFileURL, fileURLToPath } from 'node:url';
if(!process.env.PLAYWRIGHT_MODULE||!process.env.CHROMIUM_PATH)throw Error('PLAYWRIGHT_MODULE and CHROMIUM_PATH are required');
const {chromium}=await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
const publicRoot=fileURLToPath(new URL('../../public',import.meta.url));let browser,page;
try{
  browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH});const browserContext=await browser.newContext({viewport:{width:1280,height:1000}});page=await browserContext.newPage();page.setDefaultTimeout(10000);const errors=[];
  page.on('pageerror',e=>errors.push(e.message));
  await page.context().route('https://staging.example.test/**',async route=>{const path=new URL(route.request().url()).pathname;
    if(path==='/'){await route.fulfill({status:200,contentType:'text/html',body:(await readFile(publicRoot+'/index.html','utf8')).replace(/<script\b[^>]*>[\s\S]*?<\/script>/gu,'')});return;}
    if(/^\/[\w-]+\.(js|css)$/u.test(path)){await route.fulfill({status:200,contentType:path.endsWith('.js')?'application/javascript':'text/css',body:await readFile(publicRoot+path)});return;}
    await route.fulfill({status:401,contentType:'application/json',body:'{"error":"authentication_required"}'});
  });
  await page.goto('https://staging.example.test/');
  await page.evaluate(async()=>{
    const {generateTeamDeviceIdentity}=await import('/team-vault-crypto.js'),trust=await import('/device-trust-v1.js'),migration=await import('/vault-v2-migration.js'),publication=await import('/vault-publication-v1.js');
    const {createAuthenticatedVaultClient}=await import('/vault-sync.js');const id=()=>crypto.randomUUID(),accountID=id(),deviceID=id(),teamID=id(),vaultID=id(),membershipID=id(),endpoint=location.origin;let sessionID=id();
    const root=await trust.createTrustRoot({endpoint,accountID}),identity={...await generateTeamDeviceIdentity(),deviceID};
    await (await import('/team-vault-crypto.js')).createIndexedDBTeamDeviceRepository().save(identity);
    const certificate=await trust.issueDeviceCertificate({root,accountID,deviceID,publicKey:identity.publicKey,keyVersion:1,issuedAt:Date.now(),serial:id()}),checkpoint=await trust.signDeviceDirectory({root,accountID,version:1,certificates:[certificate]});
    const pin={endpoint,accountID,rootFingerprint:root.fingerprint,highWater:1,checkpointDigest:await trust.deviceDirectoryDigest(checkpoint)},repository=trust.createIndexedDBDeviceTrustRepository();await repository.saveRootIfAbsent(root);await repository.savePinIfAbsent(pin);
    const target={accountID,deviceID,membershipID,membershipEpoch:1,deviceKeyVersion:1,publicKey:identity.publicKey,rootPublicKey:root.publicKey,certificate,checkpoint};
    const scope={teamID,vaultID,attemptID:id(),sourceRevision:1,policyVersion:1,sourceHash:'a'.repeat(64),snapshotHash:'b'.repeat(64)};
    const recordID=id(),secondID=id();let current=await migration.prepareLegacyMigration({scope,document:{schemaVersion:1,records:[{id:recordID,type:'snippet',version:1,modifiedAt:Date.now(),data:{title:'First',body:'SYNTHETIC-BODY',folder:'Original'}},{id:secondID,type:'snippet',version:1,modifiedAt:Date.now(),data:{title:'Second',body:'SECOND-BODY',folder:'Destination'}}],tombstones:[],vectorClock:{}},policy:[],
      identity,deviceID,root,endpoint,pinnedTrust:{loadPin:()=>repository.loadPin(endpoint,accountID),advancePin:(a,b)=>repository.advancePin(a,b)},checkpointKey:crypto.getRandomValues(new Uint8Array(32)),recipientTargets:()=>[target],persistCheckpoint:async()=>{},
      readerPublication:{publisherAccountID:accountID,publisherKeyVersion:1,custodianDeviceIDs:[deviceID],custodianTargets:[target],verifyIdentityReservations:async()=>{}}});
    const operations=new Map(),groups=[],member={id:membershipID,userID:accountID,epoch:1,role:'owner',displayName:'Synthetic Owner',username:'synthetic'};
    const hash=async value=>Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(migration.canonicalMigrationJSON(value)))),b=>b.toString(16).padStart(2,'0')).join('');
    let policy=[],sequence=1,headerHash=await publication.publicationHash('header',current.readerProjection.header);
    const own=()=>current.readerProjection.recipients[0],publisher=()=>({...target,keyVersion:1,generationID:current.readerProjection.header.payload.generationID,headerHash});
    const currentContext=()=>({teamID,publicationAvailable:window.qa.available,environment:'staging',actorRole:'owner',sessionID,actorKeyVersion:1,groups:structuredClone(groups),edges:[],memberships:[member],current:[{teamID,vaultID,generationID:current.readerProjection.header.payload.generationID,sequence,headerHash,resources:current.resources,policy,custodianDeviceIDs:[deviceID]}]});
    const ordinary=async(resourceID,part)=>({headerHash,generationID:current.readerProjection.header.payload.generationID,descriptor:current.readerProjection.descriptors.find(d=>d.payload.resourceID===resourceID&&d.payload.part===part),envelope:current.objects.find(o=>o.resourceID===resourceID&&o.part===part).envelope,...own().proofs.find(p=>p.resourceID===resourceID&&p.part===part)});
    const reply=(value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'Content-Type':'application/json'}});
    window.qa={ids:{teamID,vaultID,accountID,deviceID,recordID,secondID},identity,available:true,requests:[],commits:0,foundationWrites:0,legacyWrites:0,current:()=>current,operations,renewSession:()=>{sessionID=id();},snapshot:()=>({rootPublicKey:root.publicKey,checkpoint,certificates:[certificate]})};
    async function fetchValue(path,options={}) {
      const url=new URL(path,location.href),body=options.body?JSON.parse(options.body):null,route=url.pathname;qa.requests.push({route,method:options.method??'GET',body});
      if(route==='/v1/auth/login')return reply({token:'s'.repeat(40),user:{id:accountID,email:'synthetic@example.test',displayName:'Synthetic Owner',username:'synthetic'},deviceID});
      if(options.headers?.Authorization!==`Bearer ${'s'.repeat(40)}`)throw Error('missing_fixture_authentication');
      if(route.endsWith('/access-context'))return reply({formatState:'V2_ACTIVE',policyMutationAvailable:false,groupMutationAvailable:false,blockers:['crypto_publication_required']});
      if(route.includes('/access/preview')||route.includes('/access/commit')){qa.foundationWrites++;return reply({error:'crypto_publication_required'},409);}
      if(route.endsWith('/vaults')||route.endsWith('/access-vaults'))return reply({rows:[{id:vaultID,teamID,name:'Synthetic Vault',formatState:'V2_ACTIVE'}],nextCursor:null});
      if(route.endsWith('/members'))return reply({members:[member],total:1,nextCursor:null});
      if(route.endsWith('/access-groups'))return reply({rows:groups,nextCursor:null});
      if(route.includes('/publication/')) {
        if(options.headers['X-Publication-Version']==='1') {
          if(options.headers['X-Vault-Schema-Version']!=='2'||options.headers['X-Vault-Capability']!=='resource_acl_v2')throw Error('missing_capability_headers');
          if(route.endsWith('/context')){const ownedID=route.split('/operations/')[1]?.split('/')[0],owned=ownedID?operations.get(ownedID):null;if(ownedID&&(!owned||!owned.state))return reply({error:'publication_operation_not_found'},404);if([...operations.entries()].some(([opID,op])=>op.state==='READY'&&opID!==ownedID))return reply({error:'publication_ready_attempt_exists'},409);return reply({...currentContext(),...(owned?{operationState:owned.state??'PREPARING'}:{})});}
          if(route.endsWith('/preview')) {
            let op=operations.get(body.request.operationID);if(!op){const request=body.request,generationID=id(),snapshot={devices:[target],sourceRevision:sequence,policyVersion:sequence+1},predecessor={vaultID,generationID:current.readerProjection.header.payload.generationID,sequence,headerHash};
              const nextScope={teamID,vaultID,attemptID:generationID,sourceRevision:sequence,policyVersion:sequence+1,snapshotHash:await hash(snapshot)},generation={vaultID,generationID,sequence:sequence+1,previousHash:headerHash,scope:nextScope,snapshot};
              const rows=request.vaults[0].resources.flatMap(r=>(r.kind==='CREDENTIAL'?['METADATA','SECRET']:['GENERAL']).map(part=>({type:'PART',vaultID,resourceID:r.id,part,devices:[target]})));rows.push({type:'CUSTODY',vaultID,devices:[target]});
              const subject={accountID,deviceID,membershipID,membershipEpoch:1,deviceKeyVersion:1},binding={version:1,teamID,operationID:request.operationID,actorAccountID:accountID,actorDeviceID:deviceID,sessionID,keyVersion:1,requestHash:await hash(request),readSetHash:'d'.repeat(64),predecessors:[predecessor],counts:{vaults:1,resources:request.vaults[0].resources.length,parts:rows.length,wrappers:rows.length},effectiveAt:'2026-10-02T00:00:00Z',rowCount:rows.length,rowsHash:await hash(rows)};
              nextScope.sourceHash=await hash({operationID:request.operationID,requestHash:binding.requestHash,readSetHash:binding.readSetHash,predecessor:headerHash});binding.policyHash=await hash([{vaultID,policy:request.vaults[0].policy}]);binding.recipientHash=await hash([{vaultID,parts:rows.filter(r=>r.type==='PART').map(r=>({resourceID:r.resourceID,part:r.part,devices:[subject]})),custodians:[subject]}]);binding.successorHash=await hash([{vaultID,sequence:generation.sequence,previousHash:headerHash,resources:request.vaults[0].resources,policyHash:await hash(request.vaults[0].policy),snapshot}]);
              op={preview:{token:'signed-fixture-preview',request,binding,generations:[generation],rows,nextCursor:null},objects:[],chunks:[],receipt:null};operations.set(request.operationID,op);
            }return reply(op.preview);
          }
          if(route.endsWith('/repair/directory'))return reply({header:current.readerProjection.header,headerHash,generationID:current.readerProjection.header.payload.generationID,scope:current.manifest.payload.scope,manifest:current.manifest,publisher:publisher(),administrativeResourceID:current.administrativeSidecar.resourceID,inventory:own().inventory,descriptors:current.readerProjection.descriptors,nextCursor:null});
          if(route.endsWith('/repair/part')) {
            if(body.part!=='ADMINISTRATIVE')return reply(await ordinary(body.resourceID,body.part));
            const item=(await publication.prepareAdministrativeSidecarCommitment(current.administrativeSidecar,[target])).items[0];return reply({...item,resourceID:current.administrativeSidecar.resourceID,part:'SECRET',envelope:current.administrativeSidecar.envelope,headerHash,generationID:current.readerProjection.header.payload.generationID,scope:current.manifest.payload.scope,manifest:current.manifest,publisher:publisher()});
          }
          if(route.endsWith('/start')){const pending=operations.get(body.request.operationID);if(pending.state==='DISCARDED')return reply({error:'publication_operation_discarded'},409);if(qa.failStart)throw TypeError('synthetic_start_not_received');pending.state='PREPARING';return reply({operationID:body.request.operationID,state:pending.state,generations:pending.preview.generations});}
          const operationID=route.split('/operations/')[1]?.split('/')[0],op=operations.get(operationID);if(!op)throw Error('fixture_operation_missing');
          if(route.endsWith('/receipt'))return op.receipt?reply(op.receipt):reply({error:'publication_not_committed'},404);
          if(route.includes('/parts/')){op.objects.push(body.object);return reply({});}
          if(route.includes('/projection-chunks/')){op.chunks[body.index]=migration.fromBase64(body.data);if(body.index<body.count-1)return reply({complete:false});const bytes=new Uint8Array(op.chunks.reduce((n,b)=>n+b.length,0));let at=0;for(const chunk of op.chunks){bytes.set(chunk,at);at+=chunk.length;}op.projection=JSON.parse(new TextDecoder().decode(bytes));if(await hash(op.projection)!==body.sha256)throw Error('fixture_chunk_hash');return reply({complete:true,headerHash:await publication.publicationHash('header',op.projection.projection.header)});}
          if(route.endsWith('/validate')){op.manifest=body.manifests[0].manifest;op.state='READY';return reply({operationID:op.preview.request.operationID,state:op.state});}
          if(route.endsWith('/discard')){if(op.receipt)return reply({error:'publication_already_committed'},409);op.state='DISCARDED';return reply({operationID,state:'DISCARDED'});}
          if(route.endsWith('/commit')){if(qa.failCommit)throw TypeError('synthetic_lost_request');op.state='COMMITTED';const p=op.projection.projection,currentGeneration=op.preview.generations[0];current={resources:op.preview.request.vaults[0].resources,objects:op.objects,administrativeSidecar:op.projection.sidecar,readerProjection:p,manifest:op.manifest};policy=op.preview.request.vaults[0].policy;sequence=currentGeneration.sequence;headerHash=await publication.publicationHash('header',p.header);qa.commits++;const gm=op.preview.request.groupMutation;if(gm?.action==='CREATE')groups.push({id:gm.groupID,name:gm.name,version:1});op.receipt={operationID,teamID,requestHash:op.preview.binding.requestHash,actorAccountID:accountID,actorDeviceID:deviceID,vaults:[{vaultID,generationID:currentGeneration.generationID,sequence,headerHash}],committedAt:'2026-10-02T00:01:00Z'};return reply(op.receipt);}
          if(route.includes('/readback/'))return reply({vaultID,header:op.projection.projection.header,headerHash:op.receipt.vaults[0].headerHash,manifest:op.manifest});
          throw Error('unknown_fixture_publication_route:'+route);
        }
        if(route.endsWith('/header'))return reply({header:current.readerProjection.header,headerHash,inventory:own().inventory,subject:own().inventory.payload});
        if(route.endsWith('/publisher'))return reply(publisher());
        if(route.endsWith('/directory'))return reply({headerHash,generationID:current.readerProjection.header.payload.generationID,inventory:own().inventory,descriptors:current.readerProjection.descriptors,nextCursor:null});
        if(route.includes('/resources/'))return reply(await ordinary(route.split('/resources/')[1].split('/')[0],route.split('/parts/')[1]));
      }
      throw Error('unknown_fixture_route:'+route);
    }
    qa.fetchValue=fetchValue;const authenticated=createAuthenticatedVaultClient({fetchValue});await authenticated.login({email:'synthetic@example.test',password:'synthetic-password',deviceID,publicKey:identity.publicKey});
    const client={...authenticated,listDevices:async()=>[],deviceTrustSnapshot:async()=>({rootPublicKey:root.publicKey,checkpoint,certificates:[certificate]}),listPendingTeamInvitations:async()=>[],listTeams:async()=>[{id:teamID,name:'Synthetic Team',role:'owner'}],listTeamMembersPage:async()=>({members:[member],total:1,nextCursor:null}),listSharedVaults:async()=>[{id:vaultID,teamID,name:'Synthetic Vault',formatState:'V2_ACTIVE',rotationRequired:false}],listTeamInvitations:async()=>[],getTeamDeviceAdmissionPolicy:async()=>({editable:false,automaticDeviceAdmission:true})};
    const section=document.querySelector('#team-vault'),parent=section.parentNode,next=section.nextSibling;section.remove();const app=await import('/app.js');parent.insertBefore(section,next);document.documentElement.lang='en';
    qa.workspace=app.initializeTeamWorkspace({client,deviceTrustRepository:repository,backgroundSyncIntervalMilliseconds:0,workspaceRefreshIntervalMilliseconds:0});await qa.workspace.activate(identity);qa.workspace.setView('hosts','snippet');for(let node=section;node;node=node.parentElement){node.hidden=false;node.removeAttribute('inert');}
  });
  await page.waitForFunction(()=>document.querySelectorAll('#team-vault-records .resource-card').length>=4,null,{timeout:10000});
  const settled=()=>page.waitForFunction(()=>{const s=qa.workspace.accessManager.state();return s.capability?.wholePublication===true&&!s.loading&&!s.preview&&[...document.querySelectorAll('#team-access-view button')].some(b=>b.textContent==='Refresh'&&!b.disabled);});
  const recordID=await page.evaluate(()=>qa.ids.recordID);const card=page.locator(`#team-vault-records [data-resource-id="${recordID}"]`);

  const before=await page.locator('#team-vault-workspace-status').textContent();await card.getByRole('button',{name:'Edit',exact:true}).click();
  await page.waitForFunction(before=>document.querySelector('#team-record-editor').open||document.querySelector('#team-vault-workspace-status').textContent!==before,before);
  if(!await page.locator('#team-record-editor').evaluate(d=>d.open))throw Error(JSON.stringify(await page.evaluate(()=>({status:document.querySelector('#team-vault-workspace-status').textContent,error:qa.workspace.accessManager.state().error,requests:qa.requests.map(r=>r.route)}))));
  await page.locator('#team-record-editor').waitFor({state:'visible'});
  await page.locator('#team-vault-record-form [name="secret"]').fill('EDITED-SYNTHETIC-BODY');await page.locator('#team-vault-record-form button[type="submit"]').click();
  await page.waitForFunction(()=>window.qa.workspace.accessManager.state().preview?.wholePublication===true);assert.equal(await page.evaluate(()=>qa.commits),0);
  await page.locator('#team-access-view').getByRole('button',{name:'Confirm change',exact:true}).click();await page.waitForFunction(()=>qa.commits===1);await settled();
  const edited=await page.evaluate(async()=>{const p=qa.current().objects.find(o=>o.resourceID===qa.ids.recordID),{unwrapResourceCEK,decryptResourcePart}=await import('/resource-crypto-v2.js');const cek=await unwrapResourceCEK({wrapper:p.wrappers[0],context:p.wrappers[0].context,privateKey:qa.identity.privateKey});try{const bytes=await decryptResourcePart({envelope:p.envelope,context:p.envelope.context,cek});try{return {body:JSON.parse(new TextDecoder().decode(bytes)).record.data.body,resourceID:p.resourceID,sequence:p.envelope.context.keyVersion,requests:qa.requests.filter(r=>r.route.endsWith('/preview')).map(r=>JSON.stringify(r.body))};}finally{bytes.fill(0);}}finally{cek.fill(0);}});
  assert.equal(edited.body,'EDITED-SYNTHETIC-BODY');assert.equal(edited.resourceID,recordID);assert.equal(edited.sequence,2);assert.ok(edited.requests.every(body=>!body.includes('EDITED-SYNTHETIC-BODY')));
  await page.evaluate(()=>qa.workspace.setView('hosts','snippet'));await card.getByRole('button',{name:'Move',exact:true}).click();await page.locator('#team-access-view .access-detail .modern-select-trigger').waitFor();
  const destination=await page.evaluate(()=>qa.current().resources.find(r=>r.kind==='FOLDER'&&r.id!==qa.current().resources.find(v=>v.id===qa.ids.recordID).parentFolderID).id);
  await page.locator('#team-access-view .access-detail .modern-select-trigger').click();await page.getByRole('option',{name:'Destination',exact:true}).click();await page.locator('#team-access-view').getByRole('button',{name:'Move resource',exact:true}).click();await page.locator('#team-access-view').getByRole('button',{name:'Preview consequences',exact:true}).click();await page.locator('#team-access-view').getByRole('button',{name:'Confirm change',exact:true}).click();await page.waitForFunction(()=>qa.commits===2);assert.equal(await page.evaluate(()=>qa.current().resources.find(r=>r.id===qa.ids.recordID).parentFolderID),destination);
  await settled();await page.evaluate(()=>qa.workspace.setView('hosts','snippet'));await card.getByRole('button',{name:'Share',exact:true}).click();await settled();
  await page.locator('#team-access-view').getByRole('button',{name:'Members',exact:true}).click();await page.locator('#team-access-view .access-rows input[type="checkbox"]').first().check();await page.locator('#team-access-view').getByRole('button',{name:'Grant access',exact:true}).click();await page.locator('#team-access-view').getByRole('button',{name:'Preview consequences',exact:true}).click();await page.locator('#team-access-view').getByRole('button',{name:'Confirm change',exact:true}).click();await page.waitForFunction(()=>qa.commits===3);
  await settled();await page.evaluate(()=>qa.workspace.accessManager.setDraft({type:'GROUP_CREATE',name:'Synthetic group'}));await page.locator('#team-access-view').getByRole('button',{name:'Preview consequences',exact:true}).click();await page.locator('#team-access-view').getByRole('button',{name:'Confirm change',exact:true}).click();await page.waitForFunction(()=>qa.commits===4);
  await settled();
  await page.waitForFunction(()=>[...document.querySelectorAll('#team-access-view button')].some(b=>b.textContent==='Refresh'&&!b.disabled));
  await page.evaluate(()=>{qa.failCommit=true;qa.workspace.accessManager.setDraft({type:'GROUP_CREATE',name:'Unfinished group'});});
  await page.locator('#team-access-view').getByRole('button',{name:'Preview consequences',exact:true}).click();await page.locator('#team-access-view').getByRole('button',{name:'Confirm change',exact:true}).click();
  await page.waitForFunction(()=>qa.workspace.accessManager.state().error?.code==='publication_network_unavailable');
  const recoveryID=await page.evaluate(()=>[...qa.operations].find(([,op])=>op.state==='READY')[0]);assert.equal(await page.evaluate(()=>qa.commits),4);
  await page.evaluate(()=>qa.renewSession());const recovery=await page.context().newPage();recovery.setDefaultTimeout(10000);recovery.on('pageerror',e=>errors.push(e.message));
  await recovery.exposeFunction('fixtureRequest',async(path,options)=>{try{return await page.evaluate(async({path,options})=>{const response=await qa.fetchValue(path,options);return {status:response.status,body:await response.text()};},{path,options});}catch(error){if(/synthetic_start_not_received|synthetic_lost_request/u.test(error.message))return {networkFailure:true};throw error;}});
  const ids=await page.evaluate(()=>qa.ids),snapshot=await page.evaluate(()=>qa.snapshot()),beforeRecovery=await page.evaluate(()=>qa.requests.length);
  await recovery.goto('https://staging.example.test/');await recovery.reload();
  const activateRecovery=()=>recovery.evaluate(async({ids,snapshot})=>{
    const {createAuthenticatedVaultClient}=await import('/vault-sync.js'),{createIndexedDBTeamDeviceRepository,ensureTeamDeviceIdentity}=await import('/team-vault-crypto.js'),{createIndexedDBDeviceTrustRepository}=await import('/device-trust-v1.js');
    const identity=await ensureTeamDeviceIdentity({repository:createIndexedDBTeamDeviceRepository(),deviceID:ids.deviceID});
    const authenticated=createAuthenticatedVaultClient({fetchValue:async(path,options)=>{const r=await fixtureRequest(path,options);if(r.networkFailure)throw TypeError('synthetic_network_failure');return new Response(r.body,{status:r.status,headers:{'Content-Type':'application/json'}});}});await authenticated.login({email:'synthetic@example.test',password:'synthetic-password',deviceID:ids.deviceID,publicKey:identity.publicKey});
    const client={...authenticated,listDevices:async()=>[],deviceTrustSnapshot:async()=>snapshot,listPendingTeamInvitations:async()=>[],listTeams:async()=>[{id:ids.teamID,name:'Synthetic Team',role:'owner'}],listTeamMembersPage:async()=>({members:[],total:0,nextCursor:null}),listSharedVaults:async()=>[{id:ids.vaultID,teamID:ids.teamID,name:'Synthetic Vault',formatState:'V2_ACTIVE',rotationRequired:false}],listTeamInvitations:async()=>[],getTeamDeviceAdmissionPolicy:async()=>({editable:false,automaticDeviceAdmission:true})};
    const section=document.querySelector('#team-vault'),parent=section.parentNode,next=section.nextSibling;section.remove();const app=await import('/app.js');parent.insertBefore(section,next);document.documentElement.lang='en';
    window.reloaded=app.initializeTeamWorkspace({client,deviceTrustRepository:createIndexedDBDeviceTrustRepository(),backgroundSyncIntervalMilliseconds:0,workspaceRefreshIntervalMilliseconds:0});await reloaded.activate(identity);reloaded.setView('hosts','snippet');for(let node=section;node;node=node.parentElement){node.hidden=false;node.removeAttribute('inert');}
  },{ids,snapshot});await activateRecovery();
  await recovery.locator('#team-access-view').getByRole('button',{name:'Discard the prepared update',exact:true}).waitFor();assert.equal(await recovery.locator('#team-access-view').getByRole('button',{name:'Retry',exact:true}).isDisabled(),true);
  assert.deepEqual(await page.evaluate(start=>qa.requests.slice(start).filter(r=>r.method==='POST'&&(/\/(start|parts|projection-chunks|repair)\//u.test(r.route)||r.route.endsWith('/start'))).map(r=>r.route),beforeRecovery),[]);
  await recovery.locator('#team-access-view').getByRole('button',{name:'Discard the prepared update',exact:true}).click();await recovery.waitForFunction(()=>reloaded.accessManager.state().capability?.policyMutationAvailable===true);
  assert.equal(await page.evaluate(opID=>qa.operations.get(opID).state,recoveryID),'DISCARDED');assert.equal(await page.evaluate(()=>qa.commits),4);
  const recoveryRequests=await page.evaluate(start=>qa.requests.slice(start).map(r=>r.route),beforeRecovery);assert.ok(recoveryRequests.some(r=>r.endsWith('/operations/'+recoveryID+'/receipt')));assert.ok(recoveryRequests.some(r=>r.endsWith('/operations/'+recoveryID+'/context')));assert.ok(recoveryRequests.some(r=>r.endsWith('/operations/'+recoveryID+'/discard')));
  await recovery.waitForFunction(()=>[...document.querySelectorAll('#team-access-view button')].some(b=>b.textContent==='Refresh'&&!b.disabled));
  await page.evaluate(()=>{qa.failCommit=false;qa.failStart=true;});await recovery.evaluate(()=>reloaded.accessManager.setDraft({type:'GROUP_CREATE',name:'Cancelled before START'}));
  await recovery.locator('#team-access-view').getByRole('button',{name:'Preview consequences',exact:true}).click();await recovery.locator('#team-access-view').getByRole('button',{name:'Confirm change',exact:true}).click();await recovery.waitForFunction(()=>reloaded.accessManager.state().error?.code==='publication_network_unavailable');
  const beforeStartID=await recovery.evaluate(()=>reloaded.accessManager.state().preview.request.operationID),beforeStartReload=await page.evaluate(()=>qa.requests.length);
  assert.equal(await page.evaluate(opID=>qa.operations.get(opID).state??null,beforeStartID),null);await recovery.reload();await activateRecovery();
  await recovery.locator('#team-access-view').getByRole('button',{name:'Discard the prepared update',exact:true}).waitFor();assert.equal(await recovery.locator('#team-access-view').getByRole('button',{name:'Retry',exact:true}).isDisabled(),true);
  assert.equal(await page.evaluate(start=>qa.requests.slice(start).some(r=>r.route.endsWith('/start')),beforeStartReload),false);
  await recovery.locator('#team-access-view').getByRole('button',{name:'Discard the prepared update',exact:true}).click();await recovery.waitForFunction(()=>reloaded.accessManager.state().capability?.policyMutationAvailable===true);
  assert.equal(await page.evaluate(opID=>qa.operations.get(opID).state,beforeStartID),'DISCARDED');assert.equal(await page.evaluate(()=>qa.commits),4);
  const cancellationOrder=await page.evaluate(start=>qa.requests.slice(start).map(r=>r.route),beforeStartReload),cancelAt=cancellationOrder.findIndex(r=>r.endsWith('/operations/'+beforeStartID+'/discard'));
  assert.ok(cancelAt>=0);assert.ok(cancellationOrder.slice(cancelAt+1).some(r=>r.endsWith('/operations/'+beforeStartID+'/receipt')));
  await recovery.close();
  assert.deepEqual(await page.evaluate(()=>({foundation:qa.foundationWrites,legacy:qa.legacyWrites})),{foundation:0,legacy:0});assert.deepEqual(errors,[]);
  console.log('PASS: real Edge app editor + move + share + group + renewed-session READY reload/discard + cancellation before START/reload, authenticated capabilities, WebCrypto/IndexedDB/checkpoint/receipt/readback; synthetic scoped server');
}catch(error){if(page)console.error(JSON.stringify(await page.evaluate(()=>({state:(()=>{const s=qa.workspace.accessManager.state();return {context:s.context,error:s.error,capability:s.capability,draft:s.draft?.type,operationID:s.preview?.request?.operationID};})(),status:document.querySelector('#team-vault-workspace-status').textContent,view:document.querySelector('#team-vault').dataset.teamView,text:document.querySelector('#team-access-view').textContent,requests:qa.requests.slice(-15).map(r=>r.route)}))));throw error;}finally{await browser?.close();}
