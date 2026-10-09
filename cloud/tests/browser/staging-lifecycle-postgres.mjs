// Local disposable PG + actual Edge integration only. Fixture accounts/signed
// trust are provisioned explicitly; this never substitutes for real onboarding.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createServer as httpsServer} from 'node:https';
import {createServer as netServer} from 'node:net';
import {request as httpRequest} from 'node:http';
import {mkdtemp,readFile,writeFile,mkdir,rm,realpath} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath,pathToFileURL} from 'node:url';
import {randomUUID} from 'node:crypto';
import {publicationRuntimeFixture,stopPublicationRuntime} from '../publication-runtime-fixture.mjs';
import {validateSignedDeviceBundle} from '../../src/device-trust-policy.mjs';
import {VaultMigrationStore} from '../../src/vault-migration-store.mjs';
import {hashSessionToken} from '../../src/security.mjs';
import {readProtectedJSON,validateOperatorProof} from '../../scripts/staging-publication-acceptance.mjs';
import {installBrowserLifecycle,installBrowserOfflineLifecycle,installRevokedBrowserProbes,launchLifecycleBrowser,lifecycleBrowserPlan,renewLifecycleCheckpoint,checkpointDigest,stagingV1Records} from './staging-real-lifecycle.mjs';
const pepper='s'.repeat(32),runID='local-browser-'+randomUUID().slice(0,8);
const socketPort=async()=>{const s=netServer();await new Promise(r=>s.listen(0,'127.0.0.1',r));const p=s.address().port;await new Promise(r=>s.close(r));return p;};
export async function runLocalBrowserLifecycle({pool,databaseURL}){
 const directory=await realpath(await mkdtemp(join(tmpdir(),'browser-lifecycle-pg-'))),tlsPort=await socketPort(),port=await socketPort(),origin=`https://127.0.0.1:${tlsPort}`;
 let runtime,tls,browser,recipientBrowser,extraBrowser;const profile=join(directory,'profile');await mkdir(profile,{mode:0o700});
 const teamID=randomUUID(),vaultID=randomUUID(),ownerMembershipID=randomUUID(),accountID=randomUUID(),deviceID=randomUUID();
 const f={accountID,deviceID,input:{teamID,vaultID,attemptID:randomUUID(),actorUserID:accountID,actorDeviceID:deviceID,schemaVersion:2,capability:'resource_acl_v2'},recipient:{membershipID:ownerMembershipID},config:{environment:'staging',enabled:true,allowedVaultIDs:[],activationGuard:async()=>{}}};
 const member={accountID:randomUUID(),deviceID:randomUUID()},membershipID=randomUUID(),auxID=randomUUID(),auxAttempt=randomUUID();
 f.config.allowedVaultIDs=[vaultID,auxID];
 for(const person of [f,member]){await pool.query('INSERT INTO users(id,email,username,email_verified_at) VALUES($1,$2,$3,now())',[person.accountID,person.accountID+'@example.test','local_'+person.accountID.replaceAll('-','').slice(0,24)]);await pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'local','test')",[person.deviceID,person.accountID]);}
 await pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'fixture',$2)",[teamID,accountID]);await pool.query("INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'owner')",[ownerMembershipID,teamID,accountID]);await pool.query('INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)',[ownerMembershipID,deviceID]);
 await pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,envelope_version,ciphertext,nonce,auth_tag,content_hash,updated_by_device_id) VALUES($1,$2,'fixture',$3,1,1,'LEGACY_ENCRYPTED_DATA','AAAAAAAAAAAAAAAA','AAAAAAAAAAAAAAAAAAAAAA',$4,$5)",[vaultID,teamID,accountID,'A'.repeat(43),deviceID]);
 const vaults=[{vaultID:f.input.vaultID,attemptID:f.input.attemptID,name:`TEST-ONLY-CODEX-${runID}-populated`},{vaultID:auxID,attemptID:auxAttempt,name:`TEST-ONLY-CODEX-${runID}-empty`}];
 try{
  await pool.query('UPDATE teams SET name=$2 WHERE id=$1',[f.input.teamID,`TEST-ONLY-CODEX-${runID}-team`]);await pool.query('UPDATE shared_vaults SET name=$2 WHERE id=$1',[f.input.vaultID,vaults[0].name]);
  await pool.query("INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,envelope_version,ciphertext,nonce,auth_tag,content_hash,updated_by_device_id) VALUES($1,$2,$3,$4,1,1,'LEGACY_ENCRYPTED_DATA','AAAAAAAAAAAAAAAA','AAAAAAAAAAAAAAAAAAAAAA',$5,$6)",[auxID,f.input.teamID,vaults[1].name,f.accountID,'A'.repeat(43),f.deviceID]);
  await pool.query("INSERT INTO team_memberships(id,team_id,user_id,role) VALUES($1,$2,$3,'editor')",[membershipID,f.input.teamID,member.accountID]);await pool.query('INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)',[membershipID,member.deviceID]);
  const token='local-fixture-'+randomUUID(),sessionID=randomUUID();await pool.query('INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval \'1 day\')',[sessionID,f.accountID,f.deviceID,hashSessionToken(token,pepper)]);
  const fence=await publicationRuntimeFixture(databaseURL),child=spawn(process.execPath,['src/server.mjs'],{cwd:fileURLToPath(new URL('../../',import.meta.url)),env:{...process.env,DATABASE_URL:databaseURL,CLOUD_HOST:'127.0.0.1',CLOUD_PORT:String(port),CLOUD_PUBLIC_ORIGIN:origin,SESSION_TOKEN_PEPPER:pepper,EMAIL_VERIFICATION_TOKEN_PEPPER:'e'.repeat(32),PASSWORD_RESET_TOKEN_PEPPER:'p'.repeat(32),TEAM_INVITATION_TOKEN_PEPPER:'t'.repeat(32),TEAM_OUTBOX_ENCRYPTION_KEY:'o'.repeat(32),ABUSE_TOKEN_PEPPER:'a'.repeat(32),PROXY_SHARED_SECRET:'b'.repeat(64),PUBLICATION_READER_ENABLED:'true',PUBLICATION_ENVIRONMENT:'staging',PUBLICATION_ALLOWED_VAULT_IDS:f.config.allowedVaultIDs.join(','),PUBLICATION_CURSOR_SECRET:'z'.repeat(32),PUBLICATION_FENCE_PATH:fence.path,WHOLE_PUBLICATION_ENABLED:'true',WHOLE_PUBLICATION_PREVIEW_SECRET:'w'.repeat(32)},stdio:'ignore'});runtime={child,cleanup:fence.cleanup};
  for(let i=0;i<100;i++){try{if((await fetch(`http://127.0.0.1:${port}/healthz`)).ok)break;}catch{}await new Promise(r=>setTimeout(r,30));}
  execFileSync('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=127.0.0.1','-keyout',join(directory,'tls.key'),'-out',join(directory,'tls.crt')],{stdio:'ignore'});
  tls=httpsServer({key:await readFile(join(directory,'tls.key')),cert:await readFile(join(directory,'tls.crt'))},(req,res)=>{
   if(req.url==='/fixture'){res.writeHead(200,{'content-type':'text/html'});res.end('<!doctype html><html><body><main id="fixture"></main></body></html>');return;}
   const upstream=httpRequest({host:'127.0.0.1',port,path:req.url,method:req.method,headers:req.headers},reply=>{res.writeHead(reply.statusCode,reply.headers);reply.pipe(res);});upstream.on('error',()=>{res.writeHead(502);res.end();});req.pipe(upstream);
  });await new Promise(r=>tls.listen(tlsPort,'127.0.0.1',r));
  const {chromium}=await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  const launch=()=>chromium.launchPersistentContext(profile,{executablePath:process.env.CHROMIUM_PATH,headless:true,ignoreHTTPSErrors:true,serviceWorkers:'block'});
  browser=await launch();await browser.addCookies([{name:'sr_session',value:token,url:origin,httpOnly:true,secure:true,sameSite:'Strict',expires:Math.floor(Date.now()/1000)+86400}]);let page=await browser.newPage();await page.goto(origin+'/fixture');
  // Each real Browser profile generates and keeps only its own private keys.
  const setup=async({origin,runID,accountID,deviceID,membershipID,teamID,vaults,owner})=>{
   const keys=await import('/team-vault-crypto.js'),trust=await import('/device-trust-v1.js');
   const identity={...await keys.generateTeamDeviceIdentity(),deviceID},root=await trust.createTrustRoot({endpoint:origin,accountID});
   const certificate=await trust.issueDeviceCertificate({root,accountID,deviceID,publicKey:identity.publicKey,keyVersion:1,issuedAt:1800000000,serial:crypto.randomUUID()}),checkpoint=await trust.signDeviceDirectory({root,accountID,version:1,certificates:[certificate]});
   const target={accountID,deviceID,membershipID,membershipEpoch:1,publicKey:identity.publicKey,rootPublicKey:root.publicKey,certificate,checkpoint};
   const own=trust.createIndexedDBDeviceTrustRepository();await keys.createIndexedDBTeamDeviceRepository().save(identity);await own.saveRootIfAbsent(root);await own.savePinIfAbsent({endpoint:origin,accountID,rootFingerprint:root.fingerprint,highWater:1,checkpointDigest:await trust.deviceDirectoryDigest(checkpoint)});
   const db=await new Promise((resolve,reject)=>{const r=indexedDB.open('selective-remote-real-'+runID,1);r.onupgradeneeded=()=>r.result.createObjectStore('run');r.onsuccess=()=>resolve(r.result);r.onerror=reject;});
   const enrollment={accountID,deviceID,membershipID,membershipEpoch:1,teamID,vaults};
   const put=(key,value)=>new Promise((resolve,reject)=>{const t=db.transaction('run','readwrite');t.objectStore('run').put(value,key);t.oncomplete=resolve;t.onerror=reject;});
   if(owner)await put('created',{teamID,actorUserID:accountID,actorDeviceID:deviceID,vaults});await put('enrolled',enrollment);
   globalThis.__localFixture={identities:{[accountID]:identity},roots:{[accountID]:root},targets:[target],put,enrollment};return {target,enrollment};
  };
  const ownerSetup=await page.evaluate(setup,{origin,runID,accountID:f.accountID,deviceID:f.deviceID,membershipID:f.recipient.membershipID,teamID:f.input.teamID,vaults,owner:true});
  const recipientProfile=join(directory,'recipient');await mkdir(recipientProfile,{mode:0o700});recipientBrowser=await chromium.launchPersistentContext(recipientProfile,{executablePath:process.env.CHROMIUM_PATH,headless:true,ignoreHTTPSErrors:true,serviceWorkers:'block'});
  const recipientToken='local-fixture-'+randomUUID();await pool.query('INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval \'1 day\')',[randomUUID(),member.accountID,member.deviceID,hashSessionToken(recipientToken,pepper)]);
  await recipientBrowser.addCookies([{name:'sr_session',value:recipientToken,url:origin,httpOnly:true,secure:true,sameSite:'Strict',expires:Math.floor(Date.now()/1000)+86400}]);let recipientPage=await recipientBrowser.newPage();await recipientPage.goto(origin+'/fixture');
  const recipientSetup=await recipientPage.evaluate(setup,{origin,runID,accountID:member.accountID,deviceID:member.deviceID,membershipID,teamID:f.input.teamID,vaults,owner:false});
  const recipientInitial=structuredClone(recipientSetup.target);
  const extra={accountID:member.accountID,deviceID:randomUUID()},extraProfile=join(directory,'extra');await mkdir(extraProfile,{mode:0o700});
  await pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'local extra','test')",[extra.deviceID,extra.accountID]);await pool.query('INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id) VALUES($1,1,$2)',[membershipID,extra.deviceID]);
  extraBrowser=await chromium.launchPersistentContext(extraProfile,{executablePath:process.env.CHROMIUM_PATH,headless:true,ignoreHTTPSErrors:true,serviceWorkers:'block'});const extraToken='local-fixture-'+randomUUID();await pool.query('INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval \'1 day\')',[randomUUID(),extra.accountID,extra.deviceID,hashSessionToken(extraToken,pepper)]);
  await extraBrowser.addCookies([{name:'sr_session',value:extraToken,url:origin,httpOnly:true,secure:true,sameSite:'Strict',expires:Math.floor(Date.now()/1000)+86400}]);let extraPage=await extraBrowser.newPage();await extraPage.goto(origin+'/fixture');
  const extraPublicKey=await extraPage.evaluate(async deviceID=>{const keys=await import('/team-vault-crypto.js'),identity={...await keys.generateTeamDeviceIdentity(),deviceID};await keys.createIndexedDBTeamDeviceRepository().save(identity);return identity.publicKey;},extra.deviceID);
  const extraSetup=await recipientPage.evaluate(async({extra,extraPublicKey})=>{const trust=await import('/device-trust-v1.js'),db=globalThis.__localFixture,root=db.roots[extra.accountID],member=db.targets[0];const certificate=await trust.issueDeviceCertificate({root,accountID:extra.accountID,deviceID:extra.deviceID,publicKey:extraPublicKey,keyVersion:1,issuedAt:1800000000,serial:crypto.randomUUID()}),checkpoint=await trust.signDeviceDirectory({root,accountID:extra.accountID,version:2,certificates:[member.certificate,certificate]});const own=trust.createIndexedDBDeviceTrustRepository(),old=await own.loadPin(root.endpoint,extra.accountID);await own.advancePin(old,{...old,highWater:2,checkpointDigest:await trust.deviceDirectoryDigest(checkpoint)});db.targets[0]={...member,checkpoint};return {member:db.targets[0],extra:{...member,deviceID:extra.deviceID,publicKey:extraPublicKey,certificate,checkpoint}};},{extra,extraPublicKey});
  recipientSetup.target=extraSetup.member;
  await extraPage.evaluate(async({origin,runID,teamID,vaults,target,owner})=>{const trust=await import('/device-trust-v1.js'),pub=await import('/vault-publication-client.js');await trust.createIndexedDBDeviceTrustRepository().savePinIfAbsent({endpoint:origin,accountID:target.accountID,rootFingerprint:target.certificate.payload.issuerFingerprint,highWater:2,checkpointDigest:await trust.deviceDirectoryDigest(target.checkpoint)});await pub.createIndexedDBPublicationRepository().savePinIfAbsent(origin,teamID,{endpoint:origin,accountID:owner.accountID,rootFingerprint:owner.certificate.payload.issuerFingerprint,highWater:1,checkpointDigest:await trust.deviceDirectoryDigest(owner.checkpoint)});const r=indexedDB.open('selective-remote-real-'+runID,1),db=await new Promise((resolve,reject)=>{r.onupgradeneeded=()=>r.result.createObjectStore('run');r.onsuccess=()=>resolve(r.result);r.onerror=reject;});await new Promise((resolve,reject)=>{const t=db.transaction('run','readwrite');t.objectStore('run').put({accountID:target.accountID,deviceID:target.deviceID,membershipID:target.membershipID,membershipEpoch:1,teamID,vaults},'enrolled');t.oncomplete=resolve;t.onerror=reject;});db.close();},{origin,runID,teamID,vaults,target:extraSetup.extra,owner:ownerSetup.target});
  const extraEnrollment={...recipientSetup.enrollment,deviceID:extra.deviceID};
  const publicSetup={targets:[ownerSetup.target,recipientSetup.target,extraSetup.extra],enrollment:ownerSetup.enrollment};
  for(const [targetPage,peer] of [[page,recipientSetup.target],[recipientPage,ownerSetup.target]])await targetPage.evaluate(async({origin,teamID,peer})=>{
   const trust=await import('/device-trust-v1.js'),publication=await import('/vault-publication-client.js');
   await publication.createIndexedDBPublicationRepository().savePinIfAbsent(origin,teamID,{endpoint:origin,accountID:peer.accountID,rootFingerprint:peer.certificate.payload.issuerFingerprint,highWater:peer.checkpoint.payload.version,checkpointDigest:await trust.deviceDirectoryDigest(peer.checkpoint)});
   globalThis.__localFixture.targets.push(peer);
  },{origin,teamID:f.input.teamID,peer});
  for(const target of publicSetup.targets){
   const b=await validateSignedDeviceBundle(target);
   await pool.query("UPDATE devices SET public_key=$2,public_key_algorithm='p256-ecdh-v1',key_registered_at=now(),key_approved_at=now() WHERE id=$1",[target.deviceID,JSON.stringify(target.publicKey)]);if(target.deviceID!==extra.deviceID)await pool.query('INSERT INTO device_trust_roots_v1(account_id,root_public_key,fingerprint,custodian_device_id) VALUES($1,$2,$3,$4)',[target.accountID,b.rootBytes,b.fingerprint,target.deviceID]);
   await pool.query('INSERT INTO device_trust_certificates_v1(account_id,device_id,key_version,certificate_bytes,signature,serial,certificate_json) VALUES($1,$2,1,$3,$4,$5,$6)',[target.accountID,target.deviceID,b.certificateBytes,b.certificateSignature,b.serial,target.certificate]);
   if(target.deviceID!==extra.deviceID){const initial=target.accountID===member.accountID?recipientInitial:target,ib=await validateSignedDeviceBundle(initial);await pool.query('INSERT INTO device_trust_directories_v1(account_id,version,directory_bytes,signature,directory_json) VALUES($1,1,$2,$3,$4)',[target.accountID,ib.directoryBytes,ib.directorySignature,initial.checkpoint]);}
  }
  const finalDirectory=await validateSignedDeviceBundle(recipientSetup.target);await pool.query('INSERT INTO device_trust_directories_v1(account_id,version,directory_bytes,signature,directory_json) VALUES($1,2,$2,$3,$4)',[member.accountID,finalDirectory.directoryBytes,finalDirectory.directorySignature,recipientSetup.target.checkpoint]);
  // Share the runtime's real durable fence with local fixture activation.
  const {MigrationFence}=await import('../../src/migration-fence.mjs');
  const migrationStore=new VaultMigrationStore(pool,{...f.config,fence:new MigrationFence(fence.path)});
  await page.exposeFunction('__localOperator',async request=>{
   const s=migrationStore,i=request.input;switch(request.operation){case'preview':return s.preview(i);case'start':return s.start(i);case'verify-identities':return s.verifyIdentityReservations(i);case'upload':return s.putPart(i,request.object);case'upload-reader':return s.putReaderProjection(i,request.projection,request.sidecar);case'validate':return s.validate(i,request.manifest);case'activate':return s.activate(i,request.manifestHash);default:throw Error('local_operation');}
  });
  await page.evaluate(stagingV1Records,{installOnly:true});
  const seed=async(selected,groupID=null)=>page.evaluate(async({origin,runID,teamID,vaults,accountID,deviceID,groupID,member})=>{
   const m=await import('/vault-v2-migration.js'),p=await import('/vault-publication-v1.js'),db=globalThis.__localFixture;
   const pin=async(endpoint,account)=>{const trust=await import('/device-trust-v1.js'),pub=await import('/vault-publication-client.js');return account===accountID?trust.createIndexedDBDeviceTrustRepository().loadPin(endpoint,account):pub.createIndexedDBPublicationRepository().loadPin(endpoint,teamID,account);};
   const result={};
   for(const v of [...vaults].reverse()){
    const input={teamID,vaultID:v.vaultID,attemptID:v.attemptID,actorUserID:accountID,actorDeviceID:deviceID,schemaVersion:2,capability:'resource_acl_v2'},preview=await __localOperator({operation:'preview',input}),scope={teamID,vaultID:v.vaultID,attemptID:v.attemptID,sourceRevision:preview.sourceRevision,sourceHash:preview.sourceHash,snapshotHash:preview.snapshotHash,policyVersion:preview.policyVersion};
    const document={schemaVersion:1,records:v.name.endsWith('-empty')?[]:globalThis.__prcCreateV1Records().map(r=>({...r,version:1,modifiedAt:1800000000})),tombstones:[],vectorClock:{}},checkpointKey=crypto.getRandomValues(new Uint8Array(32));
    const inventory=await m.prepareMigrationInventory({document,scope,checkpointKey,persistCheckpoint:async()=>{}});const policy=[];if(groupID)for(const r of inventory.resources)for(const [principalKind,principalID,mask,membership] of [['USER',accountID,({HOST:13,SNIPPET:13,CREDENTIAL:15,FORWARDING:9,FOLDER:33})[r.kind],db.targets[0]],['GROUP',groupID,r.kind==='CREDENTIAL'?3:1,null],['USER',member.accountID,r.kind==='CREDENTIAL'?3:1,member]])policy.push({id:crypto.randomUUID(),teamID,vaultID:v.vaultID,principalKind,principalID,targetKind:r.kind==='FOLDER'?'FOLDER':'RESOURCE',targetID:r.id,mask,revokedAt:null,...(membership?{membershipID:membership.membershipID,membershipEpoch:1}:{})});const started=await __localOperator({operation:'start',input:{...input,resources:inventory.resources,...(groupID?{policy}:{})}});
    const out=await m.prepareLegacyMigration({document,scope:started.scope,policy:started.policy,checkpointKey,checkpoint:inventory.checkpoint,persistCheckpoint:async()=>{},root:db.roots[accountID],identity:db.identities[accountID],deviceID,endpoint:origin,pinnedTrust:{loadPin:pin,advancePin:async(old,next)=>{const t=await import('/device-trust-v1.js'),p=await import('/vault-publication-client.js');return old.accountID===accountID?t.createIndexedDBDeviceTrustRepository().advancePin(old,next):p.createIndexedDBPublicationRepository().advancePin(origin,teamID,old,next);}},recipientTargets:(r,part)=>started.recipients[r.id][part],readerPublication:{publisherAccountID:accountID,publisherKeyVersion:1,custodianDeviceIDs:[deviceID],custodianTargets:[db.targets[0]],verifyIdentityReservations:resources=>__localOperator({operation:'verify-identities',input:{...input,resources}})}});
    for(const object of out.objects)await __localOperator({operation:'upload',input,object});await __localOperator({operation:'upload-reader',input,projection:out.readerProjection,sidecar:out.administrativeSidecar});await __localOperator({operation:'validate',input,manifest:out.manifest});await __localOperator({operation:'activate',input,manifestHash:await m.migrationHash(out.manifest)});
    const records=await Promise.all(document.records.map(async r=>({id:r.id,type:r.type,digest:await m.migrationHash(r)}))),secrets=document.records.filter(r=>r.type==='credential').map(r=>({resourceID:r.id,sha256:'a'.repeat(64)})),expected={records,secrets,resources:out.resources.map(({id,kind,parentFolderID})=>({id,kind,parentFolderID}))};await db.put('expected:'+v.vaultID,{records,secrets});result[v.vaultID]={expected,current:{vaultID:v.vaultID,generationID:v.attemptID,sequence:1,headerHash:await p.publicationHash('header',out.readerProjection.header)}};
   }return result;
  },{origin,runID,teamID:f.input.teamID,vaults:[selected],accountID:f.accountID,deviceID:f.deviceID,groupID,member:{...member,membershipID}});
  const prepared=await seed(vaults[1]);
  await page.evaluate(installBrowserLifecycle,{origin,runID,email:`${f.accountID}@example.test`,moduleHashes:{}});
  const scope={...vaults[1],teamID:f.input.teamID,activeVaultIDs:[auxID],member:{accountID:member.accountID,deviceID:member.deviceID,membershipID,membershipEpoch:1},expected:prepared[auxID].expected};
  const call=(command,arg=scope)=>page.evaluate(({command,arg})=>__prcLifecycle(command,arg),{command,arg});
  const create=await call('group-create');assert.equal(create.receipt.vaults.length,1);let current=await call('current');scope.groupID=current.groups.find(g=>g.name===`TEST-ONLY-CODEX-${runID}-group`).id;
  const add=await call('group-member-add');assert.equal(add.receipt.vaults.length,1);
  Object.assign(prepared,await seed(vaults[0],scope.groupID));Object.assign(scope,vaults[0],{activeVaultIDs:vaults.map(v=>v.vaultID),expected:prepared[f.input.vaultID].expected});
  await recipientPage.evaluate(installBrowserLifecycle,{origin,runID,email:member.accountID+'@example.test',moduleHashes:{}});await extraPage.evaluate(installBrowserLifecycle,{origin,runID,email:member.accountID+'@example.test',moduleHashes:{}});
  const recipientCall=(command,arg)=>recipientPage.evaluate(({command,arg})=>__prcLifecycle(command,arg),{command,arg});
  current=await call('current');let recipientArg={...vaults[0],teamID,expected:scope.expected,current:current.current.find(v=>v.vaultID===vaultID),enrollment:recipientSetup.enrollment};
  assert.equal((await recipientCall('read',recipientArg)).secretVerified,true);assert.equal((await recipientCall('recipient-negatives',recipientArg)).checkCount,3);
  assert.equal((await call('inspect',{...scope,direct:true})).effectiveMask,3);const alternate=await call('alternate-revoke');assert.equal(alternate.receipt.vaults.length,2);
  assert.equal((await call('inspect',{...scope,direct:false})).effectiveMask,3);current=await call('current');recipientArg.current=current.current.find(v=>v.vaultID===vaultID);assert.equal((await recipientCall('read',recipientArg)).secretVerified,true);
  assert.equal((await pool.query("SELECT (metadata->>'effectiveDeltaCount')::int n FROM team_audit_events WHERE team_id=$1 AND action='vault_publication_committed' AND metadata->>'operationID'=$2",[teamID,alternate.operationID])).rows[0].n,0);
  assert.equal((await pool.query('SELECT count(*)::int n FROM team_publication_outbox WHERE operation_id=$1',[alternate.operationID])).rows[0].n,0);
  const secretDeny=await call('secret-deny');current=await call('current');recipientArg.current=current.current.find(v=>v.vaultID===vaultID);assert.equal((await recipientCall('secret-denied',recipientArg)).checkCount,2);
  const secretRestore=await call('secret-restore');current=await call('current');recipientArg.current=current.current.find(v=>v.vaultID===vaultID);assert.equal((await recipientCall('read',recipientArg)).secretVerified,true);
  let rejectedTransforms=0;
  const recoverTransform=async(command,result)=>{
   rejectedTransforms+=await page.evaluate(async({runID,command,vaultID})=>{
    const r=indexedDB.open('selective-remote-real-'+runID,1),db=await new Promise((resolve,reject)=>{r.onsuccess=()=>resolve(r.result);r.onerror=reject;});
    const load=key=>new Promise((resolve,reject)=>{const r=db.transaction('run').objectStore('run').get(key);r.onsuccess=()=>resolve(r.result);r.onerror=reject;});
    const saved=await load('transformation:'+command);if(!saved?.protector||!saved?.ciphertext||Object.hasOwn(saved,'record'))throw Error('protected_intent_required');
    const intent=JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:saved.nonce,additionalData:new TextEncoder().encode(saved.binding)},saved.protector,saved.ciphertext))),step=await load('step:'+command);delete step.expected;delete step.current;
    // Model interruption after the real commit/receipt and before acceptance:
    // expected state is the original BEFORE until exact output is verified.
    await new Promise((resolve,reject)=>{const t=db.transaction('run','readwrite');t.objectStore('run').put(step,'step:'+command);t.objectStore('run').put(intent.beforeExpected,'expected:'+vaultID);t.oncomplete=resolve;t.onerror=reject;});
    let denied=0;const wrong=command==='move'?{record:intent.beforeRecord,resources:intent.beforeResources}:{record:{...intent.expectedRecord,data:{...intent.expectedRecord.data,title:'incorrect observed title'}},resources:intent.expectedResources};
    try{globalThis.__prcVerifyTransformation(intent,wrong.record,wrong.resources);}catch(error){if(error.message!=='transformation_result_mismatch')throw error;denied++;}
    const untouched={...intent.expectedRecord,data:{...intent.expectedRecord.data,address:'incorrect observed address'}};
    try{globalThis.__prcVerifyTransformation(intent,untouched,intent.expectedResources);}catch(error){if(error.message!=='transformation_result_mismatch')throw error;denied++;}
    if(denied!==2||JSON.stringify(await load('expected:'+vaultID))!==JSON.stringify(intent.beforeExpected)||(await load('step:'+command)).expected!==undefined)throw Error('incorrect_transform_advanced_expected_state');
    db.close();return denied;
   },{runID,command,vaultID});
   // Reinstall the closure; receipt-only state recovers the original protected
   // intent, verifies actual output, then advances without a second operation.
   await page.evaluate(installBrowserLifecycle,{origin,runID,email:f.accountID+'@example.test',moduleHashes:{}});const recovered=await call(command);assert.equal(recovered.operationID,result.operationID);assert.deepEqual(recovered.expected,result.expected);return recovered;
  };
  const moved=await recoverTransform('move',await call('move'));scope.expected=moved.expected;const edited=await recoverTransform('edit',await call('edit'));scope.expected=edited.expected;assert.equal(rejectedTransforms,4);
  const lost=await call('lost-response');assert.equal(lost.responseDiscarded,true);const refreshed=await call('refresh-recovery');assert.equal(refreshed.refreshRecovered,true);
  const race=await call('stale-race');assert.equal(race.checkCount,1);
  current=await call('current');const retained={...recipientArg,current:current.current.find(v=>v.vaultID===vaultID),expected:scope.expected,enrollment:extraEnrollment};await extraPage.evaluate(arg=>__prcLifecycle('retain-revoked-probes',arg),retained);
  await recipientCall('revoke-device',{accountID:member.accountID,deviceID:extra.deviceID});
  // Behavioral reproduction of the former recovery path: authenticating the
  // just-revoked preserved profile fails before any probe can clear its cookie.
  await assert.rejects(extraPage.evaluate(installBrowserLifecycle,{origin,runID,email:member.accountID+'@example.test',moduleHashes:{}}),/authentication_required/);
  assert.equal((await extraPage.evaluate(()=>__prcLifecycle('revoked-probes'))).checkCount,4);
  // Stop at the durable post-revoke root-proof checkpoint, then resume its
  // same semantic state with a fresh invocation and only surviving auth.
  const pending={version:1,runID,origin,sourceSHA:'a'.repeat(40),phase:'revoke-device',checkpointID:randomUUID(),launchNonce:randomUUID(),publicState:{teamID,vaults:current.current.map(v=>({vaultID:v.vaultID,current:v})),native:null,operationID:null,expectedDeltaCount:null}};
  pending.checkpointSHA256=checkpointDigest(pending);pending.operationID=null;pending.expectedDeltaCount=null;
  const baseline={unchanged:true,vaultCount:0,personalVaultCount:0,userCount:0,sha256:'a'.repeat(64)},oldProof={...Object.fromEntries(['version','runID','origin','sourceSHA','phase','checkpointID','launchNonce','checkpointSHA256'].map(k=>[k,pending[k]])),ordinary:baseline,outbox:null},journalPath=join(directory,'pending-journal.json'),oldProofPath=join(directory,`operator-proof-${pending.checkpointID}-${pending.launchNonce}.json`);
  await writeFile(journalPath,JSON.stringify({pending}),{mode:0o600,flag:'wx'});await writeFile(oldProofPath,JSON.stringify(oldProof),{mode:0o600,flag:'wx'});const oldBytes=await readFile(oldProofPath,'utf8'),trustBefore=(await pool.query('SELECT max(version)::int n FROM device_trust_directories_v1 WHERE account_id=$1',[member.accountID])).rows[0].n;
  await extraBrowser.close();extraBrowser=null;await browser.close();browser=null;await recipientBrowser.close();recipientBrowser=null;
  const plan=lifecycleBrowserPlan('revoke-device',true);assert.deepEqual(plan,{indexes:[0,1],authenticated:[0,1]});
  browser=await launch();page=await browser.newPage();await page.goto(origin+'/fixture');recipientBrowser=await chromium.launchPersistentContext(recipientProfile,{executablePath:process.env.CHROMIUM_PATH,headless:true,ignoreHTTPSErrors:true,serviceWorkers:'block'});recipientPage=await recipientBrowser.newPage();await recipientPage.goto(origin+'/fixture');
  for(const index of plan.authenticated){const survivorPage=index===0?page:recipientPage,account=index===0?f:member;await survivorPage.evaluate(installBrowserLifecycle,{origin,runID,email:account.accountID+'@example.test',moduleHashes:{}});assert.equal((await survivorPage.evaluate(()=>__prcLifecycle('identity',{custodian:true}))).deviceID,account.deviceID);}
  const resumedJournal=await readProtectedJSON(journalPath),nonce=randomUUID();renewLifecycleCheckpoint(resumedJournal,'revoke-device',nonce);await writeFile(journalPath,JSON.stringify(resumedJournal),{mode:0o600});
  assert.equal(resumedJournal.pending.checkpointID,pending.checkpointID);assert.equal(resumedJournal.pending.checkpointSHA256,pending.checkpointSHA256);assert.deepEqual(resumedJournal.pending.publicState,pending.publicState);assert.notEqual(nonce,pending.launchNonce);assert.throws(()=>validateOperatorProof(oldProof,resumedJournal.pending,baseline));
  const newProof={...oldProof,launchNonce:nonce},newProofPath=join(directory,`operator-proof-${pending.checkpointID}-${nonce}.json`);await writeFile(newProofPath,JSON.stringify(newProof),{mode:0o600,flag:'wx'});validateOperatorProof(await readProtectedJSON(newProofPath),resumedJournal.pending,baseline);assert.equal(await readFile(oldProofPath,'utf8'),oldBytes);assert.equal((await pool.query('SELECT max(version)::int n FROM device_trust_directories_v1 WHERE account_id=$1',[member.accountID])).rows[0].n,trustBefore);
  assert.equal((await call('repair-required',{...retained,enrollment:ownerSetup.enrollment})).outcome,'DENIED');const rotated=await call('rotate');assert.equal(rotated.receipt.vaults.length,2);
  current=await call('current');recipientArg.current=current.current.find(v=>v.vaultID===vaultID);recipientArg.expected=scope.expected;assert.equal((await recipientCall('read',recipientArg)).secretVerified,true);
  extraBrowser=await chromium.launchPersistentContext(extraProfile,{executablePath:process.env.CHROMIUM_PATH,headless:true,ignoreHTTPSErrors:true,serviceWorkers:'block'});extraPage=await extraBrowser.newPage();await extraPage.goto(origin+'/fixture');assert.equal((await extraPage.evaluate(installRevokedBrowserProbes,{origin,runID,...extra,teamID,vaultID,current:recipientArg.current})).checkCount,5);
  const selected=current.current.find(v=>v.vaultID===f.input.vaultID),readArg={...vaults[0],teamID:f.input.teamID,enrollment:publicSetup.enrollment,expected:scope.expected,current:selected};
  const read=await call('read',readArg);assert.equal(read.secretVerified,true);assert.ok(await page.locator('#prc-real-publication').count());
  for(const op of [create,add,alternate,secretDeny,secretRestore,moved,edited,lost,refreshed,race,rotated])assert.equal((await pool.query('SELECT count(*)::int n FROM team_publication_receipts WHERE operation_id=$1',[op.operationID])).rows[0].n,1);
  await browser.close();browser=null;browser=await launch();const second=await browser.newPage();await second.goto(origin+'/fixture');await second.route('**/v1/**',route=>route.abort());
  await second.evaluate(installBrowserOfflineLifecycle,{origin,runID,enrollment:publicSetup.enrollment,launchNonce:randomUUID()});const offline=await second.evaluate(arg=>__prcOffline(arg),readArg);assert.equal(offline.offlineVerified,true);
  const cdpProfile=join(directory,'actual-child');await mkdir(cdpProfile,{mode:0o700});const firstChild=await launchLifecycleBrowser({chromium,profile:cdpProfile,headless:true});const firstPID=firstChild.pid;await firstChild.close();assert.throws(()=>process.kill(firstPID,0),{code:'ESRCH'});const secondChild=await launchLifecycleBrowser({chromium,profile:cdpProfile,headless:true});try{assert.notEqual(secondChild.pid,firstPID);}finally{await secondChild.close();}
  return {operations:11,allVaults:2,secretVerified:true,offlineVerified:true,pendingResumeVerified:true,rejectedTransforms};
 }finally{await extraBrowser?.close();await recipientBrowser?.close();await browser?.close();await stopPublicationRuntime(runtime);if(tls)await new Promise(r=>tls.close(r));await rm(directory,{recursive:true,force:true});}
}
