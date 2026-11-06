import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { IDBFactory } from "fake-indexeddb";
import { authorizeVaultStorageUpgrade, openVaultStorage } from "../public/vault-storage.js";
import { createIndexedDBVaultRepository, createLocalVaultController } from "../public/vault-local.js";
import { createIndexedDBTeamDeviceRepository } from "../public/team-vault-crypto.js";
import { createIndexedDBTeamVaultRepository } from "../public/team-vault-sync.js";

const databaseName = "selective-remote-cloud";
const storeName = "local-vault";
const accountID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const deviceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const scope = { type: "team", teamID: accountID, vaultID: deviceID };
const passphrase = "synthetic test passphrase";

function openLegacy(indexedDB) {
  const request = indexedDB.open(databaseName, 1);
  request.onupgradeneeded = () => request.result.createObjectStore(storeName);
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function put(database, key, value) {
  return new Promise((resolve, reject) => {
    const tx = database.transaction(storeName, "readwrite");
    tx.objectStore(storeName).put(value, key);
    tx.oncomplete = resolve;
    tx.onabort = () => reject(tx.error);
  });
}

test("an existing legacy database is not upgraded before the user can save other tabs", async () => {
  const indexedDB = new IDBFactory();
  const old = await openLegacy(indexedDB);
  await put(old, "legacy-copy", { ciphertext: "preserved" });
  old.close();

  await assert.rejects(createIndexedDBVaultRepository(indexedDB).load(), /vault_storage_upgrade_confirmation_required/u);
  const reopened = await openLegacy(indexedDB);
  const read = reopened.transaction(storeName).objectStore(storeName).get("legacy-copy");
  const saved = await new Promise((resolve, reject) => {
    read.onsuccess = () => resolve(read.result);
    read.onerror = () => reject(read.error);
  });
  reopened.close();
  assert.deepEqual(saved, { ciphertext: "preserved" });
});

test("before approval the probe never queues a version upgrade, even while an old connection is open", async () => {
  const indexedDB = new IDBFactory();
  const old = await openLegacy(indexedDB);
  const calls = [];
  const inspected = { open(...args) { calls.push(args); return indexedDB.open(...args); } };
  try {
    await assert.rejects(createIndexedDBVaultRepository(inspected).load(), /vault_storage_upgrade_confirmation_required/u);
    assert.deepEqual(calls, [[databaseName]]);
    const anotherOldConnection = await openLegacy(indexedDB);
    await put(anotherOldConnection, "unsaved-editor-example", { ciphertext: "saved before approval" });
    anotherOldConnection.close();
  } finally { old.close(); }
});

test("probing an absent database does not create it before approval", async () => {
  const indexedDB = new IDBFactory();
  await assert.rejects(createIndexedDBVaultRepository(indexedDB).load(), /vault_storage_upgrade_confirmation_required/u);
  assert.deepEqual(await indexedDB.databases(), []);
});

test("an old browser writer cannot replace a newer Personal Vault snapshot", async () => {
  const indexedDB = new IDBFactory();
  const oldConnection = await openLegacy(indexedDB);
  oldConnection.close();
  authorizeVaultStorageUpgrade(indexedDB);
  const repository = createIndexedDBVaultRepository(indexedDB).forAccount(accountID);
  const vault = createLocalVaultController({ repository, cryptoValue: webcrypto });
  await vault.create(passphrase);
  await vault.upsert({ type: "host", data: { title: "New", address: "new.invalid" } });
  const newerSnapshot = await repository.load();

  await assert.rejects(async () => {
    const legacy = await openLegacy(indexedDB);
    try {
      const key = `personal-account:v1:${accountID}:snapshot`;
      await put(legacy, key, { obsolete: true });
    } finally { legacy.close(); }
  }, error => error?.name === "VersionError");

  assert.deepEqual(await repository.load(), newerSnapshot);
  const reopened = createLocalVaultController({ repository, cryptoValue: webcrypto });
  await reopened.unlock(passphrase);
  assert.deepEqual(reopened.document().records.map(record => record.data.address), ["new.invalid"]);
});

for (const [name, useStorage] of [
  ["Personal", indexedDB => createIndexedDBVaultRepository(indexedDB).load()],
  ["Team device", indexedDB => createIndexedDBTeamDeviceRepository(indexedDB).load(deviceID)],
  ["Team Vault", indexedDB => createIndexedDBTeamVaultRepository(scope, indexedDB).load(deviceID)],
]) {
  test(`${name} storage fences legacy opens and preserves pre-existing records`, async () => {
    const indexedDB = new IDBFactory();
    const old = await openLegacy(indexedDB);
    await put(old, "preserved-synthetic-record", { ciphertext: "opaque" });
    old.close();
    authorizeVaultStorageUpgrade(indexedDB);

    assert.equal(await useStorage(indexedDB), null);
    await assert.rejects(openLegacy(indexedDB), error => error?.name === "VersionError");
    const request = indexedDB.open(databaseName);
    const database = await new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
    const preserved = await new Promise((resolve, reject) => {
      const tx = database.transaction(storeName), read = tx.objectStore(storeName).get("preserved-synthetic-record");
      read.onsuccess = () => resolve(read.result);
      read.onerror = () => reject(read.error);
    });
    database.close();
    assert.deepEqual(preserved, { ciphertext: "opaque" });
  });
}

test("a blocked upgrade is cancelled and does not later alter the legacy database", async () => {
  const indexedDB = new IDBFactory();
  const old = await openLegacy(indexedDB);
  let blocked;
  try {
    await put(old, "in-flight", { revision: 1 });
    const repository = createIndexedDBVaultRepository(indexedDB);
    authorizeVaultStorageUpgrade(indexedDB);
    await assert.rejects(repository.load(), error => {
      blocked = error;
      return error.message === "vault_storage_upgrade_blocked" && typeof error.settled?.then === "function";
    });
    await put(old, "in-flight", { revision: 2 });
  } finally { old.close(); }

  await blocked.settled;
  const reopened = await openLegacy(indexedDB);
  const value = await new Promise((resolve, reject) => {
    const tx = reopened.transaction(storeName), read = tx.objectStore(storeName).get("in-flight");
    read.onsuccess = () => resolve(read.result);
    read.onerror = () => reject(read.error);
  });
  reopened.close();
  assert.deepEqual(value, { revision: 2 });
  const repository = createIndexedDBVaultRepository(indexedDB);
  await assert.rejects(repository.load(), /vault_storage_upgrade_confirmation_required/u);
  authorizeVaultStorageUpgrade(indexedDB);
  assert.equal(await repository.load(), null);
  await assert.rejects(openLegacy(indexedDB), error => error?.name === "VersionError");
});

test("a probe queued behind another blocked upgrade times out without changing the old database", { timeout: 1000 }, async () => {
  const indexedDB = new IDBFactory();
  const old = await openLegacy(indexedDB);
  authorizeVaultStorageUpgrade(indexedDB);
  let firstError;
  try {
    await assert.rejects(openVaultStorage(indexedDB, "unavailable"), error => {
      firstError = error;
      return error.message === "vault_storage_upgrade_blocked";
    });
    await assert.rejects(openVaultStorage(indexedDB, "unavailable", { probeTimeoutMs: 25 }), /vault_storage_probe_waiting/u);
  } finally { old.close(); }
  await firstError.settled;
  const reopened = await openLegacy(indexedDB);
  assert.equal(reopened.version, 1);
  reopened.close();
});
