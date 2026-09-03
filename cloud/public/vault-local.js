import {
  decryptVaultEnvelope,
  encryptVaultPayload,
  generateVaultKey,
  unwrapVaultKey,
  wrapVaultKey,
} from "./vault-crypto.js";
import {
  createEmptyVaultDocument,
  deleteVaultRecord,
  upsertVaultRecord,
  validateVaultDocument,
} from "./vault-model.js";

const databaseName = "selective-remote-cloud";
const storeName = "local-vault";
const snapshotKey = "personal";
const exactUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const recordTypes = new Set(["host", "credential", "snippet", "forwarding"]);
const snapshotKeys = ["deviceID", "envelope", "revision"];
const envelopeKeys = ["authTag", "baseRevision", "ciphertext", "contentHash", "envelopeVersion", "nonce", "wrappedKey"];

function exactKeys(value, expected, code) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(code);
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    throw new Error(code);
  }
}

function validatedSnapshot(value) {
  exactKeys(value, snapshotKeys, "invalid_local_vault");
  exactKeys(value.envelope, envelopeKeys, "invalid_local_vault");
  if (!Number.isSafeInteger(value.revision) || value.revision < 1) throw new Error("invalid_local_vault");
  if (value.envelope.baseRevision !== value.revision - 1) throw new Error("invalid_local_vault");
  const deviceID = String(value.deviceID ?? "").toLowerCase();
  if (!exactUUID.test(deviceID)) throw new Error("invalid_local_vault");
  return { revision: value.revision, deviceID, envelope: value.envelope };
}

function clone(value) {
  return globalThis.structuredClone
    ? globalThis.structuredClone(value)
    : JSON.parse(JSON.stringify(value));
}

function openDatabase(indexedDBValue) {
  if (!indexedDBValue?.open) return Promise.reject(new Error("local_vault_storage_unavailable"));
  return new Promise((resolve, reject) => {
    const request = indexedDBValue.open(databaseName, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(storeName)) request.result.createObjectStore(storeName);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error("local_vault_storage_unavailable"));
    request.onblocked = () => reject(new Error("local_vault_storage_unavailable"));
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
      request.onerror = () => reject(new Error("local_vault_storage_failed"));
      tx.onabort = () => reject(new Error("local_vault_storage_failed"));
      tx.onerror = () => reject(new Error("local_vault_storage_failed"));
      tx.oncomplete = () => resolve(result);
    });
  } finally {
    database.close();
  }
}

export function createIndexedDBVaultRepository(indexedDBValue = globalThis.indexedDB) {
  return {
    async load() {
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(snapshotKey));
      return value === null || value === undefined ? null : clone(value);
    },
    async save(value) {
      const snapshot = validatedSnapshot(value);
      await transaction(indexedDBValue, "readwrite", (store) => store.put(clone(snapshot), snapshotKey));
    },
  };
}

export function createLocalVaultController({
  repository,
  cryptoValue = globalThis.crypto,
  now = () => new Date().toISOString(),
  randomUUID = () => cryptoValue.randomUUID(),
} = {}) {
  if (!repository || typeof repository.load !== "function" || typeof repository.save !== "function") {
    throw new Error("invalid_local_vault_repository");
  }

  let snapshot = null;
  let vaultKey = null;
  let document = null;

  function requireUnlocked() {
    if (!snapshot || !vaultKey || !document) throw new Error("local_vault_locked");
  }

  async function persist(nextDocument) {
    requireUnlocked();
    const normalized = validateVaultDocument(nextDocument);
    const envelope = await encryptVaultPayload({
      vaultKey,
      payload: normalized,
      baseRevision: snapshot.revision,
      wrappedKey: snapshot.envelope.wrappedKey,
      cryptoValue,
    });
    const nextSnapshot = validatedSnapshot({
      revision: snapshot.revision + 1,
      deviceID: snapshot.deviceID,
      envelope,
    });
    await repository.save(nextSnapshot);
    snapshot = nextSnapshot;
    document = normalized;
    return clone(document);
  }

  return {
    async status() {
      if (snapshot && vaultKey && document) return "unlocked";
      return (await repository.load()) ? "locked" : "empty";
    },

    async create(passphrase) {
      if (await repository.load()) throw new Error("local_vault_exists");
      const nextVaultKey = await generateVaultKey(cryptoValue);
      const wrappedKey = await wrapVaultKey(nextVaultKey, passphrase, cryptoValue);
      const nextDocument = createEmptyVaultDocument();
      const envelope = await encryptVaultPayload({
        vaultKey: nextVaultKey,
        payload: nextDocument,
        baseRevision: 0,
        wrappedKey,
        cryptoValue,
      });
      const nextSnapshot = validatedSnapshot({ revision: 1, deviceID: randomUUID(), envelope });
      await repository.save(nextSnapshot);
      snapshot = nextSnapshot;
      vaultKey = nextVaultKey;
      document = nextDocument;
      return clone(document);
    },

    async unlock(passphrase) {
      snapshot = null;
      vaultKey = null;
      document = null;
      const stored = await repository.load();
      if (!stored) throw new Error("local_vault_missing");
      const nextSnapshot = validatedSnapshot(stored);
      const nextVaultKey = await unwrapVaultKey(nextSnapshot.envelope.wrappedKey, passphrase, cryptoValue);
      const nextDocument = validateVaultDocument(
        await decryptVaultEnvelope(nextVaultKey, nextSnapshot.envelope, cryptoValue),
      );
      snapshot = nextSnapshot;
      vaultKey = nextVaultKey;
      document = nextDocument;
      return clone(document);
    },

    lock() {
      snapshot = null;
      vaultKey = null;
      document = null;
    },

    document() {
      requireUnlocked();
      return clone(document);
    },

    async upsert({ id = randomUUID(), type, data }) {
      requireUnlocked();
      if (!recordTypes.has(type)) throw new Error("invalid_record_type");
      const next = upsertVaultRecord(document, {
        id,
        type,
        data,
        deviceID: snapshot.deviceID,
        modifiedAt: now(),
      });
      await persist(next);
      return id;
    },

    async delete(id) {
      requireUnlocked();
      return persist(deleteVaultRecord(document, {
        id,
        deviceID: snapshot.deviceID,
        deletedAt: now(),
      }));
    },
  };
}
