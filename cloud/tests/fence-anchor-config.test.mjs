import test from 'node:test';
import assert from 'node:assert/strict';
import {rootCertificates} from 'node:tls';
import {loadFenceAnchorConfig} from '../src/fence-anchor-config.mjs';
const db='postgresql://main:test@primary.example:5432/app';
const env={PUBLICATION_FENCE_ANCHOR_URL:'postgresql://runtime:test@anchor.example:5432/fence',
 PUBLICATION_FENCE_ANCHOR_ID:'11111111-1111-4111-8111-111111111111',
 PUBLICATION_FENCE_ANCHOR_CA_BASE64:Buffer.from(rootCertificates[0]).toString('base64')};
test('independent anchor is opt-in only with complete TLS configuration',()=>{
 assert.equal(loadFenceAnchorConfig({},db),null);
 assert.equal(loadFenceAnchorConfig(env,db).deploymentID,env.PUBLICATION_FENCE_ANCHOR_ID);
 for(const missing of Object.keys(env)){const value={...env};delete value[missing];assert.throws(()=>loadFenceAnchorConfig(value,db),/invalid_deployment_anchor_configuration/);}
});
test('anchor rejects same server, URL SSL overrides, invalid IDs and invalid CA',()=>{
 for(const overrides of [
  {PUBLICATION_FENCE_ANCHOR_URL:'postgresql://runtime:test@primary.example:5432/other'},
  {PUBLICATION_FENCE_ANCHOR_URL:'postgresql://runtime:test@primary.example:5433/other'},
  {PUBLICATION_FENCE_ANCHOR_URL:env.PUBLICATION_FENCE_ANCHOR_URL+'?sslmode=disable'},
  {PUBLICATION_FENCE_ANCHOR_ID:'not-an-id'},
  {PUBLICATION_FENCE_ANCHOR_CA_BASE64:Buffer.from('not a certificate').toString('base64')},
 ])assert.throws(()=>loadFenceAnchorConfig({...env,...overrides},db),/invalid_deployment_anchor_configuration/);
});

test('configured fence passes verified TLS and anchor into the real journal, and closes its pool',async()=>{
 const {createConfiguredMigrationFence}=await import('../src/configured-migration-fence.mjs');
 let options,closed=false;
 class TestPool {constructor(value){options=value;} async end(){closed=true;} async query(){throw Error('unused');}}
 const anchor=loadFenceAnchorConfig(env,db);
 const result=createConfiguredMigrationFence({fencePath:'/tmp/test-journal',anchor},{Pool:TestPool});
 assert.equal(options.connectionString,env.PUBLICATION_FENCE_ANCHOR_URL);
 assert.equal(options.ssl.rejectUnauthorized,true);assert.equal(options.ssl.ca,anchor.ca);
 assert.ok(result.fence.anchor);await result.close();assert.equal(closed,true);
});
