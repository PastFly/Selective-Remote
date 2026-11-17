// All Personal and Team records share this database. Raising its version makes
// older clients, which explicitly request version 1, fail before they can write
// a stale whole-Vault snapshot. Existing object stores and records are retained.
const databaseName = "selective-remote-cloud";
const databaseVersion = 2;
const storeName = "local-vault";
const approvals = new WeakSet();

export function authorizeVaultStorageUpgrade(indexedDBValue = globalThis.indexedDB) {
  if (!indexedDBValue?.open) throw new Error("local_vault_storage_unavailable");
  approvals.add(indexedDBValue);
}

function usableConnection(database) {
  database.onversionchange = () => database.close();
  return database;
}

// Opening without a version cannot upgrade an existing database. If the
// database does not exist, abort its implicit version-1 creation as well.
function probeVaultStorage(indexedDBValue, unavailableCode, timeoutMs) {
  return new Promise((resolve, reject) => {
    const request = indexedDBValue.open(databaseName);
    let absent = false, cancelled = false;
    const timer = setTimeout(() => {
      cancelled = true;
      reject(new Error("vault_storage_probe_waiting"));
    }, timeoutMs);
    request.onupgradeneeded = () => {
      absent = true;
      request.transaction.abort();
    };
    request.onsuccess = () => {
      clearTimeout(timer);
      const database = request.result;
      if (cancelled) { database.close(); return; }
      if (database.version === databaseVersion) { resolve(usableConnection(database)); return; }
      const newer = database.version > databaseVersion;
      database.close();
      if (newer) reject(new Error("vault_storage_newer_version"));
      else resolve(null);
    };
    request.onerror = () => {
      clearTimeout(timer);
      if (!cancelled) absent ? resolve(null) : reject(new Error(unavailableCode));
    };
    request.onblocked = () => {
      clearTimeout(timer);
      cancelled = true;
      reject(new Error("vault_storage_probe_waiting"));
    };
  });
}

export async function openVaultStorage(indexedDBValue, unavailableCode, { probeTimeoutMs = 4000 } = {}) {
  if (!indexedDBValue?.open) return Promise.reject(new Error(unavailableCode));
  // Bind a grant to this call before any asynchronous probe, including when
  // another tab wins the upgrade or the probe itself fails.
  const approved = approvals.delete(indexedDBValue);
  const existing = await probeVaultStorage(indexedDBValue, unavailableCode, probeTimeoutMs);
  if (existing) return existing;
  // Consume permission for this one attempt. A failed or blocked attempt needs
  // another explicit acknowledgement before it can be retried.
  if (!approved) throw new Error("vault_storage_upgrade_confirmation_required");
  return new Promise((resolve, reject) => {
    const request = indexedDBValue.open(databaseName, databaseVersion);
    let cancelled = false;
    let finish;
    const settled = new Promise(resolveSettled => { finish = resolveSettled; });
    request.onupgradeneeded = () => {
      // An open request continues after its promise was rejected as blocked.
      // Abort its eventual upgrade instead of silently changing the database.
      if (cancelled) { request.transaction.abort(); return; }
      if (!request.result.objectStoreNames.contains(storeName)) request.result.createObjectStore(storeName);
    };
    request.onsuccess = () => {
      const database = request.result;
      finish();
      if (cancelled) { database.close(); return; }
      resolve(usableConnection(database));
    };
    request.onerror = () => { finish(); reject(new Error(unavailableCode)); };
    request.onblocked = () => {
      cancelled = true;
      const error = new Error("vault_storage_upgrade_blocked");
      error.settled = settled;
      reject(error);
    };
  });
}
