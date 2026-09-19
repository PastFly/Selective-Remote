import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import * as vaultLocal from "../public/vault-local.js";

const { createLocalVaultController } = vaultLocal;

const passphrase = "correct horse battery staple for local recovery";
const deviceID = "11111111-1111-4111-8111-111111111111";
const recordIDs = [
  "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
];

function memoryRepository(initial = null) {
  let value = initial;
  let sessionDeviceKey = null;
  let sessionUnlock = null;
  return {
    async load() { return value ? structuredClone(value) : null; },
    async save(next) { value = structuredClone(next); },
    async loadSessionDeviceKey() { return sessionDeviceKey ? structuredClone(sessionDeviceKey) : null; },
    async saveSessionDeviceKey(next) { sessionDeviceKey = structuredClone(next); },
    async loadSessionUnlock() { return sessionUnlock ? structuredClone(sessionUnlock) : null; },
    async saveSessionUnlock(next) { sessionUnlock = structuredClone(next); },
    async deleteSessionUnlock() { sessionUnlock = null; },
    snapshot() { return value ? structuredClone(value) : null; },
    rememberedSession() { return sessionUnlock ? structuredClone(sessionUnlock) : null; },
  };
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
