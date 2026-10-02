import test from 'node:test';
import assert from 'node:assert/strict';
import { webcrypto, createHash } from 'node:crypto';
import { uuid } from './vault-v2-migration-fixtures.mjs';
import { publicationHash } from '../public/vault-publication-v1.js';
import { canonicalMigrationJSON } from '../public/vault-v2-migration.js';
import { createAuthenticatedVaultClient } from '../public/vault-sync.js';
const api = await import('../public/whole-publication-api.js').catch(() => ({}));
const teamID = uuid(), vaultID = uuid(), operationID = uuid(), accountID = uuid(), deviceID = uuid(), sessionID = uuid();
const gate = { teamID, publicationAvailable: true, environment: 'staging', current: [{ teamID, vaultID, generationID: uuid(),
  sequence: 1, headerHash: 'a'.repeat(64), resources: [], policy: [], custodianDeviceIDs: [deviceID] }], sessionID, actorKeyVersion: 1,
  groups: [], edges: [], memberships: [], actorRole: 'owner' };

test('whole publication transport authenticates through the existing session and sends mandatory version capabilities', async () => {
  const calls = [], client = createAuthenticatedVaultClient({ fetchValue: async (path, options) => {
    calls.push({ path, options }); return new Response(JSON.stringify(path === '/v1/auth/login' ? {
      token: 's'.repeat(32), deviceID, user: { id: accountID, email: 'fixture@example.invalid', username: 'fixture', displayName: 'Fixture' } } : gate));
  } });
  await client.login({ email: 'fixture@example.invalid', password: 'SYNTHETIC-PASSWORD', deviceID });
  assert.equal(typeof client.wholePublicationTransport, 'function', 'authenticated publication transport is missing');
  const transport = client.wholePublicationTransport(teamID); await transport.context();
  const request = calls.at(-1);
  assert.equal(request.path, `/v1/teams/${teamID}/publication/context`);
  assert.equal(request.options.headers.Authorization, 'Bearer ' + 's'.repeat(32));
  assert.equal(request.options.headers['X-Vault-Schema-Version'], '2');
  assert.equal(request.options.headers['X-Vault-Capability'], 'resource_acl_v2');
  assert.equal(request.options.headers['X-Publication-Version'], '1');
  assert.equal(request.options.credentials, 'same-origin');
  await transport.context({operationID});assert.equal(calls.at(-1).path,`/v1/teams/${teamID}/publication/operations/${operationID}/context`);
});

test('context requires explicit staging capability and rejects stale identity before returning authoritative data', async () => {
  for (const mutation of [g => g.environment = 'production', g => g.publicationAvailable = false, g => g.teamID = uuid()]) {
    const body = structuredClone(gate); mutation(body);
    const transport = api.createWholePublicationTransport({ teamID, getIdentity: () => ({ accountID, deviceID, sessionEpoch: '1' }),
      request: async () => new Response(JSON.stringify(body)), cryptoValue: webcrypto });
    await assert.rejects(transport.context(), /publication_unavailable|publication_scope_mismatch/);
  }
  let current = { accountID, deviceID, sessionEpoch: '1' };
  const transport = api.createWholePublicationTransport({ teamID, getIdentity: () => current, request: async () => {
    current = null; return new Response(JSON.stringify(gate)); }, cryptoValue: webcrypto });
  await assert.rejects(transport.context(), /publication_context_changed/);
});

test('projection chunks carry exact immutable canonical bytes and stop on an invalid assembly acknowledgment', async () => {
  const expectedHeader = {version:1,synthetic:'chunk-header'}, expectedHash = await publicationHash('header',expectedHeader,webcrypto);
  const calls = [], transport = api.createWholePublicationTransport({ teamID, getIdentity: () => ({ accountID, deviceID, sessionEpoch: '1' }), cryptoValue: webcrypto,
    request: async (path, options) => { const body = JSON.parse(options.body); calls.push({ path, body }); return new Response(JSON.stringify({ complete: body.index === body.count - 1,
      ...(body.index === body.count - 1 ? { headerHash: expectedHash } : {}) })); } });
  const projection = { header: expectedHeader, ciphertext: 'A'.repeat(1024 * 1024 + 5) }, sidecar = { envelope: { ciphertext: 'B'.repeat(8) } }, checkpoint = { version: 1, nonce: 'AA', ciphertext: 'CC' };
  await transport.putProjection(operationID, vaultID, projection, sidecar, checkpoint);
  assert.equal(calls.length, 3);
  assert.ok(calls.every(c => c.path === `/v1/teams/${teamID}/publication/operations/${operationID}/projection-chunks/${vaultID}`));
  const reconstructed = Buffer.concat(calls.map(c => Buffer.from(c.body.data, 'base64url')));
  assert.equal(reconstructed.toString(), canonicalMigrationJSON({ projection, sidecar, checkpoint }));
  assert.ok(calls.every(c => Buffer.from(c.body.data, 'base64url').length <= 512 * 1024));
  assert.equal(calls[0].body.sha256, createHash('sha256').update(reconstructed).digest('hex'));
  const broken = api.createWholePublicationTransport({ teamID, getIdentity: () => ({ accountID, deviceID, sessionEpoch: '1' }), cryptoValue: webcrypto,
    request: async () => new Response(JSON.stringify({ complete: true })) });
  await assert.rejects(broken.putProjection(operationID, vaultID, projection, sidecar, checkpoint), /publication_response_invalid/);
});

test('repair and mutation bodies contain bounded protocol fields and server errors stay typed', async () => {
  const calls = [], request = { version: 1, teamID, operationID, vaults: [], groupMutation: null };
  const transport = api.createWholePublicationTransport({ teamID, getIdentity: () => ({ accountID, deviceID, sessionEpoch: '1' }), cryptoValue: webcrypto,
    request: async (path, options) => { calls.push({ path, body: options.body && JSON.parse(options.body) }); return new Response('{}'); } });
  await transport.preview(request, { token: 't', cursor: 'c' }); await transport.start('t', request);
  await transport.repairDirectory({ token: 't', request }, vaultID, 'c');
  await transport.repairPart({ token: 't', request }, vaultID, deviceID, 'ADMINISTRATIVE');
  await transport.commit(operationID, 't', request);
  assert.deepEqual(calls.map(c => c.body), [{ request, token: 't', cursor: 'c' }, { token: 't', request },
    { token: 't', request, vaultID, cursor: 'c' }, { token: 't', request, vaultID, resourceID: deviceID, part: 'ADMINISTRATIVE' }, { token: 't', request }]);
  const denied = api.createWholePublicationTransport({ teamID, getIdentity: () => ({ accountID, deviceID, sessionEpoch: '1' }),
    request: async () => new Response(JSON.stringify({ error: 'publication_custodian_unavailable' }), { status: 403 }) });
  await assert.rejects(denied.context(), /publication_custodian_unavailable/);
});


test('COMMITTED recovery-only context is confined to an owned operation and never admits policy data',async()=>{
  const body={...structuredClone(gate),actorRole:null,operationState:'COMMITTED',recoveryOnly:true,current:[{...gate.current[0],custodianDeviceIDs:[]}]};
  const transport=api.createWholePublicationTransport({teamID,getIdentity:()=>({accountID,deviceID}),request:async()=>new Response(JSON.stringify(body))});
  assert.equal((await transport.context({operationID})).recoveryOnly,true);await assert.rejects(transport.context(),/publication_unavailable/);
  body.current[0].policy=[{id:uuid()}];await assert.rejects(transport.context({operationID}),/publication_unavailable/);
});


test('completed multi-chunk replay accepts only the exact expected header commitment',async()=>{
 const {publicationHash}=await import('../public/vault-publication-v1.js');
 const projection={header:{version:1,synthetic:'commitment'},ciphertext:'A'.repeat(600000)},sidecar={envelope:{}},checkpoint={version:1,nonce:'AA',ciphertext:'CC'};
 const headerHash=await publicationHash('header',projection.header,webcrypto);let calls=0;
 const transport=api.createWholePublicationTransport({teamID,getIdentity:()=>({accountID,deviceID}),cryptoValue:webcrypto,request:async()=>{calls++;return new Response(JSON.stringify({complete:true,headerHash}));}});
 await transport.putProjection(operationID,vaultID,projection,sidecar,checkpoint);assert.ok(calls>=1);
 const forged=api.createWholePublicationTransport({teamID,getIdentity:()=>({accountID,deviceID}),cryptoValue:webcrypto,request:async()=>new Response(JSON.stringify({complete:true,headerHash:'b'.repeat(64)}))});
 await assert.rejects(forged.putProjection(operationID,vaultID,projection,sidecar,checkpoint),/publication_response_invalid/);
});
