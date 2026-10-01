import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto as c } from 'node:crypto';
import { mapLegacyResources, legacyAdministrativeMetadata } from '../public/legacy-resource-mapping.js';
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
