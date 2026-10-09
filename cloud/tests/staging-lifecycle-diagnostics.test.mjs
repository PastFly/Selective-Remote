import test from 'node:test';
import assert from 'node:assert/strict';
import {webcrypto,randomUUID} from 'node:crypto';
import {lifecycleFailure,diagnosticRequestAllowed,inspectBrowserLifecycleDiagnostic,validateDiagnosticRun,lifecycleDiagnosticCodes} from '../scripts/staging-lifecycle-diagnostics.mjs';
import {redactedEvidence} from '../scripts/staging-publication-acceptance.mjs';
import * as keys from '../public/team-vault-crypto.js';
import * as trust from '../public/device-trust-v1.js';
import * as diagnostic from '../scripts/staging-lifecycle-diagnostics.mjs';

const ready=()=>({outcome:'PASS',accountMatch:'expected',rootStatus:'CUSTODIAN',hasRoot:true,hasPin:true,signedDirectoryVerified:true,certificateVerified:true});
test('diagnostic keeps failed rechecks in the same profile and closes it before opening the next',async()=>{
 assert.equal(typeof diagnostic.runSequentialDiagnosticProfiles,'function');
 const events=[];
 const result=await diagnostic.runSequentialDiagnosticProfiles({
  open:async i=>{events.push(`open${i}`);return {index:i};},
  inspect:async(_p,i,count)=>{events.push(`inspect${i}:${count}`);return count>=(i===0?2:1)?ready():{outcome:'DENIED',accountMatch:i===0?'unknown':'other_approved'};},
  showGUI:async(_p,i)=>events.push(`gui${i}`),prompt:async i=>{events.push(`prompt${i}`);return 'recheck';},
  close:async(_p,i)=>events.push(`close${i}`),
 });
 assert.deepEqual(result,{quit:false});
 assert.deepEqual(events,['open0','inspect0:0','gui0','prompt0','inspect0:1','gui0','prompt0','inspect0:2','close0','open1','inspect1:0','gui1','prompt1','inspect1:1','close1']);
});
test('explicit diagnostic quit closes only the active profile and never opens the second',async()=>{
 assert.equal(typeof diagnostic.runSequentialDiagnosticProfiles,'function');
 const events=[];
 const result=await diagnostic.runSequentialDiagnosticProfiles({open:async i=>{events.push(`open${i}`);return {};},inspect:async()=>({outcome:'DENIED'}),showGUI:async()=>{},prompt:async()=> 'quit',close:async(_p,i)=>events.push(`close${i}`)});
 assert.deepEqual(result,{quit:true});assert.deepEqual(events,['open0','close0']);
});
test('only verified expected-account custodian metadata permits diagnostic profile completion',()=>{
 assert.equal(typeof diagnostic.diagnosticProfileReady,'function');assert.equal(diagnostic.diagnosticProfileReady(ready()),true);
 for(const patch of [{outcome:'DENIED'},{accountMatch:'other_approved'},{accountMatch:'unknown'},{rootStatus:'FIRST_DEVICE'},{rootStatus:'CERTIFIED'},{hasRoot:false},{hasPin:false},{signedDirectoryVerified:false},{certificateVerified:false}])assert.equal(diagnostic.diagnosticProfileReady({...ready(),...patch}),false);
});

test('failure evidence keeps only enumerated stage and exact safe code, never raw errors',()=>{
 assert.deepEqual(lifecycleFailure({stage:'bootstrap_registration_observation',index:1,error:Error('fresh_registration_not_observed')}),{stage:'bootstrap_registration_observation',browserIndex:1,failureCode:'fresh_registration_not_observed'});
 for(const message of ['secret@example.test token=abc','page.evaluate: product_trust_required\nBearer secret','product_trust_required secret']){
  const evidence=redactedEvidence({phase:'stopped_without_acceptance',outcome:'DENIED',...lifecycleFailure({stage:'owner_identity',error:Error(message)})});
  assert.equal(evidence.failureCode,'unknown_failure');assert.equal(JSON.stringify(evidence).includes(message),false);
 }
 assert.throws(()=>redactedEvidence({phase:'stopped_without_acceptance',stage:'secret@example.test'}));
 assert.throws(()=>redactedEvidence({phase:'stopped_without_acceptance',failureCode:'secret'}));
 assert.throws(()=>redactedEvidence({phase:'diagnostic_metadata',browserIndex:2}));
});
test('diagnostic network policy permits only same-origin GET metadata/modules',()=>{
 const origin='https://cloud.pastfly.ru';
 for(const path of ['/healthz','/v1/me','/v1/device-trust','/vault-sync.js'])assert.equal(diagnosticRequestAllowed(origin+path,'GET',origin),true);
 for(const [url,method] of [[origin+'/v1/auth/register','POST'],[origin+'/v1/device-trust','POST'],[origin+'/','GET'],['https://evil.test/v1/me','GET'],[origin+'/v1/vault','GET']])assert.equal(diagnosticRequestAllowed(url,method,origin),false);
});
test('complete diagnostic startup evidence accepts the actual protected run ID shape',()=>{
 const event={phase:'diagnostic_started',evidenceClass:'DIAGNOSTIC_ONLY_NO_ACCEPTANCE',runID:'prc20261009-release-retry1',expectedSourceSHA:'a'.repeat(40),launchNonce:randomUUID(),processID:randomUUID(),previousLaunchNonce:randomUUID(),stage:'diagnostic_preflight',outcome:'NOT_RUN',testSessionMode:'PRESERVE_TRUSTED_STATE'};
 assert.deepEqual(redactedEvidence(event),event);
 const metadata={...event,phase:'diagnostic_metadata',stage:'diagnostic_trust',outcome:'PASS',browserIndex:0,count:0,accountID:randomUUID(),deviceID:randomUUID(),publicKeyFingerprint:Array(16).fill('aaaa').join('-'),rootStatus:'FIRST_DEVICE',hasPin:false,hasRoot:false,signedDirectoryVerified:false,certificateVerified:false};
 assert.deepEqual(redactedEvidence(metadata),metadata);
});
test('diagnostic requires the original failed bootstrap marker and preserved mode without completing it',()=>{
 const config={runID:'20261009-a2',expectedSourceSHA:'a'.repeat(40)},baseline={sha256:'b'.repeat(64)},nonce=randomUUID();
 const value={config,mode:'PRESERVE_TRUSTED_STATE',marker:{version:1,runID:config.runID,sourceSHA:config.expectedSourceSHA},journal:{completed:[],pending:null,baseline},baseline,evidence:[{phase:'session_gate',testSessionMode:'FRESH_ANONYMOUS',outcome:'PASS',launchNonce:nonce},{phase:'stopped_without_acceptance',outcome:'DENIED',launchNonce:nonce}]};
 const before=JSON.stringify(value);assert.equal(validateDiagnosticRun(value),nonce);assert.equal(JSON.stringify(value),before);
 for(const patch of [{mode:'FRESH_ANONYMOUS'},{marker:{...value.marker,sourceSHA:'c'.repeat(40)}},{journal:{...value.journal,completed:['bootstrap']}},{evidence:[]},{baseline:{sha256:'c'.repeat(64)}}])assert.throws(()=>validateDiagnosticRun({...value,...patch}));
});

async function fixture(published){
 const origin='https://cloud.pastfly.ru',accountID=randomUUID(),deviceID=randomUUID(),email='synthetic@example.test';
 const identity={deviceID,...await keys.generateTeamDeviceIdentity(webcrypto)},root=await trust.createTrustRoot({endpoint:origin,accountID,cryptoValue:webcrypto});
 const certificate=await trust.issueDeviceCertificate({root,accountID,deviceID,publicKey:identity.publicKey,keyVersion:1,issuedAt:1,serial:randomUUID(),cryptoValue:webcrypto});
 const checkpoint=await trust.signDeviceDirectory({root,accountID,version:1,certificates:[certificate],cryptoValue:webcrypto});
 const pin={endpoint:origin,accountID,rootFingerprint:root.fingerprint,highWater:1,checkpointDigest:await trust.deviceDirectoryDigest(checkpoint,webcrypto)};
 const snapshot=published?{state:'ROOT_PUBLISHED',rootPublicKey:root.publicKey,rootFingerprint:root.fingerprint,custodianDeviceID:deviceID,checkpoint,certificates:[certificate]}:{state:'UNINITIALIZED'};
 const reads=[];
 const deps={keys,trust,crypto:webcrypto,client:{restoreSession:async()=>({id:accountID,email}),deviceID:()=>deviceID,deviceTrustSnapshot:async()=>snapshot},readRecord:async(database,store,key)=>{reads.push({database,store,key});if(key.startsWith('team-device-key:'))return identity;if(key.startsWith('pin:'))return published?pin:null;if(key.startsWith('root:'))return published?root:null;throw Error('unexpected_read');}};
 return {args:{origin,email,moduleHashes:{},failureCodes:lifecycleDiagnosticCodes},deps,accountID,deviceID,reads};
}
test('read-only inspection reports missing first-device trust without creating it',async()=>{
 const f=await fixture(false),result=await inspectBrowserLifecycleDiagnostic(f.args,f.deps);
 assert.equal(result.outcome,'PASS');assert.equal(result.rootStatus,'FIRST_DEVICE');assert.equal(result.hasRoot,false);assert.equal(result.accountID,f.accountID);assert.equal(result.certificateVerified,false);
 assert.deepEqual(Object.keys(result).sort(),['accountID','accountMatch','certificateVerified','deviceID','hasPin','hasRoot','outcome','publicKeyFingerprint','rootStatus','signedDirectoryVerified','stage'].sort());
 assert.equal(JSON.stringify(result).includes('privateKey'),false);
});
test('read-only inspection verifies signed custodian metadata without advancing pins or committing rekey',async()=>{
 const f=await fixture(true),result=await inspectBrowserLifecycleDiagnostic(f.args,f.deps);
 assert.equal(result.rootStatus,'CUSTODIAN');assert.equal(result.signedDirectoryVerified,true);assert.equal(result.certificateVerified,true);assert.equal(f.reads.length,3);
 assert.equal(JSON.stringify(result).includes('privateKey'),false);
});
test('inspection rejects wrong account and redacts unknown browser errors',async()=>{
 const f=await fixture(false);f.args.email='another@example.test';
 assert.equal((await inspectBrowserLifecycleDiagnostic(f.args,f.deps)).failureCode,'test_account_mismatch');
 f.deps.client.restoreSession=async()=>{throw Error('email=private@example.test token=secret');};
 assert.deepEqual(await inspectBrowserLifecycleDiagnostic(f.args,f.deps),{outcome:'DENIED',stage:'diagnostic_session',accountMatch:'unknown',failureCode:'unknown_failure'});
});
test('account mismatch exposes only expected, other-approved or unknown classification',async()=>{
 const f=await fixture(false),originalEmail=f.args.email;f.args.email='second@example.test';f.args.approvedEmails=[originalEmail,f.args.email];
 const other=await inspectBrowserLifecycleDiagnostic(f.args,f.deps);assert.equal(other.accountMatch,'other_approved');assert.equal(JSON.stringify(other).includes('@'),false);
 f.args.approvedEmails=[f.args.email];assert.equal((await inspectBrowserLifecycleDiagnostic(f.args,f.deps)).accountMatch,'unknown');
 assert.deepEqual(redactedEvidence({phase:'diagnostic_metadata',accountMatch:'other_approved'}),{phase:'diagnostic_metadata',accountMatch:'other_approved'});
 assert.throws(()=>redactedEvidence({phase:'diagnostic_metadata',accountMatch:'secret@example.test'}));
});
