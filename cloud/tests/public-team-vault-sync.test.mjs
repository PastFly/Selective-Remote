import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import {
  createTeamVaultController,
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
      async listTeamKeyDevices() { return { scope, devices: currentKeyDevices }; },
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
    };
  }
  return {
    clientFor,
    revision: () => revision,
    inspect: () => ({ revision, keyGeneration, rotationRequired, envelope, wrappers: new Map(wrappers) }),
    requireRotation(nextKeyDevices) {
      currentKeyDevices = nextKeyDevices;
      rotationRequired = true;
    },
  };
}

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

test("two Team devices merge causal updates and require explicit choices for concurrent records", async () => {
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

  const conflict = await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" });
  assert.equal(conflict.status, "conflict");
  assert.equal(conflict.conflicts.length, 1);
  assert.equal(conflict.conflicts[0].local.value.data.title, "B");
  assert.equal(conflict.conflicts[0].remote.value.data.title, "A");
  await controllerB.resolveConflicts({
    revision: conflict.revision,
    resolutions: [{ id: recordID, choice: "local" }],
  });
  assert.deepEqual(
    await synchronizeTeamVault({ client: clientB, controller: controllerB, role: "editor" }),
    { status: "uploaded", revision: 3 },
  );
  assert.equal(controllerB.document().records[0].data.title, "B");
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
    /team_vault_rotation_required/,
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

test("rotation stops for an explicit causal conflict and resumes only after every choice", async () => {
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
  assert.equal(conflict.conflicts.length, 1);
  assert.equal(server.inspect().rotationRequired, true);
  await controllerB.resolveConflicts({
    revision: conflict.revision,
    resolutions: [{ id: recordID, choice: "local" }],
  });
  assert.deepEqual(
    await rotateTeamVault({ client: clientB, controller: controllerB, role: "admin" }),
    { status: "rotated", revision: 3, keyGeneration: 2 },
  );
  assert.equal(controllerB.document().records[0].data.title, "B");
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
