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

function sameWrappedKey(left, right) {
  const keys = ["algorithm", "iterations", "salt", "value"];
  return keys.every((key) => left?.[key] === right?.[key]);
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
    ? { snapshot: snapshotKey, sync: syncKey, backup: backupSnapshotKey, sessionUnlock: sessionUnlockKey }
    : accountVaultStorageKeys(accountID);
  return {
    async load() {
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(keys.snapshot));
      return value === null || value === undefined ? null : clone(value);
    },
    async save(value) {
      const snapshot = validatedSnapshot(value);
      await transaction(indexedDBValue, "readwrite", (store) => store.put(clone(snapshot), keys.snapshot));
    },
    async savePrevious(value) {
      const snapshot = validatedSnapshot(value);
      await transaction(indexedDBValue, "readwrite", (store) => store.put(clone(snapshot), keys.backup));
    },
    async loadSync() {
      const value = await transaction(indexedDBValue, "readonly", (store) => store.get(keys.sync));
      return value === null || value === undefined ? null : validatedSyncMetadata(value);
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
    async loadSessionUnlock() {
      return transaction(indexedDBValue, "readonly", (store) => store.get(keys.sessionUnlock));
    },
    async saveSessionUnlock(value) {
      await transaction(indexedDBValue, "readwrite", (store) => store.put(value, keys.sessionUnlock));
    },
    async deleteSessionUnlock() {
      await transaction(indexedDBValue, "readwrite", (store) => store.delete(keys.sessionUnlock));
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
} = {}) {
  const normalizedID = normalizedAccountID(accountID);
  if (!accountRepository || !legacyRepository) throw new Error("invalid_local_vault_repository");
  let vault = createLocalVaultController({ repository: accountRepository, cryptoValue, now, randomUUID });
  const accountStatus = await vault.status();
  if (accountStatus !== "empty") {
    const restored = passphrase === null
      ? await vault.restoreRememberedSession(normalizedID)
      : false;
    return { vault, legacyMigrated: false, restored };
  }

  const legacySnapshot = await legacyRepository.load();
  if (!legacySnapshot) return { vault, legacyMigrated: false, restored: false };
  const legacyVault = createLocalVaultController({ repository: legacyRepository, cryptoValue, now, randomUUID });
  let restored = false;
  if (passphrase !== null) {
    try {
      await legacyVault.unlock(passphrase);
      restored = true;
    } catch {
      return { vault, legacyMigrated: false, restored: false };
    }
  } else {
    const remembered = typeof legacyRepository.loadSessionUnlock === "function"
      ? await legacyRepository.loadSessionUnlock()
      : null;
    if (!remembered || String(remembered.accountID ?? "").toLowerCase() !== normalizedID) {
      return { vault, legacyMigrated: false, restored: false };
    }
    restored = await legacyVault.restoreRememberedSession(normalizedID);
    if (!restored) return { vault, legacyMigrated: false, restored: false };
  }

  await accountRepository.save(legacySnapshot);
  if (typeof legacyRepository.loadSync === "function" && typeof accountRepository.saveSync === "function") {
    const sync = await legacyRepository.loadSync();
    if (sync) await accountRepository.saveSync(sync);
  }
  vault = createLocalVaultController({ repository: accountRepository, cryptoValue, now, randomUUID });
  if (passphrase !== null) await vault.unlock(passphrase);
  else {
    await vault.unlockWithSessionKey(legacyVault.sessionKey());
    await vault.rememberSession(normalizedID);
  }
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
} = {}) {
  if (!repository || typeof repository.load !== "function" || typeof repository.save !== "function") {
    throw new Error("invalid_local_vault_repository");
  }

  let snapshot = null;
  let vaultKey = null;
  let document = null;
  let pendingConflicts = null;

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
    const value = await repository.loadSync();
    return value ? validatedSyncMetadata(value) : null;
  }

  async function saveSyncMetadata(value) {
    if (typeof repository.saveSync !== "function") throw new Error("local_vault_sync_storage_unavailable");
    await repository.saveSync(validatedSyncMetadata(value));
  }

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

  async function unlockUsingSessionKey(nextVaultKey) {
    if (snapshot || vaultKey || document) throw new Error("local_vault_not_locked");
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
      await repository.save(nextSnapshot);
      snapshot = nextSnapshot;
      vaultKey = nextVaultKey;
      document = nextDocument;
      pendingConflicts = null;
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
      pendingConflicts = null;
      return clone(document);
    },

    sessionKey() {
      requireUnlocked();
      return vaultKey;
    },

    unlockWithSessionKey: unlockUsingSessionKey,

    async rememberSession(accountValue) {
      requireUnlocked();
      if (typeof repository.loadSessionDeviceKey !== "function"
          || typeof repository.saveSessionDeviceKey !== "function"
          || typeof repository.saveSessionUnlock !== "function") return false;
      if (vaultKey.extractable !== true) return false;
      const accountID = normalizedAccountID(accountValue);
      let sessionKey = await repository.loadSessionDeviceKey();
      if (sessionKey) sessionKey = validatedSessionDeviceKey(sessionKey);
      else {
        sessionKey = await cryptoValue.subtle.generateKey(
          { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"],
        );
        await repository.saveSessionDeviceKey(sessionKey);
      }
      const nonce = cryptoValue.getRandomValues(new Uint8Array(12));
      const rawVaultKey = new Uint8Array(await cryptoValue.subtle.exportKey("raw", vaultKey));
      try {
        const ciphertext = new Uint8Array(await cryptoValue.subtle.encrypt(
          { name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(`${sessionUnlockContext}${accountID}`) },
          sessionKey,
          rawVaultKey,
        ));
        await repository.saveSessionUnlock({
          version: sessionUnlockVersion, accountID, nonce, ciphertext,
        });
        return true;
      } finally {
        rawVaultKey.fill(0);
      }
    },

    async restoreRememberedSession(accountValue) {
      if (typeof repository.loadSessionDeviceKey !== "function"
          || typeof repository.loadSessionUnlock !== "function") return false;
      if (snapshot && vaultKey && document) return false;
      if (!await repository.load()) return false;
      const accountID = normalizedAccountID(accountValue);
      try {
        const sessionKey = validatedSessionDeviceKey(await repository.loadSessionDeviceKey());
        const remembered = validatedSessionUnlock(await repository.loadSessionUnlock(), accountID);
        const rawVaultKey = new Uint8Array(await cryptoValue.subtle.decrypt(
          { name: "AES-GCM", iv: remembered.nonce, additionalData: new TextEncoder().encode(`${sessionUnlockContext}${accountID}`) },
          sessionKey,
          remembered.ciphertext,
        ));
        try {
          const nextVaultKey = await cryptoValue.subtle.importKey(
            "raw", rawVaultKey, { name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"],
          );
          await unlockUsingSessionKey(nextVaultKey);
          return true;
        } finally {
          rawVaultKey.fill(0);
        }
      } catch {
        if (typeof repository.deleteSessionUnlock === "function") await repository.deleteSessionUnlock();
        return false;
      }
    },

    async forgetRememberedSession() {
      if (typeof repository.deleteSessionUnlock === "function") await repository.deleteSessionUnlock();
    },

    lock() {
      snapshot = null;
      vaultKey = null;
      document = null;
      pendingConflicts = null;
    },

    async rewrap(passphrase) {
      requireUnlocked();
      const wrappedKey = await wrapVaultKey(vaultKey, passphrase, cryptoValue);
      const envelope = await encryptVaultPayload({
        vaultKey,
        payload: document,
        baseRevision: snapshot.revision,
        wrappedKey,
        cryptoValue,
      });
      const nextSnapshot = validatedSnapshot({
        revision: snapshot.revision + 1,
        deviceID: snapshot.deviceID,
        envelope,
      });
      await repository.save(nextSnapshot);
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
      if (!Number.isSafeInteger(baseRevision) || baseRevision < 0) throw new Error("invalid_base_revision");
      return {
        localRevision: snapshot.revision,
        envelope: await encryptVaultPayload({
          vaultKey,
          payload: document,
          baseRevision,
          wrappedKey: snapshot.envelope.wrappedKey,
          cryptoValue,
        }),
      };
    },

    async markSynced({ serverRevision, localRevision }) {
      requireUnlocked();
      if (!Number.isSafeInteger(localRevision) || localRevision < 1 || localRevision > snapshot.revision) {
        throw new Error("invalid_local_vault_sync");
      }
      await saveSyncMetadata({ serverRevision, localRevision });
      return {
        localRevision: snapshot.revision,
        serverRevision,
        dirty: localRevision !== snapshot.revision,
      };
    },

    async mergeRemote({ revision, envelope }) {
      requireUnlocked();
      const remoteSnapshot = validatedSnapshot({ revision, deviceID: snapshot.deviceID, envelope });
      const remoteDocument = validateVaultDocument(
        await decryptVaultEnvelope(vaultKey, remoteSnapshot.envelope, cryptoValue),
      );
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
      if (localChanged) await persist(merged.document);
      return {
        conflicts: [],
        automaticallyResolved,
        matchesRemote,
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
      if (await repository.load()) throw new Error("local_vault_exists");
      const deviceID = await stableDeviceID();
      const remoteSnapshot = validatedSnapshot({ revision, deviceID, envelope });
      const nextVaultKey = await unwrapVaultKey(remoteSnapshot.envelope.wrappedKey, passphrase, cryptoValue);
      const nextDocument = validateVaultDocument(
        await decryptVaultEnvelope(nextVaultKey, remoteSnapshot.envelope, cryptoValue),
      );
      await repository.save(remoteSnapshot);
      await saveSyncMetadata({ serverRevision: revision, localRevision: revision });
      snapshot = remoteSnapshot;
      vaultKey = nextVaultKey;
      document = nextDocument;
      pendingConflicts = null;
      return clone(document);
    },

    async replaceLockedWithRemote({ revision, envelope }, passphrase) {
      if (await this.status() !== "locked") throw new Error("local_vault_not_locked");
      const deviceID = await stableDeviceID();
      const remoteSnapshot = validatedSnapshot({ revision, deviceID, envelope });
      const nextVaultKey = await unwrapVaultKey(remoteSnapshot.envelope.wrappedKey, passphrase, cryptoValue);
      const nextDocument = validateVaultDocument(
        await decryptVaultEnvelope(nextVaultKey, remoteSnapshot.envelope, cryptoValue),
      );
      const previousSnapshot = validatedSnapshot(await repository.load());
      if (typeof repository.savePrevious === "function") await repository.savePrevious(previousSnapshot);
      await repository.save(remoteSnapshot);
      await saveSyncMetadata({ serverRevision: revision, localRevision: revision });
      snapshot = remoteSnapshot;
      vaultKey = nextVaultKey;
      document = nextDocument;
      pendingConflicts = null;
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
