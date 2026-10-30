import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto as c } from 'node:crypto';
import { mapLegacyResources, legacyAdministrativeMetadata, canonicalFolderComponents, folderSourceKey,
  inspectLegacyResources } from '../public/legacy-resource-mapping.js';
import { legacy, record, uuid } from './vault-v2-migration-fixtures.mjs';
import {readFile} from 'node:fs/promises';

test('actual converter native fixture preserves source ordinals and exact Folder identities',async()=>{
  const f=JSON.parse(await readFile(new URL('../../Tests/SelectiveRemoteTests/Fixtures/native-converter-mapped-v1.json',import.meta.url)));
  const mapped=mapLegacyResources({document:f.document,scope:f.scope,cryptoValue:c});
  assert.equal(mapped.resources.length,f.resources.length);
  for(const resource of f.resources.filter(r=>r.kind!=='FOLDER')){
    const parts=f.parts.filter(p=>p.resourceID===resource.id);
    for(const part of parts.filter(p=>p.part!=='METADATA'))assert.deepEqual(part.payload.record,f.document.records[resource.sourceOrdinal]);
    assert.match(resource.id,/^[a-f0-9-]{36}$/u);
  }
  const folders=f.parts.filter(p=>p.kind==='FOLDER');
  assert.equal(new Set(folders.map(p=>p.resourceID)).size,4);
  assert.equal(new Set(folders.map(p=>Buffer.from(p.payload.folder.component).toString('hex'))).size,4);
  assert.deepEqual(new Set(folders.map(p=>p.payload.folder.component)),new Set([' A ','x'.repeat(121),'é','e\u0301']));
});

test('canonical original UUID mapping survives record reorder; exact case and Unicode folder paths remain distinct',()=>{
  const a=record('host',{folder:'A/é'}),b=record('host',{folder:'a/e\u0301'}),scope={teamID:uuid(),vaultID:uuid()};
  const first=mapLegacyResources({document:legacy([a,b]),scope,cryptoValue:c});
  const next=mapLegacyResources({document:legacy([b,a]),scope,previous:first,cryptoValue:c});
  assert.equal(first.resources.find(r=>r.kind==='HOST').id,a.id);
  assert.deepEqual(next.mapping,first.mapping);
  assert.equal(first.resources.filter(r=>r.kind==='FOLDER').length,4);
});
test('malformed Unicode folder input fails closed before identity allocation',()=>{
  const scope={teamID:uuid(),vaultID:uuid()};
  for(const folder of ['\ud800','\ud801','\udc00','A/\ud800B','\ud800\ud800','\udc00\ud800']){
    assert.throws(()=>canonicalFolderComponents(folder),/invalid_folder/);
    assert.throws(()=>folderSourceKey('host',folder),/invalid_folder/);
    const document=legacy([record('host',{folder})]);
    assert.deepEqual(inspectLegacyResources(document).blockers,['invalid_folder']);
    assert.throws(()=>mapLegacyResources({document,scope,cryptoValue:c}),/invalid_folder/);
  }
});
test('well-formed Unicode remains byte-exact, including supplementary characters and a leading BOM',()=>{
  const paths=['\ufffd','😀','\ufeffA','A','é','e\u0301',' A ','a'];
  const scope={teamID:uuid(),vaultID:uuid()};
  const first=mapLegacyResources({document:legacy(paths.map(folder=>record('host',{folder}))),scope,cryptoValue:c});
  assert.equal(first.resources.filter(r=>r.kind==='FOLDER').length,paths.length);
  assert.equal(new Set(paths.map(path=>folderSourceKey('host',path))).size,paths.length);
  for(const path of paths) assert.deepEqual(canonicalFolderComponents(path),[path]);
  const recordBOM=record('host',{folder:'\ufeffA/😀'});
  const before=mapLegacyResources({document:legacy([recordBOM]),scope,cryptoValue:c});
  const after=mapLegacyResources({document:legacy([{...recordBOM,data:{folder:'B/😀'}}]),scope,
    previous:before,folderMoves:[{type:'host',from:'\ufeffA',to:'B'}],cryptoValue:c});
  assert.equal(after.mapping[folderSourceKey('host','B')],before.mapping[folderSourceKey('host','\ufeffA')]);
  assert.equal(after.mapping[folderSourceKey('host','B/😀')],before.mapping[folderSourceKey('host','\ufeffA/😀')]);
});
test('invalid source IDs get one persisted ID; duplicate valid IDs, tombstones and cross-scope reservations block',()=>{
  const scope={teamID:uuid(),vaultID:uuid()},a=record('snippet',{text:'exact'},'legacy-id');
  const f=mapLegacyResources({document:legacy([a]),scope,cryptoValue:c});
  assert.equal(mapLegacyResources({document:legacy([a]),scope,previous:f,cryptoValue:c}).resources[0].id,f.resources[0].id);
  const valid=record('host');
  assert.throws(()=>mapLegacyResources({document:legacy([valid,valid]),scope,cryptoValue:c}),/duplicate_source_id/);
  const doc=legacy([valid]);doc.tombstones=[{id:valid.id,version:2,deletedAt:'2026-10-01T00:00:00Z'}];
  assert.throws(()=>mapLegacyResources({document:doc,scope,cryptoValue:c}),/tombstoned_source_id/);
  assert.throws(()=>mapLegacyResources({document:legacy([valid]),scope,reservations:[{id:valid.id,teamID:uuid(),vaultID:uuid(),tombstoned:false}],cryptoValue:c}),/resource_id_collision/);
});
test('explicit folder rename retains folder identities including descendants and rejects ambiguous paths',()=>{
  const scope={teamID:uuid(),vaultID:uuid()},a=record('host',{folder:'A/B'});
  const f=mapLegacyResources({document:legacy([a]),scope,cryptoValue:c});
  const changed={...a,data:{folder:'C/B'}};
  const n=mapLegacyResources({document:legacy([changed]),scope,previous:f,
    folderMoves:[{type:'host',from:'A',to:'C'}],cryptoValue:c});
  assert.equal(n.mapping['folder:host:Qw'],f.mapping['folder:host:QQ']);
  assert.equal(n.mapping['folder:host:Qy9C'],f.mapping['folder:host:QS9C']);
  for(const folder of ['A//B','A/../B','A/./B','/A','A/','A/\u0000B'])
    assert.throws(()=>mapLegacyResources({document:legacy([record('host',{folder})]),scope,cryptoValue:c}),/invalid_folder/);
});
test('custodian metadata preserves tombstones/clocks/source fingerprint without duplicating live payload or SECRET',()=>{
  const scope={teamID:uuid(),vaultID:uuid()},doc=legacy([record('credential',{title:'Name',secret:'NEVER_IN_SIDECAR'})]);
  doc.tombstones=[{id:uuid(),version:{[uuid()]:3},deletedAt:'2026-10-01T00:00:00Z'}];doc.vectorClock={[uuid()]:4};
  const map=mapLegacyResources({document:doc,scope,cryptoValue:c});
  const sidecar=legacyAdministrativeMetadata({document:doc,mapping:map,sourceFingerprint:'a'.repeat(64)});
  assert.deepEqual(sidecar.sourceMetadata.tombstones,doc.tombstones);
  assert.deepEqual(sidecar.sourceMetadata.vectorClock,doc.vectorClock);
  assert.equal(JSON.stringify(sidecar).includes('NEVER_IN_SIDECAR'),false);
  assert.equal(JSON.stringify(sidecar).includes('Name'),false);
  assert.throws(()=>legacyAdministrativeMetadata({document:{...doc,duplicatePayload:doc.records},mapping:map,
    sourceFingerprint:'a'.repeat(64)}),/unsupported_source_metadata/);
});

test('native Forwarding base64url configuration survives inventory byte-exactly',async()=>{
 const {stagingV1Records}=await import('./browser/staging-real-lifecycle.mjs'),forward=stagingV1Records().find(r=>r.type==='forwarding'),document=legacy([{...forward,version:1,modifiedAt:1800000000}]),before=JSON.stringify(document);
 assert.deepEqual(inspectLegacyResources(document).blockers,[]);
 const mapped=mapLegacyResources({document,scope:{teamID:uuid(),vaultID:uuid()},cryptoValue:c});assert.equal(mapped.resources[0].id,forward.id);assert.equal(JSON.stringify(document),before);
 const decoded=JSON.parse(Buffer.from(forward.data.configuration,'base64url'));assert.equal(decoded.id,forward.id);assert.equal(decoded.rule.id,forward.id);
 const sorted=JSON.stringify(decoded,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.keys(v).sort().map(k=>[k,v[k]])):v);assert.equal(forward.data.configuration,Buffer.from(sorted).toString('base64url')); // Native JSONEncoder.sortedKeys + withoutEscapingSlashes + base64url.
});
test('native configuration decoding retains JSON compatibility and rejects opaque, noncanonical, invalid UTF8, wrong shape and embedded secrets',()=>{
 const resourceID=uuid(),native={id:resourceID,connection:{kind:'custom',host:'synthetic.invalid',username:'synthetic',port:22},rule:{id:resourceID,name:'fixture',kind:'local',bindAddress:'127.0.0.1',sourcePort:19090,destinationHost:'127.0.0.1',destinationPort:19091}},encode=value=>Buffer.from(JSON.stringify(value)).toString('base64url');
 const inspect=(type,configuration,key='configuration')=>inspectLegacyResources(legacy([record(type,{[key]:configuration},resourceID)])).blockers;
 assert.deepEqual(inspect('forwarding',JSON.stringify(native)),[]);
 const badUTF8=Buffer.from(JSON.stringify(native));badUTF8[badUTF8.indexOf('synthetic.invalid')]=255;assert.ok(inspect('forwarding',badUTF8.toString('base64url')).includes('opaque_profile_requires_conversion'));
 const tailNative=structuredClone(native);while(Buffer.byteLength(JSON.stringify(tailNative))%3===0)tailNative.rule.name+='x';const canonical=encode(tailNative),alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_',noncanonical=canonical.slice(0,-1)+alphabet[alphabet.indexOf(canonical.at(-1))+1];assert.equal(Buffer.from(canonical,'base64url').equals(Buffer.from(noncanonical,'base64url')),true);assert.ok(inspect('forwarding',noncanonical).includes('opaque_profile_requires_conversion'));
 for(const value of [encode(native)+'=',encode(native)+'!',Buffer.from([0xff]).toString('base64url'),encode([]),encode({}),encode({...native,id:uuid()}),encode({...native,rule:{...native.rule,id:uuid()}}),encode({...native,connection:{...native.connection,unknown:'value'}}),'opaque'])assert.ok(inspect('forwarding',value).includes('opaque_profile_requires_conversion'));
 assert.ok(inspect('host',encode(native)).includes('opaque_profile_requires_conversion'));assert.ok(inspect('forwarding',encode(native),'profile').includes('opaque_profile_requires_conversion'));
 assert.ok(inspect('forwarding',encode({...native,connection:{...native.connection,password:'SYNTHETIC_SECRET'}})).includes('embedded_secret_requires_conversion'));
 assert.ok(inspect('forwarding',JSON.stringify({...native,rule:{...native.rule,token:'SYNTHETIC_SECRET'}})).includes('embedded_secret_requires_conversion'));
});
