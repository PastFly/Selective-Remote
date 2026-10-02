import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash, webcrypto } from 'node:crypto';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { migrationFixture, uuid, legacy, record } from './vault-v2-migration-fixtures.mjs';
import { canonicalMigrationJSON, migrationBytes, fromBase64, prepareLegacyMigration } from '../public/vault-v2-migration.js';
import { unwrapResourceCEK, decryptResourcePart } from '../public/resource-crypto-v2.js';
import { publicationHash } from '../public/vault-publication-v1.js';
const api = await import('../public/whole-publication-client.js').catch(() => ({}));
const hash = value => createHash('sha256').update(canonicalMigrationJSON(value)).digest('hex');
const clone = structuredClone;

function localStorage() {
  const records = new Map();
  return { records, async load(key) { return clone(records.get(key) ?? null); },
    async keys(){return [...records.keys()];},
    async putIfAbsent(key, value) { if (records.has(key)) return clone(records.get(key)); records.set(key, clone(value)); return clone(value); },
    async save(key, value) { records.set(key, clone(value)); } };
}
async function fixture() {
  const f = await migrationFixture(), resourceID = uuid(), sessionID = uuid(), operationID = uuid();
  const predecessor = { vaultID: f.scope.vaultID, generationID: uuid(), sequence: 1, headerHash: 'c'.repeat(64) };
  const resources = [{ id: resourceID, kind: 'CREDENTIAL', parentFolderID: null, sourceOrdinal: 0 }];
  const request = { version: 1, teamID: f.scope.teamID, operationID, vaults: [{ vaultID: f.scope.vaultID, resources,
    policy: [], contentChanges: [], custodianDeviceIDs: [f.deviceID] }], groupMutation: null };
  const target = { ...f.recipient, deviceKeyVersion: 1 };
  const generation = { vaultID: f.scope.vaultID, generationID: uuid(), sequence: 2, previousHash: predecessor.headerHash,
    scope: { ...f.scope, attemptID: uuid(), policyVersion: 2 }, snapshot: { devices: [target], sourceRevision: 1, policyVersion: 2 } };
  generation.scope.attemptID = generation.generationID;
  const rows = ['METADATA', 'SECRET'].map(part => ({ type: 'PART', vaultID: f.scope.vaultID, resourceID, part, devices: [target] }));
  rows.push({ type: 'CUSTODY', vaultID: f.scope.vaultID, devices: [target] });
  const binding = { version: 1, teamID: request.teamID, operationID, actorAccountID: f.accountID, sessionID,
    actorDeviceID: f.deviceID, keyVersion: 1, requestHash: hash(request), readSetHash: 'd'.repeat(64), successorHash: 'e'.repeat(64),
    policyHash: 'f'.repeat(64), recipientHash: 'a'.repeat(64), predecessors: [predecessor],
    counts: { vaults: 1, resources: 1, parts: 3, wrappers: 3 }, effectiveAt: '2026-10-02T00:00:00Z', rowsHash: hash(rows), rowCount: rows.length };
  generation.scope.snapshotHash = hash(generation.snapshot);
  generation.scope.sourceHash = hash({ operationID, requestHash: binding.requestHash, readSetHash: binding.readSetHash, predecessor: predecessor.headerHash });
  const recipient = { accountID: target.accountID, deviceID: target.deviceID, membershipID: target.membershipID, membershipEpoch: 1, deviceKeyVersion: 1 };
  binding.policyHash = hash([{ vaultID: f.scope.vaultID, policy: [] }]);
  binding.recipientHash = hash([{ vaultID: f.scope.vaultID, parts: ['METADATA', 'SECRET'].map(part => ({ resourceID, part, devices: [recipient] })), custodians: [recipient] }]);
  binding.successorHash = hash([{ vaultID: f.scope.vaultID, sequence: 2, previousHash: predecessor.headerHash, resources, policyHash: hash([]), snapshot: generation.snapshot }]);
  const preview = { token: 'signed-server-preview', request, binding, generations: [generation], rows, nextCursor: null };
  const link = part => ({ teamID: request.teamID, vaultID: f.scope.vaultID, generationID: predecessor.generationID, resourceID, kind: 'CREDENTIAL', part });
  const plaintextByVault = { [f.scope.vaultID]: { verified: true, predecessor, parts: { [resourceID]: {
    METADATA: { link: link('METADATA'), metadata: { title: 'Login', username: 'alice' } },
    SECRET: { link: link('SECRET'), record: { id: uuid(), type: 'credential', version: 1, modifiedAt: 1800000000,
      data: { kind: 'password', secret: 'SYNTHETIC-SECRET', username: 'alice', title: 'Login' } } } } } } };
  const administrativeByVault = { [f.scope.vaultID]: { verified: true, predecessor, data: { version: 1,
    teamID: request.teamID, vaultID: f.scope.vaultID, generationID: predecessor.generationID,
    mapping: { 'credential/legacy-id': resourceID }, tombstones: [], vectorClock: {} } } };
  let current = { endpoint: f.endpoint, accountID: f.accountID, deviceID: f.deviceID, sessionID, keyVersion: 1, predecessors: [predecessor] };
  const storage = localStorage();
  const options = { ...f, preview, plaintextByVault, administrativeByVault, getIdentity: () => clone(current), cryptoValue: webcrypto };
  return { ...f, resourceID, request, preview, storage, options,
    setIdentity(value) { current = value; }, getIdentity: () => clone(current) };
}
const repository = f => api.createWholePublicationCheckpointRepository({ storage: f.storage, cryptoValue: webcrypto });
const prepare = f => api.prepareWholePublication({ ...f.options, checkpointRepository: repository(f) });
async function opened(f, object) {
  const wrapper = object.wrappers.find(w => w.context.deviceID === f.deviceID);
  const cek = await unwrapResourceCEK({ wrapper, context: wrapper.context, privateKey: f.identity.privateKey, cryptoValue: webcrypto });
  try { return { payload: JSON.parse(new TextDecoder().decode(await decryptResourcePart({ envelope: object.envelope,
    context: object.envelope.context, cek, cryptoValue: webcrypto }))), key: Buffer.from(cek).toString('hex') }; }
  finally { cek.fill(0); }
}

test('local canonical order is bound before preview and does not permit a server to change the intent',async()=>{
  assert.equal(typeof api.canonicalWholePublicationRequest,'function');const f=await fixture();
  f.request.vaults[0].contentChanges=['SECRET','METADATA'].map(part=>({resourceID:f.resourceID,part}));
  const canonical=api.canonicalWholePublicationRequest(f.request);
  f.preview.request=canonical;f.preview.binding.requestHash=hash(canonical);f.preview.generations[0].scope.sourceHash=hash({operationID:f.request.operationID,requestHash:f.preview.binding.requestHash,readSetHash:f.preview.binding.readSetHash,predecessor:f.preview.binding.predecessors[0].headerHash});
  const result=await api.collectWholePublicationPreview({request:f.request,transport:{preview:async request=>{assert.deepEqual(request,canonical);return f.preview;}},getIdentity:f.getIdentity,cryptoValue:webcrypto});assert.deepEqual(result.request,canonical);
  const a={id:'b',kind:'HOST'},b={id:'a',kind:'HOST'};
  assert.deepEqual(api.canonicalWholePublicationRequest({...f.request,vaults:[{...f.request.vaults[0],resources:[a,b]}]}).vaults[0].resources,[b,a]);
  const changed=clone(f.preview);changed.request.vaults[0].contentChanges=[];
  await assert.rejects(api.collectWholePublicationPreview({request:f.request,transport:{preview:async()=>changed},getIdentity:f.getIdentity,cryptoValue:webcrypto}),/publication_preview_invalid/);
});
test('pending discovery is locally protected and scoped; completion appears only after verified readback',async()=>{
  const f=await fixture(),repo=repository(f);await api.prepareWholePublication({...f.options,checkpointRepository:repo});
  assert.equal(typeof repo.pending,'function');const scope={...f.getIdentity(),teamID:f.request.teamID};
  assert.equal((await repo.pending(scope))[0].state.request.operationID,f.request.operationID);
  assert.deepEqual(await repo.pending({...scope,accountID:uuid()}),[]);
  const load=f.storage.load;f.storage.load=async key=>{assert.ok(!key.startsWith('checkpoint:'),'metadata discovery must not open an old prepared payload');return load(key);};
  assert.equal((await repo.discover({...scope,sessionID:uuid()}))[0].operationID,f.request.operationID);f.storage.load=load;
  await repo.markComplete({...scope,operationID:f.request.operationID},{operationID:f.request.operationID});
  assert.deepEqual(await repo.pending(scope),[]);
  const completion=[...f.storage.records.entries()].find(([k])=>k.startsWith('complete:'));
  completion[1].ciphertext=completion[1].ciphertext.replace(/^./u,completion[1].ciphertext[0]==='A'?'B':'A');
  await assert.rejects(repo.pending(scope),/publication_checkpoint_lost/);
});

test('complete preparation encrypts and signs all parts freshly, including unchanged secrets and administrative custody', async () => {
  assert.equal(typeof api.prepareWholePublication, 'function', 'whole publication preparation is missing');
  const f = await fixture(), out = await prepare(f), g = out.generations[0];
  assert.equal(g.objects.length, 2);
  const keys = [];
  for (const object of [...g.objects, g.administrativeSidecar]) {
    const value = await opened(f, object); keys.push(value.key);
    assert.equal(object.envelope.context.keyVersion, 2);
    assert.equal(object.envelope.context.registryVersion, 2);
    assert.equal(object.envelope.context.resourceVersion, 2);
    assert.equal(object.envelope.context.manifestVersion, 2);
    assert.equal(object.envelope.context.policyVersion, 2);
    assert.equal(object.wrappers[0].context.keyVersion, 2);
    assert.equal(value.payload.generationID ?? value.payload.link.generationID, g.generationID);
    if (object.part === 'SECRET' && object.resourceID === f.resourceID) assert.equal(value.payload.record.data.secret, 'SYNTHETIC-SECRET');
  }
  assert.equal(new Set(keys).size, 3);
  assert.equal(g.readerProjection.header.payload.sequence, 2);
  assert.equal(g.readerProjection.header.payload.previousHash, 'c'.repeat(64));
  const rootKey = await webcrypto.subtle.importKey('raw', fromBase64(f.root.publicKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  assert.equal(await webcrypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, rootKey, fromBase64(g.manifest.signature), migrationBytes(g.manifest.payload)), true);
  const checkpoint = await repository(f).load({ ...f.getIdentity(), teamID: f.request.teamID, operationID: f.request.operationID });
  assert.deepEqual(checkpoint.state.generations, out.generations);
  assert.equal(JSON.stringify([...f.storage.records.values()]).includes('SYNTHETIC-SECRET'), false);
  const f2 = await fixture(); f2.options.plaintextByVault = clone(f.options.plaintextByVault);
  f2.options.preview = clone(f.preview); f2.options.preview.request.operationID = f2.request.operationID;
  f2.options.preview.binding.operationID = f2.request.operationID; f2.options.preview.binding.requestHash = hash(f2.options.preview.request);
  f2.options.preview.generations[0].scope.sourceHash = hash({ operationID: f2.request.operationID, requestHash: f2.options.preview.binding.requestHash,
    readSetHash: f2.options.preview.binding.readSetHash, predecessor: f2.options.preview.generations[0].previousHash });
  f2.options.getIdentity = f.getIdentity; f2.options.root = f.root; f2.options.identity = f.identity; f2.options.deviceID = f.deviceID;
  f2.options.endpoint = f.endpoint; f2.options.pinnedTrust = f.pinnedTrust;
  f2.options.administrativeByVault = f.options.administrativeByVault;
  const next = await prepare(f2);
  for (let i = 0; i < g.objects.length; i++) {
    assert.notEqual(next.generations[0].objects[i].envelope.nonce, g.objects[i].envelope.nonce);
    assert.notEqual((await opened(f, next.generations[0].objects[i])).key, keys[i]);
  }
});

test('Admin cannot prepare missing SECRET, unverified predecessor, missing sidecar or absent independent trust', async () => {
  for (const variant of ['secret', 'trust', 'sidecar', 'local', 'predecessor', 'root', 'key']) {
    const f = await fixture();
    if (variant === 'secret') delete f.options.plaintextByVault[f.scope.vaultID].parts[f.resourceID].SECRET;
    if (variant === 'sidecar') delete f.options.administrativeByVault[f.scope.vaultID];
    if (variant === 'local') f.options.plaintextByVault[f.scope.vaultID].verified = false;
    if (variant === 'predecessor') f.options.plaintextByVault[f.scope.vaultID].predecessor = { ...f.options.plaintextByVault[f.scope.vaultID].predecessor, headerHash: '0'.repeat(64) };
    if (variant === 'trust') f.options.pinnedTrust = { loadPin: async () => null, advancePin: async () => assert.fail('unverified pin advanced') };
    if (variant === 'root') f.options.root = { ...f.root, privateKey: null };
    if (variant === 'key') f.options.identity = { ...f.identity, privateKey: null };
    await assert.rejects(prepare(f), variant === 'trust' ? /recipient_trust_unverified/ : /publication_custodian_unavailable|publication_stale/);
    assert.equal(f.storage.records.size, 0);
  }
});

test('preview exhausts pages and rejects row tampering, duplicates, count mismatch and changing scope before confirmation', async () => {
  const f = await fixture(); let pages = 0;
  const transport = { async preview(request, { cursor } = {}) { pages++; return { ...clone(f.preview), rows: cursor ? f.preview.rows.slice(1) : f.preview.rows.slice(0, 1), nextCursor: cursor ? null : 'second' }; } };
  const result = await api.collectWholePublicationPreview({ request: f.request, transport, getIdentity: f.getIdentity, cryptoValue: webcrypto });
  assert.equal(result.rows.length, 3); assert.equal(pages, 2);
  for (const mutate of [p => p.rows[0].part = 'SECRET', p => p.binding.counts.parts++, p => p.binding.rowsHash = '0'.repeat(64),
    p => p.binding.policyHash = '0'.repeat(64), p => p.binding.recipientHash = '0'.repeat(64), p => p.binding.successorHash = '0'.repeat(64),
    p => p.generations[0].scope.snapshotHash = '0'.repeat(64)]) {
    const value = clone(f.preview); mutate(value);
    await assert.rejects(api.collectWholePublicationPreview({ request: f.request, transport: { preview: async () => value }, getIdentity: f.getIdentity, cryptoValue: webcrypto }), /publication_preview_invalid/);
  }
});

test('checkpoint persistence failure and identity changes during crypto prevent transport writes', async () => {
  for (const change of ['save', 'logout', 'endpoint', 'accountID', 'deviceID', 'predecessors']) {
    const f = await fixture(); const saved = f.storage.save;
    f.storage.save = async (...args) => { if (change === 'save') throw Error('disk_failure'); return saved(...args); };
    if (change !== 'save') f.options.pinnedTrust = { ...f.pinnedTrust, async loadPin(...args) {
      const old = f.getIdentity(); f.setIdentity(change === 'logout' ? null : { ...old, [change]: change === 'predecessors' ? [] : change === 'endpoint' ? 'https://other.example' : uuid() });
      return f.pinnedTrust.loadPin(...args);
    } };
    let writes = 0;
    const coordinator = api.createWholePublicationCoordinator({ ...f.options, checkpointRepository: repository(f),
      transport: { preview: async () => f.preview, start: async () => { writes++; } } });
    await assert.rejects(coordinator.prepare({ request: f.request, plaintextByVault: f.options.plaintextByVault, administrativeByVault: f.options.administrativeByVault }), /disk_failure|publication_context_changed/);
    assert.equal(writes, 0);
  }
});

test('resume reuses persisted bytes after upload failure and rejects changed request or lost local protection', async () => {
  const f = await fixture(), repo = repository(f); let fail = true; const accepted = [];
  const transport = { preview: async () => clone(f.preview), start: async () => ({ generations: f.preview.generations }),
    putPart: async (_op, _vault, object) => { accepted.push(clone(object)); if (fail) { fail = false; throw Error('network_failure'); } },
    putProjection: async () => {}, validate: async () => ({ state: 'READY' }) };
  const coordinator = api.createWholePublicationCoordinator({ ...f.options, transport, checkpointRepository: repo });
  await assert.rejects(coordinator.prepare({ request: f.request, plaintextByVault: f.options.plaintextByVault, administrativeByVault: f.options.administrativeByVault }), /network_failure/);
  const resumed = await coordinator.resume({ request: f.request });
  assert.deepEqual(accepted[0], accepted[1]); assert.equal(resumed.generations.length, 1);
  const changed = clone(f.request); changed.vaults[0].contentChanges = [{ resourceID: f.resourceID, part: 'SECRET' }];
  await assert.rejects(coordinator.resume({ request: changed }), /publication_resume_changed/);
  for (const key of f.storage.records.keys()) if (key.startsWith('protection:')) f.storage.records.delete(key);
  await assert.rejects(coordinator.resume({ request: f.request }), /publication_checkpoint_lost/);
});

test('checkpoint loss prohibits preparing the same operation with fresh ciphertext', async () => {
  const f = await fixture(); await prepare(f);
  for (const key of f.storage.records.keys()) if (key.startsWith('checkpoint:')) f.storage.records.delete(key);
  await assert.rejects(prepare(f), /publication_checkpoint_lost|publication_operation_exists/);
});

test('real initial migration administrative metadata without plaintext team or vault fields can be republished', async () => {
  const f = await fixture(), initial = await prepareLegacyMigration({ ...f, document: legacy([record('credential', {
    kind: 'password', title: 'Login', username: 'alice', secret: 'SYNTHETIC-SECRET' })]), policy: [],
    recipientTargets: () => [f.recipient], persistCheckpoint: async () => {}, cryptoValue: webcrypto,
    readerPublication: { publisherAccountID: f.accountID, publisherKeyVersion: 1, custodianDeviceIDs: [f.deviceID],
      custodianTargets: [f.recipient], verifyIdentityReservations: async () => {} } });
  const administrative = (await opened(f, initial.administrativeSidecar)).payload;
  assert.equal(administrative.teamID, undefined); assert.equal(administrative.vaultID, undefined);
  administrative.generationID = f.preview.binding.predecessors[0].generationID;
  f.options.administrativeByVault[f.scope.vaultID].data = administrative;
  const out = await prepare(f);
  assert.deepEqual((await opened(f, out.generations[0].administrativeSidecar)).payload.mapping, administrative.mapping);
});

test('failed ciphertext authentication stops preparation before durable state', async () => {
  const f = await fixture();
  const brokenCrypto = { getRandomValues: v => webcrypto.getRandomValues(v), randomUUID: () => webcrypto.randomUUID(), subtle: new Proxy(webcrypto.subtle, {
    get(target, property) {
      if (property === 'encrypt') return async (...args) => { const bytes = new Uint8Array(await target.encrypt(...args)); bytes[0] ^= 1; return bytes.buffer; };
      const value = target[property]; return typeof value === 'function' ? value.bind(target) : value;
    } }) };
  await assert.rejects(api.prepareWholePublication({ ...f.options, checkpointRepository: repository(f), cryptoValue: brokenCrypto }), /publication_roundtrip_failed/);
  assert.equal(f.storage.records.size, 0);
});

test('source edits during an awaited trust read invalidate preparation before persistence', async () => {
  const f = await fixture();
  f.options.pinnedTrust = { ...f.pinnedTrust, async loadPin(...args) {
    f.options.plaintextByVault[f.scope.vaultID].parts[f.resourceID].SECRET.record.data.secret = 'CHANGED-WHILE-AWAITING';
    return f.pinnedTrust.loadPin(...args);
  } };
  await assert.rejects(prepare(f), /publication_source_changed/);
  assert.equal(f.storage.records.size, 0);
});

test('cross-account recipients require a separate existing pin and receive independently decryptable exact wrappers', async () => {
  const f = await fixture(), other = await migrationFixture(), recipient = { ...other.recipient, deviceKeyVersion: 1 };
  const g = f.preview.generations[0]; g.snapshot.devices.push(recipient);
  for (const row of f.preview.rows.filter(r => r.type === 'PART')) row.devices.push(recipient);
  f.preview.binding.counts.wrappers = 5; f.preview.binding.rowsHash = hash(f.preview.rows);
  const identities = row => row.devices.map(t => ({ accountID: t.accountID, deviceID: t.deviceID, membershipID: t.membershipID,
    membershipEpoch: t.membershipEpoch, deviceKeyVersion: t.certificate.payload.keyVersion })).sort((a, b) => a.deviceID.localeCompare(b.deviceID));
  f.preview.binding.recipientHash = hash([{ vaultID: f.scope.vaultID, parts: f.preview.rows.filter(r => r.type === 'PART').map(r => ({ resourceID: r.resourceID,
    part: r.part, devices: identities(r) })), custodians: identities(f.preview.rows.find(r => r.type === 'CUSTODY')) }]);
  g.scope.snapshotHash = hash(g.snapshot);
  f.preview.binding.successorHash = hash([{ vaultID: f.scope.vaultID, sequence: 2, previousHash: g.previousHash,
    resources: f.request.vaults[0].resources, policyHash: hash([]), snapshot: g.snapshot }]);
  f.options.pinnedTrust = { loadPin: async (_endpoint, account) => account === f.accountID ? f.pinnedTrust.loadPin() : null, advancePin: async () => {} };
  await assert.rejects(prepare(f), /recipient_trust_unverified/); assert.equal(f.storage.records.size, 0);
  f.options.pinnedTrust.loadPin = async (_endpoint, account) => account === f.accountID ? f.pinnedTrust.loadPin() : other.pinnedTrust.loadPin();
  const out = await prepare(f), secret = out.generations[0].objects.find(o => o.part === 'SECRET');
  assert.equal((await opened(other, secret)).payload.record.data.secret, 'SYNTHETIC-SECRET');
  assert.equal(secret.wrappers.length, 2); assert.equal(out.generations[0].administrativeSidecar.wrappers.length, 1);
});

test('encoded part budget rejects a large secret before persistence or upload', async () => {
  const f = await fixture(); f.options.plaintextByVault[f.scope.vaultID].parts[f.resourceID].SECRET.record.data.secret = 'S'.repeat(1024 * 1024);
  await assert.rejects(prepare(f), /publication_limit/); assert.equal(f.storage.records.size, 0);
});

test('part size guard accepts the largest encodable part and rejects its next plaintext byte', async () => {
  const sample = await fixture(), first = await prepare(sample), object = first.generations[0].objects.find(o => o.part === 'SECRET');
  const overhead = Buffer.byteLength(canonicalMigrationJSON({object})) - object.envelope.ciphertext.length;
  const plain = sample.options.plaintextByVault[sample.scope.vaultID].parts[sample.resourceID].SECRET;
  const baseBytes = Buffer.byteLength(canonicalMigrationJSON(plain)) - plain.record.data.secret.length;
  const capacity = 1024 * 1024 - overhead;
  let largestPlaintext = Math.floor(capacity * 3 / 4);
  while (Math.ceil((largestPlaintext + 1) * 4 / 3) <= capacity) largestPlaintext++;
  while (Math.ceil(largestPlaintext * 4 / 3) > capacity) largestPlaintext--;
  const valid = await fixture(); valid.options.plaintextByVault[valid.scope.vaultID].parts[valid.resourceID].SECRET.record.data.secret = 'S'.repeat(largestPlaintext - baseBytes);
  const out = await prepare(valid), prepared = out.generations[0].objects.find(o => o.part === 'SECRET');
  assert.ok(Buffer.byteLength(canonicalMigrationJSON({object:prepared})) <= 1024 * 1024);
  assert.ok(Buffer.byteLength(canonicalMigrationJSON({object:prepared})) >= 1024 * 1024 - 1);
  const invalid = await fixture(); invalid.options.plaintextByVault[invalid.scope.vaultID].parts[invalid.resourceID].SECRET.record.data.secret = 'S'.repeat(largestPlaintext - baseBytes + 1);
  await assert.rejects(prepare(invalid), /publication_limit/); assert.equal(invalid.storage.records.size, 0);
});

test('two complete Vault generations preserve different admission records for the same verified publishing device', async () => {
  const f = await fixture(), v1 = f.request.vaults[0], g1 = f.preview.generations[0], vaultID = uuid(), resourceID = uuid();
  const predecessor = { vaultID, generationID: uuid(), sequence: 5, headerHash: '1'.repeat(64) };
  const target = { ...f.recipient, deviceKeyVersion: 1, admissionID: uuid() };
  const v2 = { ...clone(v1), vaultID, resources: [{ ...v1.resources[0], id: resourceID }] };
  f.request.vaults.push(v2); f.request.vaults.sort((a, b) => a.vaultID.localeCompare(b.vaultID));
  const g2 = { ...clone(g1), vaultID, generationID: uuid(), sequence: 6, previousHash: predecessor.headerHash,
    scope: { ...g1.scope, vaultID }, snapshot: { ...g1.snapshot, devices: [target] } };
  g2.scope.attemptID = g2.generationID; g2.scope.snapshotHash = hash(g2.snapshot);
  f.preview.generations.push(g2); f.preview.generations.sort((a, b) => a.vaultID.localeCompare(b.vaultID));
  f.preview.binding.predecessors.push(predecessor); f.preview.binding.predecessors.sort((a, b) => a.vaultID.localeCompare(b.vaultID));
  f.preview.rows.push(...['METADATA', 'SECRET'].map(part => ({ type: 'PART', vaultID, resourceID, part, devices: [target] })), { type: 'CUSTODY', vaultID, devices: [target] });
  const b = f.preview.binding; b.requestHash = hash(f.request); b.rowCount = 6; b.rowsHash = hash(f.preview.rows); b.counts = { vaults: 2, resources: 2, parts: 6, wrappers: 6 };
  for (const g of [g1, g2]) g.scope.sourceHash = hash({ operationID: f.request.operationID, requestHash: b.requestHash, readSetHash: b.readSetHash, predecessor: g.previousHash });
  b.policyHash = hash(f.request.vaults.map(v => ({ vaultID: v.vaultID, policy: [] })));
  b.successorHash = hash(f.request.vaults.map(v => { const g = f.preview.generations.find(g => g.vaultID === v.vaultID); return { vaultID: v.vaultID,
    sequence: g.sequence, previousHash: g.previousHash, resources: v.resources, policyHash: hash([]), snapshot: g.snapshot }; }));
  const recipient = { accountID: f.accountID, deviceID: f.deviceID, membershipID: f.recipient.membershipID, membershipEpoch: 1, deviceKeyVersion: 1 };
  b.recipientHash = hash(f.request.vaults.map(v => ({ vaultID: v.vaultID, parts: ['METADATA', 'SECRET'].map(part => ({ resourceID: v.resources[0].id, part, devices: [recipient] })), custodians: [recipient] })));
  const oldParts = f.options.plaintextByVault[f.scope.vaultID].parts[f.resourceID], parts = clone(oldParts);
  for (const part of ['METADATA', 'SECRET']) Object.assign(parts[part].link, { vaultID, resourceID, generationID: predecessor.generationID });
  f.options.plaintextByVault[vaultID] = { verified: true, predecessor, parts: { [resourceID]: parts } };
  f.options.administrativeByVault[vaultID] = { verified: true, predecessor, data: { ...clone(f.options.administrativeByVault[f.scope.vaultID].data), vaultID, generationID: predecessor.generationID } };
  f.setIdentity({ ...f.getIdentity(), predecessors: b.predecessors });
  const out = await prepare(f); assert.equal(out.generations.length, 2);
  assert.deepEqual(out.generations.map(g => g.sequence).sort((a, b) => a - b), [2, 6]);
  for (const g of out.generations) for (const object of g.objects) assert.equal((await opened(f, object)).payload.link.vaultID, g.vaultID);
});

test('lost commit result persists a scoped receipt and blocks further writes until exact readback, across restart', async () => {
  const f = await fixture(), out = await prepare(f), g = out.generations[0];
  const receipt = { operationID: f.request.operationID, teamID: f.request.teamID, requestHash: f.preview.binding.requestHash,
    actorAccountID: f.accountID, actorDeviceID: f.deviceID, committedAt: '2026-10-02T00:00:01Z', vaults: [{ vaultID: f.scope.vaultID,
      generationID: g.generationID, sequence: 2, headerHash: await publicationHash('header', g.readerProjection.header, webcrypto) }] };
  let committed = false, readback = false, starts = 0;
  const transport = { preview: async () => { if (committed) throw Error('publication_stale'); return clone(f.preview); },
    receipt: async () => committed ? clone(receipt) : null,
    commit: async () => { committed = true; throw Error('response_lost'); }, start: async () => { starts++; } };
  const options = { ...f.options, transport, checkpointRepository: repository(f), readback: async () => readback ? { vaults: [{ vaultID: g.vaultID,
    header: clone(g.readerProjection.header), headerHash: receipt.vaults[0].headerHash, manifest: clone(g.manifest) }] } : { vaults: [] } };
  const first = api.createWholePublicationCoordinator(options);
  await assert.rejects(first.commit({ request: f.request }), /publication_readback_required/);
  assert.equal(first.writesBlocked, true); assert.deepEqual(first.pendingReceipt, receipt);
  const restarted = api.createWholePublicationCoordinator(options);
  await assert.rejects(restarted.resume({ request: f.request }), /publication_readback_required/);
  assert.equal(starts, 0); assert.equal(restarted.writesBlocked, true);
  const oldIdentity=f.getIdentity();f.setIdentity({...oldIdentity,sessionID:uuid()});const renewed=api.createWholePublicationCoordinator(options);
  await assert.rejects(renewed.resume({request:f.request}),/publication_checkpoint_lost/);
  await assert.rejects(renewed.recoverCommitted({request:f.request,checkpointIdentity:oldIdentity}),/publication_readback_required/);
  readback = true;
  assert.deepEqual(await renewed.recoverCommitted({request:f.request,checkpointIdentity:oldIdentity}),receipt);assert.equal(starts,0);
  f.setIdentity(oldIdentity);
  assert.deepEqual(await restarted.commit({ request: f.request }), receipt);
  assert.equal(restarted.writesBlocked, false);
  const foreign = clone(receipt); foreign.vaults[0].headerHash = '0'.repeat(64);
  const wrong = api.createWholePublicationCoordinator({ ...options, checkpointRepository: repository(await fixture()), transport: { ...transport, receipt: async () => foreign } });
  // A receipt cannot be interpreted without its protected matching prepared state.
  await assert.rejects(wrong.commit({ request: f.request }), /publication_checkpoint_lost/);
});

// Opt-in real browser gate, matching existing browser acceptance tooling.
if (process.env.PLAYWRIGHT_MODULE && process.env.CHROMIUM_PATH) test('real Chromium IndexedDB survives reload with nonextractable protection and rejects scope/key loss', async () => {
  const { chromium } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE));
  const server = createServer(async (request, response) => {
    try {
      const path = new URL(request.url, 'http://localhost').pathname;
      if (path === '/') { response.setHeader('Content-Type', 'text/html'); response.end('<!doctype html><title>Whole publication checkpoint test</title>'); return; }
      if (!/^\/[a-z0-9-]+\.js$/u.test(path)) throw Error();
      response.setHeader('Content-Type', 'application/javascript'); response.end(await readFile(new URL('../public' + path, import.meta.url)));
    } catch { response.writeHead(404); response.end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  let browser;
  try {
    browser = await chromium.launch({ headless: true, executablePath: process.env.CHROMIUM_PATH });
    const page = await browser.newPage(); await page.goto('http://127.0.0.1:' + server.address().port);
    const saved = await page.evaluate(async () => {
      const { createIndexedDBWholePublicationRepository } = await import('/whole-publication-client.js');
      const id = () => crypto.randomUUID(), scope = { endpoint: 'https://staging.example.test', accountID: id(), deviceID: id(),
        sessionID: id(), keyVersion: 1, teamID: id(), operationID: id(), generations: [{ vaultID: id(), generationID: id(), sequence: 2, previousHash: 'a'.repeat(64) }] };
      const state = { request: { teamID: scope.teamID, operationID: scope.operationID }, generations: scope.generations, syntheticSecret: 'BROWSER-SYNTHETIC-CHECKPOINT' };
      const checkpoint = await createIndexedDBWholePublicationRepository().save(scope, state);
      let current = true;
      const guard = () => { if (!current) throw Error('publication_context_changed'); };
      const interrupted = { ...scope, operationID: id() };
      const pending = createIndexedDBWholePublicationRepository().save(interrupted, { ...state, request: { ...state.request, operationID: interrupted.operationID } }, guard);
      current = false;
      let raceCode; try { await pending; } catch (error) { raceCode = error.message; }
      return { scope, ciphertext: checkpoint.ciphertext, raceCode, unprotectedSecret: JSON.stringify(checkpoint).includes(state.syntheticSecret) };
    });
    assert.equal(saved.unprotectedSecret, false); assert.equal(saved.raceCode, 'publication_context_changed');
    await page.reload();
    const restored = await page.evaluate(async ({ scope, ciphertext }) => {
      const { createIndexedDBWholePublicationRepository } = await import('/whole-publication-client.js');
      const repository = createIndexedDBWholePublicationRepository(), result = await repository.load(scope);
      const db = await new Promise((resolve, reject) => { const r = indexedDB.open('selective-remote-whole-publication-v1', 1); r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
      const records = await new Promise((resolve, reject) => { const r = db.transaction('records').objectStore('records').getAll(); r.onsuccess = () => resolve(r.result); r.onerror = () => reject(r.error); });
      const protection = records.find(value => value instanceof CryptoKey);
      let exportDenied = false; try { await crypto.subtle.exportKey('raw', protection); } catch { exportDenied = true; }
      let foreignScopeDenied = false; try { await repository.load({ ...scope, accountID: crypto.randomUUID() }); } catch (error) { foreignScopeDenied = error.message === 'publication_checkpoint_lost'; }
      await new Promise((resolve, reject) => { const tx = db.transaction('records', 'readwrite'), r = tx.objectStore('records').openCursor();
        r.onsuccess = () => { const cursor = r.result; if (!cursor) return; if (String(cursor.key).startsWith('protection:')) cursor.delete(); cursor.continue(); };
        tx.oncomplete = resolve; tx.onerror = () => reject(tx.error); }); db.close();
      let keyLossDenied = false; try { await repository.load(scope); } catch (error) { keyLossDenied = error.message === 'publication_checkpoint_lost'; }
      return { immutable: result.checkpoint.ciphertext === ciphertext, syntheticSecret: result.state.syntheticSecret,
        nonextractable: protection.extractable === false, exportDenied, foreignScopeDenied, keyLossDenied,
        storageLeaked: JSON.stringify(records).includes('BROWSER-SYNTHETIC-CHECKPOINT') };
    }, saved);
    assert.deepEqual(restored, { immutable: true, syntheticSecret: 'BROWSER-SYNTHETIC-CHECKPOINT', nonextractable: true,
      exportDenied: true, foreignScopeDenied: true, keyLossDenied: true, storageLeaked: false });
  } finally { await browser?.close(); await new Promise(resolve => server.close(resolve)); }
});
