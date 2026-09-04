import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { createLocalVaultController } from "../public/vault-local.js";
import {
  createAuthenticatedVaultClient,
  personalVaultScope,
  synchronizeVault,
} from "../public/vault-sync.js";

const passphrase = "correct horse battery staple for synchronized recovery";
const userID = "99999999-9999-4999-8999-999999999999";
const vaultID = "88888888-8888-4888-8888-888888888888";
const deviceA = "11111111-1111-4111-8111-111111111111";
const deviceB = "22222222-2222-4222-8222-222222222222";
const recordA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const recordB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

function memoryRepository() {
  let snapshot = null;
  let sync = null;
  let deviceID = null;
  return {
    async load() { return snapshot ? structuredClone(snapshot) : null; },
    async save(value) { snapshot = structuredClone(value); },
    async loadSync() { return sync ? structuredClone(sync) : null; },
    async saveSync(value) { sync = structuredClone(value); },
    async loadDeviceID() { return deviceID; },
    async saveDeviceID(value) { deviceID = value; },
    snapshot() { return snapshot ? structuredClone(snapshot) : null; },
  };
}

function localVault(repository, ids) {
  let index = 0;
  return createLocalVaultController({
    repository,
    cryptoValue: webcrypto,
    randomUUID: () => ids[index++],
    now: () => "2026-09-04T00:00:00.000Z",
  });
}

function jsonResponse(status, value) {
  return new Response(value === null ? null : JSON.stringify(value), {
    status,
    headers: value === null ? {} : { "Content-Type": "application/json" },
  });
}

function remoteValue(revision, envelope = null) {
  return {
    id: vaultID,
    revision,
    envelope,
    updatedAt: "2026-09-04T00:00:00.000Z",
  };
}

test("authenticated client keeps its bearer token in memory and uses only the personal scope", async () => {
  const calls = [];
  const token = "t".repeat(43);
  const envelope = {
    baseRevision: 0,
    envelopeVersion: 1,
    wrappedKey: { algorithm: "test" },
    ciphertext: "AA",
    nonce: "AAAAAAAAAAAAAAAA",
    authTag: "AAAAAAAAAAAAAAAAAAAAAA",
    contentHash: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  };
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path, options = {}) => {
      calls.push({ path, options });
      if (path === "/v1/auth/login") {
        return jsonResponse(200, {
          token,
          user: { id: userID, email: "user@example.invalid", displayName: "User" },
          deviceID: deviceA,
        });
      }
      if (path === "/v1/vault" && options.method === "PUT") {
        return jsonResponse(200, { conflict: false, revision: 1 });
      }
      if (path === "/v1/auth/logout") return jsonResponse(204, null);
      throw new Error("unexpected_request");
    },
  });

  const user = await client.login({ email: " user@example.invalid ", password: "synthetic-password", deviceID: deviceA });
  assert.deepEqual(user, { id: userID, email: "user@example.invalid", displayName: "User" });
  assert.equal(JSON.stringify(client.session()).includes(token), false);

  await assert.rejects(
    client.getVault({ type: "team", id: vaultID }),
    /unsupported_vault_scope/,
  );
  assert.equal(calls.length, 1, "unsupported scopes must fail before a network request");

  await client.putVault(personalVaultScope, envelope);
  assert.equal(calls[1].options.headers.Authorization, `Bearer ${token}`);
  assert.equal(calls[1].options.credentials, "omit");
  await client.logout();
  assert.equal(client.session(), null);
});

test("a 401 response clears the in-memory browser session", async () => {
  let request = 0;
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path) => {
      request += 1;
      if (path === "/v1/auth/login") {
        return jsonResponse(200, {
          token: "t".repeat(43),
          user: { id: userID, email: "user@example.invalid", displayName: "User" },
          deviceID: deviceA,
        });
      }
      return jsonResponse(401, { error: "unauthorized" });
    },
  });

  await client.login({ email: "user@example.invalid", password: "synthetic-password", deviceID: deviceA });
  await assert.rejects(client.getVault(), /authentication_required/);
  assert.equal(client.session(), null);
  assert.equal(request, 2);
});

test("local encrypted changes upload against the last observed server revision", async () => {
  const repository = memoryRepository();
  const vault = localVault(repository, [deviceA, recordA]);
  await vault.create(passphrase);
  const uploadedBases = [];
  let serverRevision = 0;
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(serverRevision),
    putVault: async (_scope, envelope) => {
      uploadedBases.push(envelope.baseRevision);
      serverRevision += 1;
      return { conflict: false, revision: serverRevision };
    },
  };

  assert.deepEqual(await synchronizeVault({ client, vault }), { status: "uploaded", revision: 1 });
  assert.deepEqual(await vault.syncState(), { localRevision: 1, serverRevision: 1, dirty: false });

  await vault.upsert({ id: recordA, type: "host", data: { title: "A", address: "a.invalid" } });
  assert.equal((await vault.syncState()).dirty, true);
  assert.deepEqual(await synchronizeVault({ client, vault }), { status: "uploaded", revision: 2 });
  assert.deepEqual(uploadedBases, [0, 1]);
  assert.equal((await vault.syncState()).dirty, false);
  assert.equal(JSON.stringify(repository.snapshot()).includes("a.invalid"), false);
});

test("remote and offline local changes merge locally before one conditional upload", async () => {
  const repoA = memoryRepository();
  const repoB = memoryRepository();
  const vaultA = localVault(repoA, [deviceA]);
  const vaultB = localVault(repoB, [deviceB]);
  await vaultA.create(passphrase);
  const initial = await vaultA.prepareUpload(0);
  await vaultA.markSynced({ serverRevision: 1, localRevision: initial.localRevision });
  await vaultB.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);

  await vaultA.upsert({ id: recordA, type: "host", data: { title: "A", address: "a.invalid" } });
  await vaultB.upsert({ id: recordB, type: "snippet", data: { title: "B", body: "uptime" } });
  const remote = await vaultB.prepareUpload(1);
  let uploaded = null;
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(2, remote.envelope),
    putVault: async (_scope, envelope) => {
      uploaded = envelope;
      return { conflict: false, revision: 3 };
    },
  };

  assert.deepEqual(await synchronizeVault({ client, vault: vaultA }), { status: "uploaded", revision: 3 });
  assert.equal(uploaded.baseRevision, 2);
  assert.deepEqual(vaultA.document().records.map((record) => record.id), [recordA, recordB]);
  assert.deepEqual(await vaultA.syncState(), { localRevision: 3, serverRevision: 3, dirty: false });
});

test("concurrent record conflict blocks upload and preserves the local document", async () => {
  const repoA = memoryRepository();
  const repoB = memoryRepository();
  const vaultA = localVault(repoA, [deviceA]);
  const vaultB = localVault(repoB, [deviceB]);
  await vaultA.create(passphrase);
  const initial = await vaultA.prepareUpload(0);
  await vaultA.markSynced({ serverRevision: 1, localRevision: initial.localRevision });
  await vaultB.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);

  await vaultA.upsert({ id: recordA, type: "host", data: { title: "Local", address: "local.invalid" } });
  await vaultB.upsert({ id: recordA, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  const remote = await vaultB.prepareUpload(1);
  let putCalls = 0;
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(2, remote.envelope),
    putVault: async () => { putCalls += 1; throw new Error("must_not_upload"); },
  };

  const result = await synchronizeVault({ client, vault: vaultA });
  assert.equal(result.status, "conflict");
  assert.equal(result.conflicts.length, 1);
  assert.equal(putCalls, 0);
  assert.equal(vaultA.document().records[0].data.address, "local.invalid");
});

test("a server-side optimistic conflict never marks local data as synchronized", async () => {
  const repository = memoryRepository();
  const vault = localVault(repository, [deviceA]);
  await vault.create(passphrase);
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(0),
    putVault: async () => ({ conflict: true, revision: 4 }),
  };

  assert.deepEqual(
    await synchronizeVault({ client, vault }),
    { status: "remote_changed", remoteRevision: 4 },
  );
  assert.deepEqual(await vault.syncState(), { localRevision: 1, serverRevision: 0, dirty: true });
});

test("an empty browser can import an encrypted remote Vault only with its recovery passphrase", async () => {
  const source = localVault(memoryRepository(), [deviceA]);
  const destination = localVault(memoryRepository(), [deviceB]);
  await source.create(passphrase);
  const prepared = await source.prepareUpload(0);
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(1, prepared.envelope),
  };

  await assert.rejects(synchronizeVault({ client, vault: destination }), /recovery_passphrase_required/);
  assert.deepEqual(
    await synchronizeVault({ client, vault: destination, recoveryPassphrase: passphrase }),
    { status: "downloaded", revision: 1 },
  );
  assert.deepEqual(destination.document(), { schemaVersion: 1, records: [], tombstones: [] });
  assert.deepEqual(await destination.syncState(), { localRevision: 1, serverRevision: 1, dirty: false });
});

test("an unexpected remote recovery wrapper fails closed before local state changes", async () => {
  const repository = memoryRepository();
  const vault = localVault(repository, [deviceA]);
  await vault.create(passphrase);
  const prepared = await vault.prepareUpload(0);
  await vault.markSynced({ serverRevision: 1, localRevision: prepared.localRevision });
  const salt = prepared.envelope.wrappedKey.salt;
  const changedSalt = `${salt[0] === "A" ? "B" : "A"}${salt.slice(1)}`;
  const remoteEnvelope = {
    ...prepared.envelope,
    baseRevision: 1,
    wrappedKey: { ...prepared.envelope.wrappedKey, salt: changedSalt },
  };
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(2, remoteEnvelope),
  };

  await assert.rejects(synchronizeVault({ client, vault }), /remote_wrapped_key_changed/);
  assert.deepEqual(await vault.syncState(), { localRevision: 1, serverRevision: 1, dirty: false });
});
