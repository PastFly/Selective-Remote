import { generateVaultKey } from "./vault-crypto.js";
import { openVaultStorage } from "./vault-storage.js";
import {
  createEmptyVaultDocument,
  deleteVaultRecord,
  mergeVaultDocuments,
  resolveVaultConflict,
  upsertVaultRecord,
  validateVaultDocument,
} from "./vault-model.js";
import {
  decryptTeamVaultPayload,
  encryptTeamVaultPayload,
  normalizeTeamVaultScope,
  unwrapTeamVaultKeyForDevice,
  wrapTeamVaultKeyForDevice,
} from "./team-vault-crypto.js";

const storeName = "local-vault";
const recordTypes = new Set(["host", "credential", "snippet", "forwarding", "sshKey"]);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const snapshotKeys = [
  "deviceID", "envelope", "keyGeneration", "localRevision", "scope",
  "serverRevision", "syncedLocalRevision", "wrapper",
];
const envelopeKeys = [
  "authTag", "baseRevision", "ciphertext", "contentHash", "envelopeVersion", "keyGeneration", "nonce",
];

function clone(value) {
  return globalThis.structuredClone ? globalThis.structuredClone(value) : JSON.parse(JSON.stringify(value));
}

function exactKeys(value, expected, code) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(code);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) throw new Error(code);
}

function normalizedUUID(value, code) {
  const normalized = String(value ?? "").toLowerCase();
  if (!uuidPattern.test(normalized)) throw new Error(code);
  return normalized;
}

function normalizedEnvelope(value) {
  exactKeys(value, envelopeKeys, "invalid_local_team_vault");
  if (!Number.isSafeInteger(value.baseRevision) || value.baseRevision < 0
    || !Number.isSafeInteger(value.keyGeneration) || value.keyGeneration < 1
    || value.envelopeVersion !== 1) {
    throw new Error("invalid_local_team_vault");
  }
  for (const key of ["ciphertext", "nonce", "authTag", "contentHash"]) {
    if (typeof value[key] !== "string" || !/^[A-Za-z0-9_-]+$/u.test(value[key])) {
      throw new Error("invalid_local_team_vault");
    }
  }
  return clone(value);
}

function normalizedSnapshot(value, expectedScope = null) {
  const hasServerHash = Object.hasOwn(value ?? {}, "serverContentHash");
  exactKeys(value, hasServerHash ? [...snapshotKeys, "serverContentHash"] : snapshotKeys, "invalid_local_team_vault");
  const scope = normalizeTeamVaultScope(value.scope);
  if (expectedScope && (scope.teamID !== expectedScope.teamID || scope.vaultID !== expectedScope.vaultID)) {
    throw new Error("invalid_local_team_vault");
  }
  if (hasServerHash && (value.serverRevision < 1 || !/^[A-Za-z0-9_-]{43}$/u.test(value.serverContentHash))) {
    throw new Error("invalid_local_team_vault");
  }
  const envelope = normalizedEnvelope(value.envelope);
  if (envelope.keyGeneration !== value.keyGeneration
    || !Number.isSafeInteger(value.localRevision) || value.localRevision < 1
    || !Number.isSafeInteger(value.serverRevision) || value.serverRevision < 0
    || !Number.isSafeInteger(value.syncedLocalRevision) || value.syncedLocalRevision < 0
    || value.syncedLocalRevision > value.localRevision
    || !value.wrapper || typeof value.wrapper !== "object" || Array.isArray(value.wrapper)) {
    throw new Error("invalid_local_team_vault");
  }
  return {
    scope,
    deviceID: normalizedUUID(value.deviceID, "invalid_local_team_vault"),
    keyGeneration: value.keyGeneration,
    localRevision: value.localRevision,
    serverRevision: value.serverRevision,
    syncedLocalRevision: value.syncedLocalRevision,
    ...(hasServerHash ? { serverContentHash: value.serverContentHash } : {}),
    envelope,
    wrapper: clone(value.wrapper),
  };
}

function snapshotKey(scope) {
  const normalized = normalizeTeamVaultScope(scope);
  return `team-vault:${normalized.teamID}:${normalized.vaultID}`;
}

function openDatabase(indexedDBValue) {
  return openVaultStorage(indexedDBValue, "team_vault_storage_unavailable");
}

async function transaction(indexedDBValue, mode, operation) {
  const database = await openDatabase(indexedDBValue);
  try {
    return await new Promise((resolve, reject) => {
      const tx = database.transaction(storeName, mode);
      let result = null;
      let failure = null;
      const request = operation(tx.objectStore(storeName), (value) => { result = value ?? null; }, (error) => {
        failure = error;
        tx.abort();
      });
      if (request) request.onsuccess = () => { result = request.result ?? null; };
      tx.onabort = () => reject(failure ?? new Error("team_vault_storage_failed"));
      tx.onerror = () => reject(failure ?? new Error("team_vault_storage_failed"));
      tx.oncomplete = () => resolve(result);
    });
  } finally {
    database.close();
  }
}

export function createIndexedDBTeamVaultRepository(scope, indexedDBValue = globalThis.indexedDB) {
  const normalizedScope = normalizeTeamVaultScope(scope);
  const key = snapshotKey(normalizedScope);
  function readDeviceSnapshots(store, device, done, abort, apply) {
    const scoped = store.get(`${key}:${device}`);
    scoped.onsuccess = () => {
      const legacy = store.get(key);
      legacy.onsuccess = () => {
        try {
          const current = scoped.result == null ? null : normalizedSnapshot(scoped.result, normalizedScope);
          if (current && current.deviceID !== device) throw new Error("invalid_local_team_vault");
          const old = legacy.result == null ? null : normalizedSnapshot(legacy.result, normalizedScope);
          const ownLegacy = old?.deviceID === device ? old : null;
          if (current && ownLegacy) throw new Error("team_vault_legacy_conflict");
          apply(current, ownLegacy, done);
        } catch (error) { abort(error); }
      };
    };
  }
  return {
    async load(deviceID = null) {
      const device = deviceID === null ? null : normalizedUUID(deviceID, "invalid_team_device_identity");
      const value = await transaction(indexedDBValue, "readonly", (store, done, abort) => {
        if (!device) return store.get(key);
        readDeviceSnapshots(store, device, done, abort, (scoped, legacy, finish) => finish(scoped ?? legacy));
      });
      if (value === null || value === undefined) return null;
      const snapshot = normalizedSnapshot(value, normalizedScope);
      if (device && snapshot.deviceID !== device) throw new Error("invalid_local_team_vault");
      return snapshot;
    },
    async save(value, deviceID = null, expectedSnapshot = undefined, requireCurrent = () => {}) {
      const snapshot = normalizedSnapshot(value, normalizedScope);
      const device = deviceID === null ? null : normalizedUUID(deviceID, "invalid_team_device_identity");
      if (device && snapshot.deviceID !== device) throw new Error("invalid_local_team_vault");
      const expected = expectedSnapshot == null ? expectedSnapshot : normalizedSnapshot(expectedSnapshot, normalizedScope);
      if (expected && expected.deviceID !== device) throw new Error("invalid_local_team_vault");
      await transaction(indexedDBValue, "readwrite", (store, done, abort) => {
        if (!device) { requireCurrent(); return store.put(clone(snapshot), key); }
        readDeviceSnapshots(store, device, done, abort, (scoped, legacy, finish) => {
          requireCurrent();
          if (expected !== undefined && JSON.stringify(scoped ?? legacy) !== JSON.stringify(expected)) {
            throw new Error("team_vault_stale_snapshot");
          }
          store.put(clone(snapshot), `${key}:${device}`);
          if (legacy) store.delete(key);
          finish(null);
        });
      });
    },
    async remove(deviceID = null, expectedSnapshot = undefined, requireCurrent = () => {}) {
      const device = deviceID === null ? null : normalizedUUID(deviceID, "invalid_team_device_identity");
      const expected = expectedSnapshot == null ? expectedSnapshot : normalizedSnapshot(expectedSnapshot, normalizedScope);
      if (expected && expected.deviceID !== device) throw new Error("invalid_local_team_vault");
      await transaction(indexedDBValue, "readwrite", (store, done, abort) => {
        if (!device) { requireCurrent(); return store.delete(key); }
        readDeviceSnapshots(store, device, done, abort, (scoped, legacy, finish) => {
          requireCurrent();
          if (expected !== undefined && JSON.stringify(scoped ?? legacy) !== JSON.stringify(expected)) {
            throw new Error("team_vault_stale_snapshot");
          }
          store.delete(`${key}:${device}`);
          if (legacy) store.delete(key);
          finish(null);
        });
      });
    },
  };
}

function remoteEnvelope(remote) {
  return normalizedEnvelope({
    baseRevision: Math.max(0, remote.revision - 1),
    keyGeneration: remote.keyGeneration,
    envelopeVersion: remote.envelopeVersion,
    ciphertext: remote.ciphertext,
    nonce: remote.nonce,
    authTag: remote.authTag,
    contentHash: remote.contentHash,
  });
}

export function createTeamVaultController({
  repository,
  identity,
  scope,
  cryptoValue = globalThis.crypto,
  now = () => new Date().toISOString(),
  randomUUID = () => cryptoValue.randomUUID(),
} = {}) {
  if (!repository || typeof repository.load !== "function" || typeof repository.save !== "function") {
    throw new Error("invalid_team_vault_repository");
  }
  const normalizedScope = normalizeTeamVaultScope(scope);
  const deviceID = normalizedUUID(identity?.deviceID, "invalid_team_device_identity");
  if (!identity?.privateKey) throw new Error("invalid_team_device_identity");
  let snapshot = null;
  let vaultKey = null;
  let document = null;
  let pendingConflicts = null;
  let pendingRotation = null;
  let pendingGeneration = null;
  let lockGeneration = 0;
  let activeMutation = null;

  function requireGeneration(expected) {
    if (lockGeneration !== expected) throw new Error("team_vault_locked");
  }

  // Operations that replace the live document are exclusive per controller.
  // Upload preparation stays independent so newer edits can remain dirty.
  async function mutate(name, operation) {
    if (activeMutation) throw new Error("team_vault_operation_in_progress");
    if (pendingRotation && name !== "commitRotation") throw new Error("team_vault_rotation_in_progress");
    const current = { generation: lockGeneration };
    activeMutation = current;
    try { return await operation(); }
    finally { if (activeMutation === current) activeMutation = null; }
  }

  function requireMutationCurrent() {
    if (activeMutation) requireGeneration(activeMutation.generation);
  }

  function requireUnlocked() {
    if (!snapshot || !vaultKey || !document) throw new Error("team_vault_locked");
  }

  function clearState() {
    snapshot = null;
    vaultKey = null;
    document = null;
    pendingConflicts = null;
    pendingRotation = null;
    pendingGeneration = null;
  }

  async function save(nextSnapshot, expectedSnapshot = snapshot, requireSession = () => {}) {
    const normalized = normalizedSnapshot(nextSnapshot, normalizedScope);
    const generation = lockGeneration;
    const requireCurrent = () => { requireGeneration(generation); requireSession(); };
    requireMutationCurrent();
    requireCurrent();
    await repository.save(normalized, deviceID, expectedSnapshot, requireCurrent);
    requireCurrent();
    requireMutationCurrent();
    snapshot = normalized;
  }

  async function currentSnapshot(expected, generation) {
    const stored = await repository.load(deviceID);
    requireGeneration(generation);
    const normalized = stored == null ? null : normalizedSnapshot(stored, normalizedScope);
    if (snapshot !== expected || JSON.stringify(normalized) !== JSON.stringify(expected)) {
      throw new Error("team_vault_stale_snapshot");
    }
  }

  async function unlockCurrent() {
    const generation = lockGeneration;
    const stored = await repository.load(deviceID);
    requireGeneration(generation);
    if (!stored) throw new Error("local_team_vault_missing");
    const nextSnapshot = normalizedSnapshot(stored, normalizedScope);
    const nextKey = await unwrapTeamVaultKeyForDevice({
      privateKey: identity.privateKey,
      wrapper: nextSnapshot.wrapper,
      ...normalizedScope,
      keyGeneration: nextSnapshot.keyGeneration,
      deviceID,
      cryptoValue,
    });
    const nextDocument = validateVaultDocument(await decryptTeamVaultPayload({
      vaultKey: nextKey,
      envelope: nextSnapshot.envelope,
      scope: normalizedScope,
      cryptoValue,
    }));
    requireGeneration(generation);
    const latest = await repository.load(deviceID);
    requireGeneration(generation);
    const normalizedLatest = latest == null ? null : normalizedSnapshot(latest, normalizedScope);
    if (JSON.stringify(normalizedLatest) !== JSON.stringify(nextSnapshot)) throw new Error("team_vault_stale_snapshot");
    snapshot = nextSnapshot;
    vaultKey = nextKey;
    document = nextDocument;
    pendingConflicts = null;
    pendingRotation = null;
    pendingGeneration = null;
    return clone(document);
  }

  async function persist(nextDocument) {
    requireUnlocked();
    if (pendingRotation) throw new Error("team_vault_rotation_in_progress");
    if (pendingGeneration) throw new Error("team_vault_generation_conflict");
    const expectedSnapshot = snapshot;
    const expectedDocument = document;
    const normalizedDocument = validateVaultDocument(nextDocument);
    const envelope = await encryptTeamVaultPayload({
      vaultKey,
      payload: normalizedDocument,
      scope: normalizedScope,
      baseRevision: expectedSnapshot.serverRevision,
      keyGeneration: expectedSnapshot.keyGeneration,
      cryptoValue,
    });
    if (snapshot !== expectedSnapshot || document !== expectedDocument) throw new Error("team_vault_stale_snapshot");
    await save({ ...expectedSnapshot, localRevision: expectedSnapshot.localRevision + 1, envelope }, expectedSnapshot);
    document = normalizedDocument;
    pendingConflicts = null;
    return clone(document);
  }

  const controller = {
    scope: normalizedScope,

    captureLifecycle() {
      const generation = lockGeneration;
      return (sessionDeviceID) => {
        requireGeneration(generation);
        if (sessionDeviceID !== undefined && String(sessionDeviceID ?? "").toLowerCase() !== deviceID) {
          throw new Error("authentication_required");
        }
      };
    },

    async status() {
      if (snapshot && vaultKey && document) return "unlocked";
      return (await repository.load(deviceID)) ? "locked" : "empty";
    },

    unlock: unlockCurrent,

    lock() {
      lockGeneration += 1;
      clearState();
    },

    document() {
      requireUnlocked();
      return clone(document);
    },

    async initialize(keyDevices) {
      if (await repository.load(deviceID)) throw new Error("local_team_vault_exists");
      if (!Array.isArray(keyDevices) || keyDevices.length === 0) throw new Error("team_key_devices_required");
      const unique = new Set(keyDevices.map((device) => normalizedUUID(device?.deviceID, "invalid_team_key_devices")));
      if (unique.size !== keyDevices.length || !unique.has(deviceID)) throw new Error("invalid_team_key_devices");
      const nextKey = await generateVaultKey(cryptoValue);
      const wrappers = await Promise.all(keyDevices.map((recipient) => wrapTeamVaultKeyForDevice({
        vaultKey: nextKey,
        recipient,
        ...normalizedScope,
        keyGeneration: 1,
        cryptoValue,
      })));
      const envelope = await encryptTeamVaultPayload({
        vaultKey: nextKey,
        payload: createEmptyVaultDocument(),
        scope: normalizedScope,
        baseRevision: 0,
        keyGeneration: 1,
        wrappers,
        cryptoValue,
      });
      const currentWrapper = wrappers.find((wrapper) => wrapper.deviceID === deviceID);
      const storedEnvelope = { ...envelope };
      delete storedEnvelope.wrappers;
      const nextSnapshot = {
        scope: normalizedScope,
        deviceID,
        keyGeneration: 1,
        localRevision: 1,
        serverRevision: 0,
        syncedLocalRevision: 0,
        envelope: storedEnvelope,
        wrapper: currentWrapper,
      };
      await save(nextSnapshot, null);
      vaultKey = nextKey;
      document = createEmptyVaultDocument();
      return { localRevision: 1, envelope };
    },

    async prepareInitialization(keyDevices) {
      requireUnlocked();
      if (snapshot.serverRevision !== 0 || !Array.isArray(keyDevices) || keyDevices.length === 0) {
        throw new Error("invalid_team_vault_initialization");
      }
      const expected = snapshot, currentKey = vaultKey, currentDocument = document, generation = lockGeneration;
      const unique = new Set(keyDevices.map((device) => normalizedUUID(device?.deviceID, "invalid_team_key_devices")));
      if (unique.size !== keyDevices.length || !unique.has(deviceID)) throw new Error("invalid_team_key_devices");
      const wrappers = await Promise.all(keyDevices.map((recipient) => wrapTeamVaultKeyForDevice({
        vaultKey: currentKey,
        recipient,
        ...normalizedScope,
        keyGeneration: expected.keyGeneration,
        cryptoValue,
      })));
      requireGeneration(generation);
      if (snapshot !== expected) throw new Error("team_vault_stale_snapshot");
      const envelope = await encryptTeamVaultPayload({
        vaultKey: currentKey,
        payload: currentDocument,
        scope: normalizedScope,
        baseRevision: 0,
        keyGeneration: expected.keyGeneration,
        wrappers,
        cryptoValue,
      });
      requireGeneration(generation);
      if (snapshot !== expected) throw new Error("team_vault_stale_snapshot");
      await currentSnapshot(expected, generation);
      return {
        localRevision: expected.localRevision,
        envelope,
      };
    },

    async discardUncommittedInitialization() {
      if (snapshot?.serverRevision !== 0 || snapshot?.syncedLocalRevision !== 0 || snapshot?.localRevision !== 1) {
        throw new Error("team_vault_initialization_committed");
      }
      if (typeof repository.remove !== "function") throw new Error("team_vault_storage_unavailable");
      const generation = lockGeneration;
      await repository.remove(deviceID, snapshot, () => requireGeneration(generation));
      requireMutationCurrent();
      clearState();
    },

    async importRemote(remote) {
      if (await repository.load(deviceID)) throw new Error("local_team_vault_exists");
      if (remote.rotationRequired) throw new Error("team_vault_rotation_required");
      if (remote.revision < 1 || !remote.wrapper) throw new Error("team_vault_key_unavailable");
      const envelope = remoteEnvelope(remote);
      const nextKey = await unwrapTeamVaultKeyForDevice({
        privateKey: identity.privateKey,
        wrapper: remote.wrapper,
        ...normalizedScope,
        keyGeneration: remote.keyGeneration,
        deviceID,
        cryptoValue,
      });
      const nextDocument = validateVaultDocument(await decryptTeamVaultPayload({
        vaultKey: nextKey,
        envelope,
        scope: normalizedScope,
        cryptoValue,
      }));
      const nextSnapshot = {
        scope: normalizedScope,
        deviceID,
        keyGeneration: remote.keyGeneration,
        localRevision: 1,
        serverRevision: remote.revision,
        syncedLocalRevision: 1,
        serverContentHash: envelope.contentHash,
        envelope,
        wrapper: remote.wrapper,
      };
      await save(nextSnapshot, null);
      vaultKey = nextKey;
      document = nextDocument;
      pendingConflicts = null;
      return clone(document);
    },

    async syncState() {
      requireUnlocked();
      const expected = snapshot, generation = lockGeneration;
      await currentSnapshot(expected, generation);
      return {
        localRevision: snapshot.localRevision,
        serverRevision: snapshot.serverRevision,
        keyGeneration: snapshot.keyGeneration,
        dirty: snapshot.syncedLocalRevision !== snapshot.localRevision,
      };
    },

    async verifyRemoteAccess(remote, { requireCurrent = () => {} } = {}) {
      const generation = lockGeneration;
      requireCurrent();
      if (!remote?.wrapper) throw new Error("team_vault_key_unavailable");
      let remoteKey;
      try {
        remoteKey = await unwrapTeamVaultKeyForDevice({ privateKey: identity.privateKey, wrapper: remote.wrapper,
          ...normalizedScope, keyGeneration: remote.keyGeneration, deviceID, cryptoValue });
      } catch {
        requireCurrent();
        requireGeneration(generation);
        throw new Error("team_vault_key_unavailable");
      }
      requireCurrent();
      requireGeneration(generation);
      if (snapshot && (normalizedUUID(snapshot.wrapper.membershipID, "invalid_team_vault_wrapper")
          !== normalizedUUID(remote.wrapper.membershipID, "invalid_team_vault_wrapper")
          || snapshot.wrapper.membershipEpoch !== remote.wrapper.membershipEpoch)) {
        throw new Error("team_vault_membership_changed");
      }
      // An uncommitted initialization can legitimately use a different key from
      // the first revision created concurrently by another authorized device.
      if (snapshot && snapshot.serverRevision > 0 && vaultKey && snapshot.keyGeneration === remote.keyGeneration) {
        const expected = snapshot, localKey = vaultKey;
        const localBytes = new Uint8Array(await cryptoValue.subtle.exportKey("raw", localKey));
        let remoteBytes;
        try {
          remoteBytes = new Uint8Array(await cryptoValue.subtle.exportKey("raw", remoteKey));
          requireCurrent();
          requireGeneration(generation);
          if (snapshot !== expected || vaultKey !== localKey) throw new Error("team_vault_stale_snapshot");
          let difference = localBytes.length ^ remoteBytes.length;
          for (let index = 0; index < Math.min(localBytes.length, remoteBytes.length); index++) {
            difference |= localBytes[index] ^ remoteBytes[index];
          }
          if (difference !== 0) throw new Error("team_vault_key_unavailable");
        } finally { localBytes.fill(0); remoteBytes?.fill(0); }
      }
    },

    async requireConfirmedSyncHistory({ remoteRevision = null } = {}) {
      requireUnlocked();
      const expected = snapshot, generation = lockGeneration;
      await currentSnapshot(expected, generation);
      if (snapshot.serverRevision > 0 && !snapshot.serverContentHash
          && (snapshot.syncedLocalRevision !== snapshot.localRevision
            || (remoteRevision !== null && remoteRevision !== snapshot.serverRevision))) {
        throw new Error("team_vault_history_unverified");
      }
    },

    async verifySameRevisionRemote(remote, { requireCurrent = () => {} } = {}) {
      requireUnlocked();
      requireCurrent();
      const expected = snapshot, generation = lockGeneration, currentKey = vaultKey;
      const envelope = remoteEnvelope(remote);
      const remoteDocument = validateVaultDocument(await decryptTeamVaultPayload({
        vaultKey: currentKey, envelope, scope: normalizedScope, cryptoValue,
      }));
      await currentSnapshot(expected, generation);
      requireCurrent();
      if (remote.revision !== expected.serverRevision || remote.keyGeneration !== expected.keyGeneration) {
        throw new Error("team_vault_stale_snapshot");
      }
      if (expected.serverContentHash && expected.serverContentHash !== envelope.contentHash) {
        throw new Error("team_vault_same_revision_changed");
      }
      const dirty = expected.syncedLocalRevision !== expected.localRevision;
      if (!expected.serverContentHash && dirty) throw new Error("team_vault_history_unverified");
      if (!dirty && JSON.stringify(remoteDocument) !== JSON.stringify(document)) {
        throw new Error("team_vault_same_revision_changed");
      }
      if (!expected.serverContentHash) await save({ ...expected, serverContentHash: envelope.contentHash }, expected, requireCurrent);
      requireCurrent();
    },

    async prepareUpload(baseRevision) {
      requireUnlocked();
      const expected = snapshot, currentDocument = document, currentKey = vaultKey, generation = lockGeneration;
      const envelope = await encryptTeamVaultPayload({
        vaultKey: currentKey,
        payload: currentDocument,
        scope: normalizedScope,
        baseRevision,
        keyGeneration: expected.keyGeneration,
        cryptoValue,
      });
      requireGeneration(generation);
      if (!snapshot || snapshot.keyGeneration !== expected.keyGeneration || snapshot.serverRevision !== expected.serverRevision) {
        throw new Error("team_vault_stale_snapshot");
      }
      await currentSnapshot(snapshot, generation);
      return {
        localRevision: expected.localRevision,
        envelope,
      };
    },

    async prepareWrapper(recipient) {
      requireUnlocked();
      if (pendingRotation) throw new Error("team_vault_rotation_in_progress");
      const currentKey = vaultKey, generation = lockGeneration, keyGeneration = snapshot.keyGeneration;
      const wrapper = await wrapTeamVaultKeyForDevice({
        vaultKey: currentKey,
        recipient,
        ...normalizedScope,
        keyGeneration,
        cryptoValue,
      });
      requireGeneration(generation);
      if (vaultKey !== currentKey || snapshot?.keyGeneration !== keyGeneration) throw new Error("team_vault_generation_changed");
      return wrapper;
    },

    async prepareRotation(remote, keyDevices) {
      if (pendingRotation) throw new Error("team_vault_rotation_in_progress");
      if (!remote?.rotationRequired || !Number.isSafeInteger(remote.revision) || remote.revision < 1
        || !Number.isSafeInteger(remote.keyGeneration) || remote.keyGeneration < 1) {
        throw new Error("team_vault_rotation_not_required");
      }
      let status = await this.status();
      requireMutationCurrent();
      if (status === "locked") {
        await unlockCurrent();
        status = "unlocked";
      }
      let currentKey = vaultKey;
      let localDocument = document;
      const sourceSnapshot = snapshot, generation = lockGeneration;
      const sourceLocalRevision = snapshot?.localRevision ?? 0;
      if (status === "unlocked") {
        if (snapshot.keyGeneration !== remote.keyGeneration) throw new Error("team_vault_generation_changed");
        if (snapshot.serverRevision > remote.revision) throw new Error("remote_revision_regressed");
        await this.requireConfirmedSyncHistory({ remoteRevision: remote.revision });
        requireMutationCurrent();
        await this.verifyRemoteAccess(remote);
        requireMutationCurrent();
      } else if (status === "empty") {
        if (!remote.wrapper) throw new Error("team_vault_key_unavailable");
        currentKey = await unwrapTeamVaultKeyForDevice({
          privateKey: identity.privateKey,
          wrapper: remote.wrapper,
          ...normalizedScope,
          keyGeneration: remote.keyGeneration,
          deviceID,
          cryptoValue,
        });
      } else {
        throw new Error("team_vault_locked");
      }
      const encryptedRemote = remoteEnvelope(remote);
      const remoteDocument = validateVaultDocument(await decryptTeamVaultPayload({
        vaultKey: currentKey,
        envelope: encryptedRemote,
        scope: normalizedScope,
        cryptoValue,
      }));
      if (sourceSnapshot && remote.revision === sourceSnapshot.serverRevision) {
        if (sourceSnapshot.serverContentHash && sourceSnapshot.serverContentHash !== encryptedRemote.contentHash) {
          throw new Error("team_vault_same_revision_changed");
        }
        if (!sourceSnapshot.serverContentHash && JSON.stringify(remoteDocument) !== JSON.stringify(localDocument)) {
          throw new Error("team_vault_same_revision_changed");
        }
      }
      let nextDocument = remoteDocument;
      if (localDocument) {
        const merged = mergeVaultDocuments(localDocument, remoteDocument);
        if (merged.conflicts.length > 0) {
          await currentSnapshot(sourceSnapshot, generation);
          pendingConflicts = { revision: remote.revision, document: merged.document,
            conflicts: merged.conflicts, sourceSnapshot: snapshot, remoteContentHash: encryptedRemote.contentHash };
          pendingGeneration = null;
          return { revision: remote.revision, conflicts: clone(merged.conflicts) };
        }
        nextDocument = merged.document;
      }
      if (!Array.isArray(keyDevices) || keyDevices.length === 0) throw new Error("team_key_devices_required");
      const unique = new Set(keyDevices.map((value) => normalizedUUID(value?.deviceID, "invalid_team_key_devices")));
      if (unique.size !== keyDevices.length || !unique.has(deviceID)) throw new Error("invalid_team_key_devices");
      const nextGeneration = remote.keyGeneration + 1;
      const nextKey = await generateVaultKey(cryptoValue);
      const wrappers = await Promise.all(keyDevices.map((recipient) => wrapTeamVaultKeyForDevice({
        vaultKey: nextKey,
        recipient,
        ...normalizedScope,
        keyGeneration: nextGeneration,
        cryptoValue,
      })));
      const currentWrapper = wrappers.find((wrapper) => wrapper.deviceID === deviceID);
      if (!currentWrapper) throw new Error("team_vault_key_unavailable");
      const envelope = await encryptTeamVaultPayload({
        vaultKey: nextKey,
        payload: nextDocument,
        scope: normalizedScope,
        baseRevision: remote.revision,
        keyGeneration: nextGeneration,
        wrappers,
        cryptoValue,
      });
      await currentSnapshot(sourceSnapshot, generation);
      const token = randomUUID();
      requireMutationCurrent();
      pendingRotation = {
        token,
        baseRevision: remote.revision,
        sourceLocalRevision,
        keyGeneration: nextGeneration,
        vaultKey: nextKey,
        document: nextDocument,
        uploadEnvelope: envelope,
        envelope: { ...envelope, wrappers: undefined },
        wrapper: currentWrapper,
      };
      delete pendingRotation.envelope.wrappers;
      return { token, baseRevision: remote.revision, envelope, keyGeneration: nextGeneration, conflicts: [] };
    },

    rotationPreparation() {
      if (!pendingRotation) return null;
      return {
        token: pendingRotation.token,
        baseRevision: pendingRotation.baseRevision,
        keyGeneration: pendingRotation.keyGeneration,
        envelope: clone(pendingRotation.uploadEnvelope),
      };
    },

    async commitRotation({ token, serverRevision, keyGeneration }) {
      const prepared = pendingRotation;
      if (!prepared || prepared.token !== token || prepared.keyGeneration !== keyGeneration
        || serverRevision !== prepared.baseRevision + 1) {
        throw new Error("invalid_team_vault_rotation");
      }
      const nextLocalRevision = Math.max(1, prepared.sourceLocalRevision + 1);
      await save({
        scope: normalizedScope,
        deviceID,
        keyGeneration,
        localRevision: nextLocalRevision,
        serverRevision,
        syncedLocalRevision: nextLocalRevision,
        serverContentHash: prepared.uploadEnvelope.contentHash,
        envelope: prepared.envelope,
        wrapper: prepared.wrapper,
      });
      vaultKey = prepared.vaultKey;
      document = prepared.document;
      pendingConflicts = null;
      pendingRotation = null;
      return { revision: serverRevision, keyGeneration };
    },

    cancelRotation(token) {
      if (pendingRotation?.token === token) pendingRotation = null;
    },

    async markSynced({ serverRevision, localRevision, serverContentHash = null }) {
      requireUnlocked();
      if (!Number.isSafeInteger(serverRevision) || serverRevision < 1
        || !Number.isSafeInteger(localRevision) || localRevision < 1 || localRevision > snapshot.localRevision) {
        throw new Error("invalid_team_vault_sync");
      }
      if (serverRevision < snapshot.serverRevision) {
        return { ...await this.syncState(), superseded: true };
      }
      if (serverRevision === snapshot.serverRevision && localRevision !== snapshot.syncedLocalRevision) {
        return { ...await this.syncState(), superseded: true };
      }
      const contentHash = serverContentHash ?? (serverRevision === snapshot.serverRevision ? snapshot.serverContentHash : undefined);
      const next = {
        ...snapshot,
        serverRevision,
        syncedLocalRevision: localRevision,
      };
      if (contentHash) next.serverContentHash = contentHash;
      else delete next.serverContentHash;
      await save(next);
      return { dirty: snapshot.syncedLocalRevision !== snapshot.localRevision, ...await this.syncState() };
    },

    async mergeRemote(remote) {
      requireUnlocked();
      if (remote.rotationRequired) throw new Error("team_vault_rotation_required");
      if (remote.keyGeneration !== snapshot.keyGeneration) throw new Error("team_vault_generation_changed");
      const envelope = remoteEnvelope(remote);
      const remoteDocument = validateVaultDocument(await decryptTeamVaultPayload({
        vaultKey,
        envelope,
        scope: normalizedScope,
        cryptoValue,
      }));
      requireMutationCurrent();
      await this.requireConfirmedSyncHistory({ remoteRevision: remote.revision });
      requireMutationCurrent();
      const merged = mergeVaultDocuments(document, remoteDocument);
      if (merged.conflicts.length > 0) {
        pendingConflicts = { revision: remote.revision, document: merged.document,
          conflicts: merged.conflicts, sourceSnapshot: snapshot, remoteContentHash: envelope.contentHash };
        pendingGeneration = null;
        return { conflicts: clone(merged.conflicts), matchesRemote: false, localChanged: false };
      }
      pendingConflicts = null;
      const matchesRemote = JSON.stringify(merged.document) === JSON.stringify(remoteDocument);
      const localChanged = JSON.stringify(merged.document) !== JSON.stringify(document);
      if (matchesRemote) {
        const nextLocalRevision = snapshot.localRevision + 1;
        await save({
          ...snapshot,
          localRevision: nextLocalRevision,
          serverRevision: remote.revision,
          syncedLocalRevision: nextLocalRevision,
          serverContentHash: envelope.contentHash,
          envelope,
          wrapper: remote.wrapper ?? snapshot.wrapper,
        });
        document = remoteDocument;
      } else if (localChanged) {
        await persist(merged.document);
        await save({ ...snapshot, serverRevision: remote.revision, serverContentHash: envelope.contentHash,
          wrapper: remote.wrapper ?? snapshot.wrapper });
      }
      return { conflicts: [], matchesRemote, localChanged };
    },

    async mergeRemoteGeneration(remote) {
      requireUnlocked();
      if (remote.rotationRequired) throw new Error("team_vault_rotation_required");
      if (remote.keyGeneration <= snapshot.keyGeneration || remote.revision <= snapshot.serverRevision) {
        throw new Error("team_vault_generation_changed");
      }
      if (!remote.wrapper) throw new Error("team_vault_key_unavailable");
      const nextKey = await unwrapTeamVaultKeyForDevice({
        privateKey: identity.privateKey,
        wrapper: remote.wrapper,
        ...normalizedScope,
        keyGeneration: remote.keyGeneration,
        deviceID,
        cryptoValue,
      });
      const envelope = remoteEnvelope(remote);
      const remoteDocument = validateVaultDocument(await decryptTeamVaultPayload({
        vaultKey: nextKey,
        envelope,
        scope: normalizedScope,
        cryptoValue,
      }));
      requireMutationCurrent();
      await this.requireConfirmedSyncHistory({ remoteRevision: remote.revision });
      requireMutationCurrent();
      const merged = mergeVaultDocuments(document, remoteDocument);
      if (merged.conflicts.length > 0) {
        pendingConflicts = { revision: remote.revision, document: merged.document,
          conflicts: merged.conflicts, sourceSnapshot: snapshot, remoteContentHash: envelope.contentHash };
        pendingGeneration = { vaultKey: nextKey, remote, wrapper: remote.wrapper };
        return { conflicts: clone(merged.conflicts), matchesRemote: false };
      }
      const matchesRemote = JSON.stringify(merged.document) === JSON.stringify(remoteDocument);
      const nextLocalRevision = snapshot.localRevision + 1;
      let nextEnvelope = envelope;
      if (!matchesRemote) {
        nextEnvelope = await encryptTeamVaultPayload({
          vaultKey: nextKey,
          payload: merged.document,
          scope: normalizedScope,
          baseRevision: remote.revision,
          keyGeneration: remote.keyGeneration,
          cryptoValue,
        });
      }
      requireMutationCurrent();
      await save({
        ...snapshot,
        keyGeneration: remote.keyGeneration,
        localRevision: nextLocalRevision,
        serverRevision: remote.revision,
        serverContentHash: envelope.contentHash,
        syncedLocalRevision: matchesRemote ? nextLocalRevision : snapshot.syncedLocalRevision,
        envelope: nextEnvelope,
        wrapper: remote.wrapper,
      });
      vaultKey = nextKey;
      document = merged.document;
      pendingConflicts = null;
      pendingGeneration = null;
      return { conflicts: [], matchesRemote };
    },

    pendingConflicts() {
      requireUnlocked();
      return pendingConflicts ? { revision: pendingConflicts.revision, conflicts: clone(pendingConflicts.conflicts) } : null;
    },

    async resolveConflicts({ revision, resolutions }) {
      requireUnlocked();
      if (!pendingConflicts || revision !== pendingConflicts.revision || !Array.isArray(resolutions)
        || resolutions.length !== pendingConflicts.conflicts.length) {
        throw new Error("invalid_pending_conflicts");
      }
      if (snapshot !== pendingConflicts.sourceSnapshot) throw new Error("invalid_pending_conflicts");
      const choices = new Map();
      for (const resolution of resolutions) {
        exactKeys(resolution, ["choice", "id"], "invalid_conflict_resolution");
        const id = normalizedUUID(resolution.id, "invalid_conflict_resolution");
        if (!['local', 'remote'].includes(resolution.choice) || choices.has(id)) {
          throw new Error("invalid_conflict_resolution");
        }
        choices.set(id, resolution.choice);
      }
      if (pendingConflicts.conflicts.some((conflict) => !choices.has(conflict.id))) {
        throw new Error("incomplete_conflict_resolution");
      }
      let resolved = pendingConflicts.document;
      const remoteContentHash = pendingConflicts.remoteContentHash;
      for (const conflict of pendingConflicts.conflicts) {
        resolved = resolveVaultConflict(resolved, conflict, {
          choice: choices.get(conflict.id),
          deviceID,
          resolvedAt: now(),
        });
      }
      if (pendingGeneration) {
        const generation = pendingGeneration;
        const nextLocalRevision = snapshot.localRevision + 1;
        const envelope = await encryptTeamVaultPayload({
          vaultKey: generation.vaultKey,
          payload: resolved,
          scope: normalizedScope,
          baseRevision: revision,
          keyGeneration: generation.remote.keyGeneration,
          cryptoValue,
        });
        requireMutationCurrent();
        await save({
          ...snapshot,
          keyGeneration: generation.remote.keyGeneration,
          localRevision: nextLocalRevision,
          serverRevision: revision,
          serverContentHash: remoteContentHash,
          envelope,
          wrapper: generation.wrapper,
        });
        vaultKey = generation.vaultKey;
        document = resolved;
        pendingGeneration = null;
      } else {
        await persist(resolved);
        await save({ ...snapshot, serverRevision: revision, serverContentHash: remoteContentHash });
      }
      const count = pendingConflicts?.conflicts.length ?? resolutions.length;
      pendingConflicts = null;
      return { revision, localRevision: snapshot.localRevision, conflictsResolved: count };
    },

    async applyBatch(operations) {
      requireUnlocked();
      if (!Array.isArray(operations) || operations.length === 0) throw new Error("invalid_team_vault_batch");
      let nextDocument = document;
      for (const operation of operations) {
        if (operation?.op === "upsert" && operation.record && recordTypes.has(operation.record.type)) {
          nextDocument = upsertVaultRecord(nextDocument, {
            id: operation.record.id ?? randomUUID(),
            type: operation.record.type,
            data: operation.record.data,
            deviceID,
            modifiedAt: now(),
          });
        } else if (operation?.op === "delete") {
          nextDocument = deleteVaultRecord(nextDocument, { id: operation.id, deviceID, deletedAt: now() });
        } else throw new Error("invalid_team_vault_batch");
      }
      return persist(nextDocument);
    },

    async upsert({ id = randomUUID(), type, data }) {
      requireUnlocked();
      if (!recordTypes.has(type)) throw new Error("invalid_record_type");
      await persist(upsertVaultRecord(document, {
        id,
        type,
        data,
        deviceID,
        modifiedAt: now(),
      }));
      return id;
    },

    async delete(id) {
      requireUnlocked();
      return persist(deleteVaultRecord(document, { id, deviceID, deletedAt: now() }));
    },
  };
  for (const name of ["unlock", "initialize", "discardUncommittedInitialization", "importRemote", "prepareRotation",
    "commitRotation", "markSynced", "mergeRemote", "mergeRemoteGeneration", "resolveConflicts", "applyBatch", "upsert", "delete"]) {
    const operation = controller[name];
    controller[name] = (...args) => mutate(name, () => operation.apply(controller, args));
  }
  return controller;
}

function captureTeamOperation(client, controller) {
  const session = client?.session();
  if (!session) throw new Error("authentication_required");
  const accountID = session.id;
  const generation = typeof client.sessionGeneration === "function" ? client.sessionGeneration() : null;
  const requireLifecycle = typeof controller.captureLifecycle === "function" ? controller.captureLifecycle() : () => {};
  const requireCurrent = () => {
    const current = client.session();
    if (!current || current.id !== accountID
      || (generation !== null && client.sessionGeneration() !== generation)) throw new Error("authentication_required");
    requireLifecycle(typeof client.deviceID === "function" ? client.deviceID() : undefined);
  };
  requireCurrent();
  return requireCurrent;
}

async function verifyTeamRemoteAccess({ controller, remote, requireCurrent }) {
  if (remote.revision === 0) return;
  try {
    if (typeof controller.verifyRemoteAccess !== "function") throw new Error("team_vault_key_unavailable");
    await controller.verifyRemoteAccess(remote, { requireCurrent });
    requireCurrent();
  } catch (error) {
    requireCurrent();
    controller.lock();
    throw error;
  }
}

async function readTeamVaultOrLock({ client, controller, scope, requireCurrent }) {
  try {
    return await client.getTeamVault(scope);
  } catch (error) {
    if (error?.message === "team_vault_access_denied") {
      requireCurrent();
      controller.lock();
    }
    throw error;
  }
}

async function uploadCurrent({ client, controller, scope, baseRevision, requireCurrent }) {
  const prepared = await controller.prepareUpload(baseRevision);
  requireCurrent();
  await controller.requireConfirmedSyncHistory({ remoteRevision: baseRevision });
  requireCurrent();
  const result = await client.putTeamVault(
    scope,
    prepared.envelope,
    `web:team:vault:put:${globalThis.crypto.randomUUID()}`,
  );
  requireCurrent();
  if (result.conflict) return { status: "remote_changed", remoteRevision: result.revision };
  if (result.revision !== baseRevision + 1) throw new Error("invalid_remote_revision");
  const state = await controller.markSynced({ serverRevision: result.revision, localRevision: prepared.localRevision,
    serverContentHash: prepared.envelope.contentHash });
  requireCurrent();
  if (state.superseded) return { status: state.dirty ? "uploaded_with_new_local_changes" : "up_to_date", revision: state.serverRevision };
  return { status: state.dirty ? "uploaded_with_new_local_changes" : "uploaded", revision: result.revision };
}

export async function provisionTeamVaultWrappers({ client, controller } = {}) {
  if (!client?.session()) throw new Error("authentication_required");
  if (!controller || typeof controller.prepareWrapper !== "function"
    || typeof controller.syncState !== "function") {
    throw new Error("invalid_team_vault_controller");
  }
  const requireCurrent = captureTeamOperation(client, controller);
  const scope = controller.scope;
  const state = await controller.syncState();
  requireCurrent();
  const keyDevices = await client.listTeamKeyDevices(scope);
  requireCurrent();
  if (!keyDevices || !Array.isArray(keyDevices.devices) || keyDevices.devices.length > 1_024) {
    throw new Error("invalid_team_key_devices");
  }
  const missing = keyDevices.devices.filter((device) => device.hasWrapper === false);
  let granted = 0;
  for (const recipient of missing) {
    const wrapper = await controller.prepareWrapper(recipient);
    requireCurrent();
    await client.grantTeamVaultWrapper(
      scope,
      { keyGeneration: state.keyGeneration, wrapper },
      `web:team:vault:grant:${globalThis.crypto.randomUUID()}`,
    );
    requireCurrent();
    granted += 1;
  }
  return {
    status: missing.length === 0 ? "up_to_date" : "provisioned",
    keyGeneration: state.keyGeneration,
    eligible: keyDevices.devices.length,
    missing: missing.length,
    granted,
  };
}

export async function synchronizeTeamVault({ client, controller, role } = {}) {
  if (!client?.session()) throw new Error("authentication_required");
  if (!controller || typeof controller.status !== "function") throw new Error("invalid_team_vault_controller");
  const requireCurrent = captureTeamOperation(client, controller);
  const scope = controller.scope;
  const remote = await readTeamVaultOrLock({ client, controller, scope, requireCurrent });
  requireCurrent();
  await verifyTeamRemoteAccess({ controller, remote, requireCurrent });
  requireCurrent();
  if (remote.rotationRequired) throw new Error("team_vault_rotation_required");
  let status = await controller.status();
  requireCurrent();
  if (status === "locked") {
    await controller.unlock();
    requireCurrent();
    await verifyTeamRemoteAccess({ controller, remote, requireCurrent });
    requireCurrent();
    status = "unlocked";
  }
  if (status === "empty") {
    if (remote.revision > 0) {
      await controller.importRemote(remote);
      requireCurrent();
      return { status: "downloaded", revision: remote.revision };
    }
    if (!["owner", "admin"].includes(role)) throw new Error("team_vault_initialization_forbidden");
    const devices = await client.listTeamKeyDevices(scope);
    requireCurrent();
    const prepared = await controller.initialize(devices.devices);
    requireCurrent();
    const result = await client.putTeamVault(
      scope,
      prepared.envelope,
      `web:team:vault:initialize:${globalThis.crypto.randomUUID()}`,
    );
    requireCurrent();
    if (result.conflict) {
      await controller.discardUncommittedInitialization();
      requireCurrent();
      return { status: "remote_changed", remoteRevision: result.revision };
    }
    await controller.markSynced({ serverRevision: result.revision, localRevision: prepared.localRevision,
      serverContentHash: prepared.envelope.contentHash });
    requireCurrent();
    return { status: "initialized", revision: result.revision };
  }
  if (status !== "unlocked") throw new Error("team_vault_locked");
  const state = await controller.syncState();
  requireCurrent();
  if (remote.revision > 0 && state.serverRevision === 0) {
    await controller.discardUncommittedInitialization();
    requireCurrent();
    await controller.importRemote(remote);
    requireCurrent();
    return { status: "downloaded", revision: remote.revision };
  }
  if (remote.revision === 0 && state.serverRevision === 0) {
    if (!["owner", "admin"].includes(role)) throw new Error("team_vault_initialization_forbidden");
    const devices = await client.listTeamKeyDevices(scope);
    requireCurrent();
    const prepared = await controller.prepareInitialization(devices.devices);
    requireCurrent();
    const result = await client.putTeamVault(
      scope,
      prepared.envelope,
      `web:team:vault:initialize:${globalThis.crypto.randomUUID()}`,
    );
    requireCurrent();
    if (result.conflict) return { status: "remote_changed", remoteRevision: result.revision };
    await controller.markSynced({ serverRevision: result.revision, localRevision: prepared.localRevision,
      serverContentHash: prepared.envelope.contentHash });
    requireCurrent();
    return { status: "initialized", revision: result.revision };
  }
  if (remote.revision < state.serverRevision) throw new Error("remote_revision_regressed");
  if (remote.keyGeneration < state.keyGeneration) throw new Error("team_vault_generation_changed");
  try { await controller.requireConfirmedSyncHistory({ remoteRevision: remote.revision }); }
  catch (error) {
    requireCurrent();
    if (error?.message === "team_vault_history_unverified") controller.lock();
    throw error;
  }
  requireCurrent();
  if (remote.keyGeneration > state.keyGeneration) {
    const merged = await controller.mergeRemoteGeneration(remote);
    requireCurrent();
    if (merged.conflicts.length > 0) {
      return { status: "conflict", revision: remote.revision, conflicts: merged.conflicts };
    }
    if (merged.matchesRemote) return { status: "downloaded", revision: remote.revision };
    return uploadCurrent({ client, controller, scope, baseRevision: remote.revision, requireCurrent });
  }
  if (remote.revision === state.serverRevision) {
    await controller.verifySameRevisionRemote(remote, { requireCurrent });
    requireCurrent();
    return state.dirty
      ? uploadCurrent({ client, controller, scope, baseRevision: remote.revision, requireCurrent })
      : { status: "up_to_date", revision: remote.revision };
  }
  const merged = await controller.mergeRemote(remote);
  requireCurrent();
  if (merged.conflicts.length > 0) {
    return { status: "conflict", revision: remote.revision, conflicts: merged.conflicts };
  }
  if (merged.matchesRemote) return { status: "downloaded", revision: remote.revision };
  return uploadCurrent({ client, controller, scope, baseRevision: remote.revision, requireCurrent });
}

export async function rotateTeamVault({ client, controller, role } = {}) {
  if (!client?.session()) throw new Error("authentication_required");
  if (!controller || typeof controller.prepareRotation !== "function") {
    throw new Error("invalid_team_vault_controller");
  }
  if (!["owner", "admin"].includes(role)) throw new Error("team_vault_rotation_forbidden");
  const requireCurrent = captureTeamOperation(client, controller);
  const scope = controller.scope;
  const remote = await readTeamVaultOrLock({ client, controller, scope, requireCurrent });
  requireCurrent();
  await verifyTeamRemoteAccess({ controller, remote, requireCurrent });
  requireCurrent();
  let prepared = controller.rotationPreparation();
  if (prepared && !remote.rotationRequired) {
    if (remote.revision === prepared.baseRevision + 1
      && remote.keyGeneration === prepared.keyGeneration
      && remote.contentHash === prepared.envelope.contentHash) {
      await controller.commitRotation({
        token: prepared.token,
        serverRevision: remote.revision,
        keyGeneration: remote.keyGeneration,
      });
      requireCurrent();
      return { status: "rotated", revision: remote.revision, keyGeneration: remote.keyGeneration };
    }
    controller.cancelRotation(prepared.token);
    throw new Error("team_vault_rotation_not_required");
  }
  if (!remote.rotationRequired) throw new Error("team_vault_rotation_not_required");
  if (prepared && (prepared.baseRevision !== remote.revision
    || prepared.keyGeneration !== remote.keyGeneration + 1)) {
    controller.cancelRotation(prepared.token);
    prepared = null;
  }
  if (!prepared) {
    const devices = await client.listTeamKeyDevices(scope);
    requireCurrent();
    prepared = await controller.prepareRotation(remote, devices.devices);
    try { requireCurrent(); }
    catch (error) { controller.cancelRotation(prepared.token); throw error; }
    if (prepared.conflicts.length > 0) {
      return { status: "conflict", revision: prepared.revision, conflicts: prepared.conflicts };
    }
  }
  const result = await client.putTeamVault(
    scope,
    prepared.envelope,
    `web:team:vault:rotate:${prepared.token}`,
  );
  requireCurrent();
  if (result.conflict) {
    controller.cancelRotation(prepared.token);
    return {
      status: "remote_changed",
      remoteRevision: result.revision,
      keyGeneration: result.keyGeneration,
    };
  }
  if (!result.rotationCompleted || result.revision !== prepared.baseRevision + 1
    || result.keyGeneration !== prepared.keyGeneration) {
    controller.cancelRotation(prepared.token);
    throw new Error("invalid_team_vault_rotation");
  }
  await controller.commitRotation({
    token: prepared.token,
    serverRevision: result.revision,
    keyGeneration: result.keyGeneration,
  });
  requireCurrent();
  return { status: "rotated", revision: result.revision, keyGeneration: result.keyGeneration };
}
