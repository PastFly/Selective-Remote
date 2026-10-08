// Diagnostic metadata only. No registration receipt or lifecycle acceptance is produced.
export const lifecycleDiagnosticStages=['lifecycle_operation','browser_launch','owner_registration','bootstrap_registration_observation','browser_fixture_install','browser_lifecycle_install','owner_identity','member_identity','team_bootstrap','diagnostic_preflight','diagnostic_modules','diagnostic_session','diagnostic_identity','diagnostic_trust','owner_trust_setup','diagnostic_recheck'];
export const lifecycleDiagnosticCodes=['unknown_failure','fresh_registration_not_observed','fresh_anonymous_session_required','real_origin_required','deployed_module_unavailable','deployed_module_mismatch','authentication_required','test_account_mismatch','test_account_changed','product_device_setup_required','product_trust_required','device_trust_invalid','device_trust_recovery_required','device_trust_root_conflict','device_trust_key_substitution','device_trust_download_failed','device_trust_unsupported','run_storage_failed','readonly_storage_required','diagnostic_run_mismatch','preserved_identity_changed'];
export const lifecycleRootStatuses=['FIRST_DEVICE','PUBLISH_PENDING','PAIRING_REQUIRED','LOCAL_PIN_MISSING','CUSTODIAN','CERTIFIED','REVOKED'];
export function lifecycleFailure({stage='lifecycle_operation',index,error}){
 return {stage:lifecycleDiagnosticStages.includes(stage)?stage:'lifecycle_operation',...(index===0||index===1?{browserIndex:index}:{}),failureCode:lifecycleDiagnosticCodes.includes(error?.message)?error.message:'unknown_failure'};
}
export function diagnosticRequestAllowed(value,method,origin){
 try{const url=new URL(value);return method==='GET'&&url.origin===origin&&!url.search&&!url.hash&&(['/healthz','/v1/me','/v1/device-trust'].includes(url.pathname)||/^\/[a-z0-9-]+\.js$/.test(url.pathname));}catch{return false;}
}
export function diagnosticProfileReady(value){
 return value?.outcome==='PASS'&&value.accountMatch==='expected'&&value.rootStatus==='CUSTODIAN'
  &&value.hasRoot===true&&value.hasPin===true&&value.signedDirectoryVerified===true&&value.certificateVerified===true;
}
export async function runSequentialDiagnosticProfiles({open,inspect,showGUI,prompt,close}){
 for(const index of [0,1]){
  const profile=await open(index);let count=0,result=await inspect(profile,index,count);
  for(;;){
   await showGUI(profile,index,result);
   if(await prompt(index,result)==='quit'){await close(profile,index);return {quit:true};}
   result=await inspect(profile,index,++count);
   if(diagnosticProfileReady(result)){await close(profile,index);break;}
   // The same profile remains open. Failure never advances or closes it.
  }
 }
 return {quit:false};
}
export function validateDiagnosticRun({config,mode,marker,journal,baseline,evidence}){
 const failed=evidence?.findLast(e=>e.phase==='stopped_without_acceptance'&&e.outcome==='DENIED');
 if(mode!=='PRESERVE_TRUSTED_STATE'||marker?.version!==1||marker.runID!==config.runID||marker.sourceSHA!==config.expectedSourceSHA
  ||!Array.isArray(journal?.completed)||journal.completed.length||journal.pending!==null||!journal.baseline||JSON.stringify(journal.baseline)!==JSON.stringify(baseline)
  ||!failed?.launchNonce||!evidence.some(e=>e.phase==='session_gate'&&e.launchNonce===failed.launchNonce&&e.testSessionMode==='FRESH_ANONYMOUS'&&e.outcome==='PASS'))throw Error('diagnostic_run_mismatch');
 return failed.launchNonce;
}

// Serialized into a real HTTPS page. Dependencies are injectable only for local unit tests.
// Product modules/keys remain inside that page; the result contains public metadata only.
export async function inspectBrowserLifecycleDiagnostic({origin,email,approvedEmails=[],moduleHashes,failureCodes},dependencies=null){
 let stage='diagnostic_modules',accountMatch='unknown';
 try{
  let client,keys,trust,readRecord,cryptoValue;
  if(dependencies)({client,keys,trust,readRecord,crypto:cryptoValue}=dependencies);
  else{
   if(location.origin!==origin||location.protocol!=='https:')throw Error('real_origin_required');
   for(const [path,expected]of Object.entries(moduleHashes)){
    const response=await fetch(path,{cache:'no-store',credentials:'same-origin'});if(!response.ok)throw Error('deployed_module_unavailable');
    const actual=[...new Uint8Array(await crypto.subtle.digest('SHA-256',await response.arrayBuffer()))].map(b=>b.toString(16).padStart(2,'0')).join('');
    if(actual!==expected)throw Error('deployed_module_mismatch');
   }
   const sync=await import('/vault-sync.js');keys=await import('/team-vault-crypto.js');trust=await import('/device-trust-v1.js');cryptoValue=crypto;
   client=sync.createAuthenticatedVaultClient({fetchValue:async(path,options={})=>{
    const url=new URL(path,origin);if((options.method??'GET')!=='GET'||url.origin!==origin||!['/v1/me','/v1/device-trust'].includes(url.pathname))throw Error('readonly_storage_required');
    return fetch(url,options);
   }});
   readRecord=async(name,store,key)=>{
    if(typeof indexedDB.databases!=='function')throw Error('readonly_storage_required');
    if(!(await indexedDB.databases()).some(db=>db.name===name))return null;
    const db=await new Promise((resolve,reject)=>{const r=indexedDB.open(name);r.onupgradeneeded=()=>{r.transaction.abort();reject(Error('readonly_storage_required'));};r.onsuccess=()=>resolve(r.result);r.onerror=r.onblocked=()=>reject(Error('readonly_storage_required'));});
    try{return await new Promise((resolve,reject)=>{const tx=db.transaction(store,'readonly'),r=tx.objectStore(store).get(key);let value;r.onsuccess=()=>{value=r.result??null;};tx.oncomplete=()=>resolve(value);tx.onerror=tx.onabort=()=>reject(Error('readonly_storage_required'));});}finally{db.close();}
   };
  }
  stage='diagnostic_session';const user=await client.restoreSession();
  accountMatch=user.email.toLowerCase()===email.toLowerCase()?'expected':approvedEmails.some(v=>v.toLowerCase()===user.email.toLowerCase())?'other_approved':'unknown';
  if(accountMatch!=='expected')throw Error('test_account_mismatch');
  const accountID=user.id,deviceID=client.deviceID();stage='diagnostic_identity';
  const identity=await readRecord('selective-remote-cloud','local-vault','team-device-key:'+deviceID);
  if(!identity||identity.deviceID!==deviceID)throw Error('product_device_setup_required');
  const publicKeyFingerprint=await keys.teamDevicePublicKeyFingerprint(identity.publicKey,cryptoValue);
  stage='diagnostic_trust';const snapshot=await client.deviceTrustSnapshot(),recordKey=origin+'|'+accountID;
  const pin=await readRecord('selective-remote-device-trust-v1','records','pin:'+recordKey),root=await readRecord('selective-remote-device-trust-v1','records','root:'+recordKey);
  const result={outcome:'PASS',stage,accountMatch,accountID,deviceID,publicKeyFingerprint,hasPin:!!pin,hasRoot:!!root,signedDirectoryVerified:false,certificateVerified:false};
  if(snapshot.state==='UNINITIALIZED'){
   if(pin&&!root)throw Error('device_trust_recovery_required');
   return {...result,rootStatus:root?'PUBLISH_PENDING':'FIRST_DEVICE'};
  }
  if(snapshot.state!=='ROOT_PUBLISHED')throw Error('device_trust_download_failed');
  const verified=await trust.verifySignedDeviceDirectory({rootPublicKey:snapshot.rootPublicKey,checkpoint:snapshot.checkpoint,accountID,cryptoValue});
  result.signedDirectoryVerified=true;result.rootFingerprint=snapshot.rootFingerprint;
  if(root&&(root.accountID!==accountID||root.endpoint!==origin||root.publicKey!==snapshot.rootPublicKey))throw Error('device_trust_root_conflict');
  if(!pin)return {...result,rootStatus:root?'LOCAL_PIN_MISSING':'PAIRING_REQUIRED'};
  // Pure validation only: unlike trustFlow.status(), do not persist a newer pin or pending rekey.
  const next=trust.advancePinnedTrust(pin,{endpoint:origin,accountID,rootFingerprint:snapshot.rootFingerprint,highWater:verified.version,checkpointDigest:verified.checkpointDigest});
  const entry=snapshot.checkpoint.payload.entries.find(v=>v.deviceID===deviceID),certificate=snapshot.certificates.find(v=>v.payload?.deviceID===deviceID&&v.payload.keyVersion===entry?.keyVersion);
  if(!certificate)return {...result,rootStatus:'REVOKED'};
  const device=await trust.verifyDeviceForWrapping({rootPublicKey:snapshot.rootPublicKey,certificate,checkpoint:snapshot.checkpoint,trust:next,expectedDeviceID:deviceID,cryptoValue});
  if(device.publicKey.x!==identity.publicKey.x||device.publicKey.y!==identity.publicKey.y)throw Error('device_trust_key_substitution');
  result.certificateVerified=true;
  return {...result,rootStatus:snapshot.custodianDeviceID===deviceID&&root?'CUSTODIAN':'CERTIFIED'};
 }catch(error){return {outcome:'DENIED',stage,accountMatch,failureCode:failureCodes.includes(error?.message)?error.message:'unknown_failure'};}
}
