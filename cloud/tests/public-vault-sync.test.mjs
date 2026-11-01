import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { IDBFactory } from "fake-indexeddb";
import { createIndexedDBVaultRepository, createLocalVaultController } from "../public/vault-local.js";
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
const bindingStorage = binding => ({ getItem: () => binding, setItem() {}, removeItem() {} });

function memoryRepository() {
  let snapshot = null;
  let previous = null;
  let sync = null;
  let deviceID = null;
  let ownership = null;
  return {
    async load() { return snapshot ? structuredClone(snapshot) : null; },
    async save(value) { snapshot = structuredClone(value); },
    async savePrevious(value) { previous = structuredClone(value); },
    async loadSync() { return sync ? structuredClone(sync) : null; },
    async saveSync(value) { sync = structuredClone(value); },
    async loadDeviceID() { return deviceID; },
    async saveDeviceID(value) { deviceID = value; },
    async loadOwnershipBinding() { return ownership ? structuredClone(ownership) : null; },
    async saveOwnershipBinding(value) { ownership = structuredClone(value); },
    snapshot() { return snapshot ? structuredClone(snapshot) : null; },
    previous() { return previous ? structuredClone(previous) : null; },
  };
}

test("verified remote snapshot replaces an incompatible locked browser snapshot and keeps a backup", async () => {
  const oldRepository = memoryRepository();
  const oldVault = localVault(oldRepository, [deviceA]);
  await oldVault.create("an older local wrapper password");
  await oldVault.upsert({ id: recordA, type: "host", data: { title: "Old", address: "old.invalid" } });
  oldVault.lock();

  const cloudRepository = memoryRepository();
  const cloudVault = localVault(cloudRepository, [deviceB]);
  await cloudVault.create(passphrase);
  await cloudVault.upsert({ id: recordB, type: "host", data: { title: "Cloud", address: "cloud.invalid" } });
  const remote = await cloudVault.prepareUpload(4);
  const previousSnapshot = oldRepository.snapshot();

  await oldVault.replaceLockedWithRemote({ revision: 5, envelope: remote.envelope }, passphrase);

  assert.equal(oldVault.document().records[0].data.address, "cloud.invalid");
  assert.deepEqual(oldRepository.previous(), previousSnapshot);
  assert.deepEqual(await oldVault.syncState(), { localRevision: 5, serverRevision: 5, dirty: false });
});

test("an invalid account wrapper cannot replace or back up the locked browser snapshot", async () => {
  const oldRepository = memoryRepository();
  const oldVault = localVault(oldRepository, [deviceA]);
  await oldVault.create("an older local wrapper password");
  oldVault.lock();
  const before = oldRepository.snapshot();

  const cloudRepository = memoryRepository();
  const cloudVault = localVault(cloudRepository, [deviceB]);
  await cloudVault.create("a different account password");
  const remote = await cloudVault.prepareUpload(1);

  await assert.rejects(
    oldVault.replaceLockedWithRemote({ revision: 2, envelope: remote.envelope }, passphrase),
  );
  assert.deepEqual(oldRepository.snapshot(), before);
  assert.equal(oldRepository.previous(), null);
});

function localVault(repository, ids, nowValue = "2026-09-04T00:00:00.000Z") {
  let index = 0;
  return createLocalVaultController({
    repository,
    cryptoValue: webcrypto,
    randomUUID: () => ids[index++],
    now: () => nowValue,
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
          user: { id: userID, email: "user@example.invalid", username: "user", displayName: "User" },
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
  assert.deepEqual(user, { id: userID, email: "user@example.invalid", username: "user", displayName: "User" });
  assert.equal(JSON.stringify(client.session()).includes(token), false);

  await assert.rejects(
    client.getVault({ type: "team", id: vaultID }),
    /unsupported_vault_scope/,
  );
  assert.equal(calls.length, 1, "unsupported scopes must fail before a network request");

  await client.putVault(personalVaultScope, envelope);
  assert.equal(calls[1].options.headers.Authorization, `Bearer ${token}`);
  assert.equal(calls[1].options.credentials, "same-origin");
  await client.logout();
  assert.equal(client.session(), null);
});

test("logout is unconfirmed unless the server explicitly revokes the session", async () => {
  for (const status of [200, 202, 403, 500, 503]) {
    const token = "t".repeat(43);
    let logoutAuthorization;
    const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
      if (path === "/v1/auth/login") return jsonResponse(200, {
        token, user: { id: userID, email: "user@example.invalid" }, deviceID: deviceA,
      });
      if (path === "/v1/auth/logout") {
        logoutAuthorization = options.headers.Authorization;
        return jsonResponse(status, { error: "synthetic_logout_failure" });
      }
      throw new Error("unexpected_request");
    } });
    await client.login({ email: "user@example.invalid", password: "synthetic-password", deviceID: deviceA });
    await assert.rejects(client.logout(), /logout_unconfirmed/, `status ${status}`);
    assert.equal(client.session(), null, "local identity must still be cleared");
    assert.equal(logoutAuthorization, `Bearer ${token}`, "the old session must be the revocation target");
  }
});

test("browser session restores from an HttpOnly cookie without a JavaScript token", async () => {
  const calls = [];
  const client = createAuthenticatedVaultClient({ sessionStorageValue: bindingStorage(deviceA), fetchValue: async (path, options = {}) => {
    calls.push({ path, options });
    return new Response(JSON.stringify({
      id: userID, email: "user@example.invalid", username: "user", displayName: "User", deviceID: deviceA,
    }), { status: 200, headers: { "Content-Type": "application/json", "X-Selective-Session-Binding": deviceA } });
  } });

  assert.deepEqual(await client.restoreSession(), {
    id: userID, email: "user@example.invalid", username: "user", displayName: "User",
  });
  assert.equal(client.deviceID(), deviceA);
  assert.equal(calls[0].path, "/v1/me");
  assert.equal(calls[0].options.credentials, "same-origin");
  assert.equal("Authorization" in calls[0].options.headers, false);
});

test("a cookie replaced by another tab cannot authorize the old tab's Vault write or logout", async () => {
  const oldBinding = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const newBinding = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  let cookieBinding = oldBinding, mutations = 0;
  const client = createAuthenticatedVaultClient({ sessionStorageValue: bindingStorage(oldBinding), fetchValue: async (path, options = {}) => {
    if (path === "/v1/me") return new Response(JSON.stringify({
      id: userID, deviceID: deviceA, email: "user@example.invalid",
    }), { status: 200, headers: { "Content-Type": "application/json", "X-Selective-Session-Binding": cookieBinding } });
    if (options.headers?.["X-Selective-Session-Binding"] !== cookieBinding) {
      return jsonResponse(409, { error: "browser_session_changed" });
    }
    mutations += 1;
    return jsonResponse(200, { conflict: false, revision: 1 });
  } });
  await client.restoreSession();
  cookieBinding = newBinding;
  await assert.rejects(client.putVault(personalVaultScope, {
    baseRevision: 0, envelopeVersion: 1, wrappedKey: { algorithm: "test" }, ciphertext: "AA",
    nonce: "AAAAAAAAAAAAAAAA", authTag: "AAAAAAAAAAAAAAAAAAAAAA", contentHash: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  }), /authentication_required/);
  assert.equal(mutations, 0);
  assert.equal(client.session(), null);
});

test("cookie session restore fails closed when the server cannot bind the browser session", async () => {
  const client = createAuthenticatedVaultClient({ fetchValue: async () => jsonResponse(200, {
    id: userID, deviceID: deviceA, email: "user@example.invalid",
  }) });
  await assert.rejects(client.restoreSession(), /authentication_required/);
  assert.equal(client.session(), null);
});

test("signing out an old tab cannot revoke the replacement cookie session", async () => {
  const oldBinding = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", newBinding = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  let cookie = oldBinding, revoked = false;
  const client = createAuthenticatedVaultClient({ sessionStorageValue: bindingStorage(oldBinding), fetchValue: async (path, options) => {
    if (path === "/v1/me") return new Response(JSON.stringify({ id: userID, deviceID: deviceA }), {
      status: 200, headers: { "Content-Type": "application/json", "X-Selective-Session-Binding": cookie },
    });
    if (options.headers["X-Selective-Session-Binding"] !== cookie) return jsonResponse(409, { error: "browser_session_changed" });
    revoked = true;
    return jsonResponse(204, null);
  } });
  await client.restoreSession();
  cookie = newBinding;
  await assert.rejects(client.logout(), /authentication_required/);
  assert.equal(revoked, false);
});

test("a delayed login response cannot replace a later authenticated account", async () => {
  let release, entered;
  const blocked = new Promise(resolve => { release = resolve; });
  const started = new Promise(resolve => { entered = resolve; });
  const secondUser = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const client = createAuthenticatedVaultClient({ fetchValue: async (_path, options) => {
    const body = JSON.parse(options.body);
    if (body.email === "first@example.invalid") { entered(); await blocked; }
    const id = body.email === "first@example.invalid" ? userID : secondUser;
    return jsonResponse(200, { token: id.repeat(2), user: { id, email: body.email }, deviceID: deviceA });
  } });
  const first = client.login({ email: "first@example.invalid", password: passphrase, deviceID: deviceA });
  await started;
  await client.login({ email: "second@example.invalid", password: passphrase, deviceID: deviceA });
  release();
  await assert.rejects(first, /authentication_required/);
  assert.equal(client.session().id, secondUser);
});

test("a delayed login cookie cannot restore the wrong account after reload", async () => {
  const firstBinding = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", secondBinding = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const secondUser = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const values = new Map(), storage = {
    getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, String(value)), removeItem: key => values.delete(key),
  };
  let release, entered, cookie;
  const held = new Promise(resolve => { release = resolve; });
  const started = new Promise(resolve => { entered = resolve; });
  const fetchValue = async (path, options = {}) => {
    if (path === "/v1/me") return new Response(JSON.stringify({
      id: cookie === firstBinding ? userID : secondUser, deviceID: deviceA,
    }), { status: 200, headers: { "Content-Type": "application/json", "X-Selective-Session-Binding": cookie } });
    const body = JSON.parse(options.body), first = body.email === "first@example.invalid";
    if (first) { entered(); await held; }
    cookie = first ? firstBinding : secondBinding;
    return new Response(JSON.stringify({ token: (first ? "a" : "b").repeat(43),
      user: { id: first ? userID : secondUser, email: body.email }, deviceID: deviceA }), {
      status: 200, headers: { "Content-Type": "application/json", "X-Selective-Session-Binding": cookie },
    });
  };
  const client = createAuthenticatedVaultClient({ fetchValue, sessionStorageValue: storage });
  const first = client.login({ email: "first@example.invalid", password: passphrase, deviceID: deviceA });
  await started;
  await client.login({ email: "second@example.invalid", password: passphrase, deviceID: deviceA });
  release();
  await assert.rejects(first, /authentication_required/);
  assert.equal(client.session().id, secondUser);
  const reloaded = createAuthenticatedVaultClient({ fetchValue, sessionStorageValue: storage });
  await assert.rejects(reloaded.restoreSession(), /authentication_required/);
  assert.equal(reloaded.session(), null);
});

test("browser session storage receives only a non-authenticating session identifier, never the bearer token", async () => {
  const binding = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", token = "synthetic-token-".repeat(4);
  const values = new Map(), storage = { getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) };
  const client = createAuthenticatedVaultClient({ sessionStorageValue: storage, fetchValue: async path => {
    if (path === "/v1/auth/logout") return jsonResponse(204, null);
    return new Response(JSON.stringify({ token, user: { id: userID, email: "user@example.invalid" }, deviceID: deviceA }), {
      status: 200, headers: { "Content-Type": "application/json", "X-Selective-Session-Binding": binding },
    });
  } });
  await client.login({ email: "user@example.invalid", password: passphrase, deviceID: deviceA });
  assert.deepEqual([...values.values()], [binding]);
  assert.equal(JSON.stringify([...values]).includes(token), false);
  assert.equal(JSON.stringify([...values]).includes("user@example.invalid"), false);
  await client.logout();
  assert.equal(values.size, 0);
});

test("a stale tab cannot overwrite another tab's already uploaded changes", async () => {
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(userID);
  const first = localVault(repository, [deviceA, recordA]);
  await first.create(passphrase);
  let remote = remoteValue(0), writes = 0;
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => structuredClone(remote),
    putVault: async (_scope, envelope) => {
      assert.equal(envelope.baseRevision, remote.revision);
      writes += 1;
      remote = remoteValue(remote.revision + 1, envelope);
      return { conflict: false, revision: remote.revision };
    },
  };
  await synchronizeVault({ client, vault: first });
  const stale = localVault(repository, [deviceA, recordB]);
  await stale.unlock(passphrase);
  await first.upsert({ id: recordA, type: "host", data: { title: "First", address: "first.invalid" } });
  await synchronizeVault({ client, vault: first });
  const before = structuredClone(remote);
  await assert.rejects(synchronizeVault({ client, vault: stale }), /local_vault_changed/);
  assert.equal(writes, 2);
  assert.deepEqual(remote, before);
});

test("an edit after a matching remote merge remains dirty and is not reported as synchronized", async () => {
  const repository = createIndexedDBVaultRepository(new IDBFactory()).forAccount(userID);
  const vault = localVault(repository, [deviceA, recordA, recordB]);
  await vault.create(passphrase);
  const initial = await vault.prepareUpload(0);
  await vault.markSynced({ serverRevision: 1, localRevision: 1 });
  const remoteVault = localVault(memoryRepository(), [deviceB, recordA]);
  await remoteVault.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);
  await remoteVault.upsert({ id: recordA, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  const remote = remoteValue(2, (await remoteVault.prepareUpload(1)).envelope);
  const racing = { ...vault, mergeRemote: async value => {
    const result = await vault.mergeRemote(value);
    await vault.upsert({ id: recordB, type: "host", data: { title: "Local", address: "local.invalid" } });
    return result;
  } };
  const client = { session: () => ({ id: userID }), getVault: async () => remote };
  assert.deepEqual(await synchronizeVault({ client, vault: racing }), { status: "downloaded_with_new_local_changes", revision: 2 });
  assert.equal((await vault.syncState()).dirty, true);
  assert.equal(vault.document().records.length, 2);
});

test("a 401 response clears the in-memory browser session", async () => {
  let request = 0;
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path) => {
      request += 1;
      if (path === "/v1/auth/login") {
        return jsonResponse(200, {
          token: "t".repeat(43),
          user: { id: userID, email: "user@example.invalid", username: "user", displayName: "User" },
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
  await vault.bindAccountOwnership(userID);
  const uploadedBases = [];
  let serverRevision = 0;
  let serverEnvelope = null;
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(serverRevision, serverEnvelope),
    putVault: async (_scope, envelope) => {
      uploadedBases.push(envelope.baseRevision);
      serverEnvelope = structuredClone(envelope);
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

test("concurrent records automatically keep the newer version and upload the joined history", async () => {
  const repoA = memoryRepository();
  const repoB = memoryRepository();
  const vaultA = localVault(repoA, [deviceA], "2026-09-04T01:00:00.000Z");
  const vaultB = localVault(repoB, [deviceB], "2026-09-04T02:00:00.000Z");
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
    putVault: async (_scope, envelope) => {
      putCalls += 1;
      assert.equal(envelope.baseRevision, 2);
      return { conflict: false, revision: 3 };
    },
  };

  const result = await synchronizeVault({ client, vault: vaultA });
  assert.deepEqual(result, { status: "uploaded", revision: 3 });
  assert.equal(putCalls, 1);
  assert.equal(vaultA.document().records[0].data.address, "remote.invalid");
  assert.deepEqual(vaultA.document().records[0].version, { [deviceA]: 2, [deviceB]: 1 });
});

test("automatic newest resolution includes unrelated remote records in one conditional upload", async () => {
  const repoA = memoryRepository();
  const repoB = memoryRepository();
  const vaultA = localVault(repoA, [deviceA], "2026-09-04T01:00:00.000Z");
  const vaultB = localVault(repoB, [deviceB], "2026-09-04T02:00:00.000Z");
  await vaultA.create(passphrase);
  const initial = await vaultA.prepareUpload(0);
  await vaultA.markSynced({ serverRevision: 1, localRevision: initial.localRevision });
  await vaultB.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);

  await vaultA.upsert({ id: recordA, type: "host", data: { title: "Local", address: "local.invalid" } });
  await vaultB.upsert({ id: recordA, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  await vaultB.upsert({ id: recordB, type: "snippet", data: { title: "Remote only", body: "uptime" } });
  const remote = await vaultB.prepareUpload(1);
  let serverRevision = 2;
  let uploadedBase = null;
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(serverRevision, remote.envelope),
    putVault: async (_scope, envelope) => {
      uploadedBase = envelope.baseRevision;
      serverRevision += 1;
      return { conflict: false, revision: serverRevision };
    },
  };

  assert.deepEqual(await synchronizeVault({ client, vault: vaultA }), { status: "uploaded", revision: 3 });
  assert.equal(vaultA.pendingConflicts(), null);
  assert.deepEqual(vaultA.document().records.map((record) => record.id), [recordA, recordB]);
  assert.equal(vaultA.document().records[0].data.address, "remote.invalid");
  assert.equal(uploadedBase, 2);
  assert.deepEqual(await vaultA.syncState(), { localRevision: 3, serverRevision: 3, dirty: false });
});

test("a local edit after automatic resolution starts a fresh dirty revision", async () => {
  const repoA = memoryRepository();
  const repoB = memoryRepository();
  const vaultA = localVault(repoA, [deviceA], "2026-09-04T01:00:00.000Z");
  const vaultB = localVault(repoB, [deviceB], "2026-09-04T02:00:00.000Z");
  await vaultA.create(passphrase);
  const initial = await vaultA.prepareUpload(0);
  await vaultA.markSynced({ serverRevision: 1, localRevision: initial.localRevision });
  await vaultB.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);
  await vaultA.upsert({ id: recordA, type: "host", data: { title: "Local", address: "local.invalid" } });
  await vaultB.upsert({ id: recordA, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  const remote = await vaultB.prepareUpload(1);
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(2, remote.envelope),
    putVault: async () => ({ conflict: false, revision: 3 }),
  };

  assert.deepEqual(await synchronizeVault({ client, vault: vaultA }), { status: "uploaded", revision: 3 });
  await vaultA.upsert({ id: recordB, type: "snippet", data: { title: "New local edit", body: "date" } });
  assert.equal(vaultA.pendingConflicts(), null);
  assert.deepEqual(await vaultA.syncState(), { localRevision: 4, serverRevision: 3, dirty: true });
});

test("a server-side optimistic conflict never marks local data as synchronized", async () => {
  const repository = memoryRepository();
  const vault = localVault(repository, [deviceA]);
  await vault.create(passphrase);
  await vault.bindAccountOwnership(userID);
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

test("equal revisions with different Vault keys never confirm or upload foreign local data", async () => {
  const localRepository = memoryRepository();
  const local = localVault(localRepository, [deviceA, recordA]);
  await local.create(passphrase);
  const localInitial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: localInitial.localRevision });
  await local.upsert({ id: recordA, type: "host", data: { title: "Local only", address: "local.invalid" } });
  const before = localRepository.snapshot();

  const other = localVault(memoryRepository(), [deviceB]);
  await other.create(passphrase);
  const remote = await other.prepareUpload(0);
  let uploads = 0;
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(1, remote.envelope),
    putVault: async () => { uploads += 1; return { conflict: false, revision: 2 }; },
  };

  await assert.rejects(synchronizeVault({ client, vault: local }), /remote_wrapped_key_changed/);
  assert.equal(uploads, 0);
  assert.deepEqual(localRepository.snapshot(), before);
  assert.equal((await local.syncState()).dirty, true);
});

test("an existing local Vault cannot upload to an empty account without fresh ownership proof", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA, recordA]);
  await local.create(passphrase);
  await local.upsert({ id: recordA, type: "host", data: { title: "Preserved", address: "local.invalid" } });
  const before = repository.snapshot();
  let uploads = 0;
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(0),
    putVault: async () => { uploads += 1; return { conflict: false, revision: 1 }; },
  };

  await assert.rejects(synchronizeVault({ client, vault: local }), /local_vault_owner_unverified/);
  assert.equal(uploads, 0);
  assert.deepEqual(repository.snapshot(), before);
});

test("a session switch during a Personal Vault read cannot upload to the next account", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA]);
  await local.create(passphrase);
  await local.bindAccountOwnership(userID);
  let account = userID;
  let uploads = 0;
  const client = {
    session: () => ({ id: account }),
    getVault: async () => { account = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"; return remoteValue(0); },
    putVault: async () => { uploads += 1; return { conflict: false, revision: 1 }; },
  };
  await assert.rejects(synchronizeVault({ client, vault: local }), /authentication_required/);
  assert.equal(uploads, 0);
  assert.equal((await local.syncState()).serverRevision, 0);
});

test("a new session for the same account cannot reuse an older in-flight Personal Vault read", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA]);
  await local.create(passphrase);
  await local.bindAccountOwnership(userID);
  let epoch = 1, uploads = 0;
  const client = {
    session: () => ({ id: userID }),
    publicationIdentity: () => ({ accountID: userID, deviceID: deviceA, sessionEpoch: String(epoch) }),
    getVault: async () => { epoch += 1; return remoteValue(0); },
    putVault: async () => { uploads += 1; return { conflict: false, revision: 1 }; },
  };
  await assert.rejects(synchronizeVault({ client, vault: local }), /authentication_required/);
  assert.equal(uploads, 0);
  assert.equal((await local.syncState()).serverRevision, 0);
});

test("a session change while confirming an upload cannot report success for the next session", async () => {
  let epoch = "first";
  const repository = memoryRepository();
  const originalSaveSync = repository.saveSync;
  repository.saveSync = async metadata => { await originalSaveSync(metadata); epoch = "next"; };
  const vault = localVault(repository, [deviceA]);
  await vault.create(passphrase);
  await vault.bindAccountOwnership(userID);
  const client = {
    session: () => ({ id: userID }),
    publicationIdentity: () => ({ accountID: userID, deviceID: deviceA, sessionEpoch: epoch }),
    getVault: async () => remoteValue(0),
    putVault: async () => ({ conflict: false, revision: 1 }),
  };
  await assert.rejects(synchronizeVault({ client, vault }), /authentication_required/);
});
