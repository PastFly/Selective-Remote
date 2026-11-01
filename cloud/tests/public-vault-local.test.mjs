import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { IDBFactory, IDBObjectStore } from "fake-indexeddb";
import * as vaultLocal from "../public/vault-local.js";

const {
  accountVaultStorageKeys,
  createIndexedDBVaultRepository,
  createLocalVaultController,
  prepareAccountScopedVault,
} = vaultLocal;

const passphrase = "correct horse battery staple for local recovery";
const deviceID = "11111111-1111-4111-8111-111111111111";
const recordIDs = [
  "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
];

function memoryRepository(initial = null, sharedSessionDevice = { key: null }) {
  let value = initial;
  let sync = null;
  let sessionUnlock = null;
  let ownership = null;
  return {
    async load() { return value ? structuredClone(value) : null; },
    async save(next) { value = structuredClone(next); },
    async loadLegacyState() { return { snapshot: value ? structuredClone(value) : null, sync: sync ? structuredClone(sync) : null, owner: ownership ? structuredClone(ownership) : null }; },
    async importLegacyStateIfAbsent({ snapshot, sync: nextSync, owner }) {
      if (value) throw new Error("local_vault_exists");
      value = structuredClone(snapshot);
      sync = nextSync ? structuredClone(nextSync) : null;
      ownership = { version: 1, accountID: owner, wrappedKey: structuredClone(snapshot.envelope.wrappedKey) };
    },
    async loadSync() { return sync ? structuredClone(sync) : null; },
    async saveSync(next) { sync = structuredClone(next); },
    async loadSessionDeviceKey() { return sharedSessionDevice.key ? structuredClone(sharedSessionDevice.key) : null; },
    async saveSessionDeviceKey(next) { sharedSessionDevice.key = structuredClone(next); },
    async loadSessionUnlock() { return sessionUnlock ? structuredClone(sessionUnlock) : null; },
    async saveSessionUnlock(next) { sessionUnlock = structuredClone(next); },
    async deleteSessionUnlock() { sessionUnlock = null; },
    async loadOwnershipBinding() { return ownership ? structuredClone(ownership) : null; },
    async saveOwnershipBinding(next) { ownership = structuredClone(next); },
    snapshot() { return value ? structuredClone(value) : null; },
    synchronization() { return sync ? structuredClone(sync) : null; },
    rememberedSession() { return sessionUnlock ? structuredClone(sessionUnlock) : null; },
    markLegacyOwner(accountID) { ownership = { version: 1, accountID, wrappedKey: structuredClone(value.envelope.wrappedKey) }; },
  };
}

// Seed an already verified binding in synthetic fixtures; production never
// promotes an unverified snapshot merely because a password or wrapper works.
async function markLegacyOwner(indexedDB, accountID) {
  const request = indexedDB.open("selective-remote-cloud", 1);
  const database = await new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
  });
  await new Promise((resolve, reject) => {
    const tx = database.transaction("local-vault", "readwrite"), store = tx.objectStore("local-vault");
    const snapshot = store.get("personal");
    snapshot.onsuccess = () => store.put({ version: 1, accountID,
      wrappedKey: structuredClone(snapshot.result.envelope.wrappedKey) }, "personal-legacy-owner:v1");
    tx.oncomplete = resolve; tx.onabort = () => reject(tx.error);
  });
  database.close();
}

function controller(repository, ids = [deviceID, ...recordIDs]) {
  let index = 0;
  return createLocalVaultController({
    repository,
    cryptoValue: webcrypto,
    randomUUID: () => ids[index++],
    now: () => "2026-09-03T06:30:00.000Z",
  });
}

test("new local Vault persists only an encrypted envelope", async () => {
  const repository = memoryRepository();
  const vault = controller(repository);

  assert.equal(await vault.status(), "empty");
  assert.deepEqual(await vault.create(passphrase), { schemaVersion: 1, records: [], tombstones: [] });
  assert.equal(await vault.status(), "unlocked");

  const serialized = JSON.stringify(repository.snapshot());
  assert.equal(serialized.includes(passphrase), false);
  assert.equal(serialized.includes("records"), false);
  assert.equal(serialized.includes("tombstones"), false);
  assert.equal(repository.snapshot().revision, 1);
  assert.equal(repository.snapshot().deviceID, deviceID);
});

test("Personal Vault storage keys are account-scoped by stable user ID", () => {
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const keysA = accountVaultStorageKeys(accountA);
  const keysB = accountVaultStorageKeys(accountB);

  assert.deepEqual(Object.keys(keysA).sort(), ["backup", "ownership", "sessionUnlock", "snapshot", "sync"]);
  assert.notEqual(keysA.snapshot, keysB.snapshot);
  assert.notEqual(keysA.sync, keysB.sync);
  assert.notEqual(keysA.sessionUnlock, keysB.sessionUnlock);
  assert.match(keysA.snapshot, /personal-account:v1:eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee:snapshot/u);
  assert.doesNotMatch(JSON.stringify(keysA), /@/u);
});

test("account ownership survives reload and cannot be transferred to a different snapshot", async () => {
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const root = createIndexedDBVaultRepository(new IDBFactory());
  const accountRepository = root.forAccount(accountA);
  const original = controller(accountRepository);
  await original.create(passphrase);
  await original.bindAccountOwnership(accountA);
  assert.equal(await original.hasAccountOwnership(accountA), true);
  await assert.rejects(original.bindAccountOwnership(accountB), /invalid_local_vault_owner/u);

  const reloaded = controller(accountRepository);
  await reloaded.unlock(passphrase);
  assert.equal(await reloaded.hasAccountOwnership(accountA), true);
  const otherRepository = memoryRepository();
  const other = controller(otherRepository);
  await other.create(passphrase);
  await accountRepository.save(otherRepository.snapshot());
  const changed = controller(accountRepository);
  await changed.unlock(passphrase);
  assert.equal(await changed.hasAccountOwnership(accountA), false);
});

test("an unverified scoped copy is not restored or displayed even when its password and remembered key work", async () => {
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const root = createIndexedDBVaultRepository(new IDBFactory());
  const legacy = controller(root);
  await legacy.create(passphrase);
  await legacy.upsert({ type: "host", data: { title: "A only", address: "a.invalid" } });
  const target = root.forAccount(accountB);
  await target.save(await root.load());
  const copied = controller(target);
  await copied.unlock(passphrase);
  await copied.rememberSession(accountB);
  const prepared = await prepareAccountScopedVault({
    accountID: accountB, accountRepository: target, legacyRepository: root, cryptoValue: webcrypto,
    readLegacyRemote: async () => ({ revision: 0, envelope: null }),
  });
  assert.equal(prepared.restored, false);
  assert.equal(prepared.legacyOwnershipUnverified, true);
  assert.equal(await prepared.vault.status(), "locked");
  assert.throws(() => prepared.vault.document(), /local_vault_locked/);
});

test("a stale remembered account and matching remote cannot claim the current legacy snapshot", async () => {
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const root = createIndexedDBVaultRepository(new IDBFactory());
  const original = controller(root);
  await original.create(passphrase);
  await original.rememberSession(accountA);
  const replacementRepository = memoryRepository();
  const replacement = controller(replacementRepository);
  await replacement.create(passphrase);
  const remote = await replacement.prepareUpload(0);
  await replacement.upsert({ type: "host", data: { title: "B only", address: "b.invalid" } });
  await root.save(replacementRepository.snapshot());
  const prepared = await prepareAccountScopedVault({
    accountID: accountB, accountRepository: root.forAccount(accountB), legacyRepository: root,
    passphrase, cryptoValue: webcrypto, readLegacyRemote: async () => ({ revision: 1, envelope: remote.envelope }),
  });
  assert.equal(prepared.legacyMigrated, false);
  assert.equal(prepared.legacyOwnershipUnverified, true);
  assert.equal(await root.forAccount(accountB).load(), null);
});

test("concurrent tabs cannot overwrite each other's equal-revision edits or mark the wrong snapshot clean", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const initial = controller(repository);
  await initial.create(passphrase);
  await initial.markSynced({ serverRevision: 1, localRevision: 1 });
  const first = controller(repository), second = controller(repository);
  await first.unlock(passphrase);
  await second.unlock(passphrase);
  await first.upsert({ type: "host", data: { title: "First", address: "first.invalid" } });
  await assert.rejects(second.upsert({ type: "host", data: { title: "Second", address: "second.invalid" } }), /local_vault_changed/);
  const reloaded = controller(repository);
  await reloaded.unlock(passphrase);
  assert.equal(reloaded.document().records[0].data.address, "first.invalid");
  assert.equal((await reloaded.syncState()).dirty, true);
  await assert.rejects(second.markSynced({ serverRevision: 2, localRevision: 1 }), /local_vault_changed/);
  assert.equal((await reloaded.syncState()).dirty, true);
});

test("a delayed sync confirmation cannot lower a newer confirmed server revision", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const first = controller(repository);
  await first.create(passphrase);
  const second = controller(repository);
  await second.unlock(passphrase);
  await first.markSynced({ serverRevision: 3, localRevision: 1 });
  await assert.rejects(second.markSynced({ serverRevision: 2, localRevision: 1 }), /local_vault_sync_changed/);
  assert.equal((await first.syncState()).serverRevision, 3);
});

test("a new scoped snapshot and its ownership are created together", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const fresh = controller(repository);
  await fresh.create(passphrase);
  assert.equal(await fresh.hasAccountOwnership(accountID), true);
  const next = controller(repository);
  await next.unlock(passphrase);
  assert.equal(await next.hasAccountOwnership(accountID), true);
});

test("a scoped browser vault cannot remember a different account's session", async () => {
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountA);
  const vault = controller(repository);
  await vault.create(passphrase);
  await assert.rejects(vault.rememberSession(accountB), /invalid_session_unlock/);
  assert.equal(await repository.loadSessionUnlock(), null);
});

test("two accounts remembering sessions concurrently converge on one browser device key", async () => {
  const root = createIndexedDBVaultRepository(new IDBFactory());
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  let reads = 0, release;
  const held = new Promise(resolve => { release = resolve; });
  const waitingRepository = account => {
    const repo = root.forAccount(account);
    return { ...repo, loadSessionDeviceKey: async () => {
      const existing = await repo.loadSessionDeviceKey();
      reads += 1;
      if (reads === 2) release();
      await held;
      return existing;
    } };
  };
  const a = controller(waitingRepository(accountA)), b = controller(waitingRepository(accountB));
  await a.create(passphrase);
  await b.create(passphrase);
  assert.deepEqual(await Promise.all([a.rememberSession(accountA), b.rememberSession(accountB)]), [true, true]);
  const reopenedA = controller(root.forAccount(accountA)), reopenedB = controller(root.forAccount(accountB));
  assert.equal(await reopenedA.restoreRememberedSession(accountA), true);
  assert.equal(await reopenedB.restoreRememberedSession(accountB), true);
});

test("failed remembered-key restore cannot delete a concurrently replaced unlock record", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const first = controller(repository);
  await first.create(passphrase);
  await first.rememberSession(accountID);
  const valid = await repository.loadSessionUnlock();
  const corrupt = structuredClone(valid);
  corrupt.ciphertext[0] ^= 1;
  const racing = { ...repository, loadSessionUnlock: async () => {
    await repository.saveSessionUnlock(valid);
    return corrupt;
  } };
  assert.equal(await controller(racing).restoreRememberedSession(accountID), false);
  assert.deepEqual(await repository.loadSessionUnlock(), valid);
});

test("password unlock can replace an unchanged malformed remembered record", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const indexedDB = new IDBFactory();
  const repository = createIndexedDBVaultRepository(indexedDB).forAccount(accountID);
  const seed = controller(repository);
  await seed.create(passphrase);
  assert.equal(await seed.rememberSession(accountID), true);
  const malformed = { ...await repository.loadSessionUnlock(), ciphertext: new Uint8Array([1]) };
  const request = indexedDB.open("selective-remote-cloud", 1);
  const db = await new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
  });
  await new Promise((resolve, reject) => {
    const tx = db.transaction("local-vault", "readwrite");
    tx.objectStore("local-vault").put(malformed, accountVaultStorageKeys(accountID).sessionUnlock);
    tx.oncomplete = resolve; tx.onabort = () => reject(tx.error);
  });
  db.close();
  const vault = controller(repository);
  await vault.unlock(passphrase);
  assert.equal(await vault.rememberSession(accountID), true);
  assert.equal(await controller(repository).restoreRememberedSession(accountID), true);
});

test("a changed malformed remembered record is not overwritten by a stale save", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const indexedDB = new IDBFactory();
  const repository = createIndexedDBVaultRepository(indexedDB).forAccount(accountID);
  const seed = controller(repository);
  await seed.create(passphrase);
  await seed.rememberSession(accountID);
  const valid = await repository.loadSessionUnlock();
  const request = indexedDB.open("selective-remote-cloud", 1);
  const db = await new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
  });
  const putRaw = value => new Promise((resolve, reject) => {
    const tx = db.transaction("local-vault", "readwrite");
    tx.objectStore("local-vault").put(value, accountVaultStorageKeys(accountID).sessionUnlock);
    tx.oncomplete = resolve; tx.onabort = () => reject(tx.error);
  });
  await putRaw({ ...valid, ciphertext: new Uint8Array([1]) });
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    entered(); await held; return repository.saveSessionUnlockIfCurrent(...args);
  } };
  const vault = controller(delayed);
  await vault.unlock(passphrase);
  const pending = vault.rememberSession(accountID);
  await started;
  const replacement = { ...valid, ciphertext: new Uint8Array([2]) };
  await putRaw(replacement);
  release();
  assert.equal(await pending, false);
  assert.deepEqual(await repository.loadSessionUnlock(), replacement);
  db.close();
});

for (const scenario of ["logout before save", "logout after save", "newer session before logout"]) {
  test(`logout handles a pending replacement of a malformed record: ${scenario}`, async () => {
    const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    const indexedDB = new IDBFactory();
    const repository = createIndexedDBVaultRepository(indexedDB).forAccount(accountID);
    const seed = controller(repository);
    await seed.create(passphrase);
    await seed.rememberSession(accountID);
    const malformed = { ...await repository.loadSessionUnlock(), ciphertext: new Uint8Array([1]) };
    const request = indexedDB.open("selective-remote-cloud", 1);
    const db = await new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    await new Promise((resolve, reject) => {
      const tx = db.transaction("local-vault", "readwrite");
      tx.objectStore("local-vault").put(malformed, accountVaultStorageKeys(accountID).sessionUnlock);
      tx.oncomplete = resolve; tx.onabort = () => reject(tx.error);
    });
    db.close();
    let entered, release;
    const started = new Promise(resolve => { entered = resolve; });
    const held = new Promise(resolve => { release = resolve; });
    const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
      if (scenario === "logout after save") {
        const saved = await repository.saveSessionUnlockIfCurrent(...args);
        entered(); await held; return saved;
      }
      entered(); await held; return repository.saveSessionUnlockIfCurrent(...args);
    } };
    const older = controller(delayed);
    await older.unlock(passphrase);
    const pending = older.rememberSession(accountID);
    await started;
    if (scenario === "newer session before logout") {
      const newer = controller(repository);
      await newer.unlock(passphrase);
      assert.equal(await newer.rememberSession(accountID), true);
    }
    older.lock();
    await older.forgetRememberedSession();
    release();
    assert.equal(await pending, false);
    assert.equal(await controller(repository).restoreRememberedSession(accountID),
      scenario === "newer session before logout");
  });
}

test("logout cannot be undone by a delayed remembered-key write", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const racing = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    entered(); await held;
    return repository.saveSessionUnlockIfCurrent(...args);
  } };
  const vault = controller(racing);
  await vault.create(passphrase);
  const pending = vault.rememberSession(accountID);
  await Promise.race([started, pending.then(() => { throw new Error("remembered_session_generation_missing"); })]);
  vault.lock();
  await vault.forgetRememberedSession();
  release();
  assert.equal(await pending, false);
  assert.equal(await repository.loadSessionUnlock(), null);
  assert.equal(await controller(repository).restoreRememberedSession(accountID), false);
});

test("a delayed old logout cannot delete a newer remembered session", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository,
    deleteSessionUnlock: async (...args) => { entered(); await held; return repository.deleteSessionUnlock(...args); },
    deleteSessionUnlockIfCurrent: async (...args) => { entered(); await held; return repository.deleteSessionUnlockIfCurrent(...args); },
  };
  const old = controller(delayed);
  await old.create(passphrase);
  await old.rememberSession(accountID);
  old.lock();
  const forgetting = old.forgetRememberedSession();
  await Promise.race([started, forgetting.then(() => { throw new Error("forget_hook_not_called"); })]);
  const fresh = controller(repository);
  await fresh.unlock(passphrase);
  assert.equal(await fresh.rememberSession(accountID), true);
  release();
  await forgetting;
  assert.ok(await repository.loadSessionUnlock());
  assert.equal(await controller(repository).restoreRememberedSession(accountID), true);
});

test("an old logout cannot delete a newer tab's restored remembered session", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const old = controller(repository);
  await old.create(passphrase);
  assert.equal(await old.rememberSession(accountID), true);
  const fresh = controller(repository);
  assert.equal(await fresh.restoreRememberedSession(accountID), true);
  old.lock();
  await old.forgetRememberedSession();
  assert.ok(await repository.loadSessionUnlock());
  fresh.lock();
  await fresh.forgetRememberedSession();
  assert.equal(await repository.loadSessionUnlock(), null);
});

test("logout removes its own remembered key even when its save acknowledgement is delayed", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    const saved = await repository.saveSessionUnlockIfCurrent(...args);
    entered(); await held; return saved;
  } };
  const vault = controller(delayed);
  await vault.create(passphrase);
  const remembering = vault.rememberSession(accountID);
  await started;
  vault.lock();
  await vault.forgetRememberedSession();
  release();
  assert.equal(await remembering, false);
  assert.equal(await repository.loadSessionUnlock(), null);
});

test("logout of a pending old remember preserves a newer tab's remembered key", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    entered(); await held; return repository.saveSessionUnlockIfCurrent(...args);
  } };
  const old = controller(delayed);
  await old.create(passphrase);
  const remembering = old.rememberSession(accountID);
  await started;
  const fresh = controller(repository);
  await fresh.unlock(passphrase);
  assert.equal(await fresh.rememberSession(accountID), true);
  old.lock();
  await old.forgetRememberedSession();
  release();
  assert.equal(await remembering, false);
  assert.equal(await controller(repository).restoreRememberedSession(accountID), true);
});

test("an older remember read cannot replace a newer observed unlock", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  let entered, release, calls = 0;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, loadSessionUnlockState: async () => {
    const state = await repository.loadSessionUnlockState();
    if (++calls === 1) { entered(); await held; }
    return state;
  } };
  const vault = controller(delayed);
  await vault.create(passphrase);
  const first = vault.rememberSession(accountID);
  await started;
  assert.equal(await vault.rememberSession(accountID), true);
  release();
  assert.equal(await first, false);
  vault.lock();
  await vault.forgetRememberedSession();
  assert.equal(await repository.loadSessionUnlock(), null);
});

test("an older remember acknowledgement cannot replace a newer observed unlock", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  let entered, release, calls = 0;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    const saved = await repository.saveSessionUnlockIfCurrent(...args);
    if (++calls === 1) { entered(); await held; }
    return saved;
  } };
  const vault = controller(delayed);
  await vault.create(passphrase);
  const first = vault.rememberSession(accountID);
  await started;
  assert.equal(await vault.rememberSession(accountID), true);
  release();
  assert.equal(await first, true);
  vault.lock();
  await vault.forgetRememberedSession();
  assert.equal(await repository.loadSessionUnlock(), null);
});

test("an unfinished old remember cannot adopt and delete a newer tab's unlock", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  let entered, release, calls = 0;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, loadSessionDeviceKey: async () => {
    if (++calls === 2) { entered(); await held; }
    return repository.loadSessionDeviceKey();
  } };
  const old = controller(delayed);
  await old.create(passphrase);
  assert.equal(await old.rememberSession(accountID), true);
  const fresh = controller(repository);
  await fresh.unlock(passphrase);
  assert.equal(await fresh.rememberSession(accountID), true);
  const pending = old.rememberSession(accountID);
  await started;
  old.lock();
  await old.forgetRememberedSession();
  release();
  assert.equal(await pending, false);
  assert.ok(await repository.loadSessionUnlock());
  fresh.lock();
  await fresh.forgetRememberedSession();
  assert.equal(await repository.loadSessionUnlock(), null);
});

test("cancelling an old pending save preserves and can later remove the newer tab's key", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  let entered, release, saves = 0;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    if (++saves === 2) { entered(); await held; }
    return repository.saveSessionUnlockIfCurrent(...args);
  } };
  const old = controller(delayed);
  await old.create(passphrase);
  assert.equal(await old.rememberSession(accountID), true);
  const fresh = controller(repository);
  await fresh.unlock(passphrase);
  assert.equal(await fresh.rememberSession(accountID), true);
  const pending = old.rememberSession(accountID);
  await started;
  old.lock();
  await old.forgetRememberedSession();
  release();
  assert.equal(await pending, false);
  assert.ok(await repository.loadSessionUnlock());
  fresh.lock();
  await fresh.forgetRememberedSession();
  assert.equal(await repository.loadSessionUnlock(), null);
});

test("a stale remember cannot overwrite a replacement that did not advance generation", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const seed = controller(repository);
  await seed.create(passphrase);
  await seed.rememberSession(accountID);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    entered(); await held; return repository.saveSessionUnlockIfCurrent(...args);
  } };
  const target = controller(delayed);
  await target.unlock(passphrase);
  const pending = target.rememberSession(accountID);
  await started;
  const replacement = structuredClone(await repository.loadSessionUnlock());
  replacement.nonce[0] ^= 1;
  // Simulates an older version that writes a record without this generation field.
  await repository.saveSessionUnlock(replacement);
  release();
  assert.equal(await pending, false);
  assert.deepEqual(await repository.loadSessionUnlock(), replacement);
});

test("lock invalidates in-flight password and session-key unlocks", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const seed = controller(repository);
  await seed.create(passphrase);
  const sessionKey = seed.sessionKey();
  seed.lock();
  for (const unlock of [vault => vault.unlock(passphrase), vault => vault.unlockWithSessionKey(sessionKey)]) {
    let entered, release;
    const started = new Promise(resolve => { entered = resolve; });
    const held = new Promise(resolve => { release = resolve; });
    const delayed = { ...repository, load: async () => {
      const captured = await repository.load(); entered(); await held; return captured;
    } };
    const target = controller(delayed);
    const pending = unlock(target);
    await started;
    target.lock();
    release();
    await pending.catch(() => {});
    assert.equal(await target.status(), "locked");
    assert.throws(() => target.document(), /local_vault_locked/u);
  }
});

for (const afterCommit of [false, true]) test(`logout during account restoration handles the key ${afterCommit ? "after" : "before"} its commit`, async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const root = createIndexedDBVaultRepository(new IDBFactory());
  const accountRepository = root.forAccount(accountID), seed = controller(accountRepository);
  await seed.create(passphrase);
  await seed.bindAccountOwnership(accountID);
  assert.equal(await seed.rememberSession(accountID), true);
  seed.lock();
  const original = await accountRepository.loadSessionUnlock();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...accountRepository, saveSessionUnlockIfCurrent: async (...args) => {
    if (afterCommit) {
      const result = await accountRepository.saveSessionUnlockIfCurrent(...args);
      entered(); await held; return result;
    }
    entered(); await held; return accountRepository.saveSessionUnlockIfCurrent(...args);
  } };
  let signedIn = true;
  const session = { requireCurrent() { if (!signedIn) throw new Error("authentication_required"); } };
  const activations = createPendingAccountVaultActivations(), activation = activations.begin(session);
  const preparing = (async () => {
    let installed = false;
    try {
      const prepared = await prepareAccountScopedVault({ accountID, accountRepository: delayed,
        legacyRepository: root, cryptoValue: webcrypto, onController: activation.onController, requireCurrent: activation.requireCurrent });
      session.requireCurrent(); installed = true; return prepared;
    } finally { await activation.finish(installed); }
  })();
  await started;
  const legacyController = controller(root);
  await completeBrowserSessionLogout({ client: { logout: async () => { signedIn = false; }, session: () => null },
    vault: legacyController, cancelPendingActivations: () => activations.cancelCurrent(), clearView() {}, restoreView() {} });
  release();
  await assert.rejects(preparing, /authentication_required/);
  if (afterCommit) assert.equal((await accountRepository.loadSessionUnlockState()).unlock, null);
  else assert.deepEqual((await accountRepository.loadSessionUnlockState()).unlock, original);
});

test("late canceled activation preserves a newer login's remembered key", async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const root = createIndexedDBVaultRepository(new IDBFactory()), accountRepository = root.forAccount(accountID);
  const seed = controller(accountRepository);
  await seed.create(passphrase); await seed.bindAccountOwnership(accountID); await seed.rememberSession(accountID); seed.lock();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...accountRepository, loadSessionUnlockState: async () => {
    const captured = await accountRepository.loadSessionUnlockState(); entered(); await held; return captured;
  } };
  let signedIn = true;
  const session = { requireCurrent() { if (!signedIn) throw new Error("authentication_required"); } };
  const activations = createPendingAccountVaultActivations(), activation = activations.begin(session);
  const preparing = (async () => {
    try {
      return await prepareAccountScopedVault({ accountID, accountRepository: delayed, legacyRepository: root,
        cryptoValue: webcrypto, onController: activation.onController, requireCurrent: activation.requireCurrent });
    } finally { await activation.finish(false); }
  })();
  await started;
  await completeBrowserSessionLogout({ client: { logout: async () => { signedIn = false; }, session: () => null },
    vault: controller(root), cancelPendingActivations: () => activations.cancelCurrent(), clearView() {}, restoreView() {} });
  const newer = controller(accountRepository);
  await newer.unlock(passphrase); assert.equal(await newer.rememberSession(accountID), true);
  const expected = await accountRepository.loadSessionUnlockState();
  release();
  await assert.rejects(preparing, /authentication_required/);
  assert.deepEqual(await accountRepository.loadSessionUnlockState(), expected);
});

test("logout before the first account read reports unconfirmed and preserves a later login", async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const root = createIndexedDBVaultRepository(new IDBFactory()), repository = root.forAccount(accountID);
  const seed = controller(repository);
  await seed.create(passphrase); await seed.rememberSession(accountID); seed.lock();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, loadSessionUnlockState: async () => {
    entered(); await held; return repository.loadSessionUnlockState();
  } };
  let signedIn = true, presentation;
  const activation = createPendingAccountVaultActivations();
  const pending = activation.begin({ requireCurrent() { if (!signedIn) throw new Error("authentication_required"); } });
  const preparing = (async () => {
    try {
      return await prepareAccountScopedVault({ accountID, accountRepository: delayed, legacyRepository: root,
        cryptoValue: webcrypto, onController: pending.onController, requireCurrent: pending.requireCurrent });
    } finally { await pending.finish(false); }
  })();
  await started;
  await completeBrowserSessionLogout({ client: { logout: async () => { signedIn = false; }, session: () => null },
    vault: controller(root), cancelPendingActivations: () => activation.cancelCurrent(),
    clearView() {}, restoreView(value) { presentation = value; } });
  const newer = controller(repository);
  await newer.unlock(passphrase); assert.equal(await newer.rememberSession(accountID), true);
  const expected = await repository.loadSessionUnlockState();
  release();
  await assert.rejects(preparing, /authentication_required/);
  assert.deepEqual(await repository.loadSessionUnlockState(), expected);
  assert.equal(presentation.remoteRevoked, true);
  assert.equal(presentation.localCleanupConfirmed, false);
});

test("logout cannot delete another login's key merely observed by a pending activation", async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const root = createIndexedDBVaultRepository(new IDBFactory()), repository = root.forAccount(accountID);
  const newer = controller(repository);
  await newer.create(passphrase); await newer.rememberSession(accountID);
  const expected = await repository.loadSessionUnlock();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, load: async () => { entered(); await held; return repository.load(); } };
  let signedIn = true, presentation;
  const activations = createPendingAccountVaultActivations();
  const activation = activations.begin({ requireCurrent() { if (!signedIn) throw new Error("authentication_required"); } });
  const preparing = (async () => {
    try {
      const result = await prepareAccountScopedVault({ accountID, accountRepository: delayed, legacyRepository: root,
        cryptoValue: webcrypto, onController: activation.onController, requireCurrent: activation.requireCurrent });
      activation.requireCurrent(); return result;
    } finally { await activation.finish(false); }
  })();
  await started;
  await completeBrowserSessionLogout({ client: { logout: async () => { signedIn = false; }, session: () => null },
    vault: controller(root), cancelPendingActivations: () => activations.cancelCurrent(),
    clearView() {}, restoreView(value) { presentation = value; } });
  const immediatelyAfterLogout = await repository.loadSessionUnlock();
  release();
  await assert.rejects(preparing, /authentication_required/);
  assert.deepEqual(immediatelyAfterLogout, expected);
  assert.deepEqual(await repository.loadSessionUnlock(), expected);
  assert.equal(presentation.localCleanupConfirmed, false);
});

for (const afterCommit of [false, true]) test(`logout reports cleanup before a delayed account save ${afterCommit ? "after" : "before"} commit`, async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const root = createIndexedDBVaultRepository(new IDBFactory()), repository = root.forAccount(accountID);
  const seed = controller(repository);
  await seed.create(passphrase); await seed.rememberSession(accountID); seed.lock();
  const original = await repository.loadSessionUnlock();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    if (afterCommit) {
      const result = await repository.saveSessionUnlockIfCurrent(...args);
      entered(); await held; return result;
    }
    entered(); await held; return repository.saveSessionUnlockIfCurrent(...args);
  } };
  let signedIn = true, presentation;
  const activations = createPendingAccountVaultActivations();
  const activation = activations.begin({ requireCurrent() { if (!signedIn) throw new Error("authentication_required"); } });
  const preparing = (async () => {
    try {
      const result = await prepareAccountScopedVault({ accountID, accountRepository: delayed, legacyRepository: root,
        cryptoValue: webcrypto, onController: activation.onController, requireCurrent: activation.requireCurrent });
      activation.requireCurrent(); return result;
    } finally { await activation.finish(false); }
  })();
  await started;
  await completeBrowserSessionLogout({ client: { logout: async () => { signedIn = false; }, session: () => null },
    vault: controller(root), cancelPendingActivations: () => activations.cancelCurrent(),
    clearView() {}, restoreView(value) { presentation = value; } });
  const immediatelyAfterLogout = await repository.loadSessionUnlock();
  release();
  await assert.rejects(preparing, /authentication_required/);
  assert.equal(presentation.localCleanupConfirmed, afterCommit);
  if (afterCommit) assert.equal(immediatelyAfterLogout, null);
  else assert.deepEqual(immediatelyAfterLogout, original);
});

for (const afterCommit of [false, true]) test(`logout during legacy migration ${afterCommit ? "after" : "before"} the account key commit is unconfirmed`, async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", indexedDB = new IDBFactory();
  const root = createIndexedDBVaultRepository(indexedDB), repository = root.forAccount(accountID);
  const seed = controller(root);
  await seed.create(passphrase); await seed.rememberSession(accountID); await markLegacyOwner(indexedDB, accountID); seed.lock();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    if (afterCommit) {
      const result = await repository.saveSessionUnlockIfCurrent(...args);
      entered(); await held; return result;
    }
    entered(); await held; return repository.saveSessionUnlockIfCurrent(...args);
  } };
  let signedIn = true, presentation;
  const activations = createPendingAccountVaultActivations();
  const activation = activations.begin({ requireCurrent() { if (!signedIn) throw new Error("authentication_required"); } });
  const preparing = (async () => {
    try {
      const result = await prepareAccountScopedVault({ accountID, accountRepository: delayed, legacyRepository: root,
        cryptoValue: webcrypto, onController: activation.onController, requireCurrent: activation.requireCurrent });
      activation.requireCurrent(); return result;
    } finally { await activation.finish(false); }
  })();
  await started;
  await completeBrowserSessionLogout({ client: { logout: async () => { signedIn = false; }, session: () => null },
    vault: controller(root), cancelPendingActivations: () => activations.cancelCurrent(),
    clearView() {}, restoreView(value) { presentation = value; } });
  const newer = controller(repository);
  await newer.unlock(passphrase); assert.equal(await newer.rememberSession(accountID), true);
  const expected = await repository.loadSessionUnlockState();
  release();
  await assert.rejects(preparing, /authentication_required/);
  assert.deepEqual(await repository.loadSessionUnlockState(), expected);
  assert.equal(presentation.localCleanupConfirmed, false);
});

test("a pending legacy key copy stays unconfirmed even if its source key disappears", async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", indexedDB = new IDBFactory();
  const root = createIndexedDBVaultRepository(indexedDB), repository = root.forAccount(accountID);
  const seed = controller(root);
  await seed.create(passphrase); await seed.rememberSession(accountID); await markLegacyOwner(indexedDB, accountID); seed.lock();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, saveSessionUnlockIfCurrent: async (...args) => {
    entered(); await held; return repository.saveSessionUnlockIfCurrent(...args);
  } };
  let signedIn = true, presentation;
  const activations = createPendingAccountVaultActivations();
  const activation = activations.begin({ requireCurrent() { if (!signedIn) throw new Error("authentication_required"); } });
  const preparing = (async () => {
    try {
      const result = await prepareAccountScopedVault({ accountID, accountRepository: delayed, legacyRepository: root,
        cryptoValue: webcrypto, onController: activation.onController, requireCurrent: activation.requireCurrent });
      activation.requireCurrent(); return result;
    } finally { await activation.finish(false); }
  })();
  await started;
  await root.deleteSessionUnlock();
  await completeBrowserSessionLogout({ client: { logout: async () => { signedIn = false; }, session: () => null },
    vault: controller(root), cancelPendingActivations: () => activations.cancelCurrent(),
    clearView() {}, restoreView(value) { presentation = value; } });
  release();
  await assert.rejects(preparing, /authentication_required/);
  assert.equal(presentation.localCleanupConfirmed, false);
});

test("logout reports unconfirmed if pending account key deletion fails", async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const root = createIndexedDBVaultRepository(new IDBFactory()), repository = root.forAccount(accountID);
  const seed = controller(repository);
  await seed.create(passphrase); await seed.rememberSession(accountID); seed.lock();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository,
    saveSessionUnlockIfCurrent: async (...args) => {
      const result = await repository.saveSessionUnlockIfCurrent(...args); entered(); await held; return result;
    },
    deleteSessionUnlockIfCurrent: async () => { throw new Error("synthetic_storage_failure"); },
  };
  let signedIn = true, presentation;
  const activations = createPendingAccountVaultActivations();
  const activation = activations.begin({ requireCurrent() { if (!signedIn) throw new Error("authentication_required"); } });
  const preparing = (async () => {
    try {
      const result = await prepareAccountScopedVault({ accountID, accountRepository: delayed, legacyRepository: root,
        cryptoValue: webcrypto, onController: activation.onController, requireCurrent: activation.requireCurrent });
      activation.requireCurrent(); return result;
    } finally { await activation.finish(false); }
  })();
  await started;
  await completeBrowserSessionLogout({ client: { logout: async () => { signedIn = false; }, session: () => null },
    vault: controller(root), cancelPendingActivations: () => activations.cancelCurrent(),
    clearView() {}, restoreView(value) { presentation = value; } });
  const retained = await repository.loadSessionUnlock();
  release();
  await assert.rejects(preparing, /synthetic_storage_failure/);
  assert.notEqual(retained, null);
  assert.equal(presentation.remoteRevoked, true);
  assert.equal(presentation.localCleanupConfirmed, false);
});

for (const cleanupSettled of [false, true]) test(`logout reports unfinished activation cleanup ${cleanupSettled ? "after failure" : "while pending"}`, async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const root = createIndexedDBVaultRepository(new IDBFactory()), repository = root.forAccount(accountID);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const tracked = controller({ ...repository, async deleteSessionUnlockIfCurrent() {
    entered(); await held; throw new Error("synthetic_storage_failure");
  } });
  await tracked.create(passphrase);
  await tracked.rememberSession(accountID);
  const activations = createPendingAccountVaultActivations();
  const activation = activations.begin({ requireCurrent() {} });
  await activation.onController(tracked);
  const finishing = activation.finish(false).then(() => null, error => error);
  await started;
  if (cleanupSettled) { release(); assert.match((await finishing).message, /synthetic_storage_failure/u); }
  let presentation;
  try {
    await completeBrowserSessionLogout({ client: { logout: async () => {}, session: () => null },
      vault: controller(root), cancelPendingActivations: () => activations.cancelCurrent(),
      clearView() {}, restoreView(value) { presentation = value; } });
    assert.notEqual(await repository.loadSessionUnlock(), null);
    assert.equal(presentation.localCleanupConfirmed, false);
  } finally {
    release();
    await finishing;
  }
});

test("a finishing activation's delayed cleanup preserves a newer remembered session", async () => {
  const { completeBrowserSessionLogout, createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const root = createIndexedDBVaultRepository(new IDBFactory()), repository = root.forAccount(accountID);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const old = controller({ ...repository, async deleteSessionUnlockIfCurrent(...args) {
    entered(); await held; return repository.deleteSessionUnlockIfCurrent(...args);
  } });
  await old.create(passphrase);
  await old.rememberSession(accountID);
  const activations = createPendingAccountVaultActivations(), activation = activations.begin({ requireCurrent() {} });
  await activation.onController(old);
  const finishing = activation.finish(false);
  await started;
  let presentation;
  try {
    await completeBrowserSessionLogout({ client: { logout: async () => {}, session: () => null },
      vault: controller(root), cancelPendingActivations: () => activations.cancelCurrent(),
      clearView() {}, restoreView(value) { presentation = value; } });
    const newer = controller(repository);
    await newer.unlock(passphrase);
    assert.equal(await newer.rememberSession(accountID), true);
    const expected = await repository.loadSessionUnlockState();
    release();
    await finishing;
    assert.deepEqual(await repository.loadSessionUnlockState(), expected);
    assert.equal(presentation.localCleanupConfirmed, false);
  } finally { release(); await finishing; }
});

test("an unconfirmed Personal Vault lock drops decrypted access and preserves an ambiguous remembered key", async () => {
  const { lockPersonalVault } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const vault = controller(repository);
  await vault.create(passphrase);
  await vault.rememberSession(accountID);
  const retained = await repository.loadSessionUnlockState();
  const operation = lockPersonalVault({ controller: vault, cleanup: async () => false });
  assert.throws(() => vault.document(), /local_vault_locked/u);
  assert.equal(await operation, false);
  assert.deepEqual(await repository.loadSessionUnlockState(), retained);
  assert.equal(await vault.status(), "locked");
});

test("logout confirms removal of its own claimed remembered key", async () => {
  const { completeBrowserSessionLogout } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const vault = controller(repository);
  await vault.create(passphrase); assert.equal(await vault.rememberSession(accountID), true);
  let presentation;
  await completeBrowserSessionLogout({ client: { logout: async () => {}, session: () => null }, vault,
    clearView() {}, restoreView(value) { presentation = value; } });
  assert.equal(await repository.loadSessionUnlock(), null);
  assert.equal(presentation.localCleanupConfirmed, true);
});

test("old logout preserves an identical key claimed at a newer generation", async () => {
  const { completeBrowserSessionLogout } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const vault = controller(repository);
  await vault.create(passphrase); assert.equal(await vault.rememberSession(accountID), true);
  const previous = await repository.loadSessionUnlockState();
  assert.equal(await repository.saveSessionUnlockIfCurrent(previous.unlock, previous.generation, previous.unlock), true);
  const newer = await repository.loadSessionUnlockState();
  let presentation;
  await completeBrowserSessionLogout({ client: { logout: async () => {}, session: () => null }, vault,
    clearView() {}, restoreView(value) { presentation = value; } });
  assert.deepEqual(await repository.loadSessionUnlockState(), newer);
  assert.equal(presentation.localCleanupConfirmed, false);
});

test("locking during account restoration prevents late activation", async () => {
  const { createPendingAccountVaultActivations } = await import("../public/app.js");
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const root = createIndexedDBVaultRepository(new IDBFactory()), accountRepository = root.forAccount(accountID);
  const seed = controller(accountRepository);
  await seed.create(passphrase); await seed.bindAccountOwnership(accountID); await seed.rememberSession(accountID); seed.lock();
  const original = await accountRepository.loadSessionUnlock();
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...accountRepository, saveSessionUnlockIfCurrent: async (...args) => {
    entered(); await held; return accountRepository.saveSessionUnlockIfCurrent(...args);
  } };
  const activations = createPendingAccountVaultActivations();
  const activation = activations.begin({ requireCurrent() {} });
  const preparing = (async () => {
    try {
      const prepared = await prepareAccountScopedVault({ accountID, accountRepository: delayed, legacyRepository: root,
        cryptoValue: webcrypto, onController: activation.onController, requireCurrent: activation.requireCurrent });
      activation.requireCurrent(); return prepared;
    } finally { await activation.finish(false); }
  })();
  await started;
  assert.equal(await activations.cancelCurrent(), false); release();
  await assert.rejects(preparing, /authentication_required/);
  assert.deepEqual((await accountRepository.loadSessionUnlockState()).unlock, original);
});

test("lock during creation or remote import cannot reopen the controller", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const source = controller(memoryRepository());
  await source.create(passphrase);
  const remote = await source.prepareUpload(0);
  for (const start of [vault => vault.create(passphrase), vault => vault.importRemote({ revision: 1, envelope: remote.envelope }, passphrase)]) {
    const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
    let entered, release;
    const started = new Promise(resolve => { entered = resolve; });
    const held = new Promise(resolve => { release = resolve; });
    const delayed = { ...repository, saveInitial: async (...args) => {
      await repository.saveInitial(...args); entered(); await held;
    } };
    const target = controller(delayed), pending = start(target);
    await started;
    target.lock();
    release();
    await assert.rejects(pending, /local_vault_locked/u);
    assert.equal(await target.status(), "locked");
    assert.throws(() => target.document(), /local_vault_locked/u);
  }
});

test("a failed ownership write aborts the new snapshot and permits a clean retry", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const idb = new IDBFactory(), repository = createIndexedDBVaultRepository(idb).forAccount(accountID);
  const keys = accountVaultStorageKeys(accountID);
  const opened = idb.open("selective-remote-cloud", 1);
  opened.onupgradeneeded = () => opened.result.createObjectStore("local-vault");
  const database = await new Promise((resolve, reject) => {
    opened.onsuccess = () => resolve(opened.result); opened.onerror = () => reject(opened.error);
  });
  await new Promise((resolve, reject) => {
    const tx = database.transaction("local-vault", "readwrite");
    tx.objectStore("local-vault").put({ stale: true }, keys.ownership);
    tx.oncomplete = resolve; tx.onabort = () => reject(tx.error);
  });
  database.close();
  const put = IDBObjectStore.prototype.put;
  IDBObjectStore.prototype.put = function(value, key) {
    return key === keys.ownership ? this.add(value, key) : put.call(this, value, key);
  };
  try { await assert.rejects(controller(repository).create(passphrase), /local_vault_storage_failed/); }
  finally { IDBObjectStore.prototype.put = put; }
  assert.equal(await repository.load(), null);
  const retried = controller(repository);
  await retried.create(passphrase);
  assert.equal(await retried.hasAccountOwnership(accountID), true);
});

test("a remote import cannot overwrite a legacy migration that wins the same empty slot", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const idb = new IDBFactory(), root = createIndexedDBVaultRepository(idb);
  const legacy = controller(root);
  await legacy.create(passphrase);
  const remote = await legacy.prepareUpload(0);
  await legacy.upsert({ type: "host", data: { title: "Unsynced", address: "unsynced.invalid" } });
  await markLegacyOwner(idb, accountID);
  const target = root.forAccount(accountID);
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const delayed = { ...target, saveInitial: async (...args) => { entered(); await held; return target.saveInitial(...args); } };
  const importing = controller(delayed).importRemote({ revision: 1, envelope: remote.envelope }, passphrase);
  await started;
  const prepared = await prepareAccountScopedVault({
    accountID, accountRepository: target, legacyRepository: root, passphrase, cryptoValue: webcrypto,
    readLegacyRemote: async () => ({ revision: 1, envelope: remote.envelope }),
  });
  release();
  await assert.rejects(importing, /local_vault_exists/);
  const reopened = controller(target);
  await reopened.unlock(passphrase);
  assert.equal(prepared.legacyMigrated, true);
  assert.equal(reopened.document().records[0].data.address, "unsynced.invalid");
  assert.ok(await root.load());
});

test("a remote replacement cannot overwrite edits made after the failed local unlock", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(accountID);
  const original = controller(repository);
  await original.create(passphrase);
  const concurrent = controller(repository);
  await concurrent.unlock(passphrase);
  const remote = controller(memoryRepository());
  const newPassphrase = "a different synthetic recovery password";
  await remote.create(newPassphrase);
  const envelope = (await remote.prepareUpload(0)).envelope;
  const replacement = controller(repository);
  await assert.rejects(replacement.unlock(newPassphrase));
  await concurrent.upsert({ type: "host", data: { title: "Keep", address: "keep.invalid" } });
  await assert.rejects(replacement.replaceLockedWithRemote({ revision: 1, envelope }, newPassphrase), /local_vault_changed/);
  const reloaded = controller(repository);
  await reloaded.unlock(passphrase);
  assert.equal(reloaded.document().records[0].data.address, "keep.invalid");
  assert.equal((await reloaded.syncState()).dirty, true);
});

test("a foreign legacy snapshot is preserved and not migrated for a new account", async () => {
  const legacyRepository = memoryRepository();
  const legacyVault = controller(legacyRepository);
  await legacyVault.create("account A password is long enough");
  const before = legacyRepository.snapshot();
  const accountRepository = memoryRepository();

  const prepared = await prepareAccountScopedVault({
    accountID: "ffffffff-ffff-4fff-8fff-ffffffffffff",
    accountRepository,
    legacyRepository,
    passphrase: "account B password is also long enough",
    cryptoValue: webcrypto,
  });

  assert.equal(prepared.legacyMigrated, false);
  assert.equal(prepared.restored, false);
  assert.equal(await prepared.vault.status(), "empty");
  assert.equal(accountRepository.snapshot(), null);
  assert.deepEqual(legacyRepository.snapshot(), before);
});

test("a different account with the same password cannot claim a remembered legacy Vault", async () => {
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const legacyRepository = memoryRepository();
  const legacy = controller(legacyRepository);
  await legacy.create(passphrase);
  await legacy.upsert({ type: "host", data: { title: "A only", address: "a.invalid" } });
  await legacy.rememberSession(accountA);
  const before = legacyRepository.snapshot();
  const target = memoryRepository();

  const prepared = await prepareAccountScopedVault({
    accountID: accountB, accountRepository: target, legacyRepository, passphrase, cryptoValue: webcrypto,
  });

  assert.equal(prepared.legacyMigrated, false);
  assert.equal(await prepared.vault.status(), "empty");
  assert.equal(target.snapshot(), null);
  assert.deepEqual(legacyRepository.snapshot(), before);
});

test("an unbound legacy Vault is retained until its account ownership is proven", async () => {
  const legacyRepository = memoryRepository();
  const legacy = controller(legacyRepository);
  await legacy.create(passphrase);
  const before = legacyRepository.snapshot();
  const target = memoryRepository();
  const prepared = await prepareAccountScopedVault({
    accountID: "ffffffff-ffff-4fff-8fff-ffffffffffff",
    accountRepository: target, legacyRepository, passphrase, cryptoValue: webcrypto,
  });

  assert.equal(prepared.legacyOwnershipUnverified, true);
  assert.equal(prepared.legacyMigrated, false);
  assert.equal(target.snapshot(), null);
  assert.deepEqual(legacyRepository.snapshot(), before);
});

test("an unrelated remote key cannot establish legacy Vault ownership", async () => {
  const legacyRepository = memoryRepository();
  const legacy = controller(legacyRepository);
  await legacy.create(passphrase);
  const otherRepository = memoryRepository();
  const other = controller(otherRepository);
  await other.create(passphrase);
  const remote = await other.prepareUpload(0);
  const before = legacyRepository.snapshot();
  const target = memoryRepository();

  const prepared = await prepareAccountScopedVault({
    accountID: "ffffffff-ffff-4fff-8fff-ffffffffffff", accountRepository: target,
    legacyRepository, passphrase, cryptoValue: webcrypto,
    readLegacyRemote: async () => ({ revision: 1, envelope: remote.envelope }),
  });

  assert.equal(prepared.legacyOwnershipUnverified, true);
  assert.equal(prepared.legacyMigrated, false);
  assert.equal(target.snapshot(), null);
  assert.deepEqual(legacyRepository.snapshot(), before);
});

test("a remote copy contaminated by a prior account mix-up cannot prove legacy ownership", async () => {
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const legacyRepository = memoryRepository();
  const ownerA = controller(legacyRepository);
  await ownerA.create(passphrase);
  await ownerA.upsert({ type: "host", data: { title: "Only A", address: "a.invalid" } });
  // An older client could already have uploaded A's envelope to B when their
  // passphrases matched. The remote copy therefore supplies no provenance.
  const copiedToB = await ownerA.prepareUpload(0);
  const target = memoryRepository();
  const prepared = await prepareAccountScopedVault({
    accountID: accountB, accountRepository: target, legacyRepository,
    passphrase, cryptoValue: webcrypto,
    readLegacyRemote: async () => ({ revision: 1, envelope: copiedToB.envelope }),
  });
  assert.equal(prepared.legacyOwnershipUnverified, true);
  assert.equal(await target.load(), null);
  assert.equal(await prepared.vault.status(), "empty");
});

test("a legacy remembered login created after an account mix-up is not ownership proof", async () => {
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const legacyRepository = memoryRepository();
  const ownerA = controller(legacyRepository);
  await ownerA.create(passphrase);
  await ownerA.rememberSession(accountB);
  const target = memoryRepository();
  const prepared = await prepareAccountScopedVault({
    accountID: accountB, accountRepository: target, legacyRepository, cryptoValue: webcrypto,
  });
  assert.equal(prepared.legacyOwnershipUnverified, true);
  assert.equal(await target.load(), null);
});

test("a matching remote wrapper preserves an unbound legacy Vault without importing it", async () => {
  const legacyRepository = memoryRepository();
  const legacy = controller(legacyRepository);
  await legacy.create(passphrase);
  await legacy.upsert({ type: "host", data: { title: "Existing", address: "existing.invalid" } });
  const remote = await legacy.prepareUpload(0);
  const before = legacyRepository.snapshot();
  const target = memoryRepository();
  const prepared = await prepareAccountScopedVault({
    accountID: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", accountRepository: target,
    legacyRepository, passphrase, cryptoValue: webcrypto,
    readLegacyRemote: async () => ({ revision: 1, envelope: remote.envelope }),
  });

  assert.equal(prepared.legacyMigrated, false);
  assert.equal(prepared.legacyOwnershipUnverified, true);
  assert.equal(target.snapshot(), null);
  assert.deepEqual(legacyRepository.snapshot(), before);
});

test("legacy migration cannot overwrite an account Vault created in another tab", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const idb = new IDBFactory(), root = createIndexedDBVaultRepository(idb);
  const legacy = controller(root);
  await legacy.create(passphrase);
  const before = await root.load();
  const remote = await legacy.prepareUpload(0);
  const concurrent = memoryRepository();
  await controller(concurrent).create(passphrase);
  const otherSnapshot = concurrent.snapshot();
  const target = root.forAccount(accountID);
  await markLegacyOwner(idb, accountID);
  const racing = { ...target, importLegacyStateIfAbsent: async (...args) => {
    await target.save(otherSnapshot);
    return target.importLegacyStateIfAbsent(...args);
  } };

  await assert.rejects(prepareAccountScopedVault({
    accountID, accountRepository: racing, legacyRepository: root, passphrase, cryptoValue: webcrypto,
  }), /local_vault_exists/u);
  assert.deepEqual(await target.load(), otherSnapshot);
  assert.deepEqual(await root.load(), before);
});

test("legacy ownership verification stays bound to the exact captured snapshot", async () => {
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const root = createIndexedDBVaultRepository(new IDBFactory());
  const first = controller(root);
  await first.create(passphrase);
  await first.rememberSession(accountA);
  const captured = await root.loadLegacyState();

  const secondRepository = memoryRepository();
  await controller(secondRepository).create(passphrase);
  await root.save(secondRepository.snapshot());
  const second = controller(root);
  await second.unlock(passphrase);
  await second.rememberSession(accountB);
  const staleRead = { ...root, loadLegacyState: async () => structuredClone(captured) };
  const target = root.forAccount(accountB);

  const prepared = await prepareAccountScopedVault({
    accountID: accountB, accountRepository: target, legacyRepository: staleRead, passphrase, cryptoValue: webcrypto,
  });
  assert.equal(prepared.legacyOwnershipUnverified, true);
  assert.equal(prepared.legacyMigrated, false);
  assert.equal(await target.load(), null);
});

test("a verified legacy owner lets another account use its own empty Vault", async () => {
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const idb = new IDBFactory(), root = createIndexedDBVaultRepository(idb);
  const legacy = controller(root);
  await legacy.create(passphrase);
  const remote = await legacy.prepareUpload(0);
  await markLegacyOwner(idb, accountA);
  const first = await prepareAccountScopedVault({
    accountID: accountA, accountRepository: root.forAccount(accountA), legacyRepository: root,
    passphrase, cryptoValue: webcrypto, readLegacyRemote: async () => ({ revision: 1, envelope: remote.envelope }),
  });
  assert.equal(first.legacyMigrated, true);
  const second = await prepareAccountScopedVault({
    accountID: accountB, accountRepository: root.forAccount(accountB), legacyRepository: root,
    passphrase, cryptoValue: webcrypto, readLegacyRemote: async () => ({ revision: 0, envelope: null }),
  });
  assert.equal(second.legacyMigrated, false);
  assert.notEqual(second.legacyOwnershipUnverified, true);
  assert.equal(await second.vault.status(), "empty");
});

test("verified legacy restore preserves the source remembered record during migration", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const idb = new IDBFactory(), root = createIndexedDBVaultRepository(idb);
  const legacy = controller(root);
  await legacy.create(passphrase);
  assert.equal(await legacy.rememberSession(accountID), true);
  await markLegacyOwner(idb, accountID);
  const before = await root.loadSessionUnlockState();
  const migrated = await prepareAccountScopedVault({
    accountID, accountRepository: root.forAccount(accountID), legacyRepository: root, cryptoValue: webcrypto,
  });
  assert.equal(migrated.legacyMigrated, true);
  assert.equal(migrated.restored, true);
  assert.deepEqual(await root.loadSessionUnlockState(), before);
  assert.equal(await migrated.vault.status(), "unlocked");
});

test("legacy migration stops if another tab changes the captured snapshot", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const idb = new IDBFactory(), root = createIndexedDBVaultRepository(idb);
  const legacy = controller(root);
  await legacy.create(passphrase);
  const remote = await legacy.prepareUpload(0);
  const other = memoryRepository();
  await controller(other).create(passphrase);
  const replacement = other.snapshot();
  const target = root.forAccount(accountID);
  await markLegacyOwner(idb, accountID);
  const racing = { ...target, importLegacyStateIfAbsent: async (...args) => {
    await root.save(replacement);
    return target.importLegacyStateIfAbsent(...args);
  } };
  await assert.rejects(prepareAccountScopedVault({
    accountID, accountRepository: racing, legacyRepository: root, passphrase, cryptoValue: webcrypto,
  }), /legacy_snapshot_changed/u);
  assert.deepEqual(await root.load(), replacement);
  assert.equal(await target.load(), null);
});

test("legacy migration stops if its ownership proof disappears before commit", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const idb = new IDBFactory(), root = createIndexedDBVaultRepository(idb);
  const legacy = controller(root);
  await legacy.create(passphrase);
  const before = await root.load(), target = root.forAccount(accountID);
  await markLegacyOwner(idb, accountID);
  const racing = { ...target, importLegacyStateIfAbsent: async (...args) => {
    const request = idb.open("selective-remote-cloud", 1);
    const database = await new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
    });
    await new Promise((resolve, reject) => {
      const tx = database.transaction("local-vault", "readwrite");
      tx.objectStore("local-vault").delete("personal-legacy-owner:v1");
      tx.oncomplete = resolve; tx.onabort = () => reject(tx.error);
    });
    database.close();
    return target.importLegacyStateIfAbsent(...args);
  } };
  await assert.rejects(prepareAccountScopedVault({
    accountID, accountRepository: racing, legacyRepository: root, passphrase, cryptoValue: webcrypto,
  }), /local_vault_owner_unverified/u);
  assert.equal(await target.load(), null);
  assert.deepEqual(await root.load(), before);
});

test("a same-account legacy snapshot migrates only after successful unwrap", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const legacyRepository = memoryRepository();
  const legacyVault = controller(legacyRepository);
  await legacyVault.create(passphrase);
  await legacyVault.upsert({ type: "host", data: { title: "Legacy", address: "legacy.invalid" } });
  await legacyVault.rememberSession(accountID);
  legacyRepository.markLegacyOwner(accountID);
  await legacyRepository.saveSync({ localRevision: 2, serverRevision: 2 });
  const before = legacyRepository.snapshot();
  const accountRepository = memoryRepository();

  const prepared = await prepareAccountScopedVault({
    accountID,
    accountRepository,
    legacyRepository,
    passphrase,
    cryptoValue: webcrypto,
  });

  assert.equal(prepared.legacyMigrated, true);
  assert.equal(prepared.restored, true);
  assert.equal(await prepared.vault.status(), "unlocked");
  assert.equal(prepared.vault.document().records[0].data.address, "legacy.invalid");
  assert.deepEqual(accountRepository.snapshot(), before);
  assert.deepEqual(accountRepository.synchronization(), { localRevision: 2, serverRevision: 2 });
  assert.deepEqual(legacyRepository.snapshot(), before);
});

test("remembered restore is account-bound and a wrong account leaves legacy state untouched", async () => {
  const accountA = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const accountB = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const legacyRepository = memoryRepository();
  const legacyVault = controller(legacyRepository);
  await legacyVault.create(passphrase);
  await legacyVault.rememberSession(accountA);
  legacyRepository.markLegacyOwner(accountA);
  legacyVault.lock();
  const rememberedBefore = legacyRepository.rememberedSession();

  const wrongAccount = await prepareAccountScopedVault({
    accountID: accountB,
    accountRepository: memoryRepository(),
    legacyRepository,
    cryptoValue: webcrypto,
  });
  assert.equal(wrongAccount.restored, false);
  assert.equal(await wrongAccount.vault.status(), "empty");
  assert.deepEqual(legacyRepository.rememberedSession(), rememberedBefore);

  const accountRepository = memoryRepository();
  const sameAccount = await prepareAccountScopedVault({
    accountID: accountA,
    accountRepository,
    legacyRepository,
    cryptoValue: webcrypto,
  });
  assert.equal(sameAccount.legacyMigrated, true);
  assert.equal(sameAccount.restored, true);
  assert.equal(await sameAccount.vault.status(), "unlocked");
  assert.equal((await sameAccount.vault.deviceID()), deviceID);
});

test("same-account remembered migration persists an account-scoped unlock for the next page lifecycle", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const sharedSessionDevice = { key: null };
  const legacyRepository = memoryRepository(null, sharedSessionDevice);
  const accountRepository = memoryRepository(null, sharedSessionDevice);
  const legacyVault = controller(legacyRepository);
  await legacyVault.create(passphrase);
  assert.equal(await legacyVault.rememberSession(accountID), true);
  legacyRepository.markLegacyOwner(accountID);
  legacyVault.lock();
  const legacyRemembered = legacyRepository.rememberedSession();

  const migratedPage = await prepareAccountScopedVault({
    accountID,
    accountRepository,
    legacyRepository,
    cryptoValue: webcrypto,
  });

  assert.equal(migratedPage.restored, true);
  assert.equal(await migratedPage.vault.status(), "unlocked");
  assert.equal(migratedPage.vault.sessionKey().extractable, false);
  assert.deepEqual(accountRepository.rememberedSession(), legacyRemembered);
  assert.deepEqual(legacyRepository.rememberedSession(), legacyRemembered);

  const reloadedPage = await prepareAccountScopedVault({
    accountID,
    accountRepository,
    legacyRepository,
    cryptoValue: webcrypto,
  });
  assert.equal(reloadedPage.restored, true);
  assert.equal(await reloadedPage.vault.status(), "unlocked");

  await reloadedPage.vault.forgetRememberedSession();
  reloadedPage.vault.lock();
  const afterLogout = await prepareAccountScopedVault({
    accountID,
    accountRepository,
    legacyRepository,
    cryptoValue: webcrypto,
  });
  assert.equal(afterLogout.restored, false);
  assert.equal(await afterLogout.vault.status(), "locked");
  assert.deepEqual(legacyRepository.rememberedSession(), legacyRemembered);
});

test("account A logout then account B in one browser keeps account-scoped devices and the Vault actor", async () => {
  assert.equal(typeof vaultLocal.accountDeviceStorageKey, "function");
  assert.equal(typeof vaultLocal.createAccountDeviceCoordinator, "function");
  const mappings = new Map();
  const repository = {
    async loadAccountDevice(key) { return mappings.get(key) ?? null; },
    async saveAccountDeviceIfAbsent(key, value) {
      if (!mappings.has(key)) mappings.set(key, value);
      return mappings.get(key);
    },
    async replaceAccountDevice(key, expected, replacement) {
      const current = mappings.get(key) ?? null;
      if (current !== null && current.deviceID !== expected.deviceID) return current;
      mappings.set(key, replacement);
      return replacement;
    },
  };
  const replacement = "22222222-2222-4222-8222-222222222222";
  const coordinatorForAccountA = vaultLocal.createAccountDeviceCoordinator({
    repository,
    legacyDeviceID: async () => deviceID,
    cryptoValue: webcrypto,
    randomUUID: () => replacement,
  });
  const key = await vaultLocal.accountDeviceStorageKey(" User@Example.COM ", webcrypto);

  assert.equal(key, "account-device:v1:TH8TsPIDs1myP7WbqTNTAFGl0Z9naZWeFi4lJFMZdkM");
  assert.equal(key.includes("user@example.com"), false);
  assert.equal(await coordinatorForAccountA.deviceID("account-a@example.com"), deviceID);
  assert.equal(await coordinatorForAccountA.remember("account-a@example.com", deviceID), deviceID);
  await coordinatorForAccountA.accepted("account-a@example.com", deviceID);

  // A new coordinator models the browser runtime after account A logs out.
  let replacementCalls = 0;
  const coordinatorForAccountB = vaultLocal.createAccountDeviceCoordinator({
    repository,
    legacyDeviceID: async () => deviceID,
    cryptoValue: webcrypto,
    randomUUID: () => {
      replacementCalls += 1;
      return replacementCalls === 1 ? replacement : "33333333-3333-4333-8333-333333333333";
    },
  });
  assert.equal(await coordinatorForAccountB.deviceID("user@example.com"), deviceID);
  assert.equal(await coordinatorForAccountB.remember("user@example.com", deviceID), deviceID);
  assert.equal(await coordinatorForAccountB.replaceAfterConflict("USER@example.com", deviceID), replacement);
  assert.equal(await coordinatorForAccountB.replaceAfterConflict("user@example.com", deviceID), replacement);
  assert.equal(replacementCalls, 1);
  await coordinatorForAccountB.accepted("user@example.com", replacement);
  assert.equal(await coordinatorForAccountB.deviceID(" user@example.com "), replacement);
  assert.equal(await coordinatorForAccountB.deviceID("account-a@example.com"), deviceID);
  assert.equal(await coordinatorForAccountA.replaceAfterConflict("account-a@example.com", deviceID), null);

  const localRepository = memoryRepository();
  const vault = controller(localRepository);
  await vault.create(passphrase);
  assert.equal(await vault.deviceID(), deviceID);
  assert.equal(localRepository.snapshot().deviceID, deviceID);
});

test("lock drops the in-memory key and wrong recovery passphrases fail closed", async () => {
  const repository = memoryRepository();
  const vault = controller(repository);
  await vault.create(passphrase);
  vault.lock();

  assert.throws(() => vault.document(), /local_vault_locked/);
  await assert.rejects(vault.unlock("a different long recovery passphrase"), /invalid_recovery_passphrase/);
  assert.throws(() => vault.document(), /local_vault_locked/);
  assert.deepEqual(await vault.unlock(passphrase), { schemaVersion: 1, records: [], tombstones: [] });
  await assert.rejects(vault.unlock("another incorrect recovery phrase"), /invalid_recovery_passphrase/);
  assert.throws(() => vault.document(), /local_vault_locked/);
});

test("an unlocked tab can hand its in-memory key to another tab without persisting it", async () => {
  const repository = memoryRepository();
  const firstTab = controller(repository);
  await firstTab.create(passphrase);
  await firstTab.upsert({ type: "host", data: { title: "Shared tab", address: "tab.invalid" } });

  const secondTab = controller(repository);
  assert.equal(await secondTab.status(), "locked");
  const keyClone = structuredClone(firstTab.sessionKey());
  assert.equal((await secondTab.unlockWithSessionKey(keyClone)).records[0].data.title, "Shared tab");

  secondTab.lock();
  const wrongKey = await webcrypto.subtle.generateKey(
    { name: "AES-GCM", length: 256 },
    true,
    ["encrypt", "decrypt"],
  );
  await assert.rejects(secondTab.unlockWithSessionKey(wrongKey));
  assert.equal(await secondTab.status(), "locked");
});

test("a trusted browser restores a non-extractable Vault key only for the authenticated account", async () => {
  const accountID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
  const otherAccountID = "ffffffff-ffff-4fff-8fff-ffffffffffff";
  const repository = memoryRepository();
  const firstPage = controller(repository);
  await firstPage.create(passphrase);
  await firstPage.upsert({ type: "host", data: { title: "After reload", address: "reload.invalid" } });

  assert.equal(await firstPage.rememberSession(accountID), true);
  assert.equal(JSON.stringify(repository.rememberedSession()).includes(passphrase), false);
  firstPage.lock();

  const wrongAccountPage = controller(repository);
  assert.equal(await wrongAccountPage.restoreRememberedSession(otherAccountID), false);
  assert.equal(await wrongAccountPage.status(), "locked");

  await firstPage.unlock(passphrase);
  assert.equal(await firstPage.rememberSession(accountID), true);
  firstPage.lock();
  const reloadedPage = controller(repository);
  assert.equal(await reloadedPage.restoreRememberedSession(accountID), true);
  assert.equal(reloadedPage.sessionKey().extractable, false);
  assert.equal(reloadedPage.document().records[0].data.title, "After reload");

  await reloadedPage.forgetRememberedSession();
  reloadedPage.lock();
  assert.equal(await reloadedPage.restoreRememberedSession(accountID), false);
});

test("rewrap migrates an unlocked Vault to a new account passphrase", async () => {
  const repository = memoryRepository();
  const vault = controller(repository);
  await vault.create(passphrase);
  await vault.upsert({ type: "credential", data: { title: "Admin", secret: "synthetic-secret" } });
  const previousRevision = repository.snapshot().revision;
  const accountPassphrase = "selective-remote:account-password:v1:strong account password";

  await vault.rewrap(accountPassphrase);
  assert.equal(repository.snapshot().revision, previousRevision + 1);
  vault.lock();
  await assert.rejects(vault.unlock(passphrase), /invalid_recovery_passphrase/);
  assert.equal((await vault.unlock(accountPassphrase)).records[0].data.secret, "synthetic-secret");
});

test("all personal record types round-trip and every mutation advances the encrypted revision", async () => {
  const repository = memoryRepository();
  const vault = controller(repository);
  await vault.create(passphrase);

  await vault.upsert({ type: "host", data: { title: "Host", address: "example.invalid" } });
  await vault.upsert({ type: "credential", data: { title: "Admin", username: "root", secret: "synthetic-secret" } });
  await vault.upsert({ type: "snippet", data: { title: "Check", body: "uptime" } });
  await vault.upsert({ type: "forwarding", data: { title: "DB", destination: "db.invalid:5432" } });

  assert.deepEqual(vault.document().records.map((record) => record.type), [
    "host", "credential", "snippet", "forwarding",
  ]);
  assert.equal(repository.snapshot().revision, 5);
  assert.equal(JSON.stringify(repository.snapshot()).includes("synthetic-secret"), false);

  vault.lock();
  await vault.unlock(passphrase);
  assert.equal(vault.document().records[1].data.secret, "synthetic-secret");
});

test("deletion writes an encrypted tombstone and cannot resurrect the record after unlock", async () => {
  const repository = memoryRepository();
  const vault = controller(repository);
  await vault.create(passphrase);
  const id = await vault.upsert({ type: "host", data: { title: "Disposable", address: "test.invalid" } });
  await vault.delete(id);

  assert.equal(vault.document().records.length, 0);
  assert.equal(vault.document().tombstones[0].id, id);
  assert.equal(JSON.stringify(repository.snapshot()).includes("Disposable"), false);
  vault.lock();
  await vault.unlock(passphrase);
  assert.equal(vault.document().records.length, 0);
  assert.equal(vault.document().tombstones.length, 1);
});

test("malformed local snapshots and revision mismatches are rejected before decryption", async () => {
  const repository = memoryRepository();
  const vault = controller(repository);
  await vault.create(passphrase);
  const valid = repository.snapshot();

  const extra = controller(memoryRepository({ ...valid, plaintext: {} }));
  await assert.rejects(extra.unlock(passphrase), /invalid_local_vault/);

  const mismatch = controller(memoryRepository({ ...valid, revision: valid.revision + 1 }));
  await assert.rejects(mismatch.unlock(passphrase), /invalid_local_vault/);
});

test("failed storage commits leave the unlocked document unchanged", async () => {
  const base = memoryRepository();
  const vault = controller(base);
  await vault.create(passphrase);
  const failing = {
    load: () => base.load(),
    async save() { throw new Error("storage_failed"); },
  };
  const recovered = controller(failing, [recordIDs[0]]);
  await recovered.unlock(passphrase);

  await assert.rejects(
    recovered.upsert({ type: "snippet", data: { title: "Never committed", body: "secret" } }),
    /storage_failed/,
  );
  assert.deepEqual(recovered.document(), { schemaVersion: 1, records: [], tombstones: [] });
});
