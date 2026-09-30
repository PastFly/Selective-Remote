import assert from 'node:assert/strict';
import test from 'node:test';
import {webcrypto} from 'node:crypto';
import {migrationFixture,legacy,record,uuid} from './vault-v2-migration-fixtures.mjs';
import {previewLegacyMigration,prepareLegacyMigration,openMigrationCheckpoint} from '../public/vault-v2-migration.js';
import {unwrapResourceCEK,decryptResourcePart} from '../public/resource-crypto-v2.js';
const prepare = (f,document,extra={})=>prepareLegacyMigration({...f,document,policy:[],recipientTargets:()=>[f.recipient],persistCheckpoint:async()=>{},cryptoValue:webcrypto,...extra});
test('inventory preserves exact logical records, folder ancestry and tombstones without side effects',()=>{
 const doc=legacy([record('host',{folder:'A/B'}),record('credential'),record('snippet',{folder:'A'}),record('forwarding')]);
 doc.tombstones.push({id:uuid(),version:2});
 const result=previewLegacyMigration({document:doc});
 assert.equal(result.resourceCount,7); assert.equal(result.partCount,8); assert.equal(result.tombstoneCount,1); assert.deepEqual(result.blockers,[]);
 assert.deepEqual(doc.records.map(r=>r.type),['host','credential','snippet','forwarding']);
});
test('inventory refuses unsupported records, duplicate IDs, collisions and embedded secrets',()=>{
 for(const doc of [legacy([record('sshKey')]),legacy([record('alien')]),legacy([record('host',{password:'secret'})]),legacy([record('forwarding',{nested:{privateKey:'secret'}})])]) assert.ok(previewLegacyMigration({document:doc}).blockers.length);
 const r=record('host'); assert.ok(previewLegacyMigration({document:legacy([r,r])}).blockers.includes('duplicate_source_id'));
 assert.ok(previewLegacyMigration({document:legacy([r]),existingIDs:[r.id]}).blockers.includes('resource_id_collision'));
 assert.equal(previewLegacyMigration({document:legacy([record('host',{},'invalid')])}).missingIDs,1);
});
test('Credential metadata whitelist and distinct secret CEK preserve all original fields',async()=>{
 const f=await migrationFixture(), original=record('credential',{title:'Label',username:'alice',secret:'PASSWORD',unknown:'PRIVATE'});
 const out=await prepare(f,legacy([original])); assert.equal(out.objects.length,2);
 const contents=[]; const keys=[];
 for(const obj of out.objects){const key=await unwrapResourceCEK({wrapper:obj.wrappers[0],context:obj.wrappers[0].context,privateKey:f.identity.privateKey,cryptoValue:webcrypto}); keys.push(Buffer.from(key).toString('hex'));contents.push(JSON.parse(new TextDecoder().decode(await decryptResourcePart({envelope:obj.envelope,context:obj.envelope.context,cek:key,cryptoValue:webcrypto}))));}
 assert.notEqual(keys[0],keys[1]);assert.deepEqual(contents[0],{resourceID:original.id,title:'Label',username:'alice'});assert.deepEqual(contents[1].record,original);
 assert.ok(!JSON.stringify(out.manifest).includes('PASSWORD'));assert.ok(!JSON.stringify(out.manifest).includes('Label'));
});
test('crash checkpoints preserve generated IDs and completed ciphertext exactly; tamper/scope/source changes fail',async()=>{
 const f=await migrationFixture(),doc=legacy([record('credential',{secret:'PRIVATE'},'missing')]);let saved;
 await assert.rejects(prepare(f,doc,{persistCheckpoint:async v=>{saved=v;},faultAt:s=>{if(s==='part_persisted')throw Error('injected');}}),/injected/);
 const state=await openMigrationCheckpoint({checkpoint:saved,key:f.checkpointKey,scope:f.scope,cryptoValue:webcrypto});assert.equal(state.objects.length,1);
 const out=await prepare(f,doc,{checkpoint:saved});assert.deepEqual(out.objects[0],state.objects[0]);assert.equal(out.resources[0].id,state.resources[0].id);
 await assert.rejects(prepare(f,legacy([record('credential')]),{checkpoint:saved}),/source_changed/);
 await assert.rejects(openMigrationCheckpoint({checkpoint:saved,key:f.checkpointKey,scope:{...f.scope,sourceRevision:2},cryptoValue:webcrypto}));
 await assert.rejects(openMigrationCheckpoint({checkpoint:{...saved,ciphertext:saved.ciphertext.slice(0,-2)+'AA'},key:f.checkpointKey,scope:f.scope,cryptoValue:webcrypto}));
});
test('untrusted recipient and missing self wrapper fail before signing',async()=>{
 const f=await migrationFixture(),doc=legacy([record('host')]);
 await assert.rejects(prepare(f,doc,{pinnedTrust:{loadPin:async()=>null,advancePin:async()=>{}}}),/device_trust/);
 await assert.rejects(prepare(f,doc,{recipientTargets:()=>[]}),/recipient_missing/);
 await assert.rejects(prepare(f,doc,{identity:{...f.identity,privateKey:null}}));
});
test('every client preparation fault leaves resumable encrypted checkpoint and no persisted CEK',async()=>{
 for(const stage of ['identities_persisted','ciphertext','wrappers','part_persisted','manifest']){const f=await migrationFixture();let saved;const doc=legacy([record('host',{name:'PRIVATE'})]);
 await assert.rejects(prepare(f,doc,{persistCheckpoint:async v=>{saved=v;},faultAt:s=>{if(s===stage)throw Error('injected');}}),/injected/);assert.ok(saved);assert.ok(!JSON.stringify(saved).includes('PRIVATE'));
 const out=await prepare(f,doc,{checkpoint:saved});assert.equal(out.objects.length,1);const state=await openMigrationCheckpoint({checkpoint:saved,key:f.checkpointKey,scope:f.scope,cryptoValue:webcrypto});assert.equal(state.cek,undefined);}
});
