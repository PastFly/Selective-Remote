import { generateVaultKey } from "./vault-crypto.js";
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

const databaseName = "selective-remote-cloud";
const storeName = "local-vault";
const recordTypes = new Set(["host", "credential", "snippet", "forwarding"]);
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
  exactKeys(value, snapshotKeys, "invalid_local_team_vault");
  const scope = normalizeTeamVaultScope(value.scope);
  if (expectedScope && (scope.teamID !== expectedScope.teamID || scope.vaultID !== expectedScope.vaultID)) {
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
    envelope,
    wrapper: clone(value.wrapper),
  };
}

function snapshotKey(scope) {
  const normalized = normalizeTeamVaultScope(scope);
  return `team-vault:${normalized.teamID}:${normalized.vaultID}`;
}

function openDatabase(indexedDBValue) {
  if (!indexedDBValue?.open) return Promise.reject(new Error("team_vault_storage_unavailable"));
  return new Promise((resolve, reject) => {
    const request = indexedDBValue.open(databaseName, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(storeName)) request.result.createObjectStore(storeName);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error("team_vault_storage_unavailable"));
    request.onblocked = () => reject(new Error("team_vault_storage_unavailable"));
  });
}

async function transaction(indexedDBValue, mode, operation) {
  const database = await openDatabase(indexedDBValue);
  try {
    return await new Promise((resolve, reject) => {
      const tx = database.transaction(storeName, mode);
      const request = operation(tx.objectStore(storeName));
      let result = null;
      request.onsuccess = () => { result = request.result ?? null; };
      request.onerror = () => reject(new Error("team_vault_storage_failed"));
      tx.onabort = () => reject(new Error("team_vault_storage_failed"));
      tx.onerror = () => reject(new Error("team_vault_storage_failed"));
      tx.oncomplete = () => resolve(result);
    });
  } finally {
    database.close();
  }
}

export function createIndexedDBTeamVaultRepository(scope, indexedDBValue = globalThis.indexedDB) {
  const normalizedScope = normalizeTeamVaultScope(scope);
  const key = snapshotKey(normalizedScope);
  return {
    async load() {
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(key));
      return value === null || value === undefined ? null : normalizedSnapshot(value, normalizedScope);
    },
    async save(value) {
      const snapshot = normalizedSnapshot(value, normalizedScope);
      await transaction(indexedDBValue, "readwrite", (store) => store.put(clone(snapshot), key));
    },
    async remove() {
      await transaction(indexedDBValue, "readwrite", (store) => store.delete(key));
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

  function requireUnlocked() {
    if (!snapshot || !vaultKey || !document) throw new Error("team_vault_locked");
  }

  async function save(nextSnapshot) {
    const normalized = normalizedSnapshot(nextSnapshot, normalizedScope);
    await repository.save(normalized);
    snapshot = normalized;
  }

  async function persist(nextDocument) {
    requireUnlocked();
    if (pendingRotation) throw new Error("team_vault_rotation_in_progress");
    if (pendingGeneration) throw new Error("team_vault_generation_conflict");
    const normalizedDocument = validateVaultDocument(nextDocument);
    const envelope = await encryptTeamVaultPayload({
      vaultKey,
      payload: normalizedDocument,
      scope: normalizedScope,
      baseRevision: snapshot.serverRevision,
      keyGeneration: snapshot.keyGeneration,
      cryptoValue,
    });
    await save({ ...snapshot, localRevision: snapshot.localRevision + 1, envelope });
    document = normalizedDocument;
    pendingConflicts = null;
    return clone(document);
  }

  return {
    scope: normalizedScope,

    async status() {
      if (snapshot && vaultKey && document) return "unlocked";
      return (await repository.load()) ? "locked" : "empty";
    },

    async unlock() {
      const stored = await repository.load();
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
      snapshot = nextSnapshot;
      vaultKey = nextKey;
      document = nextDocument;
      pendingConflicts = null;
      pendingRotation = null;
      pendingGeneration = null;
      return clone(document);
    },

    lock() {
      snapshot = null;
      vaultKey = null;
      document = null;
      pendingConflicts = null;
      pendingRotation = null;
      pendingGeneration = null;
    },

    document() {
      requireUnlocked();
      return clone(document);
    },

    async initialize(keyDevices) {
      if (await repository.load()) throw new Error("local_team_vault_exists");
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
      await save(nextSnapshot);
      vaultKey = nextKey;
      document = createEmptyVaultDocument();
      return { localRevision: 1, envelope };
    },

    async prepareInitialization(keyDevices) {
      requireUnlocked();
      if (snapshot.serverRevision !== 0 || !Array.isArray(keyDevices) || keyDevices.length === 0) {
        throw new Error("invalid_team_vault_initialization");
      }
      const unique = new Set(keyDevices.map((device) => normalizedUUID(device?.deviceID, "invalid_team_key_devices")));
      if (unique.size !== keyDevices.length || !unique.has(deviceID)) throw new Error("invalid_team_key_devices");
      const wrappers = await Promise.all(keyDevices.map((recipient) => wrapTeamVaultKeyForDevice({
        vaultKey,
        recipient,
        ...normalizedScope,
        keyGeneration: snapshot.keyGeneration,
        cryptoValue,
      })));
      return {
        localRevision: snapshot.localRevision,
        envelope: await encryptTeamVaultPayload({
          vaultKey,
          payload: document,
          scope: normalizedScope,
          baseRevision: 0,
          keyGeneration: snapshot.keyGeneration,
          wrappers,
          cryptoValue,
        }),
      };
    },

    async discardUncommittedInitialization() {
      if (snapshot?.serverRevision !== 0 || snapshot?.syncedLocalRevision !== 0 || snapshot?.localRevision !== 1) {
        throw new Error("team_vault_initialization_committed");
      }
      if (typeof repository.remove !== "function") throw new Error("team_vault_storage_unavailable");
      await repository.remove();
      this.lock();
    },

    async importRemote(remote) {
      if (await repository.load()) throw new Error("local_team_vault_exists");
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
        envelope,
        wrapper: remote.wrapper,
      };
      await save(nextSnapshot);
      vaultKey = nextKey;
      document = nextDocument;
      pendingConflicts = null;
      return clone(document);
    },

    async syncState() {
      requireUnlocked();
      return {
        localRevision: snapshot.localRevision,
        serverRevision: snapshot.serverRevision,
        keyGeneration: snapshot.keyGeneration,
        dirty: snapshot.syncedLocalRevision !== snapshot.localRevision,
      };
    },

    async prepareUpload(baseRevision) {
      requireUnlocked();
      return {
        localRevision: snapshot.localRevision,
        envelope: await encryptTeamVaultPayload({
          vaultKey,
          payload: document,
          scope: normalizedScope,
          baseRevision,
          keyGeneration: snapshot.keyGeneration,
          cryptoValue,
        }),
      };
    },

    async prepareWrapper(recipient) {
      requireUnlocked();
      if (pendingRotation) throw new Error("team_vault_rotation_in_progress");
      return wrapTeamVaultKeyForDevice({
        vaultKey,
        recipient,
        ...normalizedScope,
        keyGeneration: snapshot.keyGeneration,
        cryptoValue,
      });
    },

    async prepareRotation(remote, keyDevices) {
      if (pendingRotation) throw new Error("team_vault_rotation_in_progress");
      if (!remote?.rotationRequired || !Number.isSafeInteger(remote.revision) || remote.revision < 1
        || !Number.isSafeInteger(remote.keyGeneration) || remote.keyGeneration < 1) {
        throw new Error("team_vault_rotation_not_required");
      }
      let status = await this.status();
      if (status === "locked") {
        await this.unlock();
        status = "unlocked";
      }
      let currentKey = vaultKey;
      let localDocument = document;
      const sourceLocalRevision = snapshot?.localRevision ?? 0;
      if (status === "unlocked") {
        if (snapshot.keyGeneration !== remote.keyGeneration) throw new Error("team_vault_generation_changed");
        if (snapshot.serverRevision > remote.revision) throw new Error("remote_revision_regressed");
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
      let nextDocument = remoteDocument;
      if (localDocument) {
        const merged = mergeVaultDocuments(localDocument, remoteDocument);
        if (merged.conflicts.length > 0) {
          pendingConflicts = { revision: remote.revision, document: merged.document, conflicts: clone(merged.conflicts) };
          return { conflicts: clone(merged.conflicts), revision: remote.revision };
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
      const token = randomUUID();
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

    async markSynced({ serverRevision, localRevision }) {
      requireUnlocked();
      if (!Number.isSafeInteger(serverRevision) || serverRevision < 1
        || !Number.isSafeInteger(localRevision) || localRevision < 1 || localRevision > snapshot.localRevision) {
        throw new Error("invalid_team_vault_sync");
      }
      await save({
        ...snapshot,
        serverRevision,
        syncedLocalRevision: localRevision,
      });
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
      const merged = mergeVaultDocuments(document, remoteDocument);
      if (merged.conflicts.length > 0) {
        pendingConflicts = { revision: remote.revision, document: merged.document, conflicts: clone(merged.conflicts) };
        return { conflicts: clone(merged.conflicts) };
      }
      const matchesRemote = JSON.stringify(merged.document) === JSON.stringify(remoteDocument);
      const localChanged = JSON.stringify(merged.document) !== JSON.stringify(document);
      if (matchesRemote) {
        const nextLocalRevision = snapshot.localRevision + 1;
        await save({
          ...snapshot,
          localRevision: nextLocalRevision,
          serverRevision: remote.revision,
          syncedLocalRevision: nextLocalRevision,
          envelope,
          wrapper: remote.wrapper ?? snapshot.wrapper,
        });
        document = remoteDocument;
      } else if (localChanged) {
        await persist(merged.document);
        await save({ ...snapshot, serverRevision: remote.revision, wrapper: remote.wrapper ?? snapshot.wrapper });
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
      const merged = mergeVaultDocuments(document, remoteDocument);
      if (merged.conflicts.length > 0) {
        pendingGeneration = { remote, vaultKey: nextKey, envelope, wrapper: remote.wrapper };
        pendingConflicts = { revision: remote.revision, document: merged.document, conflicts: clone(merged.conflicts) };
        return { conflicts: clone(merged.conflicts) };
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
      await save({
        ...snapshot,
        keyGeneration: remote.keyGeneration,
        localRevision: nextLocalRevision,
        serverRevision: remote.revision,
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
        await save({
          ...snapshot,
          keyGeneration: generation.remote.keyGeneration,
          localRevision: nextLocalRevision,
          serverRevision: revision,
          envelope,
          wrapper: generation.wrapper,
        });
        vaultKey = generation.vaultKey;
        document = resolved;
        pendingGeneration = null;
      } else {
        await persist(resolved);
        await save({ ...snapshot, serverRevision: revision });
      }
      const count = pendingConflicts?.conflicts.length ?? resolutions.length;
      pendingConflicts = null;
      return { revision, localRevision: snapshot.localRevision, conflictsResolved: count };
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
}

async function uploadCurrent({ client, controller, scope, baseRevision }) {
  const prepared = await controller.prepareUpload(baseRevision);
  const result = await client.putTeamVault(
    scope,
    prepared.envelope,
    `web:team:vault:put:${globalThis.crypto.randomUUID()}`,
  );
  if (result.conflict) return { status: "remote_changed", remoteRevision: result.revision };
  if (result.revision !== baseRevision + 1) throw new Error("invalid_remote_revision");
  const state = await controller.markSynced({ serverRevision: result.revision, localRevision: prepared.localRevision });
  return { status: state.dirty ? "uploaded_with_new_local_changes" : "uploaded", revision: result.revision };
}

export async function synchronizeTeamVault({ client, controller, role } = {}) {
  if (!client?.session()) throw new Error("authentication_required");
  if (!controller || typeof controller.status !== "function") throw new Error("invalid_team_vault_controller");
  const scope = controller.scope;
  const remote = await client.getTeamVault(scope);
  if (remote.rotationRequired) throw new Error("team_vault_rotation_required");
  let status = await controller.status();
  if (status === "locked") {
    await controller.unlock();
    status = "unlocked";
  }
  if (status === "empty") {
    if (remote.revision > 0) {
      await controller.importRemote(remote);
      return { status: "downloaded", revision: remote.revision };
    }
    if (!["owner", "admin"].includes(role)) throw new Error("team_vault_initialization_forbidden");
    const devices = await client.listTeamKeyDevices(scope);
    const prepared = await controller.initialize(devices.devices);
    const result = await client.putTeamVault(
      scope,
      prepared.envelope,
      `web:team:vault:initialize:${globalThis.crypto.randomUUID()}`,
    );
    if (result.conflict) {
      await controller.discardUncommittedInitialization();
      return { status: "remote_changed", remoteRevision: result.revision };
    }
    await controller.markSynced({ serverRevision: result.revision, localRevision: prepared.localRevision });
    return { status: "initialized", revision: result.revision };
  }
  if (status !== "unlocked") throw new Error("team_vault_locked");
  const state = await controller.syncState();
  if (remote.revision > 0 && state.serverRevision === 0) {
    await controller.discardUncommittedInitialization();
    await controller.importRemote(remote);
    return { status: "downloaded", revision: remote.revision };
  }
  if (remote.revision === 0 && state.serverRevision === 0) {
    if (!["owner", "admin"].includes(role)) throw new Error("team_vault_initialization_forbidden");
    const devices = await client.listTeamKeyDevices(scope);
    const prepared = await controller.prepareInitialization(devices.devices);
    const result = await client.putTeamVault(
      scope,
      prepared.envelope,
      `web:team:vault:initialize:${globalThis.crypto.randomUUID()}`,
    );
    if (result.conflict) return { status: "remote_changed", remoteRevision: result.revision };
    await controller.markSynced({ serverRevision: result.revision, localRevision: prepared.localRevision });
    return { status: "initialized", revision: result.revision };
  }
  if (remote.revision < state.serverRevision) throw new Error("remote_revision_regressed");
  if (remote.keyGeneration < state.keyGeneration) throw new Error("team_vault_generation_changed");
  if (remote.keyGeneration > state.keyGeneration) {
    const merged = await controller.mergeRemoteGeneration(remote);
    if (merged.conflicts.length > 0) {
      return { status: "conflict", revision: remote.revision, conflicts: merged.conflicts };
    }
    if (merged.matchesRemote) return { status: "downloaded", revision: remote.revision };
    return uploadCurrent({ client, controller, scope, baseRevision: remote.revision });
  }
  if (remote.revision === state.serverRevision) {
    return state.dirty
      ? uploadCurrent({ client, controller, scope, baseRevision: remote.revision })
      : { status: "up_to_date", revision: remote.revision };
  }
  const merged = await controller.mergeRemote(remote);
  if (merged.conflicts.length > 0) {
    return { status: "conflict", revision: remote.revision, conflicts: merged.conflicts };
  }
  if (merged.matchesRemote) return { status: "downloaded", revision: remote.revision };
  return uploadCurrent({ client, controller, scope, baseRevision: remote.revision });
}

export async function rotateTeamVault({ client, controller, role } = {}) {
  if (!client?.session()) throw new Error("authentication_required");
  if (!controller || typeof controller.prepareRotation !== "function") {
    throw new Error("invalid_team_vault_controller");
  }
  if (!["owner", "admin"].includes(role)) throw new Error("team_vault_rotation_forbidden");
  const scope = controller.scope;
  const remote = await client.getTeamVault(scope);
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
    prepared = await controller.prepareRotation(remote, devices.devices);
    if (prepared.conflicts.length > 0) {
      return { status: "conflict", revision: prepared.revision, conflicts: prepared.conflicts };
    }
  }
  const result = await client.putTeamVault(
    scope,
    prepared.envelope,
    `web:team:vault:rotate:${prepared.token}`,
  );
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
  return { status: "rotated", revision: result.revision, keyGeneration: result.keyGeneration };
}
