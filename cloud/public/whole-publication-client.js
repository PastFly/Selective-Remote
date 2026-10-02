// Complete immutable publication preparation. Entry points require the explicit staging capability.
import { canonicalMigrationJSON, migrationBytes, migrationHash, toBase64, fromBase64 } from './vault-v2-migration.js';
import { generateResourceCEK, encryptResourcePart, decryptResourcePart, wrapResourceCEK, unwrapResourceCEK } from './resource-crypto-v2.js';
import { verifyDeviceForWrapping } from './device-trust-v1.js';
import { prepareReaderProjection, validateReaderProjection, publicationHash, wrapperCommitment } from './vault-publication-v1.js';

const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', { fatal: true });
const MAX_CHECKPOINT = 64 * 1024 * 1024, MAX_PREPARED = 128 * 1024 * 1024, MAX_OBJECT = 1024 * 1024;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const digest = /^[a-f0-9]{64}$/u;
const fail = code => { throw Error(code); };
const equal = (a, b) => canonicalMigrationJSON(a) === canonicalMigrationJSON(b);
const copy = value => JSON.parse(canonicalMigrationJSON(value));
const byteLength = value => encoder.encode(canonicalMigrationJSON(value)).length;
const partsFor = resource => resource.kind === 'CREDENTIAL' ? ['METADATA', 'SECRET'] : ['GENERAL'];
const compare = (a, b) => a < b ? -1 : a > b ? 1 : 0;
const targetIdentity = target => ({ accountID: target.accountID, deviceID: target.deviceID,
  membershipID: target.membershipID, membershipEpoch: target.membershipEpoch,
  deviceKeyVersion: target.certificate?.payload?.keyVersion });
const targetTrust = target => ({ ...targetIdentity(target), certificate: target.certificate,
  checkpoint: target.checkpoint, rootPublicKey: target.rootPublicKey });
async function hash(value, cryptoValue) {
  return Array.from(new Uint8Array(await cryptoValue.subtle.digest('SHA-256', encoder.encode(canonicalMigrationJSON(value)))), b => b.toString(16).padStart(2, '0')).join('');
}

function capturedContext(getIdentity) {
  if (typeof getIdentity !== 'function') fail('publication_context_required');
  const captured = getIdentity();
  if (!captured || typeof captured.then === 'function' || !uuid.test(captured.accountID) || !uuid.test(captured.deviceID)
    || !uuid.test(captured.sessionID) || !Number.isSafeInteger(captured.keyVersion) || captured.keyVersion < 1
    || typeof captured.endpoint !== 'string' || new URL(captured.endpoint).origin !== captured.endpoint) fail('publication_context_changed');
  const identity = copy(captured);
  const guard = () => { const current = getIdentity(); if (!current || !equal(current, identity)) fail('publication_context_changed'); };
  return { identity, guard, async checked(work) { guard(); const result = await work(); guard(); return result; } };
}
function bindingIdentity(preview, identity) {
  const b = preview?.binding;
  if (!b || b.version !== 1 || b.actorAccountID !== identity.accountID || b.actorDeviceID !== identity.deviceID
    || b.sessionID !== identity.sessionID || b.keyVersion !== identity.keyVersion) fail('publication_context_changed');
}

async function verifyPreview(preview, request, context, cryptoValue) {
  const bad = () => fail('publication_preview_invalid'), b = preview?.binding;
  bindingIdentity(preview, context.identity);
  if (typeof preview.token !== 'string' || !preview.token || !equal(preview.request, request)
    || b.teamID !== request.teamID || b.operationID !== request.operationID || request.version !== 1
    || !uuid.test(request.teamID) || !uuid.test(request.operationID) || !Array.isArray(request.vaults)
    || request.vaults.length < 1 || request.vaults.length > 10 || !Array.isArray(preview.rows)
    || !Array.isArray(preview.generations) || preview.generations.length !== request.vaults.length
    || !Array.isArray(b.predecessors) || b.predecessors.length !== request.vaults.length
    || !Number.isSafeInteger(b.rowCount) || b.rowCount < 1 || b.rowCount > 22010
    || ['requestHash', 'readSetHash', 'successorHash', 'policyHash', 'recipientHash', 'rowsHash'].some(k => !digest.test(b[k]))
    || typeof b.effectiveAt !== 'string' || !Number.isFinite(Date.parse(b.effectiveAt))) bad();
  if (preview.rows.length !== b.rowCount || await context.checked(() => hash(request, cryptoValue)) !== b.requestHash
    || await context.checked(() => hash(preview.rows, cryptoValue)) !== b.rowsHash) bad();
  const counts = { vaults: request.vaults.length, resources: 0, parts: 0, wrappers: 0 }, seen = new Set(), allIDs = new Set();
  const generationIDs = new Set(), vaultIDs = new Set(), policies = [], successors = [], recipientSets = [];
  for (const vault of request.vaults) {
    if (!uuid.test(vault.vaultID) || vaultIDs.has(vault.vaultID) || !Array.isArray(vault.resources)
      || !Array.isArray(vault.policy) || !Array.isArray(vault.contentChanges) || !Array.isArray(vault.custodianDeviceIDs)
      || !vault.custodianDeviceIDs.length || vault.custodianDeviceIDs.length > 100
      || new Set(vault.custodianDeviceIDs).size !== vault.custodianDeviceIDs.length) bad();
    vaultIDs.add(vault.vaultID); counts.resources += vault.resources.length;
    const generation = preview.generations.find(g => g.vaultID === vault.vaultID), old = b.predecessors.find(p => p.vaultID === vault.vaultID);
    if (!generation || !old || !uuid.test(generation.generationID) || generationIDs.has(generation.generationID)
      || !uuid.test(old.generationID) || !digest.test(old.headerHash) || !Number.isSafeInteger(old.sequence)
      || old.sequence < 1 || generation.sequence !== old.sequence + 1 || generation.previousHash !== old.headerHash
      || generation.scope?.teamID !== request.teamID || generation.scope.vaultID !== vault.vaultID
      || generation.scope.attemptID !== generation.generationID || !Array.isArray(generation.snapshot?.devices)) bad();
    generationIDs.add(generation.generationID);
    if (generation.scope.policyVersion !== generation.snapshot.policyVersion || generation.scope.sourceRevision !== generation.snapshot.sourceRevision
      || generation.scope.snapshotHash !== await context.checked(() => hash(generation.snapshot, cryptoValue))
      || generation.scope.sourceHash !== await context.checked(() => hash({ operationID: request.operationID,
        requestHash: b.requestHash, readSetHash: b.readSetHash, predecessor: old.headerHash }, cryptoValue))) bad();
    const required = new Set();
    for (const resource of vault.resources) {
      if (!uuid.test(resource.id) || allIDs.has(resource.id) || !['HOST', 'CREDENTIAL', 'SNIPPET', 'FORWARDING', 'FOLDER'].includes(resource.kind)
        || !(resource.parentFolderID === null || uuid.test(resource.parentFolderID)) || !Number.isSafeInteger(resource.sourceOrdinal)
        || resource.sourceOrdinal < 0) bad();
      allIDs.add(resource.id); for (const part of partsFor(resource)) required.add(resource.id + '/' + part);
    }
    const rows = preview.rows.filter(r => r.vaultID === vault.vaultID), custody = rows.filter(r => r.type === 'CUSTODY');
    if (custody.length !== 1 || !equal(custody[0].devices.map(d => d.deviceID).sort(compare), [...vault.custodianDeviceIDs].sort(compare))) bad();
    for (const row of rows) {
      if (row.type === 'DELTA') continue;
      if (!['PART', 'CUSTODY'].includes(row.type) || !Array.isArray(row.devices) || !row.devices.length || row.devices.length > 100
        || new Set(row.devices.map(d => d.deviceID)).size !== row.devices.length) bad();
      const key = vault.vaultID + '/' + (row.type === 'PART' ? row.resourceID + '/' + row.part : 'CUSTODY');
      if (seen.has(key) || row.type === 'PART' && !required.delete(row.resourceID + '/' + row.part)) bad();
      seen.add(key); counts.parts++; counts.wrappers += row.devices.length;
      for (const target of row.devices) {
        const pinnedSnapshot = generation.snapshot.devices.find(d => d.deviceID === target.deviceID);
        if (!pinnedSnapshot || !equal(target, pinnedSnapshot)) bad();
      }
    }
    if (required.size) bad();
    policies.push({ vaultID: vault.vaultID, policy: vault.policy });
    successors.push({ vaultID: vault.vaultID, sequence: generation.sequence, previousHash: generation.previousHash,
      resources: vault.resources, policyHash: await context.checked(() => hash(vault.policy, cryptoValue)), snapshot: generation.snapshot });
    recipientSets.push({ vaultID: vault.vaultID, parts: rows.filter(r => r.type === 'PART').map(r => ({ resourceID: r.resourceID,
      part: r.part, devices: r.devices.map(targetIdentity).sort((a, b) => compare(a.deviceID, b.deviceID)) })).sort((a, b) => compare(a.resourceID + '/' + a.part, b.resourceID + '/' + b.part)),
      custodians: custody[0].devices.map(targetIdentity).sort((a, b) => compare(a.deviceID, b.deviceID)) });
  }
  if (preview.rows.some(r => !vaultIDs.has(r.vaultID) || !['PART', 'CUSTODY', 'DELTA'].includes(r.type))
    || !equal(counts, b.counts) || counts.resources > 1000 || counts.wrappers > 10000) bad();
  const byVault = (a, b) => compare(a.vaultID, b.vaultID);
  if (b.policyHash !== await context.checked(() => hash(policies.sort(byVault), cryptoValue))
    || b.successorHash !== await context.checked(() => hash(successors.sort(byVault), cryptoValue))
    || b.recipientHash !== await context.checked(() => hash(recipientSets.sort(byVault), cryptoValue))) bad();
  context.guard(); return preview;
}

export function canonicalWholePublicationRequest(request) {
  const value=copy(request);if(!Array.isArray(value.vaults))fail('invalid_publication_request');
  for(const v of value.vaults){if(!Array.isArray(v.resources)||!Array.isArray(v.policy)||!Array.isArray(v.contentChanges)||!Array.isArray(v.custodianDeviceIDs))fail('invalid_publication_request');
    v.resources.sort((a,b)=>compare(a.id,b.id));v.policy.sort((a,b)=>compare(a.id,b.id));
    v.contentChanges.sort((a,b)=>compare(a.resourceID+'/'+a.part,b.resourceID+'/'+b.part));v.custodianDeviceIDs.sort(compare);}
  value.vaults.sort((a,b)=>compare(a.vaultID,b.vaultID));return value;
}
export async function collectWholePublicationPreview({ request, transport, getIdentity, token, cryptoValue = globalThis.crypto }) {
  const context = capturedContext(getIdentity), wanted = canonicalWholePublicationRequest(request), rows = [], cursors = new Set();
  let first, cursor = null;
  do {
    const page = await context.checked(() => transport.preview(copy(wanted), first ? { token: first.token, cursor } : token === undefined ? {} : { token }));
    bindingIdentity(page, context.identity);
    if (!Array.isArray(page.rows) || page.rows.length > 100 || (first && (!equal(page.binding, first.binding)
      || page.token !== first.token || !equal(page.generations, first.generations) || !equal(page.request, first.request)))) fail('publication_preview_invalid');
    if (!first) first = copy(page);
    rows.push(...copy(page.rows)); cursor = page.nextCursor;
    if (rows.length > first.binding.rowCount || cursor !== null && (typeof cursor !== 'string' || !cursor || cursors.has(cursor))) fail('publication_preview_invalid');
    if (cursor !== null) cursors.add(cursor);
  } while (cursor !== null);
  return verifyPreview({ ...first, rows, nextCursor: null }, wanted, context, cryptoValue);
}

function localPlaintext(teamID, vault, predecessor, plaintext, administrative) {
  if (!plaintext?.verified || !administrative?.verified || !plaintext.parts || !administrative.data
    || !equal(plaintext.predecessor, predecessor) || !equal(administrative.predecessor, predecessor)) fail('publication_custodian_unavailable');
  const expectedIDs = vault.resources.map(r => r.id).sort(compare);
  if (!equal(Object.keys(plaintext.parts).sort(compare), expectedIDs)) fail('publication_custodian_unavailable');
  for (const resource of vault.resources) {
    const parts = plaintext.parts[resource.id];
    if (!parts || !equal(Object.keys(parts).sort(compare), partsFor(resource).sort(compare))) fail('publication_custodian_unavailable');
    for (const part of partsFor(resource)) {
      const payload = parts[part], link = payload?.link;
      if (!link || link.teamID !== teamID || link.vaultID !== vault.vaultID
        || link.generationID !== predecessor.generationID || link.resourceID !== resource.id
        || link.kind !== resource.kind || link.part !== part || part === 'SECRET' && !payload.record
        || part === 'METADATA' && !payload.metadata) fail('publication_custodian_unavailable');
    }
  }
  // Initial migration metadata authenticates Team/Vault through its verified outer AEAD scope.
  if (administrative.data.teamID !== undefined && administrative.data.teamID !== teamID
    || administrative.data.vaultID !== undefined && administrative.data.vaultID !== vault.vaultID
    || administrative.data.scope !== undefined && (administrative.data.scope.teamID !== teamID || administrative.data.scope.vaultID !== vault.vaultID)
    || administrative.data.generationID !== predecessor.generationID) fail('publication_custodian_unavailable');
}

function checkpointScope(identity, request, generations) {
  return { endpoint: identity.endpoint, accountID: identity.accountID, deviceID: identity.deviceID,
    sessionID: identity.sessionID, keyVersion: identity.keyVersion, teamID: request.teamID, operationID: request.operationID,
    generations: generations.map(g => ({ vaultID: g.vaultID, generationID: g.generationID, sequence: g.sequence, previousHash: g.previousHash })) };
}

// V2 base64 fields have fixed encoded lengths; ciphertext length depends only on plaintext bytes.
// Predict the actual wire size before encryption, then check the produced object again.
function encodedPartBudget(context, plaintextBytes, recipients, includeHash) {
  const c = context;
  const object = { resourceID: c.resourceID, part: c.part,
    envelope: { formatVersion: 2, algorithm: 'AES-256-GCM', aadVersion: 2, context: c,
      nonce: 'A'.repeat(16), ciphertext: '', authTag: 'A'.repeat(22) },
    wrappers: recipients.map(target => ({ wrapperVersion: 2, algorithm: 'P256-ECDH-HKDF-SHA256-AES-256-GCM', aadVersion: 2,
      context: { teamID: c.teamID, vaultID: c.vaultID, resourceID: c.resourceID, part: c.part, keyVersion: c.keyVersion,
        membershipID: target.membershipID, membershipEpoch: target.membershipEpoch, deviceID: target.deviceID },
      ephemeralPublicKey: { kty: 'EC', crv: 'P-256', x: 'A'.repeat(43), y: 'A'.repeat(43), ext: true, key_ops: [] },
      nonce: 'A'.repeat(16), ciphertext: 'A'.repeat(43), authTag: 'A'.repeat(22) })) };
  if (includeHash) object.sha256 = '0'.repeat(64);
  return byteLength(includeHash?{object}:object) + Math.ceil(plaintextBytes * 4 / 3);
}

export async function prepareWholePublication({ preview, plaintextByVault, administrativeByVault, pinnedTrust, root, identity,
  deviceID, endpoint, checkpointRepository, getIdentity, cryptoValue = globalThis.crypto }) {
  const context = capturedContext(getIdentity), frozen = copy(preview);
  const source = canonicalMigrationJSON({ plaintextByVault: plaintextByVault ?? {}, administrativeByVault: administrativeByVault ?? {} });
  const local = JSON.parse(source);
  const sourceGuard = () => {
    context.guard();
    if (source !== canonicalMigrationJSON({ plaintextByVault: plaintextByVault ?? {}, administrativeByVault: administrativeByVault ?? {} })
      || !equal(preview, frozen)) fail('publication_source_changed');
  };
  await verifyPreview(frozen, frozen.request, context, cryptoValue);
  if (endpoint !== context.identity.endpoint || deviceID !== context.identity.deviceID || root?.accountID !== context.identity.accountID
    || root.endpoint !== endpoint || !root.privateKey || !identity?.privateKey || typeof checkpointRepository?.save !== 'function') fail('publication_custodian_unavailable');
  for (const vault of frozen.request.vaults) localPlaintext(frozen.request.teamID, vault, frozen.binding.predecessors.find(p => p.vaultID === vault.vaultID),
    local.plaintextByVault[vault.vaultID], local.administrativeByVault[vault.vaultID]);
  const verified = new Map(), targets = new Map();
  for (const row of frozen.rows.filter(r => r.type !== 'DELTA')) for (const target of row.devices) {
    const key = target.membershipID + '/' + target.deviceID;
    if (targets.has(key) && !equal(targetTrust(targets.get(key)), targetTrust(target))) fail('recipient_trust_unverified');
    if (targets.has(key)) continue;
    if (target.accountID !== target.certificate?.payload?.accountID || target.accountID !== target.checkpoint?.payload?.accountID
      || target.deviceID !== target.certificate?.payload?.deviceID || !uuid.test(target.membershipID)
      || !Number.isSafeInteger(target.membershipEpoch) || target.membershipEpoch < 1
      || typeof pinnedTrust?.loadPin !== 'function' || typeof pinnedTrust?.advancePin !== 'function') fail('recipient_trust_unverified');
    const trust = await context.checked(() => pinnedTrust.loadPin(endpoint, target.accountID));
    if (!trust || trust.endpoint !== endpoint || trust.accountID !== target.accountID) fail('recipient_trust_unverified');
    let checked;
    try { checked = await context.checked(() => verifyDeviceForWrapping({ ...target, trust, expectedDeviceID: target.deviceID, cryptoValue })); }
    catch (error) { if (error.message === 'publication_context_changed') throw error; fail('recipient_trust_unverified'); }
    if (target.deviceID === deviceID && (target.accountID !== root.accountID || target.rootPublicKey !== root.publicKey
      || target.certificate.payload.keyVersion !== context.identity.keyVersion || !equal(checked.publicKey, identity.publicKey))) fail('publication_custodian_unavailable');
    await context.checked(() => pinnedTrust.advancePin(trust, { ...trust, highWater: checked.highWater, checkpointDigest: checked.checkpointDigest }));
    targets.set(key, target); verified.set(key, checked.publicKey);
  }
  // Check complete local entitlement and input size before any encryption or persistence.
  for (const row of frozen.rows.filter(r => r.type !== 'DELTA')) if (!row.devices.some(d => d.accountID === root.accountID && d.deviceID === deviceID)) fail('publication_custodian_unavailable');
  if (encoder.encode(source).length * 2 > MAX_PREPARED) fail('publication_limit');
  const generations = []; let preparedBytes = 0;
  for (const generation of frozen.generations) {
    const vault = frozen.request.vaults.find(v => v.vaultID === generation.vaultID), scope = generation.scope;
    const encrypt = async (resourceID, part, payload, recipients, includeHash = true) => {
      const serialized = canonicalMigrationJSON(payload);
      const c = { teamID: scope.teamID, vaultID: scope.vaultID, resourceID, part,
        keyVersion: generation.sequence, policyVersion: scope.policyVersion, registryVersion: generation.sequence,
        resourceVersion: generation.sequence, manifestVersion: generation.sequence };
      if (encodedPartBudget(c, encoder.encode(serialized).length, recipients, includeHash) > MAX_OBJECT) fail('publication_limit');
      const cek = generateResourceCEK(cryptoValue);
      try {
        const envelope = await context.checked(() => encryptResourcePart({ plaintext: encoder.encode(serialized), cek, context: c, cryptoValue })), wrappers = [];
        for (const target of recipients) wrappers.push(await context.checked(() => wrapResourceCEK({ cek,
          context: { teamID: scope.teamID, vaultID: scope.vaultID, resourceID, part, keyVersion: generation.sequence,
            membershipID: target.membershipID, membershipEpoch: target.membershipEpoch, deviceID: target.deviceID },
          recipientPublicKey: verified.get(target.membershipID + '/' + target.deviceID), cryptoValue })));
        const own = wrappers.find(w => w.context.deviceID === deviceID); let openedKey;
        try {
          openedKey = await context.checked(() => unwrapResourceCEK({ wrapper: own, context: own.context, privateKey: identity.privateKey, cryptoValue }));
          const bytes = await context.checked(() => decryptResourcePart({ envelope, context: c, cek: openedKey, cryptoValue }));
          if (decoder.decode(bytes) !== serialized) fail('publication_roundtrip_failed');
        } catch (error) { if (error.message === 'publication_context_changed') throw error; fail('publication_roundtrip_failed'); }
        finally { openedKey?.fill(0); }
        const object = { resourceID, part, envelope, wrappers };
        if (byteLength(object) > MAX_OBJECT) fail('publication_limit');
        return object;
      } finally { cek.fill(0); }
    };
    const objects = [], recipientsByKey = new Map();
    const rows = frozen.rows.filter(r => r.vaultID === generation.vaultID && r.type !== 'DELTA');
    for (const row of rows) for (const target of row.devices) recipientsByKey.set(target.membershipID + '/' + target.deviceID, targetIdentity(target));
    for (const resource of vault.resources) for (const part of partsFor(resource)) {
      const row = rows.find(r => r.type === 'PART' && r.resourceID === resource.id && r.part === part);
      const payload = copy(local.plaintextByVault[vault.vaultID].parts[resource.id][part]); payload.link.generationID = generation.generationID;
      const object = await encrypt(resource.id, part, payload, row.devices);
      object.sha256 = await context.checked(() => migrationHash(object, cryptoValue));
      if (byteLength({object}) > MAX_OBJECT || (preparedBytes += byteLength(object)) > MAX_PREPARED) fail('publication_limit');
      objects.push(object);
    }
    const custody = rows.find(r => r.type === 'CUSTODY'), administrative = copy(local.administrativeByVault[vault.vaultID].data);
    administrative.generationID = generation.generationID;
    const administrativeSidecar = await encrypt(cryptoValue.randomUUID(), 'SECRET', administrative, custody.devices, false);
    if ((preparedBytes += byteLength(administrativeSidecar)) > MAX_PREPARED) fail('publication_limit');
    const recipients = [...recipientsByKey.values()], readerProjection = await context.checked(() => prepareReaderProjection({ scope,
      resources: vault.resources, objects, recipients, root, publisherAccountID: root.accountID, publisherDeviceID: deviceID,
      publisherKeyVersion: context.identity.keyVersion, sequence: generation.sequence, previousHash: generation.previousHash, cryptoValue }));
    await context.checked(() => validateReaderProjection({ projection: readerProjection, scope, resources: vault.resources, objects,
      recipients, rootPublicKey: root.publicKey, sequence: generation.sequence, previousHash: generation.previousHash, cryptoValue }));
    const sidecarEntries = administrativeSidecar.wrappers.map((wrapper, i) => ({ accountID: custody.devices[i].accountID,
      deviceKeyVersion: custody.devices[i].certificate.payload.keyVersion, wrapper }));
    const sidecarCommitment = { resourceID: administrativeSidecar.resourceID,
      envelopeHash: await context.checked(() => publicationHash('ciphertext', administrativeSidecar.envelope, cryptoValue)),
      wrapperRoot: (await context.checked(() => wrapperCommitment(sidecarEntries, cryptoValue))).root };
    const payload = { version: 2, scope, policyHash: await context.checked(() => migrationHash(vault.policy, cryptoValue)), resources: vault.resources,
      parts: objects.map(o => ({ resourceID: o.resourceID, part: o.part, sha256: o.sha256 })), reader: {
        projectionHash: await context.checked(() => publicationHash('projection', readerProjection, cryptoValue)),
        sidecarHash: await context.checked(() => publicationHash('sidecar', administrativeSidecar, cryptoValue)),
        custodianDeviceIDs: [...vault.custodianDeviceIDs].sort(compare), sidecarCommitment } };
    const signature = toBase64(new Uint8Array(await context.checked(() => cryptoValue.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, root.privateKey, migrationBytes(payload)))));
    generations.push({ ...generation, resources: vault.resources, objects, administrativeSidecar, readerProjection, manifest: { payload, signature } });
  }
  const state = { version: 1, request: frozen.request, binding: frozen.binding, generations };
  const scope = checkpointScope(context.identity, frozen.request, generations);
  sourceGuard();
  const checkpoint = await context.checked(() => checkpointRepository.save(scope, state, sourceGuard));
  return { ...state, checkpoint };
}

const baseScope = scope => Object.fromEntries(['endpoint', 'accountID', 'deviceID', 'sessionID', 'keyVersion', 'teamID', 'operationID'].map(k => [k, scope[k]]));
const recordKey = scope => canonicalMigrationJSON(baseScope(scope));
const protectionKey = scope => canonicalMigrationJSON({ endpoint: scope.endpoint, accountID: scope.accountID, deviceID: scope.deviceID });
const checkpointAAD = scope => encoder.encode('selective-remote/whole-publication-checkpoint/v1\0' + canonicalMigrationJSON(scope));

// Storage implements atomic putIfAbsent; only encrypted records and nonextractable local keys are durable.
export function createWholePublicationCheckpointRepository({ storage, cryptoValue = globalThis.crypto }) {
  const checked = async (guard, work) => { guard(); const value = await work(); guard(); return value; };
  const repository = {
    async save(scope, state, guard = () => {}) {
      const opKey = recordKey(scope), aad = checkpointAAD(scope), protectionID = 'protection:' + protectionKey(scope);
      if (!equal(state.request.operationID, scope.operationID) || !equal(state.request.teamID, scope.teamID)) fail('publication_resume_changed');
      if (await checked(guard, () => storage.load('operation:' + opKey)) || await checked(guard,()=>storage.load('used:'+opKey))) fail('publication_operation_exists');
      let protection = await checked(guard, () => storage.load(protectionID));
      if (!protection) {
        const candidate = await checked(guard, () => cryptoValue.subtle.generateKey({ name: 'AES-KW', length: 256 }, false, ['wrapKey', 'unwrapKey']));
        protection = await checked(guard, () => storage.putIfAbsent(protectionID, candidate));
      }
      const key = await checked(guard, () => cryptoValue.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, ['encrypt', 'decrypt']));
      const nonce = cryptoValue.getRandomValues(new Uint8Array(12));
      const ciphertext = await checked(guard, () => cryptoValue.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: aad }, key, encoder.encode(canonicalMigrationJSON(state))));
      const wrappedKey = await checked(guard, () => cryptoValue.subtle.wrapKey('raw', key, protection, 'AES-KW'));
      const checkpoint = { version: 1, scope: copy(scope), nonce: toBase64(nonce), ciphertext: toBase64(new Uint8Array(ciphertext)), wrappedKey: toBase64(new Uint8Array(wrappedKey)) };
      if (byteLength(checkpoint) > MAX_CHECKPOINT) fail('checkpoint_size_limit');
      const reservation = { checkpointHash: await checked(guard, () => hash(checkpoint, cryptoValue)) };
      const acquired = await checked(guard, () => storage.putIfAbsent('operation:' + opKey, reservation));
      if (!equal(acquired, reservation)) fail('publication_operation_exists');
      await checked(guard, () => storage.save('checkpoint:' + opKey, checkpoint));
      const persisted = await checked(guard, () => storage.load('checkpoint:' + opKey));
      if (!equal(persisted, checkpoint)) fail('publication_checkpoint_persistence_failed');
      return copy(checkpoint);
    },
    async load(scope, guard = () => {}) {
      const key = recordKey(scope), reservation = await checked(guard, () => storage.load('operation:' + key));
      const checkpoint = await checked(guard, () => storage.load('checkpoint:' + key));
      if (!reservation || !checkpoint || checkpoint.version !== 1 || !equal(baseScope(checkpoint.scope), baseScope(scope))
        || byteLength(checkpoint) > MAX_CHECKPOINT || reservation.checkpointHash !== await checked(guard, () => hash(checkpoint, cryptoValue))) fail('publication_checkpoint_lost');
      const protection = await checked(guard, () => storage.load('protection:' + protectionKey(scope)));
      if (!protection) fail('publication_checkpoint_lost');
      let bytes;
      try {
        const opened = await checked(guard, () => cryptoValue.subtle.unwrapKey('raw', fromBase64(checkpoint.wrappedKey), protection, 'AES-KW', 'AES-GCM', false, ['decrypt']));
        bytes = await checked(guard, () => cryptoValue.subtle.decrypt({ name: 'AES-GCM', iv: fromBase64(checkpoint.nonce), additionalData: checkpointAAD(checkpoint.scope) }, opened, fromBase64(checkpoint.ciphertext)));
      } catch (error) { if (error.message === 'publication_context_changed') throw error; fail('publication_checkpoint_lost'); }
      const state = JSON.parse(decoder.decode(bytes));
      if (!equal(checkpointScope(baseScope(scope), state.request, state.generations), checkpoint.scope)) fail('publication_checkpoint_lost');
      return { state, checkpoint: copy(checkpoint) };
    },
    async saveReceipt(scope, receipt, guard = () => {}, purpose = 'receipt') {
      if(!['receipt','complete'].includes(purpose))fail('publication_checkpoint_lost');
      const { checkpoint } = await repository.load(scope, guard);
      const protection = await checked(guard, () => storage.load('protection:' + protectionKey(scope)));
      const key = await checked(guard, () => cryptoValue.subtle.unwrapKey('raw', fromBase64(checkpoint.wrappedKey), protection, 'AES-KW', 'AES-GCM', false, ['encrypt']));
      const nonce = cryptoValue.getRandomValues(new Uint8Array(12));
      const aad = encoder.encode('selective-remote/whole-publication-'+purpose+'/v1\0' + canonicalMigrationJSON(checkpoint.scope));
      const ciphertext = await checked(guard, () => cryptoValue.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: aad }, key, encoder.encode(canonicalMigrationJSON(receipt))));
      const record = { nonce: toBase64(nonce), ciphertext: toBase64(new Uint8Array(ciphertext)) };
      await checked(guard, () => storage.save(purpose+':' + recordKey(scope), record));
      if (!equal(await checked(guard, () => storage.load(purpose+':' + recordKey(scope))), record)) fail('publication_checkpoint_persistence_failed');
    },
    async loadReceipt(scope, guard = () => {}, purpose = 'receipt') {
      if(!['receipt','complete'].includes(purpose))fail('publication_checkpoint_lost');
      const record = await checked(guard, () => storage.load(purpose+':' + recordKey(scope)));
      if (!record) return null;
      const { checkpoint } = await repository.load(scope, guard);
      const protection = await checked(guard, () => storage.load('protection:' + protectionKey(scope)));
      try {
        const key = await checked(guard, () => cryptoValue.subtle.unwrapKey('raw', fromBase64(checkpoint.wrappedKey), protection, 'AES-KW', 'AES-GCM', false, ['decrypt']));
        const aad = encoder.encode('selective-remote/whole-publication-'+purpose+'/v1\0' + canonicalMigrationJSON(checkpoint.scope));
        const bytes = await checked(guard, () => cryptoValue.subtle.decrypt({ name: 'AES-GCM', iv: fromBase64(record.nonce), additionalData: aad }, key, fromBase64(record.ciphertext)));
        return JSON.parse(decoder.decode(bytes));
      } catch (error) { if (error.message === 'publication_context_changed') throw error; fail('publication_checkpoint_lost'); }
    },
    markComplete(scope,receipt,guard=()=>{}){return repository.saveReceipt(scope,receipt,guard,'complete');},
    async forgetDiscarded(scope,result,guard=()=>{}) {
      if(result?.operationID!==scope.operationID||result.state!=='DISCARDED')fail('publication_response_invalid');
      // Public disposition metadata only. Hiding this record cannot bypass the fresh server context gate.
      await checked(guard,()=>storage.save('used:'+recordKey(scope),{operationID:scope.operationID,state:'DISCARDED'}));
    },
    async discover(scope,guard=()=>{}) {
      if(typeof storage.keys!=='function')return [];
      const keys=await checked(guard,()=>storage.keys()),found=[];
      for(const key of keys.filter(k=>typeof k==='string'&&k.startsWith('operation:'))) {
        let saved;try{saved=JSON.parse(key.slice(10));}catch{continue;}
        if(!['endpoint','accountID','deviceID','teamID'].every(k=>saved[k]===scope[k])||!uuid.test(saved.operationID))continue;
        if(await checked(guard,()=>storage.load('used:'+recordKey(saved))))continue;
        const done=await checked(guard,()=>storage.load('complete:'+recordKey(saved)));
        if(done){
          // Only the completion journal is opened; no old prepared or source payload is rehydrated.
          const checkpoint=await checked(guard,()=>storage.load('checkpoint:'+recordKey(saved))),reservation=await checked(guard,()=>storage.load('operation:'+recordKey(saved)));
          if(!checkpoint||!equal(baseScope(checkpoint.scope),saved)||reservation?.checkpointHash!==await checked(guard,()=>hash(checkpoint,cryptoValue)))fail('publication_checkpoint_lost');
          const protection=await checked(guard,()=>storage.load('protection:'+protectionKey(saved)));if(!protection)fail('publication_checkpoint_lost');
          try{const key=await checked(guard,()=>cryptoValue.subtle.unwrapKey('raw',fromBase64(checkpoint.wrappedKey),protection,'AES-KW','AES-GCM',false,['decrypt']));
            const aad=encoder.encode('selective-remote/whole-publication-complete/v1\0'+canonicalMigrationJSON(checkpoint.scope));
            const bytes=await checked(guard,()=>cryptoValue.subtle.decrypt({name:'AES-GCM',iv:fromBase64(done.nonce),additionalData:aad},key,fromBase64(done.ciphertext)));
            const receipt=JSON.parse(decoder.decode(bytes));if(receipt.operationID!==saved.operationID)fail('publication_checkpoint_lost');continue;
          }catch(error){guard();fail('publication_checkpoint_lost');}
        }
        found.push(copy(saved));
      }
      guard();return found;
    },
    async pending(scope,guard=()=>{}) {
      if(typeof storage.keys!=='function')return [];
      const keys=await checked(guard,()=>storage.keys()),found=[];
      for(const key of keys.filter(k=>typeof k==='string'&&k.startsWith('operation:'))) {
        let saved;try{saved=JSON.parse(key.slice(10));}catch{continue;}
        if(!['endpoint','accountID','deviceID','sessionID','keyVersion','teamID'].every(k=>saved[k]===scope[k]))continue;
        if(await checked(guard,()=>storage.load('used:'+recordKey(saved))))continue;
        const stored=await repository.load(saved,guard);if(await repository.loadReceipt(saved,guard,'complete'))continue;
        found.push({...stored,operationID:saved.operationID});
      }
      guard();return found;
    },
  };
  return repository;
}

export function createIndexedDBWholePublicationRepository(indexedDBValue = globalThis.indexedDB, { cryptoValue = globalThis.crypto } = {}) {
  async function transaction(mode, operation) {
    if (!indexedDBValue?.open) fail('publication_storage_failed');
    const db = await new Promise((resolve, reject) => {
      const r = indexedDBValue.open('selective-remote-whole-publication-v1', 1);
      r.onupgradeneeded = () => r.result.createObjectStore('records');
      r.onsuccess = () => resolve(r.result); r.onerror = r.onblocked = () => reject(Error('publication_storage_failed'));
    });
    try {
      return await new Promise((resolve, reject) => {
        const tx = db.transaction('records', mode); let value;
        tx.oncomplete = () => resolve(value); tx.onerror = tx.onabort = () => reject(Error('publication_storage_failed'));
        operation(tx.objectStore('records'), result => { value = result; });
      });
    } finally { db.close(); }
  }
  return createWholePublicationCheckpointRepository({ cryptoValue, storage: {
    keys(){return transaction('readonly',(store,done)=>{const r=store.getAllKeys();r.onsuccess=()=>done(r.result);});},
    load(key) { return transaction('readonly', (store, done) => { const r = store.get(key); r.onsuccess = () => done(r.result ?? null); }); },
    save(key, value) { return transaction('readwrite', store => { store.put(value, key); }); },
    putIfAbsent(key, value) { return transaction('readwrite', (store, done) => {
      const r = store.get(key); r.onsuccess = () => { if (r.result) done(r.result); else { store.add(value, key); done(value); } };
    }); },
  } });
}

export function createWholePublicationCoordinator(options) {
  const { transport, checkpointRepository, getIdentity, cryptoValue = globalThis.crypto } = options;
  let pendingReceipt = null, writesBlocked = false;
  const scopeFor = (context, request) => ({ ...context.identity, teamID: request.teamID, operationID: request.operationID });
  const upload = async (stored, context, token) => {
    if (writesBlocked) fail('publication_readback_required');
    const { state, checkpoint } = stored, op = state.request.operationID;
    const started = await context.checked(() => transport.start(token, copy(state.request)));
    if (started?.generations && !equal(started.generations, state.generations.map(({ objects, administrativeSidecar, readerProjection, manifest, resources, ...g }) => g))) fail('publication_stale');
    const checkpointVaultID = state.generations.map(g => g.vaultID).sort(compare)[0];
    for (const g of state.generations) {
      for (const object of g.objects) await context.checked(() => transport.putPart(op, g.vaultID, copy(object)));
      const opaqueCheckpoint = { version: checkpoint.version, nonce: checkpoint.nonce, ciphertext: checkpoint.ciphertext };
      await context.checked(() => transport.putProjection(op, g.vaultID, copy(g.readerProjection), copy(g.administrativeSidecar), g.vaultID === checkpointVaultID ? opaqueCheckpoint : undefined));
    }
    await context.checked(() => transport.validate(op, state.generations.map(g => ({ vaultID: g.vaultID, manifest: copy(g.manifest) }))));
    return { ...state, checkpoint };
  };
  const load = async (request, context) => {
    const stored = await context.checked(() => checkpointRepository.load(scopeFor(context, request), context.guard));
    if (!equal(canonicalWholePublicationRequest(request), stored.state.request)) fail('publication_resume_changed');
    bindingIdentity(stored.state, context.identity); return stored;
  };
  const validateReceipt = async (receipt, state, context) => {
    if (!receipt || receipt.operationID !== state.request.operationID || receipt.teamID !== state.request.teamID
      || receipt.requestHash !== state.binding.requestHash || receipt.actorAccountID !== context.identity.accountID
      || receipt.actorDeviceID !== context.identity.deviceID || !Array.isArray(receipt.vaults)
      || !Number.isFinite(Date.parse(receipt.committedAt))) fail('publication_receipt_invalid');
    const wanted = [];
    for (const g of state.generations) wanted.push({ vaultID: g.vaultID, generationID: g.generationID, sequence: g.sequence,
      headerHash: await context.checked(() => publicationHash('header', g.readerProjection.header, cryptoValue)) });
    wanted.sort((a, b) => compare(a.vaultID, b.vaultID));
    if (!equal(receipt.vaults, wanted)) fail('publication_receipt_invalid');
    pendingReceipt = copy(receipt); writesBlocked = true;
    await context.checked(() => checkpointRepository.saveReceipt(scopeFor(context, state.request), receipt, context.guard));
    if (typeof options.readback !== 'function') fail('publication_readback_required');
    const actual = await context.checked(() => options.readback(copy(receipt)));
    const records = actual?.vaults ?? actual;
    if (!Array.isArray(records) || records.length !== receipt.vaults.length || new Set(records.map(r => r.vaultID)).size !== records.length) fail('publication_readback_required');
    for (const expected of receipt.vaults) {
      const record = records.find(r => r.vaultID === expected.vaultID), generation = state.generations.find(g => g.vaultID === expected.vaultID);
      if (!record?.header || !record.manifest || record.headerHash !== expected.headerHash
        || !equal(record.header, generation.readerProjection.header) || !equal(record.manifest, generation.manifest)
        || expected.headerHash !== await context.checked(() => publicationHash('header', record.header, cryptoValue))) fail('publication_readback_required');
    }
    if(typeof checkpointRepository.markComplete==='function')await context.checked(()=>checkpointRepository.markComplete(scopeFor(context,state.request),receipt,context.guard));
    writesBlocked = false; return copy(receipt);
  };
  const recoverReceipt = async (state, context) => {
    const local = pendingReceipt ?? await context.checked(() => checkpointRepository.loadReceipt(scopeFor(context, state.request), context.guard));
    if (local) return validateReceipt(local, state, context);
    if (typeof transport.receipt !== 'function') return null;
    let remote;
    try { remote = await context.checked(() => transport.receipt(state.request.operationID)); }
    catch (error) { if (!['publication_receipt_not_found', 'publication_not_committed'].includes(error.message)) throw error; return null; }
    return remote ? validateReceipt(remote, state, context) : null;
  };
  return {
    get writesBlocked() { return writesBlocked; },
    get pendingReceipt() { return pendingReceipt ? copy(pendingReceipt) : null; },
    async recoverCommitted({request,checkpointIdentity}) {
      const current=capturedContext(getIdentity);
      if(!checkpointIdentity||['endpoint','accountID','deviceID'].some(k=>checkpointIdentity[k]!==current.identity[k]))fail('publication_context_changed');
      const context={...current,identity:{...current.identity,sessionID:checkpointIdentity.sessionID,keyVersion:checkpointIdentity.keyVersion}},stored=await load(request,context);
      const receipt=await recoverReceipt(stored.state,context);if(!receipt)fail('publication_not_committed');return receipt;
    },
    async prepare({ request, token, plaintextByVault, administrativeByVault, confirm, onPrepared }) {
      const context = capturedContext(getIdentity), preview = await collectWholePublicationPreview({ request, token, transport, getIdentity, cryptoValue });
      context.guard(); if (confirm && !await context.checked(() => confirm(copy(preview)))) fail('publication_cancelled');
      await prepareWholePublication({ ...options, preview, plaintextByVault, administrativeByVault, cryptoValue });
      if (onPrepared) await context.checked(() => onPrepared());
      const stored = await load(preview.request, context); return upload(stored, context, preview.token);
    },
    async resume({ request }) {
      const context = capturedContext(getIdentity), stored = await load(request, context);
      const receipt = await recoverReceipt(stored.state, context); if (receipt) return receipt;
      const preview = await collectWholePublicationPreview({ request, transport, getIdentity, cryptoValue }); context.guard();
      if (!equal(preview.binding, stored.state.binding) || !equal(preview.generations, stored.state.generations.map(({ objects, administrativeSidecar, readerProjection, manifest, resources, ...g }) => g))) fail('publication_stale');
      return upload(stored, context, preview.token);
    },
    async commit({ request }) {
      const context = capturedContext(getIdentity), stored = await load(request, context);
      const recovered = await recoverReceipt(stored.state, context); if (recovered) return recovered;
      const preview = await collectWholePublicationPreview({ request, transport, getIdentity, cryptoValue }); context.guard();
      if (!equal(preview.binding, stored.state.binding) || !equal(preview.generations, stored.state.generations.map(({ objects, administrativeSidecar, readerProjection, manifest, resources, ...g }) => g))) fail('publication_stale');
      writesBlocked = true;
      let receipt;
      try { receipt = await context.checked(() => transport.commit(request.operationID, preview.token, copy(stored.state.request))); }
      catch (error) {
        context.guard(); receipt = await context.checked(() => transport.receipt(request.operationID));
        if (!receipt) throw error;
      }
      return validateReceipt(receipt, stored.state, context);
    },
  };
}
