import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {validateOperatorRequest,bindOperatorAttempt} from '../scripts/staging-migration-operator-helper.mjs';
const identity={sourceSHA:'a'.repeat(40),imageDigest:'sha256:'+'b'.repeat(64),controllerDigest:'c'.repeat(64)};
const scope={teamID:randomUUID(),vaultID:randomUUID(),actorUserID:randomUUID(),actorDeviceID:randomUUID(),attemptID:null,name:'TEST-ONLY-CODEX-run-1-vault'};
const context=()=>({version:1,runID:'run-1',controllerIdentity:identity,allowedOperations:['preview','start','activate','check-compatibility'],
 scopes:[{...scope}],activationPolicyPath:'/var/lib/selective-remote-controller/operator/run-1-activation-policy.json'});
test('operator refuses wrong identity, operations, caller flags and mismatched protected scope before transport',()=>{
 const c=context();assert.equal(validateOperatorRequest(c,{operation:'preview',input:{...scope}},identity).operation,'preview');
 for(const request of [{operation:'shell',input:scope},{operation:'preview',input:{...scope,vaultID:randomUUID()}},{operation:'preview',input:{...scope,actorUserID:randomUUID()}},{operation:'preview',input:scope,environment:'production'},{operation:'start',input:scope},{operation:'activate',input:{...scope,attemptID:randomUUID()}}])assert.throws(()=>validateOperatorRequest(c,request,identity));
 assert.throws(()=>validateOperatorRequest(c,{operation:'preview',input:scope},{...identity,imageDigest:'sha256:'+'d'.repeat(64)}));
});
test('only explicit root context update binds an attempt while preserving exact earlier scope',()=>{
 const c=context(),attemptID=randomUUID(),updated=bindOperatorAttempt(c,{scope,expectedAttemptID:null,attemptID},identity);
 assert.equal(c.scopes[0].attemptID,null);assert.equal(updated.scopes[0].attemptID,attemptID);
 assert.equal(validateOperatorRequest(updated,{operation:'start',input:{...scope,attemptID}},identity).input.attemptID,attemptID);
 assert.throws(()=>bindOperatorAttempt(updated,{scope,expectedAttemptID:null,attemptID:randomUUID()},identity));
 assert.throws(()=>bindOperatorAttempt(c,{scope:{...scope,actorDeviceID:randomUUID()},expectedAttemptID:null,attemptID},identity));
 assert.throws(()=>validateOperatorRequest(c,{operation:'preview',input:{...scope,attemptID}},identity));
});
