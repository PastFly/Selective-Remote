import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { IDBFactory } from "./approved-idb-fixture.mjs";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import { createAuthenticatedVaultClient } from "../public/vault-sync.js";
import {
  createIndexedDBTeamVaultRepository,
  createTeamVaultController,
  provisionTeamVaultWrappers,
  rotateTeamVault,
  synchronizeTeamVault,
} from "../public/team-vault-sync.js";

const teamID = "11111111-1111-4111-8111-111111111111";
const vaultID = "22222222-2222-4222-8222-222222222222";
const deviceA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const deviceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const membershipA = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const membershipB = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const recordID = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
const scope = { type: "team", teamID, vaultID };

function memoryRepository() {
  let value = null;
  return {
    async load() { return value ? structuredClone(value) : null; },
    async save(next) { value = structuredClone(next); },
    async remove() { value = null; },
    inspect() { return value; },
  };
}

async function device(deviceID, membershipID) {
  const identity = { deviceID, ...await generateTeamDeviceIdentity(webcrypto) };
  return {
    identity,
    keyDevice: {
      deviceID,
      membershipID,
      membershipEpoch: 1,
      publicKeyAlgorithm: "p256-ecdh-v1",
      publicKey: identity.publicKey,
    },
  };
}

function sharedServer(keyDevices) {
  let revision = 0;
  let keyGeneration = 1;
  let rotationRequired = false;
  let currentKeyDevices = keyDevices;
  let envelope = null;
  let wrappers = new Map();
  function clientFor(deviceID) {
    return {
      session() { return { id: "99999999-9999-4999-8999-999999999999" }; },
      async listTeamKeyDevices() {
        return {
          scope,
          devices: currentKeyDevices.map((device) => ({
            ...device,
            hasWrapper: wrappers.has(device.deviceID),
          })),
        };
      },
      async getTeamVault() {
        return {
          scope,
          id: vaultID,
          teamID,
          name: "Operations",
          revision,
          keyGeneration,
          rotationRequired,
          envelopeVersion: envelope?.envelopeVersion ?? null,
          ciphertext: envelope?.ciphertext ?? null,
          nonce: envelope?.nonce ?? null,
          authTag: envelope?.authTag ?? null,
          contentHash: envelope?.contentHash ?? null,
          wrapper: wrappers.get(deviceID) ?? null,
          createdAt: "2026-09-05T00:00:00.000Z",
          updatedAt: "2026-09-05T00:00:00.000Z",
        };
      },
      async putTeamVault(_scope, next) {
        if (next.baseRevision !== revision) return { conflict: true, revision, keyGeneration };
        const rotating = rotationRequired;
        if (rotating && next.keyGeneration !== keyGeneration + 1) throw new Error("invalid_key_generation");
        if (!rotating && next.keyGeneration !== keyGeneration) throw new Error("invalid_key_generation");
        if (next.wrappers) wrappers = new Map(next.wrappers.map((wrapper) => [wrapper.deviceID, wrapper]));
        envelope = { ...next };
        delete envelope.wrappers;
        revision += 1;
        keyGeneration = next.keyGeneration;
        rotationRequired = false;
        return { conflict: false, revision, keyGeneration, rotationCompleted: rotating };
      },
      async grantTeamVaultWrapper(_scope, next) {
        if (next.keyGeneration !== keyGeneration) throw new Error("invalid_key_generation");
        wrappers.set(next.wrapper.deviceID, next.wrapper);
        return {
          granted: true,
          keyGeneration,
          deviceID: next.wrapper.deviceID,
        };
      },
    };
  }
  return {
    clientFor,
    revision: () => revision,
    inspect: () => ({ revision, keyGeneration, rotationRequired, envelope, wrappers: new Map(wrappers) }),
    addKeyDevice(nextKeyDevice) {
      currentKeyDevices = [...currentKeyDevices, nextKeyDevice];
    },
    requireRotation(nextKeyDevices) {
      currentKeyDevices = nextKeyDevices;
      rotationRequired = true;
    },
  };
}

function pauseAfterNextCommittedSave(repository) {
  let armed = false;
  let reachedCommit, releaseSave;
  const committed = new Promise(resolve => { reachedCommit = resolve; });
  const released = new Promise(resolve => { releaseSave = resolve; });
  return {
    repository: {
      ...repository,
      async save(...args) {
        const result = await repository.save(...args);
        if (armed) {
          armed = false;
          reachedCommit();
          await released;
        }
        return result;
      },
    },
    arm() { armed = true; },
    committed,
    release() { releaseSave(); },
  };
}

async function interruptBetweenRecordSteps({ controller, pause, acknowledgement, secondStep }) {
  pause.arm();
  const marking = controller.markSynced(acknowledgement);
  let timer;
  try {
    await Promise.race([
      pause.committed,
      marking.then(() => { throw new Error("sync_acknowledgement_was_not_paused"); }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("sync_acknowledgement_did_not_commit")), 5000); }),
    ]);
    await assert.rejects(secondStep(), /team_vault_operation_in_progress/u);
  } finally {
    clearTimeout(timer);
    pause.release();
    await marking;
  }
}

const hostRecord = { id: recordID, type: "host", data: { title: "Synthetic host", address: "synthetic.invalid" } };
const credentialID = "ffffffff-ffff-4fff-8fff-ffffffffffff";
const credentialRecord = { id: credentialID, type: "credential", data: {
  title: "Synthetic credential", username: "synthetic", secret: "synthetic", kind: "ssh", sourceID: recordID,
} };

async function compoundTestFixture() {
  const a = await device(deviceA, membershipA);
  const server = sharedServer([a.keyDevice]);
  const client = server.clientFor(deviceA);
  const pause = pauseAfterNextCommittedSave(createIndexedDBTeamVaultRepository(scope, new IDBFactory()));
  const controller = createTeamVaultController({ repository: pause.repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client, controller, role: "owner" });
  return { a, server, client, pause, controller };
}

async function prepareAcceptedAcknowledgement({ server, client, controller }) {
  const prepared = await controller.prepareUpload(server.revision());
  const accepted = await client.putTeamVault(scope, prepared.envelope);
  assert.equal(accepted.conflict, false);
  return { serverRevision: accepted.revision, localRevision: prepared.localRevision,
    serverContentHash: prepared.envelope.contentHash };
}

async function readFromFreshDeviceStore({ a, client }) {
  const observer = createTeamVaultController({
    repository: createIndexedDBTeamVaultRepository(scope, new IDBFactory()), identity: a.identity, scope, cryptoValue: webcrypto,
  });
  await synchronizeTeamVault({ client, controller: observer, role: "owner" });
  return observer.document();
}

test("uncontended Host and Credential steps persist together and can be deleted together", async () => {
  const fixture = await compoundTestFixture();
  const { controller, client } = fixture;
  await controller.upsert(hostRecord);
  await controller.upsert(credentialRecord);
  await synchronizeTeamVault({ client, controller, role: "owner" });
  const saved = await readFromFreshDeviceStore(fixture);
  assert.deepEqual(saved.records.map(record => record.id).sort(), [recordID, credentialID].sort());
  await controller.delete(credentialID);
  await controller.delete(recordID);
  await synchronizeTeamVault({ client, controller, role: "owner" });
  const deleted = await readFromFreshDeviceStore(fixture);
  assert.deepEqual(deleted.records, []);
  assert.deepEqual(deleted.tombstones.map(record => record.id).sort(), [recordID, credentialID].sort());
});

// The fake server, synthetic records and separate in-memory IndexedDB stores contain no user data.
test("an interrupted atomic Host and Credential creation commits neither and can be retried", async () => {
  const fixture = await compoundTestFixture();
  const { controller, pause, client } = fixture;
  assert.equal(typeof controller.applyBatch, "function");
  const acknowledgement = await prepareAcceptedAcknowledgement(fixture);
  const operations = [{ op: "upsert", record: hostRecord }, { op: "upsert", record: credentialRecord }];
  await interruptBetweenRecordSteps({ controller, pause, acknowledgement, secondStep: () => controller.applyBatch(operations) });
  controller.lock();
  const reloaded = await controller.unlock();
  const failedSave = { hosts: reloaded.records.filter(record => record.type === "host").length,
    credentials: reloaded.records.filter(record => record.type === "credential").length };
  await synchronizeTeamVault({ client, controller, role: "owner" });
  const remote = await readFromFreshDeviceStore(fixture);
  const uploaded = { hosts: remote.records.filter(record => record.type === "host").length,
    credentials: remote.records.filter(record => record.type === "credential").length };
  await controller.applyBatch(operations);
  const retry = { hosts: controller.document().records.filter(record => record.type === "host").length,
    credentials: controller.document().records.filter(record => record.type === "credential").length };
  assert.deepEqual({ failedSave, uploaded, retry }, {
    failedSave: { hosts: 0, credentials: 0 },
    uploaded: { hosts: 0, credentials: 0 },
    retry: { hosts: 1, credentials: 1 },
  });
});

test("an interrupted atomic Host deletion preserves both records", async () => {
  const fixture = await compoundTestFixture();
  const { controller, pause, client } = fixture;
  assert.equal(typeof controller.applyBatch, "function");
  await controller.upsert(hostRecord);
  await controller.upsert(credentialRecord);
  await synchronizeTeamVault({ client, controller, role: "owner" });
  const acknowledgement = await prepareAcceptedAcknowledgement(fixture);
  await interruptBetweenRecordSteps({ controller, pause, acknowledgement, secondStep: () => controller.applyBatch([
    { op: "delete", id: credentialID }, { op: "delete", id: recordID },
  ]) });
  controller.lock();
  const reloaded = await controller.unlock();
  await synchronizeTeamVault({ client, controller, role: "owner" });
  const remote = await readFromFreshDeviceStore(fixture);
  const state = document => ({
    host: document.records.some(record => record.id === recordID),
    credential: document.records.some(record => record.id === credentialID),
    credentialTombstone: document.tombstones.some(record => record.id === credentialID),
  });
  assert.deepEqual({ local: state(reloaded), uploaded: state(remote) }, {
    local: { host: true, credential: true, credentialTombstone: false },
    uploaded: { host: true, credential: true, credentialTombstone: false },
  });
});

test("an atomic batch preserves record links and version increments on update and deletion", async () => {
  const { controller } = await compoundTestFixture();
  assert.equal(typeof controller.applyBatch, "function");
  await controller.applyBatch([{ op: "upsert", record: hostRecord }, { op: "upsert", record: credentialRecord }]);
  await controller.applyBatch([
    { op: "upsert", record: { ...hostRecord, data: { ...hostRecord.data, favorite: true } } },
    { op: "delete", id: credentialID },
  ]);
  controller.lock();
  const document = await controller.unlock();
  const host = document.records.find(record => record.id === recordID);
  const credentialTombstone = document.tombstones.find(record => record.id === credentialID);
  assert.equal(host.data.favorite, true);
  assert.equal(host.version[deviceA], 2);
  assert.equal(credentialTombstone.version[deviceA], 2);
});

test("an invalid later batch operation leaves the entire IndexedDB snapshot unchanged", async () => {
  const { controller } = await compoundTestFixture();
  assert.equal(typeof controller.applyBatch, "function");
  await assert.rejects(controller.applyBatch([
    { op: "upsert", record: hostRecord },
    { op: "delete", id: credentialID },
  ]), /record_not_found/u);
  controller.lock();
  assert.deepEqual((await controller.unlock()).records, []);
});

test("a failed IndexedDB batch save leaves the old snapshot intact", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const base = createIndexedDBTeamVaultRepository(scope, new IDBFactory());
  let failSave = false;
  const repository = { ...base, async save(...args) {
    if (failSave) throw new Error("synthetic_storage_failure");
    return base.save(...args);
  } };
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller, role: "owner" });
  failSave = true;
  await assert.rejects(controller.applyBatch([
    { op: "upsert", record: hostRecord }, { op: "upsert", record: credentialRecord },
  ]), /synthetic_storage_failure/u);
  failSave = false;
  controller.lock();
  assert.deepEqual((await controller.unlock()).records, []);
});

test("a batch based on a stale tab cannot replace another tab's complete batch", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const indexedDB = new IDBFactory();
  const makeController = () => createTeamVaultController({
    repository: createIndexedDBTeamVaultRepository(scope, indexedDB), identity: a.identity, scope, cryptoValue: webcrypto,
  });
  const first = makeController(), stale = makeController();
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: first, role: "owner" });
  await stale.unlock();
  await first.applyBatch([{ op: "upsert", record: hostRecord }, { op: "upsert", record: credentialRecord }]);
  await assert.rejects(stale.applyBatch([{ op: "upsert", record: hostRecord }]), /team_vault_stale_snapshot/u);
  first.lock();
  assert.deepEqual((await first.unlock()).records.map(record => record.id).sort(), [recordID, credentialID].sort());
});

test("locking before batch encryption completes prevents the batch from being saved", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  let armed = false, entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const subtle = new Proxy(webcrypto.subtle, { get(target, name) {
    if (name === "encrypt") return async (...args) => {
      if (armed) { armed = false; entered(); await held; }
      return target.encrypt(...args);
    };
    const value = Reflect.get(target, name, target);
    return typeof value === "function" ? value.bind(target) : value;
  } });
  const cryptoValue = { subtle, getRandomValues: webcrypto.getRandomValues.bind(webcrypto), randomUUID: webcrypto.randomUUID.bind(webcrypto) };
  const controller = createTeamVaultController({ repository: createIndexedDBTeamVaultRepository(scope, new IDBFactory()),
    identity: a.identity, scope, cryptoValue });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller, role: "owner" });
  armed = true;
  const saving = controller.applyBatch([{ op: "upsert", record: hostRecord }, { op: "upsert", record: credentialRecord }]);
  try { await started; controller.lock(); } finally { release(); }
  await assert.rejects(saving, /team_vault_(locked|stale_snapshot)/u);
  assert.deepEqual((await controller.unlock()).records, []);
});

test("locking after a batch commits may reject its acknowledgement but preserves the whole batch", async () => {
  const { controller, pause } = await compoundTestFixture();
  assert.equal(typeof controller.applyBatch, "function");
  pause.arm();
  const saving = controller.applyBatch([{ op: "upsert", record: hostRecord }, { op: "upsert", record: credentialRecord }]);
  let timer;
  try {
    await Promise.race([
      pause.committed,
      saving.then(() => { throw new Error("batch_was_not_paused"); }),
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("batch_did_not_commit")), 5000); }),
    ]);
    controller.lock();
  } finally {
    clearTimeout(timer);
    pause.release();
  }
  await assert.rejects(saving, /team_vault_locked/u);
  const reloaded = await controller.unlock();
  assert.deepEqual(reloaded.records.map(record => record.id).sort(), [recordID, credentialID].sort());
  assert.equal(reloaded.records.find(record => record.id === credentialID).data.sourceID, recordID);
});

test("a batch waiting outside its storage transaction cannot commit after lock", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const base = createIndexedDBTeamVaultRepository(scope, new IDBFactory());
  let armed = false, entered, release;
  const started = new Promise(resolve => { entered = resolve; }), held = new Promise(resolve => { release = resolve; });
  const repository = { ...base, async save(...args) {
    if (armed) { armed = false; entered(); await held; }
    return base.save(...args);
  } };
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller, role: "owner" });
  armed = true;
  const saving = controller.applyBatch([{ op: "upsert", record: hostRecord }, { op: "upsert", record: credentialRecord }]);
  try { await started; controller.lock(); } finally { release(); }
  await assert.rejects(saving, /team_vault_locked/u);
  const reloaded = await controller.unlock();
  assert.deepEqual(reloaded.records, []);
});

test("a Team editor opened before a remote merge cannot overwrite the merged record", async () => {
  const application = await import("../public/app.js");
  assert.equal(typeof application.captureTeamRecordEditorSnapshot, "function");
  const { readFile } = await import("node:fs/promises"), { runInNewContext } = await import("node:vm");
  const a = await device(deviceA, membershipA), b = await device(deviceB, membershipB), server = sharedServer([a.keyDevice, b.keyDevice]);
  const makeController = identity => createTeamVaultController({ repository: createIndexedDBTeamVaultRepository(scope, new IDBFactory()), identity, scope, cryptoValue: webcrypto });
  const first = makeController(a.identity), second = makeController(b.identity);
  const clientA = server.clientFor(deviceA), clientB = server.clientFor(deviceB);
  await synchronizeTeamVault({ client: clientA, controller: first, role: "owner" });
  await first.upsert({ id: recordID, type: "host", data: { title: "Old title", address: "ssh://synthetic@old.invalid:22" } });
  await synchronizeTeamVault({ client: clientA, controller: first, role: "owner" });
  await synchronizeTeamVault({ client: clientB, controller: second, role: "editor" });
  const opened = first.document().records.find(record => record.id === recordID);
  const editorSnapshot = application.captureTeamRecordEditorSnapshot(first.document().records, opened);
  await second.upsert({ id: recordID, type: "host", data: { ...opened.data, address: "ssh://synthetic@new.invalid:22" } });
  await synchronizeTeamVault({ client: clientB, controller: second, role: "editor" });
  await synchronizeTeamVault({ client: clientA, controller: first, role: "owner" });
  assert.equal(first.document().records.find(record => record.id === recordID).data.address, "ssh://synthetic@new.invalid:22");

  const source = await readFile(new URL("../public/app.js", import.meta.url), "utf8");
  const start = source.indexOf('  recordForm.addEventListener("submit", async (event) => {', source.indexOf("export function initializeTeamWorkspace"));
  const end = source.indexOf("\n  recordCreate.addEventListener", start);
  assert.ok(start >= 0 && end > start);
  let submit, failure = null, resets = 0;
  const button = { disabled: false }, value = value => ({ value, disabled: false });
  const target = { controller: first, teamID, vaultID, sessionID: "synthetic-account", sessionGeneration: "1" };
  const recordForm = { addEventListener(_event, handler) { submit = handler; }, querySelector() { return button; } };
  const context = { recordForm, controller: first, editingPublication: null, canEdit: () => true, activeConflicts: null,
    selectedVault: { id: vaultID, rotationRequired: false }, recordSavePending: false, currentEditTarget: () => target,
    teamVaultEditTargetMatches: application.teamVaultEditTargetMatches, teamVaultRecordOperations: application.teamVaultRecordOperations,
    teamRecordEditorMatches: application.teamRecordEditorMatches, teamHostConnectionData: application.teamHostConnectionData,
    teamHostRecordData: application.teamHostRecordData, recordType: value("host"), recordTitle: value("Edited title"),
    recordTarget: value("old.invalid"), hostProtocol: value("ssh"), hostPort: value("22"), hostUsername: value("synthetic"),
    hostFolder: value(""), hostTags: value(""), hostDescription: value(""), hostRemovePassword: { checked: false }, hostPassword: value(""),
    editingRecordID: recordID, editingRecordSnapshot: editorSnapshot, draftRecordID: null, draftCredentialID: null,
    resetRecordEditor() { resets++; }, clearConflicts() {}, rotateButton: { disabled: false }, canManage: () => true, renderRecords() {},
    setText() {}, workspaceStatus: {}, documentValue: {}, showTeamVaultRecordSaveError({ error }) { failure = error.message; } };
  runInNewContext(source.slice(start, end), context);
  await submit({ preventDefault() {} });
  const record = first.document().records.find(value => value.id === recordID);
  assert.equal(record.data.address, "ssh://synthetic@new.invalid:22");
  assert.equal(record.data.title, "Old title");
  assert.equal(context.recordTitle.value, "Edited title");
  assert.equal(resets, 0);
  assert.equal(failure, "team_vault_editor_changed");
});

test("switching Team accounts preserves each device's encrypted local changes", async () => {
  const indexedDB = new IDBFactory();
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const legacy = createIndexedDBTeamVaultRepository(scope, indexedDB);
  const oldRepository = memoryRepository();
  const oldController = createTeamVaultController({ repository: oldRepository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: oldController, role: "owner" });
  await oldController.upsert({ id: recordID, type: "host", data: { title: "Unsynced A", address: "a.invalid" } });
  await legacy.save(oldRepository.inspect());
  const legacyBefore = await legacy.load();
  oldController.lock();

  const repoB = createIndexedDBTeamVaultRepository(scope, indexedDB);
  const controllerB = createTeamVaultController({ repository: repoB, identity: b.identity, scope, cryptoValue: webcrypto });
  assert.deepEqual(await synchronizeTeamVault({ client: server.clientFor(deviceB), controller: controllerB, role: "editor" }),
    { status: "downloaded", revision: 1 });
  assert.deepEqual(controllerB.document().records, []);
  await assert.rejects(repoB.save(legacyBefore, deviceB), /invalid_local_team_vault/u);
  assert.deepEqual(await legacy.load(), legacyBefore);

  const repoA = createIndexedDBTeamVaultRepository(scope, indexedDB);
  const controllerA = createTeamVaultController({ repository: repoA, identity: a.identity, scope, cryptoValue: webcrypto });
  assert.equal(await controllerA.status(), "locked");
  const restored = await controllerA.unlock();
  assert.equal(restored.records[0].data.title, "Unsynced A");
  assert.equal((await controllerA.syncState()).dirty, true);
  await controllerA.upsert({ type: "snippet", data: { title: "Still local", body: "echo preserved" } });
  controllerB.lock();
  assert.deepEqual((await controllerB.unlock()).records, []);

  await repoB.remove(deviceB);
  controllerA.lock();
  assert.equal((await controllerA.unlock()).records.find(record => record.id === recordID).data.title, "Unsynced A");
  assert.equal(controllerA.document().records.length, 2);
});

test("an older browser tab cannot overwrite a migrated device snapshot", async () => {
  const indexedDB = new IDBFactory();
  const a = await device(deviceA, membershipA);
  const server = sharedServer([a.keyDevice]);
  const oldRepository = memoryRepository();
  const old = createTeamVaultController({ repository: oldRepository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: old, role: "owner" });
  await old.upsert({ id: recordID, type: "host", data: { title: "Old", address: "old.invalid" } });
  const legacy = createIndexedDBTeamVaultRepository(scope, indexedDB);
  const oldSnapshot = structuredClone(oldRepository.inspect());
  await legacy.save(oldSnapshot);

  const current = createTeamVaultController({ repository: createIndexedDBTeamVaultRepository(scope, indexedDB), identity: a.identity, scope, cryptoValue: webcrypto });
  await current.unlock();
  await current.upsert({ type: "snippet", data: { title: "New", body: "echo local" } });
  assert.equal((await legacy.load()) === null, true);

  await legacy.save(oldSnapshot);
  await assert.rejects(current.upsert({ type: "snippet", data: { title: "Blocked", body: "echo blocked" } }), /team_vault_legacy_conflict/u);
  current.lock();
  await assert.rejects(current.unlock(), /team_vault_legacy_conflict/u);
  assert.deepEqual(await legacy.load(), oldSnapshot);
});

test("a legacy tab change during migration cannot be silently overwritten", async () => {
  const indexedDB = new IDBFactory();
  const a = await device(deviceA, membershipA);
  const server = sharedServer([a.keyDevice]);
  const oldRepository = memoryRepository();
  const old = createTeamVaultController({ repository: oldRepository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: old, role: "owner" });
  const legacy = createIndexedDBTeamVaultRepository(scope, indexedDB);
  await legacy.save(oldRepository.inspect());
  const current = createTeamVaultController({ repository: createIndexedDBTeamVaultRepository(scope, indexedDB), identity: a.identity, scope, cryptoValue: webcrypto });
  await current.unlock();

  await old.upsert({ id: recordID, type: "host", data: { title: "Old tab", address: "old.invalid" } });
  const changedLegacy = structuredClone(oldRepository.inspect());
  await legacy.save(changedLegacy);
  await assert.rejects(current.upsert({ type: "snippet", data: { title: "New tab", body: "echo local" } }), /team_vault_stale_snapshot/u);
  assert.deepEqual(await legacy.load(), changedLegacy);
});

test("concurrent tabs on one device cannot silently replace local changes", async () => {
  const indexedDB = new IDBFactory();
  const a = await device(deviceA, membershipA);
  const server = sharedServer([a.keyDevice]);
  const makeController = () => createTeamVaultController({ repository: createIndexedDBTeamVaultRepository(scope, indexedDB), identity: a.identity, scope, cryptoValue: webcrypto });
  const first = makeController();
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: first, role: "owner" });
  const second = makeController();
  await second.unlock();
  await first.upsert({ id: recordID, type: "host", data: { title: "First tab", address: "first.invalid" } });
  await assert.rejects(second.upsert({ type: "snippet", data: { title: "Second tab", body: "echo local" } }), /team_vault_stale_snapshot/u);
  first.lock();
  const restored = await first.unlock();
  assert.equal(restored.records.find(record => record.id === recordID).data.title, "First tab");
});

test("overlapping edits in one Team controller never silently replace a saved edit", async () => {
  const indexedDB = new IDBFactory(), a = await device(deviceA, membershipA);
  const server = sharedServer([a.keyDevice]);
  let armed = false, encryptions = 0, secondEntered, releaseSecond;
  const secondStarted = new Promise(resolve => { secondEntered = resolve; });
  const resumeSecond = new Promise(resolve => { releaseSecond = resolve; });
  const subtle = new Proxy(webcrypto.subtle, { get(target, name) {
    if (name === "encrypt") return async (...args) => {
      const attempt = armed ? ++encryptions : 0;
      const result = await target.encrypt(...args);
      if (attempt === 2) { secondEntered(); await resumeSecond; }
      return result;
    };
    const value = Reflect.get(target, name, target);
    return typeof value === "function" ? value.bind(target) : value;
  } });
  const cryptoValue = { subtle, getRandomValues: webcrypto.getRandomValues.bind(webcrypto), randomUUID: webcrypto.randomUUID.bind(webcrypto) };
  const controller = createTeamVaultController({ repository: createIndexedDBTeamVaultRepository(scope, indexedDB),
    identity: a.identity, scope, cryptoValue });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller, role: "owner" });
  armed = true;
  const first = controller.upsert({ id: recordID, type: "host", data: { title: "First", address: "first.invalid" } });
  const second = controller.upsert({ type: "snippet", data: { title: "Second", body: "echo second" } })
    .then(() => "saved", error => error.message);
  let timer;
  try {
    const progress = await Promise.race([secondStarted.then(() => "encrypting"), second, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("second_edit_did_not_reach_encryption")), 5000);
    })]);
    if (progress !== "encrypting") assert.equal(progress, "team_vault_operation_in_progress");
    await first;
  } finally { clearTimeout(timer); releaseSecond(); }
  const secondResult = await second;
  controller.lock();
  const restored = await controller.unlock();
  assert.equal(restored.records.find(record => record.id === recordID)?.data.address, "first.invalid");
  assert.ok(secondResult === "team_vault_operation_in_progress" || restored.records.some(record => record.data?.title === "Second"));
});

test("a Team Vault initializes for every approved device and persists ciphertext only", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const repository = memoryRepository();
  const controller = createTeamVaultController({
    repository,
    identity: a.identity,
    scope,
    cryptoValue: webcrypto,
  });

  assert.deepEqual(
    await synchronizeTeamVault({ client: server.clientFor(deviceA), controller, role: "owner" }),
    { status: "initialized", revision: 1 },
  );
  assert.equal(server.revision(), 1);
  assert.equal(await controller.status(), "unlocked");
  assert.deepEqual(controller.document(), { schemaVersion: 1, records: [], tombstones: [] });
  const stored = JSON.stringify(repository.inspect());
  assert.doesNotMatch(stored, /Operations|secret|"records":/u);
  assert.equal(repository.inspect().syncedLocalRevision, 1);
});

test("an unlocked member provisions missing wrappers without manager presence", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice]);
  const controllerA = createTeamVaultController({
    repository: memoryRepository(),
    identity: a.identity,
    scope,
    cryptoValue: webcrypto,
  });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: controllerA, role: "owner" });
  server.addKeyDevice(b.keyDevice);

  assert.deepEqual(
    await provisionTeamVaultWrappers({ client: server.clientFor(deviceA), controller: controllerA }),
    { status: "provisioned", keyGeneration: 1, eligible: 2, missing: 1, granted: 1 },
  );
  assert.equal(server.inspect().wrappers.has(deviceB), true);
  assert.deepEqual(
    await provisionTeamVaultWrappers({ client: server.clientFor(deviceA), controller: controllerA }),
    { status: "up_to_date", keyGeneration: 1, eligible: 2, missing: 0, granted: 0 },
  );

  const controllerB = createTeamVaultController({
    repository: memoryRepository(),
    identity: b.identity,
    scope,
    cryptoValue: webcrypto,
  });
  assert.deepEqual(
    await synchronizeTeamVault({ client: server.clientFor(deviceB), controller: controllerB, role: "viewer" }),
    { status: "downloaded", revision: 1 },
  );
  assert.deepEqual(controllerB.document(), { schemaVersion: 1, records: [], tombstones: [] });
});

test("temporary write stop keeps Team changes pending and never confirms upload", async () => {
  const a = await device(deviceA, membershipA);
  const server = sharedServer([a.keyDevice]);
  const repository = memoryRepository();
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  const stableClient = server.clientFor(deviceA);
  await synchronizeTeamVault({ client: stableClient, controller, role: "owner" });
  await controller.upsert({ id: recordID, type: "host", data: { title: "TEST-ONLY-CODEX-HOST", address: "192.0.2.10" } });
  const beforeDocument = structuredClone(controller.document());
  const beforeState = structuredClone(repository.inspect());
  const stoppedClient = { ...stableClient, async putTeamVault() { throw new Error("vault_write_temporarily_unavailable"); } };
  await assert.rejects(synchronizeTeamVault({ client: stoppedClient, controller, role: "owner" }), /vault_write_temporarily_unavailable/u);
  assert.deepEqual(controller.document(), beforeDocument);
  assert.deepEqual(repository.inspect(), beforeState);
  assert.ok(repository.inspect().localRevision > repository.inspect().syncedLocalRevision);
  assert.equal(repository.inspect().serverRevision, 1);
});

test("an interrupted first upload retries initialization with wrappers for every current device", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const repository = memoryRepository();
  const controller = createTeamVaultController({
    repository,
    identity: a.identity,
    scope,
    cryptoValue: webcrypto,
  });
  let interrupted = true;
  const stableClient = server.clientFor(deviceA);
  const client = {
    ...stableClient,
    async putTeamVault(...args) {
      if (interrupted) {
        interrupted = false;
        throw new Error("network_interrupted");
      }
      return stableClient.putTeamVault(...args);
    },
  };

  await assert.rejects(
    synchronizeTeamVault({ client, controller, role: "owner" }),
    /network_interrupted/u,
  );
  assert.equal(await controller.status(), "unlocked");
  assert.equal(repository.inspect().serverRevision, 0);
  assert.deepEqual(
    await synchronizeTeamVault({ client, controller, role: "owner" }),
    { status: "initialized", revision: 1 },
  );
  assert.equal(repository.inspect().syncedLocalRevision, 1);
});

test("an empty uncommitted initialization yields to a concurrently initialized remote Vault", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const repositoryA = memoryRepository();
  const repositoryB = memoryRepository();
  const controllerA = createTeamVaultController({ repository: repositoryA, identity: a.identity, scope, cryptoValue: webcrypto });
  const controllerB = createTeamVaultController({ repository: repositoryB, identity: b.identity, scope, cryptoValue: webcrypto });
  const stableClientA = server.clientFor(deviceA);
  const interruptedClientA = {
    ...stableClientA,
    async putTeamVault() { throw new Error("network_interrupted"); },
  };

  await assert.rejects(
    synchronizeTeamVault({ client: interruptedClientA, controller: controllerA, role: "owner" }),
    /network_interrupted/u,
  );
  assert.deepEqual(
    await synchronizeTeamVault({ client: server.clientFor(deviceB), controller: controllerB, role: "admin" }),
    { status: "initialized", revision: 1 },
  );
  assert.deepEqual(
    await synchronizeTeamVault({ client: stableClientA, controller: controllerA, role: "owner" }),
    { status: "downloaded", revision: 1 },
  );
  assert.equal(repositoryA.inspect().serverRevision, 1);
});

test("a changed uncommitted initialization is never discarded for a concurrent remote Vault", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const repositoryA = memoryRepository();
  const controllerA = createTeamVaultController({ repository: repositoryA, identity: a.identity, scope, cryptoValue: webcrypto });
  const controllerB = createTeamVaultController({ repository: memoryRepository(), identity: b.identity, scope, cryptoValue: webcrypto });
  const stableClientA = server.clientFor(deviceA);
  const interruptedClientA = {
    ...stableClientA,
    async putTeamVault() { throw new Error("network_interrupted"); },
  };

  await assert.rejects(
    synchronizeTeamVault({ client: interruptedClientA, controller: controllerA, role: "owner" }),
    /network_interrupted/u,
  );
  await controllerA.upsert({ type: "host", data: { title: "Local", address: "local.invalid" } });
  await synchronizeTeamVault({ client: server.clientFor(deviceB), controller: controllerB, role: "admin" });
  await assert.rejects(
    synchronizeTeamVault({ client: stableClientA, controller: controllerA, role: "owner" }),
    /team_vault_initialization_committed/u,
  );
  assert.equal(repositoryA.inspect().localRevision, 2);
  assert.equal(controllerA.document().records[0].data.title, "Local");
});

test("two Team devices preserve concurrent records until explicit conflict resolution", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const repositoryA = memoryRepository();
  const repositoryB = memoryRepository();
  const controllerA = createTeamVaultController({
    repository: repositoryA,
    identity: a.identity,
    scope,
    cryptoValue: webcrypto,
    now: () => "2026-09-05T01:00:00.000Z",
  });
  const controllerB = createTeamVaultController({
    repository: repositoryB,
    identity: b.identity,
    scope,
    cryptoValue: webcrypto,
    now: () => "2026-09-05T02:00:00.000Z",
  });
  const clientA = server.clientFor(deviceA);
  const clientB = server.clientFor(deviceB);

  await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  assert.deepEqual(
    await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" }),
    { status: "downloaded", revision: 1 },
  );
  await controllerA.upsert({ id: recordID, type: "host", data: { title: "A", address: "a.invalid" } });
  await controllerB.upsert({ id: recordID, type: "host", data: { title: "B", address: "b.invalid" } });
  assert.deepEqual(
    await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" }),
    { status: "uploaded", revision: 2 },
  );

  const before = repositoryB.inspect();
  const conflict = await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" });
  assert.equal(conflict.status, "conflict");
  assert.equal(server.revision(), 2);
  assert.deepEqual(repositoryB.inspect(), before);
  await controllerB.resolveConflicts({ revision: 2, resolutions: [{ id: recordID, choice: "local" }] });
  assert.deepEqual(await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" }),
    { status: "uploaded", revision: 3 });
  assert.equal(controllerB.document().records[0].data.title, "B");
});

test("a damaged same-revision Team Cloud copy is not overwritten", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = memoryRepository();
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  const client = server.clientFor(deviceA);
  await synchronizeTeamVault({ client, controller, role: "owner" });
  await controller.upsert({ id: recordID, type: "host", data: { title: "Offline", address: "offline.invalid" } });
  const before = repository.inspect(), envelope = server.inspect().envelope;
  envelope.ciphertext = (envelope.ciphertext[0] === "A" ? "B" : "A") + envelope.ciphertext.slice(1);
  await assert.rejects(synchronizeTeamVault({ client, controller, role: "owner" }), /team_vault_content_hash_mismatch/u);
  assert.equal(server.revision(), 1);
  assert.deepEqual(repository.inspect(), before);
});

test("legacy dirty Team metadata without a fingerprint never authorizes a write", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = memoryRepository();
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  const client = server.clientFor(deviceA);
  await synchronizeTeamVault({ client, controller, role: "owner" });
  const legacy = repository.inspect();
  delete legacy.serverContentHash;
  await repository.save(legacy);
  controller.lock();
  await controller.unlock();
  await controller.upsert({ id: recordID, type: "host", data: { title: "Offline", address: "offline.invalid" } });
  const before = repository.inspect();
  await assert.rejects(synchronizeTeamVault({ client, controller, role: "owner" }), /team_vault_history_unverified/u);
  assert.equal(server.revision(), 1);
  assert.deepEqual(repository.inspect(), before);
});

test("a different valid Team document at the same Cloud revision cannot be overwritten", async () => {
  const a = await device(deviceA, membershipA), b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]), repositoryA = memoryRepository();
  const local = createTeamVaultController({ repository: repositoryA, identity: a.identity, scope, cryptoValue: webcrypto });
  const other = createTeamVaultController({ repository: memoryRepository(), identity: b.identity, scope, cryptoValue: webcrypto });
  const clientA = server.clientFor(deviceA), clientB = server.clientFor(deviceB);
  await synchronizeTeamVault({ client: clientA, controller: local, role: "owner" });
  await synchronizeTeamVault({ client: clientB, controller: other, role: "editor" });
  await local.upsert({ id: recordID, type: "host", data: { title: "Local", address: "local.invalid" } });
  await other.upsert({ id: recordID, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  const changed = await other.prepareUpload(0), before = repositoryA.inspect();
  Object.assign(server.inspect().envelope, changed.envelope);
  await assert.rejects(synchronizeTeamVault({ client: clientA, controller: local, role: "owner" }), /team_vault_same_revision_changed/u);
  assert.equal(server.revision(), 1);
  assert.deepEqual(repositoryA.inspect(), before);
});

test("a clean legacy Team copy pins the matching Cloud fingerprint before later edits", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = memoryRepository();
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  const client = server.clientFor(deviceA);
  await synchronizeTeamVault({ client, controller, role: "owner" });
  const legacy = repository.inspect();
  delete legacy.serverContentHash;
  await repository.save(legacy);
  controller.lock();
  await controller.unlock();
  assert.deepEqual(await synchronizeTeamVault({ client, controller, role: "owner" }), { status: "up_to_date", revision: 1 });
  assert.equal(repository.inspect().serverContentHash, server.inspect().envelope.contentHash);
  await controller.upsert({ id: recordID, type: "host", data: { title: "Local", address: "local.invalid" } });
  assert.deepEqual(await synchronizeTeamVault({ client, controller, role: "owner" }), { status: "uploaded", revision: 2 });
});

test("a changed session cannot pin a delayed legacy Team fingerprint", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory());
  let armed = false, enter, release, epoch = "1";
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, async save(...args) {
    if (armed) { enter(); await held; }
    return repository.save(...args);
  } };
  const controller = createTeamVaultController({ repository: delayed, identity: a.identity, scope, cryptoValue: webcrypto });
  const client = { ...server.clientFor(deviceA), sessionGeneration: () => epoch, deviceID: () => deviceA };
  await synchronizeTeamVault({ client, controller, role: "owner" });
  const snapshot = await repository.load(deviceA), legacy = structuredClone(snapshot);
  delete legacy.serverContentHash;
  await repository.save(legacy, deviceA, snapshot);
  controller.lock();
  await controller.unlock();
  armed = true;
  const pending = synchronizeTeamVault({ client, controller, role: "owner" });
  await started;
  epoch = "2";
  release();
  await assert.rejects(pending, /authentication_required/u);
  assert.deepEqual(await repository.load(deviceA), legacy);
});

test("rotation and unapproved-device states fail closed without replacing local ciphertext", async () => {
  const a = await device(deviceA, membershipA);
  const repository = memoryRepository();
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  const client = {
    session() { return { id: "99999999-9999-4999-8999-999999999999" }; },
    async getTeamVault() {
      return {
        scope,
        revision: 1,
        keyGeneration: 2,
        rotationRequired: true,
        wrapper: null,
      };
    },
  };
  await assert.rejects(
    synchronizeTeamVault({ client, controller, role: "viewer" }),
    /team_vault_key_unavailable/,
  );
  assert.equal(repository.inspect(), null);
});

test("an Owner rotates atomically for the complete active device set and excludes a revoked device", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const repositoryA = memoryRepository();
  const repositoryB = memoryRepository();
  const controllerA = createTeamVaultController({ repository: repositoryA, identity: a.identity, scope, cryptoValue: webcrypto });
  const controllerB = createTeamVaultController({ repository: repositoryB, identity: b.identity, scope, cryptoValue: webcrypto });

  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: controllerA, role: "owner" });
  await synchronizeTeamVault({ client: server.clientFor(deviceB), controller: controllerB, role: "editor" });
  await controllerA.upsert({ id: recordID, type: "host", data: { title: "Production", address: "prod.invalid" } });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: controllerA, role: "owner" });
  server.requireRotation([a.keyDevice]);

  assert.deepEqual(
    await rotateTeamVault({ client: server.clientFor(deviceA), controller: controllerA, role: "owner" }),
    { status: "rotated", revision: 3, keyGeneration: 2 },
  );
  assert.equal(repositoryA.inspect().keyGeneration, 2);
  assert.equal(controllerA.document().records[0].data.title, "Production");
  assert.doesNotMatch(JSON.stringify(repositoryA.inspect()), /Production|prod\.invalid/u);
  assert.deepEqual([...server.inspect().wrappers.keys()], [deviceA]);
  await assert.rejects(
    synchronizeTeamVault({ client: server.clientFor(deviceB), controller: controllerB, role: "editor" }),
    /team_vault_key_unavailable/u,
  );
  assert.equal(repositoryB.inspect().keyGeneration, 1);
});

test("competing rotations commit once and never replace the losing local snapshot", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const repositoryA = memoryRepository();
  const repositoryB = memoryRepository();
  const controllerA = createTeamVaultController({ repository: repositoryA, identity: a.identity, scope, cryptoValue: webcrypto });
  const controllerB = createTeamVaultController({ repository: repositoryB, identity: b.identity, scope, cryptoValue: webcrypto });
  const stableA = server.clientFor(deviceA);
  const stableB = server.clientFor(deviceB);
  await synchronizeTeamVault({ client: stableA, controller: controllerA, role: "owner" });
  await synchronizeTeamVault({ client: stableB, controller: controllerB, role: "admin" });
  server.requireRotation([a.keyDevice, b.keyDevice]);
  let arrivals = 0;
  let release;
  const barrier = new Promise((resolve) => { release = resolve; });
  function racing(client) {
    return {
      ...client,
      async putTeamVault(...args) {
        arrivals += 1;
        if (arrivals === 2) release();
        await barrier;
        return client.putTeamVault(...args);
      },
    };
  }

  const results = await Promise.all([
    rotateTeamVault({ client: racing(stableA), controller: controllerA, role: "owner" }),
    rotateTeamVault({ client: racing(stableB), controller: controllerB, role: "admin" }),
  ]);
  assert.deepEqual(results.map((value) => value.status).sort(), ["remote_changed", "rotated"]);
  const generations = [repositoryA.inspect().keyGeneration, repositoryB.inspect().keyGeneration].sort();
  assert.deepEqual(generations, [1, 2]);
  assert.equal(server.inspect().keyGeneration, 2);
});

test("rotation waits for explicit conflict resolution before replacing the key", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const controllerA = createTeamVaultController({
    repository: memoryRepository(), identity: a.identity, scope, cryptoValue: webcrypto,
    now: () => "2026-09-06T01:00:00.000Z",
  });
  const controllerB = createTeamVaultController({
    repository: memoryRepository(), identity: b.identity, scope, cryptoValue: webcrypto,
    now: () => "2026-09-06T02:00:00.000Z",
  });
  const clientA = server.clientFor(deviceA);
  const clientB = server.clientFor(deviceB);
  await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "admin" });
  await controllerA.upsert({ id: recordID, type: "host", data: { title: "A", address: "a.invalid" } });
  await controllerB.upsert({ id: recordID, type: "host", data: { title: "B", address: "b.invalid" } });
  await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  server.requireRotation([a.keyDevice, b.keyDevice]);

  const conflict = await rotateTeamVault({ client: clientB, controller: controllerB, role: "admin" });
  assert.equal(conflict.status, "conflict");
  assert.equal(server.revision(), 2);
  assert.equal(controllerB.document().records[0].data.title, "B");
  await controllerB.resolveConflicts({ revision: 2, resolutions: [{ id: recordID, choice: "local" }] });
  assert.deepEqual(await rotateTeamVault({ client: clientB, controller: controllerB, role: "admin" }),
    { status: "rotated", revision: 3, keyGeneration: 2 });
  assert.equal(controllerB.document().records[0].data.title, "B");
});

test("a rotated Team generation preserves concurrent offline edits until explicit resolution", async () => {
  const a = await device(deviceA, membershipA), b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const controllerA = createTeamVaultController({ repository: memoryRepository(), identity: a.identity, scope, cryptoValue: webcrypto });
  const repositoryB = memoryRepository();
  const controllerB = createTeamVaultController({ repository: repositoryB, identity: b.identity, scope, cryptoValue: webcrypto });
  const clientA = server.clientFor(deviceA), clientB = server.clientFor(deviceB);
  await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" });
  await controllerA.upsert({ id: recordID, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  await controllerB.upsert({ id: recordID, type: "host", data: { title: "Offline", address: "offline.invalid" } });
  await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  server.requireRotation([a.keyDevice, b.keyDevice]);
  await rotateTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  const before = repositoryB.inspect();
  const result = await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" });
  assert.equal(result.status, "conflict");
  assert.equal(server.revision(), 3);
  assert.deepEqual(repositoryB.inspect(), before);
  assert.equal(controllerB.document().records[0].data.title, "Offline");
  await controllerB.resolveConflicts({ revision: 3, resolutions: [{ id: recordID, choice: "local" }] });
  assert.deepEqual(await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" }),
    { status: "uploaded", revision: 4 });
});

test("a device without a current Team wrapper is locked before legacy history is examined", async () => {
  const a = await device(deviceA, membershipA), b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]), repositoryA = memoryRepository();
  const controllerA = createTeamVaultController({ repository: repositoryA, identity: a.identity, scope, cryptoValue: webcrypto });
  const controllerB = createTeamVaultController({ repository: memoryRepository(), identity: b.identity, scope, cryptoValue: webcrypto });
  const clientA = server.clientFor(deviceA), clientB = server.clientFor(deviceB);
  await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "admin" });
  await controllerA.upsert({ id: recordID, type: "host", data: { title: "Offline", address: "offline.invalid" } });
  const legacy = repositoryA.inspect();
  delete legacy.serverContentHash;
  await repositoryA.save(legacy);
  controllerA.lock();
  await controllerA.unlock();
  server.requireRotation([b.keyDevice]);
  await rotateTeamVault({ client: clientB, controller: controllerB, role: "admin" });
  const remote = await clientA.getTeamVault(scope);
  assert.equal(remote.wrapper, null);
  await assert.rejects(synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" }), /team_vault_key_unavailable/u);
  assert.equal(await controllerA.status(), "locked");
  assert.deepEqual(repositoryA.inspect(), legacy);
  assert.throws(() => controllerA.document(), /team_vault_locked/u);
});

test("an unusable Team wrapper locks an already open local Vault", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = memoryRepository();
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  const goodClient = server.clientFor(deviceA);
  await synchronizeTeamVault({ client: goodClient, controller, role: "owner" });
  const before = repository.inspect();
  const client = { ...goodClient, async getTeamVault() {
    const remote = await goodClient.getTeamVault();
    const wrapper = structuredClone(remote.wrapper);
    wrapper.ciphertext = (wrapper.ciphertext[0] === "A" ? "B" : "A") + wrapper.ciphertext.slice(1);
    return { ...remote, wrapper };
  } };
  await assert.rejects(synchronizeTeamVault({ client, controller, role: "owner" }), /team_vault_key_unavailable/u);
  assert.equal(await controller.status(), "locked");
  assert.deepEqual(repository.inspect(), before);
});

for (const replacement of ["new epoch", "new membership"]) {
  test(`a ${replacement} cannot publish offline changes from the previous Team membership`, async () => {
    const a = await device(deviceA, membershipA), b = await device(deviceB, membershipB);
    const server = sharedServer([a.keyDevice, b.keyDevice]), repositoryA = memoryRepository();
    const controllerA = createTeamVaultController({ repository: repositoryA, identity: a.identity, scope, cryptoValue: webcrypto });
    const controllerB = createTeamVaultController({ repository: memoryRepository(), identity: b.identity, scope, cryptoValue: webcrypto });
    const clientA = server.clientFor(deviceA), clientB = server.clientFor(deviceB);
    await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
    await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "admin" });
    await controllerA.upsert({ id: recordID, type: "host", data: { title: "Offline", address: "offline.invalid" } });
    const before = structuredClone(repositoryA.inspect());
    server.requireRotation([b.keyDevice]);
    await rotateTeamVault({ client: clientB, controller: controllerB, role: "admin" });
    server.addKeyDevice({ ...a.keyDevice,
      ...(replacement === "new epoch" ? { membershipEpoch: 2 }
        : { membershipID: "ffffffff-ffff-4fff-8fff-ffffffffffff" }) });
    await provisionTeamVaultWrappers({ client: clientB, controller: controllerB });
    assert.ok((await clientA.getTeamVault(scope)).wrapper);
    await assert.rejects(synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" }), /team_vault_membership_changed/u);
    assert.equal(server.revision(), 2);
    assert.equal(await controllerA.status(), "locked");
    assert.deepEqual(repositoryA.inspect(), before);
  });
}

for (const status of [403, 404, 503]) {
  test(`Team GET ${status} ${status === 503 ? "preserves an open Vault on a temporary failure" : "locks an already open Vault after access denial"}`, async () => {
    const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]), repository = memoryRepository();
    const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
    await synchronizeTeamVault({ client: server.clientFor(deviceA), controller, role: "owner" });
    await controller.upsert({ id: recordID, type: "host", data: { title: "Offline", address: "offline.invalid" } });
    const before = structuredClone(repository.inspect());
    const client = createAuthenticatedVaultClient({ fetchValue: async path => path === "/v1/auth/login"
      ? Response.json({ token: "a".repeat(43), user: { id: membershipA, email: "a@example.invalid" }, deviceID: deviceA },
        { headers: { "X-Selective-Session-Binding": deviceA } })
      : Response.json({ error: "team_not_found" }, { status }) });
    await client.login({ email: "a@example.invalid", password: "synthetic password", deviceID: deviceA });
    await assert.rejects(synchronizeTeamVault({ client, controller, role: "owner" }),
      status === 503 ? /team_vault_download_failed/u : /team_vault_access_denied/u);
    assert.equal(await controller.status(), status === 503 ? "unlocked" : "locked");
    assert.deepEqual(repository.inspect(), before);
  });
}

test("a delayed Team access denial from an old session cannot lock a new session", async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const controller = createTeamVaultController({ repository: memoryRepository(), identity: a.identity, scope, cryptoValue: webcrypto });
  const stable = server.clientFor(deviceA);
  await synchronizeTeamVault({ client: stable, controller, role: "owner" });
  let epoch = "1", enter, release;
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const client = { ...stable, sessionGeneration: () => epoch, async getTeamVault() {
    enter(); await held; throw new Error("team_vault_access_denied");
  } };
  const pending = synchronizeTeamVault({ client, controller, role: "owner" });
  await started;
  epoch = "2";
  release();
  await assert.rejects(pending, /authentication_required/u);
  assert.equal(await controller.status(), "unlocked");
});

test("locking while conflict resolution waits to save does not change the local Team snapshot", async () => {
  const a = await device(deviceA, membershipA), b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory());
  let armed = false, enter, release;
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, async save(...args) {
    if (armed) { enter(); await held; }
    return repository.save(...args);
  } };
  const controllerA = createTeamVaultController({ repository: memoryRepository(), identity: a.identity, scope, cryptoValue: webcrypto });
  const controllerB = createTeamVaultController({ repository: delayed, identity: b.identity, scope, cryptoValue: webcrypto });
  const clientA = server.clientFor(deviceA), clientB = server.clientFor(deviceB);
  await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" });
  await controllerA.upsert({ id: recordID, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  await controllerB.upsert({ id: recordID, type: "host", data: { title: "Offline", address: "offline.invalid" } });
  await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  assert.equal((await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" })).status, "conflict");
  const before = await repository.load(deviceB);
  armed = true;
  const pending = controllerB.resolveConflicts({ revision: 2, resolutions: [{ id: recordID, choice: "remote" }] });
  await started;
  controllerB.lock();
  release();
  await assert.rejects(pending, /team_vault_locked/u);
  assert.deepEqual(await repository.load(deviceB), before);
  const fresh = createTeamVaultController({ repository, identity: b.identity, scope, cryptoValue: webcrypto });
  assert.equal((await fresh.unlock()).records[0].data.address, "offline.invalid");
});

test("a retained device adopts the rotated generation and uploads its causal local changes", async () => {
  const a = await device(deviceA, membershipA);
  const b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]);
  const controllerA = createTeamVaultController({ repository: memoryRepository(), identity: a.identity, scope, cryptoValue: webcrypto });
  const repositoryB = memoryRepository();
  const controllerB = createTeamVaultController({ repository: repositoryB, identity: b.identity, scope, cryptoValue: webcrypto });
  const clientA = server.clientFor(deviceA);
  const clientB = server.clientFor(deviceB);
  await synchronizeTeamVault({ client: clientA, controller: controllerA, role: "owner" });
  await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" });
  await controllerB.upsert({ id: recordID, type: "host", data: { title: "Offline", address: "offline.invalid" } });
  server.requireRotation([a.keyDevice, b.keyDevice]);
  await rotateTeamVault({ client: clientA, controller: controllerA, role: "owner" });

  assert.deepEqual(
    await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" }),
    { status: "uploaded", revision: 3 },
  );
  assert.equal(repositoryB.inspect().keyGeneration, 2);
  assert.equal(controllerB.document().records[0].data.title, "Offline");
});

test("an unknown network result recovers the exact committed rotation without a second mutation", async () => {
  const a = await device(deviceA, membershipA);
  const server = sharedServer([a.keyDevice]);
  const repository = memoryRepository();
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  const stable = server.clientFor(deviceA);
  await synchronizeTeamVault({ client: stable, controller, role: "owner" });
  server.requireRotation([a.keyDevice]);
  let putCalls = 0;
  const interrupted = {
    ...stable,
    async putTeamVault(...args) {
      putCalls += 1;
      const result = await stable.putTeamVault(...args);
      throw Object.assign(new Error("network_interrupted"), { committedResult: result });
    },
  };

  await assert.rejects(
    rotateTeamVault({ client: interrupted, controller, role: "owner" }),
    /network_interrupted/u,
  );
  assert.equal(repository.inspect().keyGeneration, 1);
  assert.deepEqual(
    await rotateTeamVault({ client: interrupted, controller, role: "owner" }),
    { status: "rotated", revision: 2, keyGeneration: 2 },
  );
  assert.equal(putCalls, 1);
  assert.equal(repository.inspect().keyGeneration, 2);
});

// Concurrent mutations may fail closed, but a successful edit must survive.
function observedResult(promise) {
  return promise.then(value => ({ value }), error => ({ error }));
}

function assertTeamConcurrentError(result) {
  assert.match(String(result.error?.message ?? ""),
    /team_vault_(legacy_conflict|stale_snapshot|locked|operation_in_progress|rotation_in_progress)/u);
}

function delayedTeamCrypto(method) {
  let armed = false, calls = 0, enter, release;
  const started = new Promise(resolve => { enter = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const subtle = new Proxy(webcrypto.subtle, { get(target, name) {
    if (name === method) return async (...args) => {
      const attempt = armed ? ++calls : 0;
      const result = await target[name](...args);
      if (attempt === 1) { enter(); await held; }
      return result;
    };
    const value = Reflect.get(target, name, target);
    return typeof value === "function" ? value.bind(target) : value;
  } });
  return {
    cryptoValue: { subtle, getRandomValues: webcrypto.getRandomValues.bind(webcrypto), randomUUID: webcrypto.randomUUID.bind(webcrypto) },
    arm() { armed = true; }, started, release,
  };
}

test("an edit concurrent with generation merge is retained", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), b = await device(deviceB, membershipB);
  const server = sharedServer([a.keyDevice, b.keyDevice]), indexedDB = new IDBFactory();
  const repoA = createIndexedDBTeamVaultRepository(scope, indexedDB), repoB = createIndexedDBTeamVaultRepository(scope, indexedDB);
  const gate = delayedTeamCrypto("encrypt");
  const first = createTeamVaultController({ repository: repoA, identity: a.identity, scope, cryptoValue: webcrypto });
  const second = createTeamVaultController({ repository: repoB, identity: b.identity, scope, cryptoValue: gate.cryptoValue });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: first, role: "owner" });
  await synchronizeTeamVault({ client: server.clientFor(deviceB), controller: second, role: "editor" });
  await second.upsert({ type: "host", data: { title: "Before", address: "before.invalid" } });
  server.requireRotation([a.keyDevice, b.keyDevice]);
  await rotateTeamVault({ client: server.clientFor(deviceA), controller: first, role: "owner" });
  const remote = await server.clientFor(deviceB).getTeamVault();
  gate.arm();
  const merging = observedResult(second.mergeRemoteGeneration(remote));
  await gate.started;
  const edit = await observedResult(second.upsert({ type: "host", data: { title: "Late", address: "late.invalid" } }));
  gate.release();
  const merged = await merging;
  if (edit.error) assertTeamConcurrentError(edit);
  if (merged.error) assertTeamConcurrentError(merged);
  second.lock();
  const restored = await second.unlock();
  const addresses = restored.records.map(record => record.data.address);
  assert.ok(addresses.includes("before.invalid"));
  if (!edit.error) assert.ok(addresses.includes("late.invalid"));
});

test("an edit concurrent with rotation is retained", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), gate = delayedTeamCrypto("encrypt");
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: gate.cryptoValue });
  const client = server.clientFor(deviceA);
  await synchronizeTeamVault({ client, controller, role: "owner" });
  await controller.upsert({ type: "host", data: { title: "Before", address: "before.invalid" } });
  await synchronizeTeamVault({ client, controller, role: "owner" });
  server.requireRotation([a.keyDevice]);
  gate.arm();
  const rotating = observedResult(rotateTeamVault({ client, controller, role: "owner" }));
  await gate.started;
  const edit = await observedResult(controller.upsert({ type: "host", data: { title: "Late", address: "late.invalid" } }));
  gate.release();
  const rotation = await rotating;
  if (edit.error) assertTeamConcurrentError(edit);
  if (rotation.error) assertTeamConcurrentError(rotation);
  controller.lock();
  const restored = await controller.unlock();
  const addresses = restored.records.map(record => record.data.address);
  assert.ok(addresses.includes("before.invalid"));
  if (!edit.error) assert.ok(addresses.includes("late.invalid"));
});

test("concurrent initializations cannot erase an edit after one succeeds", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), gate = delayedTeamCrypto("encrypt");
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory());
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: gate.cryptoValue });
  gate.arm();
  const first = observedResult(controller.initialize([a.keyDevice]));
  await gate.started;
  const second = await observedResult(controller.initialize([a.keyDevice]));
  let edit = null;
  if (!second.error) edit = await observedResult(controller.upsert({ type: "host", data: { title: "Saved", address: "saved.invalid" } }));
  gate.release();
  const initial = await first;
  if (second.error) assertTeamConcurrentError(second);
  if (initial.error) assertTeamConcurrentError(initial);
  if (edit?.error) assertTeamConcurrentError(edit);
  controller.lock();
  const restored = await controller.unlock();
  if (edit && !edit.error) assert.equal(restored.records[0].data.address, "saved.invalid");
});

test("a delayed import cannot erase an edit made after initialization", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const source = createTeamVaultController({ repository: createIndexedDBTeamVaultRepository(scope, new IDBFactory()), identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client: server.clientFor(deviceA), controller: source, role: "owner" });
  const remote = await server.clientFor(deviceA).getTeamVault();
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), gate = delayedTeamCrypto("decrypt");
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: gate.cryptoValue });
  gate.arm();
  const importing = observedResult(controller.importRemote(remote));
  await gate.started;
  const initial = await observedResult(controller.initialize([a.keyDevice]));
  let edit = null;
  if (!initial.error) edit = await observedResult(controller.upsert({ type: "host", data: { title: "Saved", address: "saved.invalid" } }));
  gate.release();
  const imported = await importing;
  if (initial.error) assertTeamConcurrentError(initial);
  if (imported.error) assertTeamConcurrentError(imported);
  if (edit?.error) assertTeamConcurrentError(edit);
  controller.lock();
  const restored = await controller.unlock();
  if (edit && !edit.error) assert.equal(restored.records[0].data.address, "saved.invalid");
});

test("a late unlock cannot reopen a locked Team controller", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory());
  const seed = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await seed.initialize([a.keyDevice]);
  let enter, release;
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, load: async (...args) => {
    const result = await repository.load(...args); enter(); await held; return result;
  } };
  const controller = createTeamVaultController({ repository: delayed, identity: a.identity, scope, cryptoValue: webcrypto });
  const unlocking = observedResult(controller.unlock());
  await started;
  controller.lock();
  release();
  await unlocking;
  assert.equal(await controller.status(), "locked");
  assert.throws(() => controller.document(), /team_vault_locked/u);
});

for (const operation of ["initialize", "rotation"]) {
  test(`a late ${operation} commit cannot reopen a locked Team controller`, { timeout: 5000 }, async () => {
    const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
    const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory());
    let armed = operation === "initialize", enter, release;
    const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
    const delayed = { ...repository, save: async (...args) => {
      const result = await repository.save(...args);
      if (armed) { armed = false; enter(); await held; }
      return result;
    } };
    const controller = createTeamVaultController({ repository: delayed, identity: a.identity, scope, cryptoValue: webcrypto });
    if (operation === "rotation") {
      await synchronizeTeamVault({ client: server.clientFor(deviceA), controller, role: "owner" });
      server.requireRotation([a.keyDevice]);
      armed = true;
    }
    const pending = observedResult(operation === "initialize"
      ? controller.initialize([a.keyDevice])
      : rotateTeamVault({ client: server.clientFor(deviceA), controller, role: "owner" }));
    await started;
    controller.lock();
    release();
    await pending;
    assert.equal(await controller.status(), "locked");
    assert.throws(() => controller.document(), /team_vault_locked/u);
    if (operation === "rotation") assert.equal(server.revision(), 2, "a committed remote rotation cannot be retracted");
  });
}

test("Team lock invalidates an upload before cloud mutation", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), gate = delayedTeamCrypto("encrypt");
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: gate.cryptoValue });
  const client = server.clientFor(deviceA);
  await synchronizeTeamVault({ client, controller, role: "owner" });
  await controller.upsert({ type: "host", data: { title: "Unsynced", address: "unsynced.invalid" } });
  gate.arm();
  const syncing = observedResult(synchronizeTeamVault({ client, controller, role: "owner" }));
  await gate.started;
  controller.lock();
  gate.release();
  await syncing;
  assert.equal(server.revision(), 1);
});

test("late older unlock cannot hide a saved edit and report up to date", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), client = server.clientFor(deviceA);
  const seed = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client, controller: seed, role: "owner" });
  seed.lock();
  let calls = 0, enter, release;
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, load: async (...args) => {
    const result = await repository.load(...args);
    if (++calls === 1) { enter(); await held; }
    return result;
  } };
  const controller = createTeamVaultController({ repository: delayed, identity: a.identity, scope, cryptoValue: webcrypto });
  const earlier = observedResult(controller.unlock());
  await started;
  const later = await observedResult(controller.unlock());
  if (!later.error) await controller.upsert({ type: "host", data: { title: "Saved", address: "saved.invalid" } });
  release();
  const old = await earlier;
  if (later.error) {
    assertTeamConcurrentError(later);
    assert.ifError(old.error);
    await controller.upsert({ type: "host", data: { title: "Saved", address: "saved.invalid" } });
  } else if (old.error) assertTeamConcurrentError(old);
  assert.equal(controller.document().records[0].data.address, "saved.invalid");
  assert.notEqual((await synchronizeTeamVault({ client, controller, role: "owner" })).status, "up_to_date");
});

test("an old successful upload acknowledgement cannot regress synced metadata", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), client = server.clientFor(deviceA);
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client, controller, role: "owner" });
  await controller.upsert({ type: "host", data: { title: "First", address: "first.invalid" } });
  let enter, release;
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...client, putTeamVault: async (...args) => {
    const result = await client.putTeamVault(...args); enter(); await held; return result;
  } };
  const earlier = observedResult(synchronizeTeamVault({ client: delayed, controller, role: "owner" }));
  await started;
  await controller.upsert({ type: "host", data: { title: "Second", address: "second.invalid" } });
  assert.equal((await synchronizeTeamVault({ client, controller, role: "owner" })).status, "uploaded");
  release();
  const old = await earlier;
  const state = await controller.syncState();
  if (!old.error) assert.equal(old.value.revision, 3);
  assert.equal(state.serverRevision, 3);
  assert.equal(state.dirty, false);
});

test("edit during prepareUpload remains dirty and uploads on retry", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), gate = delayedTeamCrypto("encrypt");
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: gate.cryptoValue });
  const client = server.clientFor(deviceA);
  await synchronizeTeamVault({ client, controller, role: "owner" });
  await controller.upsert({ type: "host", data: { title: "First", address: "first.invalid" } });
  gate.arm();
  const syncing = synchronizeTeamVault({ client, controller, role: "owner" });
  await gate.started;
  await controller.upsert({ type: "host", data: { title: "Late", address: "late.invalid" } });
  gate.release();
  assert.equal((await syncing).status, "uploaded_with_new_local_changes");
  assert.equal((await controller.syncState()).dirty, true);
  assert.equal((await synchronizeTeamVault({ client, controller, role: "owner" })).status, "uploaded");
  controller.lock();
  const restored = await controller.unlock();
  assert.deepEqual(restored.records.map(record => record.data.address).sort(), ["first.invalid", "late.invalid"]);
});

test("a sync started before lock cannot reopen the Team Vault after a delayed GET", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), client = server.clientFor(deviceA);
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client, controller, role: "owner" });
  let enter, release;
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...client, getTeamVault: async (...args) => { const remote = await client.getTeamVault(...args); enter(); await held; return remote; } };
  const syncing = observedResult(synchronizeTeamVault({ client: delayed, controller, role: "owner" }));
  await started;
  controller.lock();
  release();
  await syncing;
  assert.equal(await controller.status(), "locked");
});

test("locking during Team initialization preparation reports a locked Vault", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), gate = delayedTeamCrypto("encrypt");
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory());
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: gate.cryptoValue });
  await controller.initialize([a.keyDevice]);
  gate.arm();
  const preparing = observedResult(controller.prepareInitialization([a.keyDevice]));
  await gate.started;
  controller.lock();
  gate.release();
  const result = await preparing;
  assert.match(String(result.error?.message ?? ""), /team_vault_locked/u);
  assert.equal(await controller.status(), "locked");
});

test("another tab's saved edit requires reopening before synchronization", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), client = server.clientFor(deviceA);
  const first = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  const second = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client, controller: first, role: "owner" });
  await second.unlock();
  await first.upsert({ type: "host", data: { title: "Saved", address: "saved.invalid" } });
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await assert.rejects(synchronizeTeamVault({ client, controller: second, role: "owner" }), /team_vault_stale_snapshot/u);
  }
  second.lock();
  assert.equal((await synchronizeTeamVault({ client, controller: second, role: "owner" })).status, "uploaded");
  assert.equal(second.document().records[0].data.address, "saved.invalid");
});

test("obsolete Team sync cannot upload after same-account reauthentication", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), stable = server.clientFor(deviceA);
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client: stable, controller, role: "owner" });
  await controller.upsert({ type: "host", data: { title: "Saved", address: "saved.invalid" } });
  let epoch = "1", enter, release;
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const client = { ...stable, sessionGeneration: () => epoch, getTeamVault: async (...args) => {
    const remote = await stable.getTeamVault(...args); enter(); await held; return remote;
  } };
  const syncing = synchronizeTeamVault({ client, controller, role: "owner" });
  await started;
  epoch = "2";
  release();
  await assert.rejects(syncing, /authentication_required/u);
  assert.equal(server.revision(), 1);
});

test("a concurrent tab edit stops Team rotation before it publishes", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), client = server.clientFor(deviceA);
  const gate = delayedTeamCrypto("encrypt");
  const rotating = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: gate.cryptoValue });
  const editing = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client, controller: rotating, role: "owner" });
  await editing.unlock();
  server.requireRotation([a.keyDevice]);
  gate.arm();
  const pending = observedResult(rotateTeamVault({ client, controller: rotating, role: "owner" }));
  await gate.started;
  await editing.upsert({ type: "host", data: { title: "Saved", address: "saved.invalid" } });
  gate.release();
  assertTeamConcurrentError(await pending);
  assert.equal(server.revision(), 1, "the stale rotation must not be sent after the local edit");
  editing.lock();
  assert.equal((await editing.unlock()).records[0].data.address, "saved.invalid");
});

test("an obsolete Team rotation preparation does not leave a pending rotation", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), stable = server.clientFor(deviceA);
  const gate = delayedTeamCrypto("encrypt");
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: gate.cryptoValue });
  await synchronizeTeamVault({ client: stable, controller, role: "owner" });
  server.requireRotation([a.keyDevice]);
  let epoch = "1";
  const client = { ...stable, sessionGeneration: () => epoch };
  gate.arm();
  const pending = observedResult(rotateTeamVault({ client, controller, role: "owner" }));
  await gate.started;
  epoch = "2";
  gate.release();
  assert.match(String((await pending).error?.message ?? ""), /authentication_required/u);
  assert.equal(server.revision(), 1);
  assert.equal(controller.rotationPreparation(), null);
  await controller.upsert({ type: "host", data: { title: "Saved", address: "saved.invalid" } });
});

test("a Team controller cannot upload under another device session", { timeout: 5000 }, async () => {
  const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
  const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory()), original = server.clientFor(deviceA);
  const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
  await synchronizeTeamVault({ client: original, controller, role: "owner" });
  await controller.upsert({ type: "host", data: { title: "Saved", address: "saved.invalid" } });
  const other = { ...original, session: () => ({ id: "88888888-8888-4888-8888-888888888888" }), deviceID: () => deviceB };
  await assert.rejects(synchronizeTeamVault({ client: other, controller, role: "editor" }), /authentication_required/u);
  assert.equal(server.revision(), 1);
  assert.equal((await controller.syncState()).dirty, true);
});

for (const scenario of ["lock", "session"]) {
  test(`a delayed Team rotation GET cannot publish after ${scenario}`, { timeout: 5000 }, async () => {
    const a = await device(deviceA, membershipA), server = sharedServer([a.keyDevice]);
    const repository = createIndexedDBTeamVaultRepository(scope, new IDBFactory());
    const stable = server.clientFor(deviceA);
    const controller = createTeamVaultController({ repository, identity: a.identity, scope, cryptoValue: webcrypto });
    await synchronizeTeamVault({ client: stable, controller, role: "owner" });
    server.requireRotation([a.keyDevice]);
    let epoch = "1", enter, release;
    const started = new Promise((resolve) => { enter = resolve; });
    const held = new Promise((resolve) => { release = resolve; });
    const client = { ...stable, sessionGeneration: () => epoch, getTeamVault: async (...args) => {
      const remote = await stable.getTeamVault(...args);
      enter();
      await held;
      return remote;
    } };
    const pending = rotateTeamVault({ client, controller, role: "owner" });
    await started;
    if (scenario === "lock") controller.lock(); else epoch = "2";
    release();
    await assert.rejects(pending, /authentication_required|team_vault_locked/u);
    assert.equal(server.revision(), 1);
    assert.equal(server.inspect().rotationRequired, true);
  });
}
