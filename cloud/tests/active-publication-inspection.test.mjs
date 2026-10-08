import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {isolatedPublicationDatabase,publicationRuntimeFixture,stopPublicationRuntime} from './publication-runtime-fixture.mjs';
import {seedMigration} from './vault-v2-migration-db-fixtures.mjs';
import {seedPublishedVault,requestFor,storeFor,prepareWholeFixture,uploadWholeFixture} from './whole-publication-fixtures.mjs';
import {defaultMigrationPolicy} from '../src/migration-policy.mjs';
import {uuid,legacy,record} from './vault-v2-migration-fixtures.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {publicationHash} from '../public/vault-publication-v1.js';
import {hashSessionToken} from '../src/security.mjs';
import {createAuthenticatedVaultClient} from '../public/vault-sync.js';
import {createWholePublicationAccessDriver} from '../public/whole-publication-flow.js';
const caps={'x-vault-schema-version':'2','x-vault-capability':'resource_acl_v2','x-publication-version':'1'};
const pepper='s'.repeat(32);
async function runtime(databaseURL,vaultID){
 const fence=await publicationRuntimeFixture(databaseURL),socket=createServer();await new Promise(r=>socket.listen(0,'127.0.0.1',r));const port=socket.address().port;await new Promise(r=>socket.close(r));
 const child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../',import.meta.url)),env:{...process.env,DATABASE_URL:databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(port),SESSION_TOKEN_PEPPER:pepper,EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),TEAM_INVITATION_TOKEN_PEPPER:'t'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),PUBLICATION_READER_ENABLED:'true',PUBLICATION_ENVIRONMENT:'staging',PUBLICATION_ALLOWED_VAULT_IDS:vaultID,PUBLICATION_CURSOR_SECRET:'z'.repeat(32),PUBLICATION_FENCE_PATH:fence.path,WHOLE_PUBLICATION_ENABLED:'true',WHOLE_PUBLICATION_PREVIEW_SECRET:'w'.repeat(32)}});
 let output='';child.stdout.on('data',d=>output+=d);child.stderr.on('data',d=>output+=d);const origin='http://127.0.0.1:'+port;
 for(let i=0;i<100;i++){if(child.exitCode!==null)throw Error(output);try{if((await fetch(origin+'/healthz')).ok)return{child,origin,fencePath:fence.path,cleanup:fence.cleanup};}catch{}await new Promise(r=>setTimeout(r,20));}throw Error('runtime_timeout');
}
for(const mutation of ['device','epoch','role','group','policy','rotation','publisher'])test(`active publication actual HTTP/client inspection preserves paths and rejects ${mutation} drift`,{skip:!process.env.TEST_DATABASE_URL},async()=>{
 const isolated=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),pool=isolated.pool;let server;
 try{
  const base=await seedMigration(pool),member=await seedMigration(pool),membershipID=uuid(),groupID=uuid(),accounts={};
  for(const role of ['admin','viewer','outsider']){
   const person=await seedMigration(pool),id=uuid();accounts[role]=person;
   if(role!=='outsider'){await pool.query('INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,$4)',[id,base.input.teamID,person.accountID,role]);await pool.query('INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)',[id,person.deviceID]);}
  }
  await pool.query("INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'editor')",[membershipID,base.input.teamID,member.accountID]);
  await pool.query('INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)',[membershipID,member.deviceID]);
  await pool.query("INSERT INTO team_access_groups(id,team_id,name,created_by_user_id) VALUES($1,$2,'inspection',$3)",[groupID,base.input.teamID,base.accountID]);
  await pool.query('INSERT INTO team_access_group_members(id,team_id,group_id,user_id,membership_id,membership_epoch,created_by_user_id) VALUES($1,$2,$3,$4,$5,1,$6)',[uuid(),base.input.teamID,groupID,member.accountID,membershipID,base.accountID]);
  const originalPins=base.pinnedTrust;base.pinnedTrust={loadPin:(e,a)=>a===member.accountID?member.pinnedTrust.loadPin(e,a):originalPins.loadPin(e,a),advancePin:(a,b)=>a.accountID===member.accountID?member.pinnedTrust.advancePin(a,b):originalPins.advancePin(a,b)};
  const f=await seedPublishedVault(pool,{base,document:legacy([record('credential',{title:'inspection',secret:'synthetic'})]),policyFor:(resources,snapshot)=>{
   const policy=defaultMigrationPolicy({resources,snapshot}).filter(g=>g.principalID===base.accountID);
   policy.push({id:uuid(),teamID:base.input.teamID,vaultID:base.input.vaultID,principalKind:'USER',principalID:member.accountID,membershipID,membershipEpoch:1,targetKind:'RESOURCE',targetID:resources[0].id,mask:3,revokedAt:null});
   policy.push({id:uuid(),teamID:base.input.teamID,vaultID:base.input.vaultID,principalKind:'GROUP',principalID:groupID,targetKind:'RESOURCE',targetID:resources[0].id,mask:3,revokedAt:null});return policy;
  }});
  const token='inspection-session-'+uuid();await pool.query('UPDATE sessions SET token_hash=$2 WHERE id=$1',[f.sessionID,hashSessionToken(token,pepper)]);
  server=await runtime(isolated.databaseURL,f.input.vaultID);
  const client=createAuthenticatedVaultClient({fetchValue:(path,options)=>fetch(server.origin+path,{...options,headers:{...options?.headers,Authorization:'Bearer '+token}})});await client.restoreSession();
  const scope={teamID:f.input.teamID,vaultID:f.input.vaultID};
  const driver=createWholePublicationAccessDriver({transport:client.wholePublicationTransport(scope.teamID),sessionIdentity:()=>client.publicationIdentity(server.origin),checkpointRepository:{discover:async()=>[]}});
  await driver.getContext(scope);
  // Actual legacy call reproduces the existing active-panel failure; the new
  // driver must provide the same inspection through a coherent generation.
  await assert.rejects(client.accessClient().effective(scope,f.out.resources[0].id,member.accountID,member.deviceID),/access_v2_preparing_required/);
  const effective=await driver.effective(scope,f.out.resources[0].id,member.accountID,member.deviceID);
  assert.equal(effective.policyEffective.policyMask,3);assert.equal(effective.policyEffective.paths.length,2);
  assert.equal(effective.deviceUsability.cryptoAvailable,'WRAP_PRESENT_UNVERIFIED');assert.equal(effective.deviceUsability.effectiveUsable,'UNKNOWN');

  assert.equal((await driver.resourcesByPrincipal(scope,'USER',member.accountID)).rows.length,1);
  assert.equal((await driver.resourcesByPrincipal(scope,'GROUP',groupID)).rows[0].policyEffective.policyMask,3);
  assert.equal((await driver.whoHas(scope,f.out.resources[0].id)).rows.length,2);
  const page=await driver.whoHas(scope,f.out.resources[0].id,{limit:1});assert.ok(page.nextCursor);
  assert.ok((await driver.whoHas(scope,f.out.resources[0].id,{limit:1,cursor:page.nextCursor})).rows.length<=1);
  await assert.rejects(driver.resourcesByPrincipal(scope,'USER',member.accountID,{cursor:page.nextCursor}),/invalid_access_page/);
  assert.equal((await driver.listDevices(scope,member.accountID)).rows[0].admitted,true);
  const pin={generationID:f.scope.attemptID,headerHash:await publicationHash('header',f.out.readerProjection.header)};
  const inspectionPath='/v1/teams/'+scope.teamID+'/vaults/'+scope.vaultID+'/publication/inspection';
  const query={...pin,inspection:'effective',resourceID:f.out.resources[0].id,subjectUserID:member.accountID,subjectDeviceID:member.deviceID};
  const raw=async(q=query,headers=caps,bearer=token)=>{const r=await fetch(server.origin+inspectionPath+'?'+new URLSearchParams(q),{headers:{...headers,Authorization:'Bearer '+bearer}});return{status:r.status,body:await r.json()};};
  for(const key of Object.keys(caps)){const h={...caps};delete h[key];assert.equal((await raw(query,h)).status,409);}
  assert.equal((await raw({...query,generationID:uuid()})).body.error,'publication_changed');
  assert.equal((await raw({...query,headerHash:'a'.repeat(64)})).body.error,'publication_changed');
  assert.equal((await raw({...query,subjectDeviceID:f.deviceID})).body.deviceUsability.effectiveUsable,'NO');
  const memberToken='member-inspection-'+uuid(),memberSession=uuid();await pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[memberSession,member.accountID,member.deviceID,hashSessionToken(memberToken,pepper)]);
  assert.equal((await raw(query,caps,memberToken)).status,403);
  const memberHeader=await fetch(server.origin+'/v1/teams/'+scope.teamID+'/vaults/'+scope.vaultID+'/publication/header',{headers:{...caps,Authorization:'Bearer '+memberToken}});assert.equal(memberHeader.status,200);
  for(const [role,person]of Object.entries(accounts)){
   const token='role-inspection-'+uuid();await pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",[uuid(),person.accountID,person.deviceID,hashSessionToken(token,pepper)]);
   assert.equal((await raw(query,caps,token)).status,role==='admin'?200:role==='outsider'?404:403);
  }
  if(process.env.PLAYWRIGHT_MODULE&&mutation==='device'){
   const {chromium}=await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE)),browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_PATH});
   try{
    const page=await browser.newPage();page.setDefaultTimeout(5000);await page.goto(server.origin);
    await page.evaluate(async({token,scope})=>{
     document.documentElement.lang='en';
     const {createAuthenticatedVaultClient}=await import('/vault-sync.js'),{createWholePublicationAccessDriver}=await import('/whole-publication-flow.js'),{createAccessManager}=await import('/access-manager.js');
     const client=createAuthenticatedVaultClient({fetchValue:(path,options)=>fetch(path,{...options,headers:{...options?.headers,Authorization:'Bearer '+token}})});await client.restoreSession();
     const driver=createWholePublicationAccessDriver({transport:client.wholePublicationTransport(scope.teamID),sessionIdentity:()=>client.publicationIdentity(location.origin),checkpointRepository:{discover:async()=>[]}});
     const root=document.createElement('section');root.id='real-inspection';document.body.replaceChildren(root);
     window.inspector=createAccessManager({root,client:client.accessClient(),context:{...scope,role:'owner'},publicationDriver:async()=>driver});await window.inspector.refresh();
    },{token,scope});
    const root=page.locator('#real-inspection');await root.getByRole('navigation').getByRole('button',{name:'Members',exact:true}).click();
    const inspectionResponse=page.waitForResponse(r=>r.url().includes('/resources-by-principal/')||r.url().includes('inspection=resources'));
    await root.locator('.access-directory').locator('li').filter({hasText:'m_'+member.accountID.replaceAll('-','').slice(0,24)}).getByRole('button',{name:'Resources',exact:true}).click();
    const response=await inspectionResponse;assert.equal(response.status(),200,JSON.stringify(await response.json()));
    await root.locator('label').filter({hasText:'Member device'}).locator('.modern-select-trigger').click();await page.getByRole('option').filter({hasText:'test'}).click();
    await root.getByRole('button',{name:'Check device',exact:true}).click();
    await root.getByText('Device availability: Availability on this device is unverified',{exact:true}).waitFor();
    assert.match(await root.innerText(),/GROUP|Group/);
   }finally{await browser.close();}
  }
  const store=storeFor(pool,f,{fence:new MigrationFence(server.fencePath)});
  const grantIDs=f.started.policy.filter(g=>g.principalID===member.accountID||g.principalID===groupID).map(g=>g.id);
  for(let i=0;i<grantIDs.length;i++){
   const request=requestFor(f),context=await client.wholePublicationTransport(scope.teamID).context();
   request.vaults[0].policy=context.current[0].policy.filter(g=>g.id!==grantIDs[i]);
   const preview=await store.preview(f.input,request),out=await prepareWholeFixture(f,preview);await uploadWholeFixture(store,f,preview,out);await store.commit(f.input,request.operationID,preview.token,request);
   await driver.getContext(scope);const current=await driver.effective(scope,f.out.resources[0].id,member.accountID,member.deviceID);
   assert.equal(current.policyEffective.policyMask,i===0?3:0);assert.equal(current.policyEffective.paths.length,i===0?1:0);
   assert.equal(current.deviceUsability.effectiveUsable,i===0?'UNKNOWN':'NO');
   const h=await fetch(server.origin+'/v1/teams/'+scope.teamID+'/vaults/'+scope.vaultID+'/publication/header',{headers:{...caps,Authorization:'Bearer '+memberToken}});assert.equal(h.status,i===0?200:403);
   f.out=out.generations[0];f.started.policy=request.vaults[0].policy;
  }
  if(mutation==='device')await pool.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[member.deviceID]);
  if(mutation==='publisher')await pool.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[f.deviceID]);
  if(mutation==='epoch'){await pool.query('UPDATE team_memberships SET revoked_at=now() WHERE id=$1',[membershipID]);await pool.query("INSERT INTO team_memberships(id,team_id,user_id,role,epoch) VALUES($1,$2,$3,'editor',2)",[uuid(),scope.teamID,member.accountID]);}
  if(mutation==='role')await pool.query("UPDATE team_memberships SET role='viewer' WHERE id=$1",[membershipID]);
  if(mutation==='group')await pool.query('UPDATE team_access_group_members SET removed_at=now(),version=version+1 WHERE group_id=$1',[groupID]);
  if(mutation==='policy')await pool.query('UPDATE shared_vaults SET access_policy_version=access_policy_version+1 WHERE id=$1',[scope.vaultID]);
  if(mutation==='rotation')await pool.query('UPDATE shared_vaults SET rotation_required=true WHERE id=$1',[scope.vaultID]);
  await assert.rejects(driver.effective(scope,f.out.resources[0].id,member.accountID,member.deviceID),/publication_repair_required|publication_access_denied|authentication_required|unauthorized/);
 }finally{await stopPublicationRuntime(server);await isolated.cleanup();}
});

test('active signed Folder View inspection requires GENERAL delivery through HTTP client and driver',{skip:!process.env.TEST_DATABASE_URL},async()=>{
 const isolated=await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL),pool=isolated.pool;let server;
 try{
  const base=await seedMigration(pool),member=await seedMigration(pool),membershipID=uuid();
  await pool.query("INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'editor')",[membershipID,base.input.teamID,member.accountID]);
  await pool.query('INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)',[membershipID,member.deviceID]);
  const originalPins=base.pinnedTrust;base.pinnedTrust={loadPin:(e,a)=>a===member.accountID?member.pinnedTrust.loadPin(e,a):originalPins.loadPin(e,a),advancePin:(a,b)=>a.accountID===member.accountID?member.pinnedTrust.advancePin(a,b):originalPins.advancePin(a,b)};
  let folderID,managementID;
  const f=await seedPublishedVault(pool,{base,document:legacy([record('host',{title:'encrypted folder child',hostname:'test.example',folder:'encrypted folder'}),record('host',{title:'management child',hostname:'test.example',folder:'management only'})]),policyFor:(resources,snapshot)=>{
   const policy=defaultMigrationPolicy({resources,snapshot}).filter(g=>g.principalID===base.accountID);
   [folderID,managementID]=resources.filter(r=>r.kind==='FOLDER').map(r=>r.id);
   for(const [targetID,mask]of [[folderID,33],[managementID,32]])policy.push({id:uuid(),teamID:base.input.teamID,vaultID:base.input.vaultID,principalKind:'USER',principalID:member.accountID,membershipID,membershipEpoch:1,targetKind:'FOLDER',targetID,mask,revokedAt:null});
   return policy;
  }});
  assert.ok(f.out.readerProjection.recipients.find(r=>r.inventory.payload.deviceID===member.deviceID).proofs.some(p=>p.resourceID===folderID&&p.part==='GENERAL'));
  const token='folder-inspection-'+uuid();await pool.query('UPDATE sessions SET token_hash=$2 WHERE id=$1',[f.sessionID,hashSessionToken(token,pepper)]);
  server=await runtime(isolated.databaseURL,f.input.vaultID);
  const client=createAuthenticatedVaultClient({fetchValue:(path,options)=>fetch(server.origin+path,{...options,headers:{...options?.headers,Authorization:'Bearer '+token}})});await client.restoreSession();
  const scope={teamID:f.input.teamID,vaultID:f.input.vaultID},driver=createWholePublicationAccessDriver({transport:client.wholePublicationTransport(scope.teamID),sessionIdentity:()=>client.publicationIdentity(server.origin),checkpointRepository:{discover:async()=>[]}});
  await driver.getContext(scope);
  const result=await driver.effective(scope,folderID,member.accountID,member.deviceID);
  assert.equal(result.policyEffective.policyMask,33);
  assert.equal(result.deviceUsability.cryptoAvailable,'WRAP_PRESENT_UNVERIFIED');assert.equal(result.deviceUsability.effectiveUsable,'UNKNOWN');
  assert.deepEqual(result.deviceUsability.cryptoAvailableByPermission,{View:'WRAP_PRESENT_UNVERIFIED'});assert.deepEqual(result.deviceUsability.effectiveUsableByPermission,{View:'UNKNOWN'});
  for(const deviceID of [f.deviceID,uuid()]){
   const denied=await driver.effective(scope,folderID,member.accountID,deviceID);
   assert.equal(denied.policyEffective.policyMask,33);
   assert.equal(denied.deviceUsability.cryptoAvailable,'NO');assert.equal(denied.deviceUsability.effectiveUsable,'NO');
   assert.deepEqual(denied.deviceUsability.cryptoAvailableByPermission,{View:'NO'});assert.deepEqual(denied.deviceUsability.effectiveUsableByPermission,{View:'NO'});
   assert.deepEqual(denied.deviceUsability.blockedReasons,['DEVICE_NOT_ADMITTED']);
  }
  const management=await driver.effective(scope,managementID,member.accountID,member.deviceID);
  assert.equal(management.policyEffective.policyMask,32);assert.deepEqual(management.deviceUsability.cryptoAvailableByPermission,{});assert.deepEqual(management.deviceUsability.effectiveUsableByPermission,{});assert.equal(management.deviceUsability.cryptoAvailable,'NO');
 }finally{await stopPublicationRuntime(server);await isolated.cleanup();}
});
