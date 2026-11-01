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
  mergeVaultDocuments,
  resolveVaultConflictsByNewest,
  resolveVaultConflict,
  upsertVaultRecord,
  validateVaultDocument,
} from "./vault-model.js";

const databaseName = "selective-remote-cloud";
const storeName = "local-vault";
const snapshotKey = "personal";
const syncKey = "personal-sync";
const backupSnapshotKey = "personal-previous";
const legacyOwnershipKey = "personal-legacy-owner:v1";
const deviceKey = "browser-device";
const sessionDeviceKey = "personal-session-device-key";
const sessionUnlockKey = "personal-session-unlock";
const sessionUnlockVersion = 1;
const sessionUnlockContext = "selective-remote:personal-vault:browser-session:v1:";
const accountVaultKeyPrefix = "personal-account:v1:";
const accountDeviceDigestContext = "selective-remote/account-device-email/v1";
const accountDeviceKeyPrefix = "account-device:v1:";
const accountDeviceStateKeys = ["deviceID", "registrationAccepted"];
const exactUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const base64URLDigest = /^[A-Za-z0-9_-]{43}$/u;
const recordTypes = new Set(["host", "credential", "snippet", "forwarding", "sshKey"]);
const snapshotKeys = ["deviceID", "envelope", "revision"];
const envelopeKeys = ["authTag", "baseRevision", "ciphertext", "contentHash", "envelopeVersion", "nonce", "wrappedKey"];
const syncKeys = ["localRevision", "serverRevision"];

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

function validatedSyncMetadata(value) {
  exactKeys(value, syncKeys, "invalid_local_vault_sync");
  if (!Number.isSafeInteger(value.localRevision) || value.localRevision < 1) {
    throw new Error("invalid_local_vault_sync");
  }
  if (!Number.isSafeInteger(value.serverRevision) || value.serverRevision < 0) {
    throw new Error("invalid_local_vault_sync");
  }
  return { localRevision: value.localRevision, serverRevision: value.serverRevision };
}

function normalizedDeviceID(value) {
  const deviceID = String(value ?? "").toLowerCase();
  if (!exactUUID.test(deviceID)) throw new Error("invalid_local_device");
  return deviceID;
}

function normalizedAccountEmail(value) {
  const email = String(value ?? "").trim().toLowerCase();
  if (email.length < 3 || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(email)) {
    throw new Error("invalid_email");
  }
  return email;
}

function bytesToBase64URL(bytes) {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

export async function accountDeviceStorageKey(email, cryptoValue = globalThis.crypto) {
  if (!cryptoValue?.subtle) throw new Error("web_crypto_unavailable");
  const input = new TextEncoder().encode(`${accountDeviceDigestContext}\0${normalizedAccountEmail(email)}`);
  const digest = bytesToBase64URL(new Uint8Array(await cryptoValue.subtle.digest("SHA-256", input)));
  return `${accountDeviceKeyPrefix}${digest}`;
}

function normalizedAccountDeviceKey(value) {
  const key = String(value ?? "");
  if (!key.startsWith(accountDeviceKeyPrefix)
      || !base64URLDigest.test(key.slice(accountDeviceKeyPrefix.length))) {
    throw new Error("invalid_account_device_key");
  }
  return key;
}

function normalizedAccountDevice(value) {
  if (typeof value === "string") {
    return { deviceID: normalizedDeviceID(value), registrationAccepted: false };
  }
  exactKeys(value, accountDeviceStateKeys, "invalid_account_device");
  if (typeof value.registrationAccepted !== "boolean") throw new Error("invalid_account_device");
  return {
    deviceID: normalizedDeviceID(value.deviceID),
    registrationAccepted: value.registrationAccepted,
  };
}

function normalizedAccountID(value) {
  const accountID = String(value ?? "").toLowerCase();
  if (!exactUUID.test(accountID)) throw new Error("invalid_account");
  return accountID;
}

export function accountVaultStorageKeys(accountValue) {
  const accountID = normalizedAccountID(accountValue);
  const prefix = `${accountVaultKeyPrefix}${accountID}:`;
  return {
    snapshot: `${prefix}snapshot`,
    sync: `${prefix}sync`,
    backup: `${prefix}previous`,
    sessionUnlock: `${prefix}session-unlock`,
    ownership: `${prefix}ownership`,
  };
}

function byteArray(value, length, code) {
  if (!ArrayBuffer.isView(value) || value.BYTES_PER_ELEMENT !== 1 || value.byteLength !== length) {
    throw new Error(code);
  }
  return new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
}

function validatedSessionDeviceKey(value) {
  const usages = Array.from(value?.usages ?? []);
  if (value?.type !== "secret" || value?.extractable !== false
      || value?.algorithm?.name !== "AES-GCM" || value?.algorithm?.length !== 256
      || !usages.includes("encrypt") || !usages.includes("decrypt")) {
    throw new Error("invalid_session_device_key");
  }
  return value;
}

function validatedSessionUnlock(value, accountID) {
  exactKeys(value, ["accountID", "ciphertext", "nonce", "version"], "invalid_session_unlock");
  if (value.version !== sessionUnlockVersion || normalizedAccountID(value.accountID) !== accountID) {
    throw new Error("invalid_session_unlock");
  }
  return {
    version: sessionUnlockVersion,
    accountID,
    nonce: byteArray(value.nonce, 12, "invalid_session_unlock"),
    ciphertext: byteArray(value.ciphertext, 48, "invalid_session_unlock"),
  };
}

function sameSessionUnlock(left, right) {
  if (left == null || right == null) return left == null && right == null;
  try {
    const accountID = normalizedAccountID(left.accountID);
    const a = validatedSessionUnlock(left, accountID), b = validatedSessionUnlock(right, accountID);
    return a.nonce.every((value, index) => value === b.nonce[index])
      && a.ciphertext.every((value, index) => value === b.ciphertext[index]);
  } catch { return false; }
}

// A damaged record can be replaced after a password unlock, but only if the
// exact record read before encryption is still present in the transaction.
function sameStoredSessionUnlock(left, right) {
  if (sameSessionUnlock(left, right)) return true;
  try {
    const keys = ["accountID", "ciphertext", "nonce", "version"];
    exactKeys(left, keys, "invalid_session_unlock");
    exactKeys(right, keys, "invalid_session_unlock");
    if (typeof left.accountID !== "string" || left.accountID !== right.accountID
        || typeof left.version !== "number" || !Object.is(left.version, right.version)) return false;
    return ["nonce", "ciphertext"].every((key) => {
      const a = left[key], b = right[key];
      if (!ArrayBuffer.isView(a) || !ArrayBuffer.isView(b)
          || a.BYTES_PER_ELEMENT !== 1 || b.BYTES_PER_ELEMENT !== 1
          || a.constructor.name !== b.constructor.name || a.byteLength !== b.byteLength
          || a.byteLength > 4096) return false;
      const aa = new Uint8Array(a.buffer, a.byteOffset, a.byteLength);
      const bb = new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
      return aa.every((value, index) => value === bb[index]);
    });
  } catch { return false; }
}

function sameWrappedKey(left, right) {
  const keys = ["algorithm", "iterations", "salt", "value"];
  if (!left || !right || typeof left.algorithm !== "string" || !Number.isSafeInteger(left.iterations)
      || typeof left.salt !== "string" || typeof left.value !== "string") return false;
  return keys.every((key) => left?.[key] === right?.[key]);
}

function validatedOwnershipBinding(value, accountID) {
  exactKeys(value, ["accountID", "version", "wrappedKey"], "invalid_local_vault_owner");
  if (value.version !== 1 || normalizedAccountID(value.accountID) !== accountID
      || !sameWrappedKey(value.wrappedKey, value.wrappedKey)) throw new Error("invalid_local_vault_owner");
  return clone(value);
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

export function createIndexedDBVaultRepository(indexedDBValue = globalThis.indexedDB, { accountID = null } = {}) {
  const keys = accountID === null
    ? { snapshot: snapshotKey, sync: syncKey, backup: backupSnapshotKey, sessionUnlock: sessionUnlockKey, ownership: legacyOwnershipKey }
    : accountVaultStorageKeys(accountID);
  const sessionUnlockGenerationKey = `${keys.sessionUnlock}:generation`;
  return {
    async load() {
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(keys.snapshot));
      return value === null || value === undefined ? null : clone(value);
    },
    async save(value) {
      const snapshot = validatedSnapshot(value);
      await transaction(indexedDBValue, "readwrite", (store) => store.put(clone(snapshot), keys.snapshot));
    },
    async saveInitial(value, syncValue = null) {
      const snapshot = validatedSnapshot(value);
      const metadata = syncValue === null ? null : validatedSyncMetadata(syncValue);
      const database = await openDatabase(indexedDBValue);
      try {
        await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite"), store = tx.objectStore(storeName);
          let failure = null;
          const request = store.get(keys.snapshot);
          request.onsuccess = () => {
            if (request.result != null) { failure = new Error("local_vault_exists"); tx.abort(); return; }
            store.add(clone(snapshot), keys.snapshot);
            if (metadata) store.put(metadata, keys.sync);
            if (accountID !== null) store.put({ version: 1, accountID: normalizedAccountID(accountID),
              wrappedKey: clone(snapshot.envelope.wrappedKey) }, keys.ownership);
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve();
        });
      } finally { database.close(); }
    },
    async saveIfCurrent(expectedValue, nextValue, { backup = false, sync = null } = {}) {
      const expected = validatedSnapshot(expectedValue), next = validatedSnapshot(nextValue);
      const metadata = sync === null ? null : validatedSyncMetadata(sync);
      const database = await openDatabase(indexedDBValue);
      try {
        await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite"), store = tx.objectStore(storeName);
          let failure = null;
          const current = store.get(keys.snapshot), owner = store.get(keys.ownership);
          let remaining = 2;
          for (const request of [current, owner]) request.onsuccess = () => {
            if (--remaining) return;
            try {
              if (!current.result || JSON.stringify(validatedSnapshot(current.result)) !== JSON.stringify(expected)) {
                throw new Error("local_vault_changed");
              }
              if (backup) store.put(clone(expected), keys.backup);
              store.put(clone(next), keys.snapshot);
              if (metadata) store.put(metadata, keys.sync);
              if (accountID !== null && owner.result) {
                const binding = validatedOwnershipBinding(owner.result, normalizedAccountID(accountID));
                if (!sameWrappedKey(binding.wrappedKey, expected.envelope.wrappedKey)) throw new Error("local_vault_owner_unverified");
                store.put({ ...binding, wrappedKey: clone(next.envelope.wrappedKey) }, keys.ownership);
              }
            } catch (error) { failure = error; tx.abort(); }
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve();
        });
      } finally { database.close(); }
    },
    async saveSyncIfCurrent(expectedValue, syncValue) {
      const expected = validatedSnapshot(expectedValue), metadata = validatedSyncMetadata(syncValue);
      const database = await openDatabase(indexedDBValue);
      try {
        await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite"), store = tx.objectStore(storeName);
          let failure = null;
          const current = store.get(keys.snapshot), prior = store.get(keys.sync);
          let remaining = 2;
          for (const request of [current, prior]) request.onsuccess = () => {
            if (--remaining) return;
            try {
              if (!current.result || JSON.stringify(validatedSnapshot(current.result)) !== JSON.stringify(expected)) {
                throw new Error("local_vault_changed");
              }
              if (prior.result && validatedSyncMetadata(prior.result).serverRevision > metadata.serverRevision) {
                throw new Error("local_vault_sync_changed");
              }
              store.put(metadata, keys.sync);
            } catch (error) { failure = error; tx.abort(); }
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve();
        });
      } finally { database.close(); }
    },
    async loadLegacyState() {
      if (accountID !== null) throw new Error("invalid_local_vault_owner");
      const database = await openDatabase(indexedDBValue);
      try {
        return await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readonly");
          const store = tx.objectStore(storeName);
          const snapshot = store.get(keys.snapshot);
          const sync = store.get(keys.sync);
          const owner = store.get(keys.ownership);
          tx.onabort = () => reject(new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve({ snapshot: snapshot.result ?? null, sync: sync.result ?? null, owner: owner.result ?? null });
        });
      } finally { database.close(); }
    },
    async importLegacyStateIfAbsent({ snapshot, sync, owner }) {
      if (accountID === null) throw new Error("invalid_local_vault_owner");
      const normalizedSnapshot = validatedSnapshot(snapshot);
      const metadata = sync == null ? null : validatedSyncMetadata(sync);
      if (metadata && metadata.localRevision > normalizedSnapshot.revision) throw new Error("invalid_local_vault_sync");
      const binding = validatedOwnershipBinding({
        version: 1, accountID: owner, wrappedKey: normalizedSnapshot.envelope.wrappedKey,
      }, normalizedAccountID(accountID));
      const database = await openDatabase(indexedDBValue);
      try {
        await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite");
          const store = tx.objectStore(storeName);
          let failure = null;
          const requests = [store.get(keys.snapshot), store.get(snapshotKey), store.get(syncKey), store.get(legacyOwnershipKey)];
          let remaining = requests.length;
          for (const request of requests) request.onsuccess = () => {
            if (--remaining !== 0) return;
            try {
              const [target, source, sourceSync, sourceOwner] = requests.map(item => item.result ?? null);
              if (target) throw new Error("local_vault_exists");
              const current = source == null ? null : validatedSnapshot(source);
              const currentSync = sourceSync == null ? null : validatedSyncMetadata(sourceSync);
              if (JSON.stringify(current) !== JSON.stringify(normalizedSnapshot)
                  || JSON.stringify(currentSync) !== JSON.stringify(metadata)) throw new Error("legacy_snapshot_changed");
              if (!sourceOwner) throw new Error("local_vault_owner_unverified");
              const prior = validatedOwnershipBinding(sourceOwner, normalizedAccountID(sourceOwner.accountID));
              if (!sameWrappedKey(prior.wrappedKey, normalizedSnapshot.envelope.wrappedKey)
                  || prior.accountID !== binding.accountID) throw new Error("invalid_local_vault_owner");
              store.add(clone(normalizedSnapshot), keys.snapshot);
              if (metadata) store.put(metadata, keys.sync);
              store.put(binding, keys.ownership);
              store.put(binding, legacyOwnershipKey);
            } catch (error) { failure = error; tx.abort(); }
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve();
        });
      } finally { database.close(); }
    },
    async savePrevious(value) {
      const snapshot = validatedSnapshot(value);
      await transaction(indexedDBValue, "readwrite", (store) => store.put(clone(snapshot), keys.backup));
    },
    async loadSync() {
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(keys.sync));
      return value === null || value === undefined ? null : validatedSyncMetadata(value);
    },
    async loadSyncForSnapshot(expectedValue) {
      const expected = validatedSnapshot(expectedValue);
      const database = await openDatabase(indexedDBValue);
      try {
        return await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readonly"), store = tx.objectStore(storeName);
          const current = store.get(keys.snapshot), metadata = store.get(keys.sync);
          let failure = null, result = null, remaining = 2;
          for (const request of [current, metadata]) request.onsuccess = () => {
            if (--remaining) return;
            try {
              if (!current.result || JSON.stringify(validatedSnapshot(current.result)) !== JSON.stringify(expected)) {
                throw new Error("local_vault_changed");
              }
              result = metadata.result == null ? null : validatedSyncMetadata(metadata.result);
            } catch (error) { failure = error; tx.abort(); }
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve(result);
        });
      } finally { database.close(); }
    },
    async saveSync(value) {
      const metadata = validatedSyncMetadata(value);
      await transaction(indexedDBValue, "readwrite", (store) => store.put(clone(metadata), keys.sync));
    },
    async loadDeviceID() {
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(deviceKey));
      return value === null || value === undefined ? null : normalizedDeviceID(value);
    },
    async saveDeviceID(value) {
      const deviceID = normalizedDeviceID(value);
      await transaction(indexedDBValue, "readwrite", (store) => store.put(deviceID, deviceKey));
    },
    async loadAccountDevice(key) {
      const normalizedKey = normalizedAccountDeviceKey(key);
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(normalizedKey));
      return value === null || value === undefined ? null : normalizedAccountDevice(value);
    },
    async saveAccountDeviceIfAbsent(key, value) {
      const normalizedKey = normalizedAccountDeviceKey(key);
      const accountDevice = normalizedAccountDevice(value);
      const database = await openDatabase(indexedDBValue);
      try {
        return await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite");
          const store = tx.objectStore(storeName);
          let committed = null;
          const request = store.get(normalizedKey);
          request.onerror = () => reject(new Error("local_vault_storage_failed"));
          request.onsuccess = () => {
            if (request.result !== null && request.result !== undefined) {
              try { committed = normalizedAccountDevice(request.result); } catch { reject(new Error("invalid_account_device")); }
              return;
            }
            const add = store.add(accountDevice, normalizedKey);
            add.onerror = () => reject(new Error("local_vault_storage_failed"));
            add.onsuccess = () => { committed = accountDevice; };
          };
          tx.onabort = () => reject(new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve(committed);
        });
      } finally {
        database.close();
      }
    },
    async replaceAccountDevice(key, expected, replacement) {
      const normalizedKey = normalizedAccountDeviceKey(key);
      const expectedAccountDevice = normalizedAccountDevice(expected);
      const replacementAccountDevice = normalizedAccountDevice(replacement);
      const database = await openDatabase(indexedDBValue);
      try {
        return await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite");
          const store = tx.objectStore(storeName);
          let committed = null;
          const request = store.get(normalizedKey);
          request.onerror = () => reject(new Error("local_vault_storage_failed"));
          request.onsuccess = () => {
            if (request.result !== null && request.result !== undefined) {
              try { committed = normalizedAccountDevice(request.result); } catch { reject(new Error("invalid_account_device")); return; }
              if (committed.deviceID !== expectedAccountDevice.deviceID
                  || committed.registrationAccepted !== expectedAccountDevice.registrationAccepted) return;
            }
            const put = store.put(replacementAccountDevice, normalizedKey);
            put.onerror = () => reject(new Error("local_vault_storage_failed"));
            put.onsuccess = () => { committed = replacementAccountDevice; };
          };
          tx.onabort = () => reject(new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve(committed);
        });
      } finally {
        database.close();
      }
    },
    async loadSessionDeviceKey() {
      return transaction(indexedDBValue, "readonly", (store) => store.get(sessionDeviceKey));
    },
    async saveSessionDeviceKey(value) {
      await transaction(indexedDBValue, "readwrite", (store) => store.put(value, sessionDeviceKey));
    },
    async saveSessionDeviceKeyIfAbsent(value) {
      const candidate = validatedSessionDeviceKey(value);
      const database = await openDatabase(indexedDBValue);
      try {
        return await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite"), store = tx.objectStore(storeName);
          let selected = null, failure = null;
          const request = store.get(sessionDeviceKey);
          request.onsuccess = () => {
            try {
              selected = request.result ? validatedSessionDeviceKey(request.result) : candidate;
              if (!request.result) store.add(candidate, sessionDeviceKey);
            } catch (error) { failure = error; tx.abort(); }
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve(selected);
        });
      } finally { database.close(); }
    },
    async loadSessionUnlock() {
      return transaction(indexedDBValue, "readonly", (store) => store.get(keys.sessionUnlock));
    },
    async saveSessionUnlock(value) {
      const unlock = accountID === null ? value : validatedSessionUnlock(value, normalizedAccountID(accountID));
      await transaction(indexedDBValue, "readwrite", (store) => store.put(unlock, keys.sessionUnlock));
    },
    async loadSessionUnlockGeneration() {
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(sessionUnlockGenerationKey));
      if (value === null) return 0;
      if (!Number.isSafeInteger(value) || value < 0) throw new Error("local_vault_storage_failed");
      return value;
    },
    async loadSessionUnlockState() {
      const database = await openDatabase(indexedDBValue);
      try {
        return await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readonly"), store = tx.objectStore(storeName);
          const generation = store.get(sessionUnlockGenerationKey), unlock = store.get(keys.sessionUnlock);
          tx.oncomplete = () => {
            const current = generation.result ?? 0;
            if (!Number.isSafeInteger(current) || current < 0) { reject(new Error("local_vault_storage_failed")); return; }
            resolve({ generation: current, unlock: unlock.result ?? null });
          };
          tx.onabort = () => reject(new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(new Error("local_vault_storage_failed"));
        });
      } finally { database.close(); }
    },
    async saveSessionUnlockIfCurrent(value, expectedGeneration, expectedUnlock) {
      if (!Number.isSafeInteger(expectedGeneration) || expectedGeneration < 0 || expectedUnlock === undefined) throw new Error("local_vault_storage_failed");
      const unlock = accountID === null ? value : validatedSessionUnlock(value, normalizedAccountID(accountID));
      const database = await openDatabase(indexedDBValue);
      try {
        return await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite"), store = tx.objectStore(storeName);
          let committed = false, failure = null;
          const generation = store.get(sessionUnlockGenerationKey), previous = store.get(keys.sessionUnlock);
          let remaining = 2;
          for (const request of [generation, previous]) request.onsuccess = () => {
            if (--remaining) return;
            const current = generation.result ?? 0;
            if (!Number.isSafeInteger(current) || current < 0 || current === Number.MAX_SAFE_INTEGER) { failure = new Error("local_vault_storage_failed"); tx.abort(); return; }
            if (current !== expectedGeneration || !sameStoredSessionUnlock(previous.result ?? null, expectedUnlock)) return;
            store.put(unlock, keys.sessionUnlock);
            store.put(current + 1, sessionUnlockGenerationKey);
            committed = true;
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve(committed);
        });
      } finally { database.close(); }
    },
    async deleteSessionUnlock() {
      const database = await openDatabase(indexedDBValue);
      try {
        await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite"), store = tx.objectStore(storeName);
          let failure = null;
          const request = store.get(sessionUnlockGenerationKey);
          request.onsuccess = () => {
            const current = request.result ?? 0;
            if (!Number.isSafeInteger(current) || current < 0 || current === Number.MAX_SAFE_INTEGER) {
              failure = new Error("local_vault_storage_failed"); tx.abort(); return;
            }
            store.put(current + 1, sessionUnlockGenerationKey);
            store.delete(keys.sessionUnlock);
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve();
        });
      } finally { database.close(); }
    },
    async deleteSessionUnlockIfCurrent(expected, pending = [], { strictGeneration = false } = {}) {
      if (expected !== null && (!Number.isSafeInteger(expected.generation) || expected.generation < 0)) {
        throw new Error("local_vault_storage_failed");
      }
      const database = await openDatabase(indexedDBValue);
      try {
        return await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite"), store = tx.objectStore(storeName);
          const generation = store.get(sessionUnlockGenerationKey), unlock = store.get(keys.sessionUnlock);
          let remaining = 2, deleted = false, failure = null;
          for (const request of [generation, unlock]) request.onsuccess = () => {
            if (--remaining) return;
            const current = generation.result ?? 0, currentUnlock = unlock.result ?? null;
            if (!Number.isSafeInteger(current) || current < 0 || current === Number.MAX_SAFE_INTEGER) {
              failure = new Error("local_vault_storage_failed"); tx.abort(); return;
            }
            const observedMatch = expected && (!strictGeneration || current === expected.generation) && (expected.unlock
              ? sameSessionUnlock(currentUnlock, expected.unlock)
              : current === expected.generation && currentUnlock === null);
            const pendingMatch = currentUnlock && pending.some(candidate =>
              (!strictGeneration || current === candidate.base?.generation + 1)
                && sameSessionUnlock(currentUnlock, candidate.unlock));
            const invalidatePending = pending.some(candidate => candidate.base
              && current === candidate.base.generation && sameStoredSessionUnlock(currentUnlock, candidate.base.unlock));
            if (!observedMatch && !pendingMatch && !invalidatePending) return;
            store.put(current + 1, sessionUnlockGenerationKey);
            if (observedMatch || pendingMatch) { store.delete(keys.sessionUnlock); deleted = true; }
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve(deleted);
        });
      } finally { database.close(); }
    },
    async loadOwnershipBinding() {
      if (accountID === null) return null;
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(keys.ownership));
      return value == null ? null : validatedOwnershipBinding(value, normalizedAccountID(accountID));
    },
    async saveOwnershipBinding(value) {
      if (accountID === null) throw new Error("invalid_local_vault_owner");
      const binding = validatedOwnershipBinding(value, normalizedAccountID(accountID));
      const database = await openDatabase(indexedDBValue);
      try {
        await new Promise((resolve, reject) => {
          const tx = database.transaction(storeName, "readwrite");
          const store = tx.objectStore(storeName);
          let failure = null;
          const request = store.get(keys.snapshot);
          request.onsuccess = () => {
            try {
              const current = validatedSnapshot(request.result);
              if (!sameWrappedKey(current.envelope.wrappedKey, binding.wrappedKey)) {
                throw new Error("invalid_local_vault_owner");
              }
              store.put(binding, keys.ownership);
            } catch (error) { failure = error; tx.abort(); }
          };
          tx.onabort = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.onerror = () => reject(failure ?? new Error("local_vault_storage_failed"));
          tx.oncomplete = () => resolve();
        });
      } finally { database.close(); }
    },
    forAccount(accountValue) {
      return createIndexedDBVaultRepository(indexedDBValue, { accountID: normalizedAccountID(accountValue) });
    },
  };
}

export async function prepareAccountScopedVault({
  accountID,
  accountRepository,
  legacyRepository,
  passphrase = null,
  cryptoValue = globalThis.crypto,
  now = () => new Date().toISOString(),
  randomUUID = () => cryptoValue.randomUUID(),
  onController = async () => {},
  requireCurrent = () => {},
} = {}) {
  const normalizedID = normalizedAccountID(accountID);
  if (!accountRepository || !legacyRepository) throw new Error("invalid_local_vault_repository");
  requireCurrent();
  const unlockState = typeof accountRepository.loadSessionUnlockState === "function"
    ? await accountRepository.loadSessionUnlockState() : null;
  requireCurrent();
  const unlockGeneration = unlockState?.generation ?? null;
  let vault = createLocalVaultController({ repository: accountRepository, cryptoValue, now, randomUUID, initialUnlockState: unlockState });
  await onController(vault);
  requireCurrent();
  const accountStatus = await vault.status();
  requireCurrent();
  if (accountStatus !== "empty") {
    const stored = await accountRepository.load();
    requireCurrent();
    const binding = typeof accountRepository.loadOwnershipBinding === "function"
      ? await accountRepository.loadOwnershipBinding() : null;
    requireCurrent();
    let ownership = null;
    try { if (binding) ownership = validatedOwnershipBinding(binding, normalizedID); } catch {}
    if (!ownership || !stored || !sameWrappedKey(ownership.wrappedKey, stored.envelope?.wrappedKey)) {
      return { vault, legacyMigrated: false, restored: false, legacyOwnershipUnverified: true };
    }
    const restored = passphrase === null
      ? await vault.restoreRememberedSession(normalizedID)
      : false;
    requireCurrent();
    if (restored && !await vault.hasAccountOwnership(normalizedID)) {
      vault.lock();
      return { vault, legacyMigrated: false, restored: false, legacyOwnershipUnverified: true };
    }
    return { vault, legacyMigrated: false, restored };
  }

  if (typeof legacyRepository.loadLegacyState !== "function"
      || typeof accountRepository.importLegacyStateIfAbsent !== "function") {
    throw new Error("local_vault_storage_unavailable");
  }
  const legacyState = await legacyRepository.loadLegacyState();
  requireCurrent();
  const legacySnapshot = legacyState.snapshot;
  if (!legacySnapshot) return { vault, legacyMigrated: false, restored: false };
  const remembered = typeof legacyRepository.loadSessionUnlock === "function"
    ? await legacyRepository.loadSessionUnlock()
    : null;
  requireCurrent();
  const legacyVault = createLocalVaultController({
    repository: { ...legacyRepository, load: async () => clone(legacySnapshot),
      loadSessionUnlock: async () => clone(remembered), deleteSessionUnlock: async () => {},
      // The retained legacy record is read-only during migration.
      saveSessionUnlockIfCurrent: undefined },
    cryptoValue, now, randomUUID,
  });
  let restored = false;
  let claimedOwner = null;
  if (legacyState.owner) {
    const owner = validatedOwnershipBinding(legacyState.owner, normalizedAccountID(legacyState.owner.accountID));
    if (sameWrappedKey(owner.wrappedKey, legacySnapshot.envelope?.wrappedKey)) claimedOwner = owner.accountID;
  }
  if (claimedOwner && claimedOwner !== normalizedID) return { vault, legacyMigrated: false, restored: false };
  // Older clients could copy A's unlocked snapshot to B and even upload or
  // remember it under B. Neither a matching remote wrapper nor a remembered
  // key created by those clients proves ownership. Only a binding previously
  // written by the protected migration is accepted; preserve other data for
  // an explicit, independently verified recovery flow.
  if (claimedOwner !== normalizedID) {
    return { vault, legacyMigrated: false, restored: false, legacyOwnershipUnverified: true };
  }
  await onController(legacyVault);
  requireCurrent();
  const rememberedAccount = remembered?.accountID ? String(remembered.accountID).toLowerCase() : null;
  const rememberedRestored = remembered && rememberedAccount === normalizedID
    ? await legacyVault.restoreRememberedSession(normalizedID) : false;
  requireCurrent();

  if (passphrase !== null) {
    try {
      await legacyVault.unlock(passphrase);
      restored = true;
    } catch {
      throw new Error("legacy_vault_unlock_failed");
    }
    requireCurrent();
  } else {
    restored = rememberedRestored;
  }

  await accountRepository.importLegacyStateIfAbsent({ snapshot: legacySnapshot, sync: legacyState.sync, owner: normalizedID });
  requireCurrent();
  let migratedUnlockState = unlockState;
  if (passphrase === null && restored) {
    if (typeof accountRepository.saveSessionUnlock !== "function") {
      throw new Error("local_vault_storage_unavailable");
    }
    const unlock = validatedSessionUnlock(remembered, normalizedID);
    if (unlockGeneration !== null && typeof accountRepository.saveSessionUnlockIfCurrent === "function") {
      if (await accountRepository.saveSessionUnlockIfCurrent(unlock, unlockGeneration, unlockState.unlock)) {
        migratedUnlockState = { generation: unlockGeneration + 1, unlock };
      }
    } else await accountRepository.saveSessionUnlock(unlock);
    requireCurrent();
  }
  vault = createLocalVaultController({ repository: accountRepository, cryptoValue, now, randomUUID, initialUnlockState: migratedUnlockState });
  await onController(vault);
  requireCurrent();
  if (passphrase !== null) await vault.unlock(passphrase);
  else if (restored) await vault.unlockWithSessionKey(legacyVault.sessionKey());
  requireCurrent();
  return { vault, legacyMigrated: true, restored };
}

export function createAccountDeviceCoordinator({
  repository,
  legacyDeviceID,
  cryptoValue = globalThis.crypto,
  randomUUID = () => cryptoValue.randomUUID(),
} = {}) {
  if (!repository
      || typeof repository.loadAccountDevice !== "function"
      || typeof repository.saveAccountDeviceIfAbsent !== "function"
      || typeof repository.replaceAccountDevice !== "function"
      || typeof legacyDeviceID !== "function") {
    throw new Error("invalid_account_device_repository");
  }

  async function key(email) {
    return accountDeviceStorageKey(email, cryptoValue);
  }

  return {
    async deviceID(email) {
      const mapped = await repository.loadAccountDevice(await key(email));
      return mapped ? normalizedAccountDevice(mapped).deviceID : normalizedDeviceID(await legacyDeviceID());
    },
    async remember(email, deviceIDValue) {
      const accountDevice = normalizedAccountDevice(await repository.saveAccountDeviceIfAbsent(
        await key(email),
        { deviceID: normalizedDeviceID(deviceIDValue), registrationAccepted: false },
      ));
      return accountDevice.deviceID;
    },
    async accepted(email, deviceIDValue) {
      const storageKey = await key(email);
      const deviceID = normalizedDeviceID(deviceIDValue);
      const current = normalizedAccountDevice(await repository.loadAccountDevice(storageKey));
      if (current.deviceID !== deviceID || current.registrationAccepted) return current.deviceID;
      const committed = normalizedAccountDevice(await repository.replaceAccountDevice(
        storageKey,
        current,
        { deviceID, registrationAccepted: true },
      ));
      return committed.deviceID;
    },
    async replaceAfterConflict(email, conflictingDeviceID) {
      const storageKey = await key(email);
      const expectedDeviceID = normalizedDeviceID(conflictingDeviceID);
      const current = normalizedAccountDevice(await repository.loadAccountDevice(storageKey));
      if (current.deviceID !== expectedDeviceID) {
        return current.registrationAccepted ? null : current.deviceID;
      }
      if (current.registrationAccepted) return null;
      const committed = normalizedAccountDevice(await repository.replaceAccountDevice(
        storageKey,
        current,
        { deviceID: normalizedDeviceID(randomUUID()), registrationAccepted: false },
      ));
      return committed.registrationAccepted ? null : committed.deviceID;
    },
  };
}

export function createLocalVaultController({
  repository,
  cryptoValue = globalThis.crypto,
  now = () => new Date().toISOString(),
  randomUUID = () => cryptoValue.randomUUID(),
  initialUnlockState = null,
} = {}) {
  if (!repository || typeof repository.load !== "function" || typeof repository.save !== "function") {
    throw new Error("invalid_local_vault_repository");
  }

  let snapshot = null;
  let vaultKey = null;
  let document = null;
  let pendingConflicts = null;
  let lastFailedUnlockSnapshot = null;
  let lockGeneration = 0;
  let observedUnlockState = initialUnlockState ? clone(initialUnlockState) : null;
  let observedUnlockGeneration = observedUnlockState?.generation ?? -1;
  // A value merely read from shared storage may belong to another session.
  let claimedUnlockState = null;
  const pendingSessionUnlocks = new Set();

  function observeClaimedUnlock(state) {
    if (!claimedUnlockState || state.generation > claimedUnlockState.generation) claimedUnlockState = clone(state);
  }

  function observeUnlockState(state) {
    if (!state || !Number.isSafeInteger(state.generation) || state.generation < 0) {
      throw new Error("local_vault_storage_failed");
    }
    if (state.generation > observedUnlockGeneration) {
      observedUnlockGeneration = state.generation;
      observedUnlockState = clone(state);
    } else if (state.generation === observedUnlockGeneration && observedUnlockState
        && !sameSessionUnlock(observedUnlockState.unlock, state.unlock)) {
      // An older client may replace the record without advancing generation.
      // Do not let an ambiguous observation authorize a later deletion.
      observedUnlockState = null;
    }
  }

  function requireGeneration(expected) {
    if (lockGeneration !== expected) throw new Error("local_vault_locked");
  }

  async function stableDeviceID() {
    if (snapshot?.deviceID) return snapshot.deviceID;
    const stored = typeof repository.loadDeviceID === "function" ? await repository.loadDeviceID() : null;
    if (stored) return normalizedDeviceID(stored);
    const generated = normalizedDeviceID(randomUUID());
    if (typeof repository.saveDeviceID === "function") await repository.saveDeviceID(generated);
    return generated;
  }

  async function syncMetadata() {
    if (typeof repository.loadSync !== "function") return null;
    const value = snapshot && typeof repository.loadSyncForSnapshot === "function"
      ? await repository.loadSyncForSnapshot(snapshot) : await repository.loadSync();
    return value ? validatedSyncMetadata(value) : null;
  }

  async function saveSyncMetadata(value) {
    if (typeof repository.saveSync !== "function") throw new Error("local_vault_sync_storage_unavailable");
    const metadata = validatedSyncMetadata(value);
    if (snapshot && typeof repository.saveSyncIfCurrent === "function") await repository.saveSyncIfCurrent(snapshot, metadata);
    else await repository.saveSync(metadata);
  }

  function requireUnlocked() {
    if (!snapshot || !vaultKey || !document) throw new Error("local_vault_locked");
  }

  async function persist(nextDocument, { returnSnapshot = false } = {}) {
    requireUnlocked();
    const generation = lockGeneration;
    const expected = snapshot;
    const normalized = validateVaultDocument(nextDocument);
    const envelope = await encryptVaultPayload({
      vaultKey,
      payload: normalized,
      baseRevision: expected.revision,
      wrappedKey: expected.envelope.wrappedKey,
      cryptoValue,
    });
    const nextSnapshot = validatedSnapshot({
      revision: expected.revision + 1,
      deviceID: expected.deviceID,
      envelope,
    });
    requireGeneration(generation);
    if (typeof repository.saveIfCurrent === "function") await repository.saveIfCurrent(expected, nextSnapshot);
    else await repository.save(nextSnapshot);
    requireGeneration(generation);
    snapshot = nextSnapshot;
    document = normalized;
    return returnSnapshot ? clone(nextSnapshot) : clone(document);
  }

  async function unlockUsingSessionKey(nextVaultKey) {
    if (snapshot || vaultKey || document) throw new Error("local_vault_not_locked");
    const generation = lockGeneration;
    const algorithm = nextVaultKey?.algorithm;
    const usages = Array.from(nextVaultKey?.usages ?? []);
    if (nextVaultKey?.type !== "secret"
        || algorithm?.name !== "AES-GCM"
        || algorithm?.length !== 256
        || !usages.includes("encrypt")
        || !usages.includes("decrypt")) {
      throw new Error("invalid_vault_session_key");
    }
    const stored = await repository.load();
    if (!stored) throw new Error("local_vault_missing");
    const nextSnapshot = validatedSnapshot(stored);
    const nextDocument = validateVaultDocument(
      await decryptVaultEnvelope(nextVaultKey, nextSnapshot.envelope, cryptoValue),
    );
    requireGeneration(generation);
    snapshot = nextSnapshot;
    vaultKey = nextVaultKey;
    document = nextDocument;
    pendingConflicts = null;
    return clone(document);
  }

  return {
    async status() {
      if (snapshot && vaultKey && document) return "unlocked";
      return (await repository.load()) ? "locked" : "empty";
    },

    async create(passphrase) {
      const generation = lockGeneration;
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
      const nextSnapshot = validatedSnapshot({ revision: 1, deviceID: await stableDeviceID(), envelope });
      requireGeneration(generation);
      if (typeof repository.saveInitial === "function") await repository.saveInitial(nextSnapshot);
      else await repository.save(nextSnapshot);
      requireGeneration(generation);
      snapshot = nextSnapshot;
      vaultKey = nextVaultKey;
      document = nextDocument;
      pendingConflicts = null;
      return clone(document);
    },

    async unlock(passphrase) {
      const generation = lockGeneration;
      snapshot = null;
      vaultKey = null;
      document = null;
      const stored = await repository.load();
      requireGeneration(generation);
      if (!stored) throw new Error("local_vault_missing");
      const nextSnapshot = validatedSnapshot(stored);
      lastFailedUnlockSnapshot = nextSnapshot;
      const nextVaultKey = await unwrapVaultKey(nextSnapshot.envelope.wrappedKey, passphrase, cryptoValue);
      const nextDocument = validateVaultDocument(
        await decryptVaultEnvelope(nextVaultKey, nextSnapshot.envelope, cryptoValue),
      );
      requireGeneration(generation);
      snapshot = nextSnapshot;
      vaultKey = nextVaultKey;
      document = nextDocument;
      pendingConflicts = null;
      lastFailedUnlockSnapshot = null;
      return clone(document);
    },

    sessionKey() {
      requireUnlocked();
      return vaultKey;
    },

    async bindAccountOwnership(accountValue) {
      requireUnlocked();
      if (typeof repository.saveOwnershipBinding !== "function") throw new Error("local_vault_storage_unavailable");
      await repository.saveOwnershipBinding({
        version: 1, accountID: normalizedAccountID(accountValue), wrappedKey: snapshot.envelope.wrappedKey,
      });
    },

    async hasAccountOwnership(accountValue) {
      requireUnlocked();
      if (typeof repository.loadOwnershipBinding !== "function") return false;
      const accountID = normalizedAccountID(accountValue);
      const value = await repository.loadOwnershipBinding();
      if (!value) return false;
      const binding = validatedOwnershipBinding(value, accountID);
      return sameWrappedKey(binding.wrappedKey, snapshot.envelope.wrappedKey);
    },

    unlockWithSessionKey: unlockUsingSessionKey,

    async rememberSession(accountValue) {
      requireUnlocked();
      if (typeof repository.loadSessionDeviceKey !== "function"
          || typeof repository.saveSessionDeviceKey !== "function"
          || typeof repository.saveSessionUnlock !== "function") return false;
      const capturedGeneration = lockGeneration, rememberedVaultKey = vaultKey;
      if (rememberedVaultKey.extractable !== true) return false;
      const accountID = normalizedAccountID(accountValue);
      const unlockState = typeof repository.loadSessionUnlockState === "function"
        ? await repository.loadSessionUnlockState() : null;
      if (unlockState && !observedUnlockState && observedUnlockGeneration < 0 && unlockState.unlock === null) {
        observeUnlockState(unlockState);
      }
      const unlockGeneration = unlockState?.generation ?? null;
      if (lockGeneration !== capturedGeneration) return false;
      let sessionKey = await repository.loadSessionDeviceKey();
      if (sessionKey) sessionKey = validatedSessionDeviceKey(sessionKey);
      else {
        sessionKey = await cryptoValue.subtle.generateKey(
          { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"],
        );
        if (typeof repository.saveSessionDeviceKeyIfAbsent === "function") {
          sessionKey = validatedSessionDeviceKey(await repository.saveSessionDeviceKeyIfAbsent(sessionKey));
        } else await repository.saveSessionDeviceKey(sessionKey);
      }
      const nonce = cryptoValue.getRandomValues(new Uint8Array(12));
      const rawVaultKey = new Uint8Array(await cryptoValue.subtle.exportKey("raw", rememberedVaultKey));
      try {
        const ciphertext = new Uint8Array(await cryptoValue.subtle.encrypt(
          { name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(`${sessionUnlockContext}${accountID}`) },
          sessionKey,
          rawVaultKey,
        ));
        const unlock = {
          version: sessionUnlockVersion, accountID, nonce, ciphertext,
        };
        if (lockGeneration !== capturedGeneration) return false;
        const pending = { unlock, base: unlockState ? clone(unlockState) : null };
        pendingSessionUnlocks.add(pending);
        try {
          if (unlockGeneration !== null && typeof repository.saveSessionUnlockIfCurrent === "function") {
            if (!await repository.saveSessionUnlockIfCurrent(unlock, unlockGeneration, unlockState.unlock)) return false;
            observeUnlockState({ generation: unlockGeneration + 1, unlock });
            observeClaimedUnlock({ generation: unlockGeneration + 1, unlock });
          } else await repository.saveSessionUnlock(unlock);
          if (lockGeneration !== capturedGeneration) return false;
          return true;
        } finally { pendingSessionUnlocks.delete(pending); }
      } finally {
        rawVaultKey.fill(0);
      }
    },

    async restoreRememberedSession(accountValue) {
      const generation = lockGeneration;
      if (typeof repository.loadSessionDeviceKey !== "function"
          || typeof repository.loadSessionUnlock !== "function") return false;
      if (snapshot && vaultKey && document) return false;
      if (!await repository.load()) return false;
      const accountID = normalizedAccountID(accountValue);
      try {
        const unlockState = typeof repository.loadSessionUnlockState === "function"
          ? await repository.loadSessionUnlockState() : null;
        if (unlockState && observedUnlockState
            && (unlockState.generation !== observedUnlockState.generation
              || !sameSessionUnlock(unlockState.unlock, observedUnlockState.unlock))) return false;
        if (unlockState && !observedUnlockState && observedUnlockGeneration >= 0) return false;
        const sessionKey = validatedSessionDeviceKey(await repository.loadSessionDeviceKey());
        const remembered = validatedSessionUnlock(await repository.loadSessionUnlock(), accountID);
        if (unlockState && !sameSessionUnlock(unlockState.unlock, remembered)) return false;
        const rawVaultKey = new Uint8Array(await cryptoValue.subtle.decrypt(
          { name: "AES-GCM", iv: remembered.nonce, additionalData: new TextEncoder().encode(`${sessionUnlockContext}${accountID}`) },
          sessionKey,
          remembered.ciphertext,
        ));
        try {
          const nextVaultKey = await cryptoValue.subtle.importKey(
            "raw", rawVaultKey, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"],
          );
          requireGeneration(generation);
          if (unlockState && typeof repository.saveSessionUnlockIfCurrent === "function") {
            // Claim a distinct remembered record for this controller. A late
            // logout from an older tab must not delete a session restored now.
            const nonce = cryptoValue.getRandomValues(new Uint8Array(12));
            const ciphertext = new Uint8Array(await cryptoValue.subtle.encrypt(
              { name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(`${sessionUnlockContext}${accountID}`) },
              sessionKey,
              rawVaultKey,
            ));
            requireGeneration(generation);
            const unlock = { version: sessionUnlockVersion, accountID, nonce, ciphertext };
            const pending = { unlock, base: clone(unlockState) };
            pendingSessionUnlocks.add(pending);
            try {
              if (!await repository.saveSessionUnlockIfCurrent(unlock, unlockState.generation, unlockState.unlock)) return false;
              observeUnlockState({ generation: unlockState.generation + 1, unlock });
              observeClaimedUnlock({ generation: unlockState.generation + 1, unlock });
            } finally { pendingSessionUnlocks.delete(pending); }
            requireGeneration(generation);
          } else if (unlockState && !observedUnlockState) observeUnlockState(unlockState);
          await unlockUsingSessionKey(nextVaultKey);
          requireGeneration(generation);
          return true;
        } finally {
          rawVaultKey.fill(0);
        }
      } catch {
        // A concurrent tab may have replaced the record since it was read.
        // Preserve it; an explicit successful unlock can safely replace it.
        return false;
      }
    },

    async forgetTrackedRememberedSession() {
      if (typeof repository.deleteSessionUnlockIfCurrent !== "function") return false;
      const expected = claimedUnlockState ? clone(claimedUnlockState) : null;
      const pending = [...pendingSessionUnlocks].map(clone);
      if (!expected && !pending.length) {
        // Preserve any unclaimed record; its owner cannot be established here.
        if (typeof repository.loadSessionUnlock !== "function") return false;
        return (await repository.loadSessionUnlock()) == null;
      }
      return repository.deleteSessionUnlockIfCurrent(expected, pending, { strictGeneration: true });
    },

    async forgetRememberedSession() {
      if (typeof repository.deleteSessionUnlockIfCurrent === "function") {
        const expected = observedUnlockState ? clone(observedUnlockState) : null;
        const pending = [...pendingSessionUnlocks].map(clone);
        if (!expected && !pending.length) return false;
        return repository.deleteSessionUnlockIfCurrent(expected, pending);
      }
      if (typeof repository.deleteSessionUnlock === "function") await repository.deleteSessionUnlock();
    },

    lock() {
      lockGeneration += 1;
      snapshot = null;
      vaultKey = null;
      document = null;
      pendingConflicts = null;
      lastFailedUnlockSnapshot = null;
    },

    async rewrap(passphrase) {
      requireUnlocked();
      const generation = lockGeneration;
      const expected = snapshot;
      const wrappedKey = await wrapVaultKey(vaultKey, passphrase, cryptoValue);
      const envelope = await encryptVaultPayload({
        vaultKey,
        payload: document,
        baseRevision: expected.revision,
        wrappedKey,
        cryptoValue,
      });
      const nextSnapshot = validatedSnapshot({
        revision: expected.revision + 1,
        deviceID: expected.deviceID,
        envelope,
      });
      requireGeneration(generation);
      if (typeof repository.saveIfCurrent === "function") await repository.saveIfCurrent(expected, nextSnapshot);
      else await repository.save(nextSnapshot);
      requireGeneration(generation);
      snapshot = nextSnapshot;
      return clone(document);
    },

    document() {
      requireUnlocked();
      return clone(document);
    },

    async deviceID() {
      return stableDeviceID();
    },

    async syncState() {
      requireUnlocked();
      const metadata = await syncMetadata();
      return {
        localRevision: snapshot.revision,
        serverRevision: metadata?.serverRevision ?? 0,
        dirty: !metadata || metadata.localRevision !== snapshot.revision,
      };
    },

    async prepareUpload(baseRevision) {
      requireUnlocked();
      const generation = lockGeneration, current = snapshot;
      if (!Number.isSafeInteger(baseRevision) || baseRevision < 0) throw new Error("invalid_base_revision");
      const envelope = await encryptVaultPayload({
        vaultKey,
        payload: document,
        baseRevision,
        wrappedKey: current.envelope.wrappedKey,
        cryptoValue,
      });
      requireGeneration(generation);
      return {
        localRevision: current.revision,
        envelope,
      };
    },

    async markSynced({ serverRevision, localRevision }) {
      requireUnlocked();
      if (!Number.isSafeInteger(localRevision) || localRevision < 1 || localRevision > snapshot.revision) {
        throw new Error("invalid_local_vault_sync");
      }
      const expected = snapshot;
      const metadata = { serverRevision, localRevision };
      if (typeof repository.saveSyncIfCurrent === "function") await repository.saveSyncIfCurrent(expected, metadata);
      else await saveSyncMetadata(metadata);
      return {
        localRevision: snapshot.revision,
        serverRevision,
        dirty: localRevision !== snapshot.revision,
      };
    },

    verifyRemoteWrapper({ revision, envelope }) {
      requireUnlocked();
      const remoteSnapshot = validatedSnapshot({ revision, deviceID: snapshot.deviceID, envelope });
      if (!sameWrappedKey(remoteSnapshot.envelope.wrappedKey, snapshot.envelope.wrappedKey)) {
        throw new Error("remote_wrapped_key_changed");
      }
    },

    async mergeRemote({ revision, envelope }) {
      requireUnlocked();
      const generation = lockGeneration;
      const remoteSnapshot = validatedSnapshot({ revision, deviceID: snapshot.deviceID, envelope });
      const remoteDocument = validateVaultDocument(
        await decryptVaultEnvelope(vaultKey, remoteSnapshot.envelope, cryptoValue),
      );
      requireGeneration(generation);
      if (!sameWrappedKey(remoteSnapshot.envelope.wrappedKey, snapshot.envelope.wrappedKey)) {
        throw new Error("remote_wrapped_key_changed");
      }
      const merged = mergeVaultDocuments(document, remoteDocument);
      const automaticallyResolved = merged.conflicts.length;
      if (automaticallyResolved > 0) {
        merged.document = resolveVaultConflictsByNewest(merged.document, merged.conflicts, {
          deviceID: snapshot.deviceID,
          resolvedAt: now(),
        });
      }
      pendingConflicts = null;
      const matchesRemote = JSON.stringify(merged.document) === JSON.stringify(remoteDocument);
      const localChanged = JSON.stringify(merged.document) !== JSON.stringify(document);
      const matchedSnapshot = localChanged ? await persist(merged.document, { returnSnapshot: true }) : clone(snapshot);
      return {
        conflicts: [],
        automaticallyResolved,
        matchesRemote,
        localRevision: matchedSnapshot.revision,
        localChanged,
      };
    },

    pendingConflicts() {
      requireUnlocked();
      return pendingConflicts
        ? { revision: pendingConflicts.revision, conflicts: clone(pendingConflicts.conflicts) }
        : null;
    },

    async resolveConflicts({ revision, resolutions }) {
      requireUnlocked();
      if (!pendingConflicts || revision !== pendingConflicts.revision || !Array.isArray(resolutions)) {
        throw new Error("invalid_pending_conflicts");
      }
      if (resolutions.length !== pendingConflicts.conflicts.length) {
        throw new Error("incomplete_conflict_resolution");
      }
      const choices = new Map();
      for (const resolution of resolutions) {
        exactKeys(resolution, ["choice", "id"], "invalid_conflict_resolution");
        const id = String(resolution.id ?? "").toLowerCase();
        if (!exactUUID.test(id) || !["local", "remote"].includes(resolution.choice) || choices.has(id)) {
          throw new Error("invalid_conflict_resolution");
        }
        choices.set(id, resolution.choice);
      }
      const expectedIDs = new Set(pendingConflicts.conflicts.map((conflict) => conflict.id));
      if (choices.size !== expectedIDs.size || [...choices.keys()].some((id) => !expectedIDs.has(id))) {
        throw new Error("invalid_conflict_resolution");
      }

      let resolvedDocument = pendingConflicts.document;
      const deviceID = snapshot.deviceID;
      const resolvedAt = now();
      for (const conflict of pendingConflicts.conflicts) {
        resolvedDocument = resolveVaultConflict(resolvedDocument, conflict, {
          choice: choices.get(conflict.id),
          deviceID,
          resolvedAt,
        });
      }
      const previousLocalRevision = snapshot.revision;
      await persist(resolvedDocument);
      pendingConflicts = null;
      await saveSyncMetadata({ serverRevision: revision, localRevision: previousLocalRevision });
      return {
        revision,
        localRevision: snapshot.revision,
        conflictsResolved: resolutions.length,
      };
    },

    async importRemote({ revision, envelope }, passphrase) {
      const generation = lockGeneration;
      if (await repository.load()) throw new Error("local_vault_exists");
      const deviceID = await stableDeviceID();
      const remoteSnapshot = validatedSnapshot({ revision, deviceID, envelope });
      const nextVaultKey = await unwrapVaultKey(remoteSnapshot.envelope.wrappedKey, passphrase, cryptoValue);
      const nextDocument = validateVaultDocument(
        await decryptVaultEnvelope(nextVaultKey, remoteSnapshot.envelope, cryptoValue),
      );
      requireGeneration(generation);
      if (typeof repository.saveInitial === "function") {
        await repository.saveInitial(remoteSnapshot, { serverRevision: revision, localRevision: revision });
      } else {
        await repository.save(remoteSnapshot);
        await saveSyncMetadata({ serverRevision: revision, localRevision: revision });
      }
      requireGeneration(generation);
      snapshot = remoteSnapshot;
      vaultKey = nextVaultKey;
      document = nextDocument;
      pendingConflicts = null;
      return clone(document);
    },

    async replaceLockedWithRemote({ revision, envelope }, passphrase) {
      const generation = lockGeneration;
      if (snapshot || vaultKey || document) throw new Error("local_vault_not_locked");
      const stored = lastFailedUnlockSnapshot ?? await repository.load();
      if (!stored) throw new Error("local_vault_not_locked");
      const previousSnapshot = validatedSnapshot(stored);
      const deviceID = await stableDeviceID();
      const remoteSnapshot = validatedSnapshot({ revision, deviceID, envelope });
      const nextVaultKey = await unwrapVaultKey(remoteSnapshot.envelope.wrappedKey, passphrase, cryptoValue);
      const nextDocument = validateVaultDocument(
        await decryptVaultEnvelope(nextVaultKey, remoteSnapshot.envelope, cryptoValue),
      );
      requireGeneration(generation);
      if (typeof repository.saveIfCurrent === "function") {
        await repository.saveIfCurrent(previousSnapshot, remoteSnapshot,
          { backup: true, sync: { serverRevision: revision, localRevision: revision } });
      } else {
        if (typeof repository.savePrevious === "function") await repository.savePrevious(previousSnapshot);
        await repository.save(remoteSnapshot);
        await saveSyncMetadata({ serverRevision: revision, localRevision: revision });
      }
      requireGeneration(generation);
      snapshot = remoteSnapshot;
      vaultKey = nextVaultKey;
      document = nextDocument;
      pendingConflicts = null;
      lastFailedUnlockSnapshot = null;
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
      pendingConflicts = null;
      return id;
    },

    async delete(id) {
      requireUnlocked();
      const result = await persist(deleteVaultRecord(document, {
        id,
        deviceID: snapshot.deviceID,
        deletedAt: now(),
      }));
      pendingConflicts = null;
      return result;
    },
  };
}
