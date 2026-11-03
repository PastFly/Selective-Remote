import assert from "node:assert/strict";
import { createHash, webcrypto } from "node:crypto";
import test from "node:test";
import { IDBFactory } from "./approved-idb-fixture.mjs";
import { createIndexedDBVaultRepository, createLocalVaultController } from "../public/vault-local.js";
import { encryptVaultPayload } from "../public/vault-crypto.js";
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

test("a verified remote snapshot cannot replace an inaccessible locked browser snapshot", async () => {
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

  await assert.rejects(oldVault.replaceLockedWithRemote({ revision: 5, envelope: remote.envelope }, passphrase), /local_vault_recovery_required/u);
  assert.deepEqual(oldRepository.snapshot(), previousSnapshot);
  assert.equal(oldRepository.previous(), null);
  await oldVault.unlock("an older local wrapper password");
  assert.equal(oldVault.document().records[0].data.address, "old.invalid");
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
    headers: value === null ? {} : { "Content-Type": "application/json",
      ...(status === 200 && value.token && value.user && value.deviceID ? { "X-Selective-Session-Binding": deviceA } : {}) },
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
      if (path === "/v1/meta") return Response.json({}, { headers: { "X-Selective-V1-Write-Fence": "1" } });
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
  const write = calls.find(call => call.path === "/v1/vault" && call.options.method === "PUT");
  assert.equal(write.options.headers.Authorization, `Bearer ${token}`);
  assert.equal(write.options.credentials, "same-origin");
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

test("a late confirmed account deletion preserves the replacement browser session", async () => {
  const secondUser = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  const firstBinding = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const secondBinding = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
  const values = new Map();
  const storage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: key => values.delete(key),
  };
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const client = createAuthenticatedVaultClient({ sessionStorageValue: storage, fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") {
      const first = JSON.parse(options.body).email === "first@example.invalid";
      return new Response(JSON.stringify({ token: (first ? "a" : "b").repeat(43),
        user: { id: first ? userID : secondUser, email: first ? "first@example.invalid" : "second@example.invalid" },
        deviceID: deviceA }), { status: 200, headers: {
        "Content-Type": "application/json", "X-Selective-Session-Binding": first ? firstBinding : secondBinding,
      } });
    }
    if (path === "/v1/me" && options.method === "DELETE") {
      assert.equal(options.headers.Authorization, `Bearer ${"a".repeat(43)}`);
      entered(); await held;
      return jsonResponse(200, { deleted: true });
    }
    if (path === "/v1/auth/logout") return jsonResponse(204, null);
    throw new Error("unexpected_synthetic_request");
  } });
  await client.login({ email: "first@example.invalid", password: passphrase, deviceID: deviceA });
  const deletion = client.deleteAccount({ email: "first@example.invalid", password: passphrase });
  try {
    await started;
    await client.logout();
    await client.login({ email: "second@example.invalid", password: passphrase, deviceID: deviceA });
    const secondEpoch = client.sessionGeneration();
    release();
    const result = await deletion;
    assert.equal(client.session()?.id, secondUser);
    assert.equal(client.sessionGeneration(), secondEpoch);
    assert.equal(values.get("selective-remote:browser-session-binding:v1"), secondBinding);
    assert.deepEqual(result, { deleted: true, sessionChanged: true });
  } finally { release(); }
});

test("a late account deletion cannot invalidate a replacement login in flight", async () => {
  const secondUser = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  let deleteEntered, releaseDelete, loginEntered, releaseLogin;
  const deleteStarted = new Promise(resolve => { deleteEntered = resolve; });
  const deleteHeld = new Promise(resolve => { releaseDelete = resolve; });
  const loginStarted = new Promise(resolve => { loginEntered = resolve; });
  const loginHeld = new Promise(resolve => { releaseLogin = resolve; });
  const client = createAuthenticatedVaultClient({ sessionStorageValue: null, fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") {
      const email = JSON.parse(options.body).email;
      if (email === "second@example.invalid") { loginEntered(); await loginHeld; }
      return jsonResponse(200, { token: "t".repeat(43),
        user: { id: email === "second@example.invalid" ? secondUser : userID, email }, deviceID: deviceA });
    }
    if (path === "/v1/me" && options.method === "DELETE") {
      deleteEntered(); await deleteHeld; return jsonResponse(200, { deleted: true });
    }
    throw new Error("unexpected_synthetic_request");
  } });
  await client.login({ email: "first@example.invalid", password: passphrase, deviceID: deviceA });
  const deletion = client.deleteAccount({ email: "first@example.invalid", password: passphrase });
  let replacement;
  try {
    await deleteStarted;
    replacement = client.login({ email: "second@example.invalid", password: passphrase, deviceID: deviceA });
    await loginStarted;
    const newEpoch = client.sessionGeneration();
    releaseDelete();
    assert.deepEqual(await deletion, { deleted: true, sessionChanged: true });
    assert.equal(client.sessionGeneration(), newEpoch);
    releaseLogin();
    assert.equal((await replacement).id, secondUser);
    assert.equal(client.session()?.id, secondUser);
  } finally {
    releaseDelete(); releaseLogin();
    if (replacement) await replacement.catch(() => {});
  }
});

test("a late username update cannot rewrite the replacement account", async () => {
  const secondUser = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const client = createAuthenticatedVaultClient({ sessionStorageValue: null, fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") {
      const first = JSON.parse(options.body).email === "first@example.invalid";
      return jsonResponse(200, { token: (first ? "a" : "b").repeat(43), deviceID: deviceA,
        user: { id: first ? userID : secondUser, email: first ? "first@example.invalid" : "second@example.invalid",
          username: first ? "first" : "second", displayName: first ? "First" : "Second" } });
    }
    if (path === "/v1/account/username" && options.method === "PATCH") {
      assert.equal(options.headers.Authorization, `Bearer ${"a".repeat(43)}`);
      entered(); await held;
      return jsonResponse(200, { username: "first-renamed" });
    }
    throw new Error("unexpected_synthetic_request");
  } });
  await client.login({ email: "first@example.invalid", password: passphrase, deviceID: deviceA });
  const update = client.updateUsername({ username: "first-renamed", password: passphrase });
  try {
    await started;
    await client.login({ email: "second@example.invalid", password: passphrase, deviceID: deviceA });
    const newEpoch = client.sessionGeneration();
    release();
    const result = await update;
    assert.equal(client.session()?.id, secondUser);
    assert.equal(client.session()?.username, "second");
    assert.equal(client.sessionGeneration(), newEpoch);
    assert.deepEqual(result, { id: userID, email: "first@example.invalid", username: "first-renamed",
      displayName: "First", sessionChanged: true });
  } finally { release(); }
});

test("a username update confirmed after logout does not recreate a session", async () => {
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const client = createAuthenticatedVaultClient({ sessionStorageValue: null, fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") return jsonResponse(200, { token: "a".repeat(43), deviceID: deviceA,
      user: { id: userID, email: "first@example.invalid", username: "first", displayName: "First" } });
    if (path === "/v1/account/username" && options.method === "PATCH") {
      entered(); await held; return jsonResponse(200, { username: "first-renamed" });
    }
    if (path === "/v1/auth/logout") return jsonResponse(204, null);
    throw new Error("unexpected_synthetic_request");
  } });
  await client.login({ email: "first@example.invalid", password: passphrase, deviceID: deviceA });
  const update = client.updateUsername({ username: "first-renamed", password: passphrase });
  try {
    await started;
    await client.logout();
    const loggedOutEpoch = client.sessionGeneration();
    release();
    assert.deepEqual(await update, { id: userID, email: "first@example.invalid", username: "first-renamed",
      displayName: "First", sessionChanged: true });
    assert.equal(client.session(), null);
    assert.equal(client.sessionGeneration(), loggedOutEpoch);
  } finally { release(); }
});

test("confirmed deletion retires only its current session and keeps its existing result shape", async () => {
  const binding = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  const values = new Map();
  const storage = {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: key => values.delete(key),
  };
  const client = createAuthenticatedVaultClient({ sessionStorageValue: storage, fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") return new Response(JSON.stringify({ token: "a".repeat(43),
      user: { id: userID, email: "first@example.invalid" }, deviceID: deviceA }), {
      status: 200, headers: { "Content-Type": "application/json", "X-Selective-Session-Binding": binding },
    });
    if (path === "/v1/me" && options.method === "DELETE") return jsonResponse(200, { deleted: true });
    throw new Error("unexpected_synthetic_request");
  } });
  await client.login({ email: "first@example.invalid", password: passphrase, deviceID: deviceA });
  let identityAtNotification = "not-notified";
  client.subscribePublicationIdentity(() => { identityAtNotification = client.session(); });
  const originalEpoch = Number(client.sessionGeneration());
  assert.deepEqual(await client.deleteAccount({ email: "first@example.invalid", password: passphrase }), { deleted: true });
  assert.equal(client.session(), null);
  assert.equal(identityAtNotification, null);
  assert.equal(Number(client.sessionGeneration()), originalEpoch + 1);
  assert.equal(values.has("selective-remote:browser-session-binding:v1"), false);
});

test("a replacement login during deletion response parsing is preserved", async () => {
  const secondUser = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const client = createAuthenticatedVaultClient({ sessionStorageValue: null, fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") {
      const first = JSON.parse(options.body).email === "first@example.invalid";
      return jsonResponse(200, { token: (first ? "a" : "b").repeat(43), deviceID: deviceA,
        user: { id: first ? userID : secondUser, email: first ? "first@example.invalid" : "second@example.invalid" } });
    }
    if (path === "/v1/me" && options.method === "DELETE") return {
      status: 200, ok: true, async json() { entered(); await held; return { deleted: true }; },
    };
    throw new Error("unexpected_synthetic_request");
  } });
  await client.login({ email: "first@example.invalid", password: passphrase, deviceID: deviceA });
  const deletion = client.deleteAccount({ email: "first@example.invalid", password: passphrase });
  try {
    await started;
    await client.login({ email: "second@example.invalid", password: passphrase, deviceID: deviceA });
    const newEpoch = client.sessionGeneration();
    release();
    assert.deepEqual(await deletion, { deleted: true, sessionChanged: true });
    assert.equal(client.session()?.id, secondUser);
    assert.equal(client.sessionGeneration(), newEpoch);
  } finally { release(); }
});

test("a late rejected deletion cannot retire a replacement session", async () => {
  const secondUser = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  let entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const client = createAuthenticatedVaultClient({ sessionStorageValue: null, fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") {
      const first = JSON.parse(options.body).email === "first@example.invalid";
      return jsonResponse(200, { token: (first ? "a" : "b").repeat(43), deviceID: deviceA,
        user: { id: first ? userID : secondUser, email: first ? "first@example.invalid" : "second@example.invalid" } });
    }
    if (path === "/v1/me" && options.method === "DELETE") {
      entered(); await held; return jsonResponse(401, { error: "authentication_required" });
    }
    throw new Error("unexpected_synthetic_request");
  } });
  await client.login({ email: "first@example.invalid", password: passphrase, deviceID: deviceA });
  const deletion = client.deleteAccount({ email: "first@example.invalid", password: passphrase });
  try {
    await started;
    await client.login({ email: "second@example.invalid", password: passphrase, deviceID: deviceA });
    const newEpoch = client.sessionGeneration();
    release();
    await assert.rejects(deletion, /authentication_required/);
    assert.equal(client.session()?.id, secondUser);
    assert.equal(client.sessionGeneration(), newEpoch);
  } finally { release(); }
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
    if (path === "/v1/meta") return Response.json({}, { headers: { "X-Selective-V1-Write-Fence": "1" } });
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

test("login refuses a legacy server without a verifiable browser session binding", async () => {
  for (const binding of [null, "invalid-binding"]) {
    const calls = [];
    const storage = new Map();
    const client = createAuthenticatedVaultClient({
      sessionStorageValue: { getItem: key => storage.get(key), setItem: (key, value) => storage.set(key, value), removeItem: key => storage.delete(key) },
      fetchValue: async (path, options) => {
        calls.push({ path, method: options.method });
        const headers = { "Content-Type": "application/json" };
        if (binding !== null) headers["X-Selective-Session-Binding"] = binding;
        return new Response(JSON.stringify({ token: "a".repeat(43), user: { id: userID }, deviceID: deviceA }), { status: 200, headers });
      },
    });
    await assert.rejects(client.login({ email: "synthetic@example.invalid", password: "synthetic-password", deviceID: deviceA }), /cloud_upgrade_required/u);
    assert.equal(client.session(), null);
    assert.equal(storage.size, 0);
    assert.deepEqual(calls, [{ path: "/v1/auth/login", method: "POST" }]);
  }
});

test("cookie session restore reports an unsupported server and remains locked", async () => {
  const client = createAuthenticatedVaultClient({ fetchValue: async () => jsonResponse(200, {
    id: userID, deviceID: deviceA, email: "user@example.invalid",
  }) });
  await assert.rejects(client.restoreSession(), /cloud_upgrade_required/);
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
  await vault.markSynced({ serverRevision: 1, localRevision: 1, serverContentHash: initial.envelope.contentHash });
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

test("a current authenticated 401 notifies identity listeners with the retired session receipt", async () => {
  const client = createAuthenticatedVaultClient({
    fetchValue: async (path) => path === "/v1/auth/login"
      ? jsonResponse(200, { token: "t".repeat(43), deviceID: deviceA,
        user: { id: userID, email: "synthetic@example.invalid", username: "synthetic" } })
      : jsonResponse(401, { error: "unauthorized" }),
  });
  await client.login({ email: "synthetic@example.invalid", password: "synthetic-password", deviceID: deviceA });
  const before = client.sessionGeneration();
  const notifications = [];
  client.subscribePublicationIdentity((cause) => {
    notifications.push({ cause, current: client.session(), generation: client.sessionGeneration() });
  });
  await assert.rejects(client.getVault(), /authentication_required/u);
  assert.equal(notifications.length, 1);
  assert.equal(notifications[0].cause?.message, "authentication_required");
  assert.equal(notifications[0].cause?.invalidatedSessionEpoch, before);
  assert.equal(notifications[0].cause?.retiredAuthenticatedSession, true);
  assert.equal(notifications[0].current, null);
  assert.equal(notifications[0].generation, String(Number(before) + 1));
});

test("a delayed 401 from an older request does not emit retirement for a newer session", async () => {
  const nextUser = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
  let enter, release;
  const started = new Promise((resolve) => { enter = resolve; });
  const held = new Promise((resolve) => { release = resolve; });
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") {
      const first = JSON.parse(options.body).email === "first@example.invalid";
      return jsonResponse(200, { token: (first ? "a" : "b").repeat(43), deviceID: deviceA,
        user: { id: first ? userID : nextUser, email: first ? "first@example.invalid" : "next@example.invalid" } });
    }
    enter();
    await held;
    return jsonResponse(401, { error: "unauthorized" });
  } });
  await client.login({ email: "first@example.invalid", password: "synthetic-password", deviceID: deviceA });
  const causes = [];
  client.subscribePublicationIdentity((cause) => { if (cause) causes.push(cause); });
  const pending = client.getVault();
  await started;
  await client.login({ email: "next@example.invalid", password: "synthetic-password", deviceID: deviceA });
  release();
  await assert.rejects(pending, /authentication_required/u);
  assert.equal(client.session()?.id, nextUser);
  assert.deepEqual(causes, []);
});

test("temporary write stop keeps Personal changes dirty and never confirms upload", async () => {
  const repository = memoryRepository();
  const vault = localVault(repository, [deviceA, recordA]);
  await vault.create(passphrase);
  await vault.bindAccountOwnership(userID);
  await vault.upsert({ id: recordA, type: "host", data: { title: "TEST-ONLY-CODEX-HOST", address: "192.0.2.10" } });
  const before = structuredClone(repository.snapshot());
  const beforeDocument = structuredClone(vault.document());
  const beforeState = await vault.syncState();
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(0),
    putVault: async () => { throw new Error("vault_write_temporarily_unavailable"); },
  };
  await assert.rejects(synchronizeVault({ client, vault }), /vault_write_temporarily_unavailable/u);
  assert.deepEqual(repository.snapshot(), before);
  assert.deepEqual(vault.document(), beforeDocument);
  assert.deepEqual(await vault.syncState(), beforeState);
  assert.equal((await vault.syncState()).dirty, true);
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
  await vaultA.markSynced({ serverRevision: 1, localRevision: initial.localRevision, serverContentHash: initial.envelope.contentHash });
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

test("concurrent records require an explicit choice before uploading the joined history", async () => {
  const repoA = memoryRepository();
  const repoB = memoryRepository();
  const vaultA = localVault(repoA, [deviceA], "2026-09-04T01:00:00.000Z");
  const vaultB = localVault(repoB, [deviceB], "2026-09-04T02:00:00.000Z");
  await vaultA.create(passphrase);
  const initial = await vaultA.prepareUpload(0);
  await vaultA.markSynced({ serverRevision: 1, localRevision: initial.localRevision, serverContentHash: initial.envelope.contentHash });
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
  assert.equal(result.status, "conflict");
  assert.equal(putCalls, 0);
  assert.equal(vaultA.document().records[0].data.address, "local.invalid");
  await vaultA.resolveConflicts({ revision: 2, resolutions: [{ id: recordA, choice: "remote" }] });
  assert.deepEqual(await synchronizeVault({ client, vault: vaultA }), { status: "uploaded", revision: 3 });
  assert.equal(putCalls, 1);
  assert.equal(vaultA.document().records[0].data.address, "remote.invalid");
  assert.deepEqual(vaultA.document().records[0].version, { [deviceA]: 2, [deviceB]: 1 });
});

test("explicit conflict resolution includes unrelated remote records in one conditional upload", async () => {
  const repoA = memoryRepository();
  const repoB = memoryRepository();
  const vaultA = localVault(repoA, [deviceA], "2026-09-04T01:00:00.000Z");
  const vaultB = localVault(repoB, [deviceB], "2026-09-04T02:00:00.000Z");
  await vaultA.create(passphrase);
  const initial = await vaultA.prepareUpload(0);
  await vaultA.markSynced({ serverRevision: 1, localRevision: initial.localRevision, serverContentHash: initial.envelope.contentHash });
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

  assert.equal((await synchronizeVault({ client, vault: vaultA })).status, "conflict");
  assert.equal(uploadedBase, null);
  await vaultA.resolveConflicts({ revision: 2, resolutions: [{ id: recordA, choice: "remote" }] });
  assert.deepEqual(await synchronizeVault({ client, vault: vaultA }), { status: "uploaded", revision: 3 });
  assert.equal(vaultA.pendingConflicts(), null);
  assert.deepEqual(vaultA.document().records.map((record) => record.id), [recordA, recordB]);
  assert.equal(vaultA.document().records[0].data.address, "remote.invalid");
  assert.equal(uploadedBase, 2);
  assert.deepEqual(await vaultA.syncState(), { localRevision: 3, serverRevision: 3, dirty: false });
});

test("a local edit after explicit resolution starts a fresh dirty revision", async () => {
  const repoA = memoryRepository();
  const repoB = memoryRepository();
  const vaultA = localVault(repoA, [deviceA], "2026-09-04T01:00:00.000Z");
  const vaultB = localVault(repoB, [deviceB], "2026-09-04T02:00:00.000Z");
  await vaultA.create(passphrase);
  const initial = await vaultA.prepareUpload(0);
  await vaultA.markSynced({ serverRevision: 1, localRevision: initial.localRevision, serverContentHash: initial.envelope.contentHash });
  await vaultB.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);
  await vaultA.upsert({ id: recordA, type: "host", data: { title: "Local", address: "local.invalid" } });
  await vaultB.upsert({ id: recordA, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  const remote = await vaultB.prepareUpload(1);
  const client = {
    session: () => ({ id: userID }),
    getVault: async () => remoteValue(2, remote.envelope),
    putVault: async () => ({ conflict: false, revision: 3 }),
  };

  assert.equal((await synchronizeVault({ client, vault: vaultA })).status, "conflict");
  await vaultA.resolveConflicts({ revision: 2, resolutions: [{ id: recordA, choice: "remote" }] });
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
  await vault.markSynced({ serverRevision: 1, localRevision: prepared.localRevision,
    serverContentHash: prepared.envelope.contentHash });
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
  await local.markSynced({ serverRevision: 1, localRevision: localInitial.localRevision,
    serverContentHash: localInitial.envelope.contentHash });
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

for (const recomputeHash of [false, true]) {
  test(`a damaged Cloud copy at the same revision is not overwritten (${recomputeHash ? "AEAD failure" : "hash mismatch"})`, async () => {
    const repository = memoryRepository();
    const vault = localVault(repository, [deviceA, recordA]);
    await vault.create(passphrase);
    const initial = await vault.prepareUpload(0);
    await vault.markSynced({ serverRevision: 1, localRevision: initial.localRevision,
      serverContentHash: initial.envelope.contentHash });
    await vault.upsert({ id: recordA, type: "host", data: { title: "Local", address: "local.invalid" } });
    const before = repository.snapshot();
    const envelope = structuredClone(initial.envelope);
    const ciphertext = Buffer.from(envelope.ciphertext, "base64url");
    ciphertext[0] ^= 1;
    envelope.ciphertext = ciphertext.toString("base64url");
    if (recomputeHash) {
      envelope.contentHash = createHash("sha256").update(Buffer.concat([
        Buffer.from([1]), Buffer.from(envelope.nonce, "base64url"), ciphertext,
        Buffer.from(envelope.authTag, "base64url"),
      ])).digest("base64url");
    }
    let uploads = 0;
    const client = { session: () => ({ id: userID }), getVault: async () => remoteValue(1, envelope),
      putVault: async () => { uploads++; return { conflict: false, revision: 2 }; } };
    await assert.rejects(synchronizeVault({ client, vault }), recomputeHash ? /vault_decryption_failed/u : /vault_content_hash_mismatch/u);
    assert.equal(uploads, 0);
    assert.deepEqual(repository.snapshot(), before);
    assert.equal((await vault.syncState()).dirty, true);
  });
}

test("different valid contents at an unchanged Cloud revision cannot be silently overwritten", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA, recordA]);
  await local.create(passphrase);
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision,
    serverContentHash: initial.envelope.contentHash });
  const other = localVault(memoryRepository(), [deviceB, recordB]);
  await other.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);
  await other.upsert({ id: recordB, type: "snippet", data: { title: "Cloud only", body: "echo remote" } });
  const changedAtSameRevision = await other.prepareUpload(0);
  await local.upsert({ id: recordA, type: "host", data: { title: "Local only", address: "local.invalid" } });
  const before = repository.snapshot();
  let uploads = 0;
  const client = { session: () => ({ id: userID }), getVault: async () => remoteValue(1, changedAtSameRevision.envelope),
    putVault: async () => { uploads++; return { conflict: false, revision: 2 }; } };
  await assert.rejects(synchronizeVault({ client, vault: local }), /remote_same_revision_changed/u);
  assert.equal(uploads, 0);
  assert.deepEqual(repository.snapshot(), before);
  assert.equal((await local.syncState()).dirty, true);
});

test("a same-revision changed record cannot be overwritten even when local version dominates", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA, recordA]);
  await local.create(passphrase);
  await local.upsert({ id: recordA, type: "host", data: { title: "Original", address: "original.invalid" } });
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision,
    serverContentHash: initial.envelope.contentHash });
  const altered = local.document();
  altered.records[0].data.address = "other.invalid";
  const envelope = await encryptVaultPayload({ vaultKey: local.sessionKey(), payload: altered,
    baseRevision: 0, wrappedKey: initial.envelope.wrappedKey, cryptoValue: webcrypto });
  await local.upsert({ id: recordA, type: "host", data: { title: "Local", address: "local.invalid" } });
  const before = repository.snapshot();
  let uploads = 0;
  const client = { session: () => ({ id: userID }), getVault: async () => remoteValue(1, envelope),
    putVault: async () => { uploads++; return { conflict: false, revision: 2 }; } };
  await assert.rejects(synchronizeVault({ client, vault: local }), /remote_same_revision_changed/u);
  assert.equal(uploads, 0);
  assert.deepEqual(repository.snapshot(), before);
});

test("legacy dirty metadata without a confirmed Cloud fingerprint never authorizes an upload", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA, recordA]);
  await local.create(passphrase);
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision });
  await local.upsert({ id: recordA, type: "host", data: { title: "Local", address: "local.invalid" } });
  const before = repository.snapshot();
  let uploads = 0;
  const client = { session: () => ({ id: userID }), getVault: async () => remoteValue(1, initial.envelope),
    putVault: async () => { uploads++; return { conflict: false, revision: 2 }; } };
  await assert.rejects(synchronizeVault({ client, vault: local }), /remote_history_unverified/u);
  assert.equal(uploads, 0);
  assert.deepEqual(repository.snapshot(), before);
});

test("legacy dirty metadata stops before merging a newer Cloud revision", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA, recordA]);
  await local.create(passphrase);
  await local.upsert({ id: recordA, type: "host", data: { title: "Original", address: "original.invalid" } });
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision });
  const other = localVault(memoryRepository(), [deviceB]);
  await other.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);
  await local.upsert({ id: recordA, type: "host", data: { title: "Offline", address: "offline.invalid" } });
  await other.upsert({ id: recordA, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  const remote = await other.prepareUpload(1), before = repository.snapshot();
  let uploads = 0;
  const client = { session: () => ({ id: userID }), getVault: async () => remoteValue(2, remote.envelope),
    putVault: async () => { uploads++; return { conflict: false, revision: 3 }; } };
  await assert.rejects(synchronizeVault({ client, vault: local }), /remote_history_unverified/u);
  assert.equal(uploads, 0);
  assert.deepEqual(repository.snapshot(), before);
  assert.equal(local.document().records[0].data.address, "offline.invalid");
});

test("a newer Cloud revision is not overwritten when clean legacy metadata has no fingerprint", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA, recordA]);
  await local.create(passphrase);
  await local.upsert({ id: recordA, type: "host", data: { title: "Old", address: "cloud.invalid" } });
  const older = await local.prepareUpload(0);
  await local.upsert({ id: recordA, type: "host", data: { title: "Local", address: "local.invalid" } });
  await local.markSynced({ serverRevision: 1, localRevision: (await local.prepareUpload(0)).localRevision });
  const before = repository.snapshot();
  let uploads = 0;
  const client = { session: () => ({ id: userID }),
    getVault: async () => remoteValue(2, { ...older.envelope, baseRevision: 1 }),
    putVault: async () => { uploads++; return { conflict: false, revision: 3 }; } };
  await assert.rejects(synchronizeVault({ client, vault: local }), /remote_history_unverified/u);
  assert.equal(uploads, 0);
  assert.deepEqual(repository.snapshot(), before);
});

test("an offline edit during remote decrypt cannot invalidate a confirmed snapshot", async () => {
  const repository = memoryRepository();
  let holdDecrypt = false, entered, release;
  const started = new Promise(resolve => { entered = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const cryptoValue = { getRandomValues: webcrypto.getRandomValues.bind(webcrypto),
    subtle: new Proxy(webcrypto.subtle, { get(target, key) {
      if (key === "decrypt") return async (...args) => { if (holdDecrypt) { entered(); await held; } return target.decrypt(...args); };
      const value = target[key]; return typeof value === "function" ? value.bind(target) : value;
    } }) };
  const local = createLocalVaultController({ repository, cryptoValue, randomUUID: () => deviceA,
    now: () => "2026-09-04T00:00:00.000Z" });
  await local.create(passphrase);
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision,
    serverContentHash: initial.envelope.contentHash });
  const other = localVault(memoryRepository(), [deviceB]);
  await other.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);
  await other.upsert({ id: recordB, type: "snippet", data: { title: "Remote", body: "echo remote" } });
  const remote = await other.prepareUpload(1);
  let uploads = 0;
  const client = { session: () => ({ id: userID }), getVault: async () => remoteValue(2, remote.envelope),
    putVault: async () => { uploads++; return { conflict: false, revision: 3 }; } };
  holdDecrypt = true;
  const pending = synchronizeVault({ client, vault: local });
  await started;
  await local.upsert({ id: recordA, type: "host", data: { title: "Offline", address: "offline.invalid" } });
  const before = repository.snapshot();
  release();
  await assert.rejects(pending, /local_vault_changed/u);
  assert.equal(uploads, 0);
  assert.deepEqual(repository.snapshot(), before);
});

test("concurrent offline edits are preserved until the user explicitly resolves the conflict", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA, recordA], "2026-09-04T01:00:00.000Z");
  await local.create(passphrase);
  await local.upsert({ id: recordA, type: "host", data: { title: "Original", address: "original.invalid" } });
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision,
    serverContentHash: initial.envelope.contentHash });
  const other = localVault(memoryRepository(), [deviceB], "2026-09-04T02:00:00.000Z");
  await other.importRemote({ revision: 1, envelope: initial.envelope }, passphrase);
  await local.upsert({ id: recordA, type: "host", data: { title: "Offline", address: "offline.invalid" } });
  await other.upsert({ id: recordA, type: "host", data: { title: "Remote", address: "remote.invalid" } });
  const remote = await other.prepareUpload(1), before = repository.snapshot();
  let uploads = 0;
  const client = { session: () => ({ id: userID }), getVault: async () => remoteValue(2, remote.envelope),
    putVault: async (_scope, envelope) => { uploads++; assert.equal(envelope.baseRevision, 2); return { conflict: false, revision: 3 }; } };
  const result = await synchronizeVault({ client, vault: local });
  assert.equal(result.status, "conflict");
  assert.equal(result.conflicts.length, 1);
  assert.equal(uploads, 0);
  assert.deepEqual(repository.snapshot(), before);
  assert.equal(local.document().records[0].data.address, "offline.invalid");
  await local.resolveConflicts({ revision: 2, resolutions: [{ id: recordA, choice: "local" }] });
  assert.equal(local.document().records[0].data.address, "offline.invalid");
  assert.deepEqual(await synchronizeVault({ client, vault: local }), { status: "uploaded", revision: 3 });
  assert.equal(uploads, 1);
});

test("a clean legacy snapshot establishes its Cloud fingerprint before later edits upload", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA, recordA]);
  await local.create(passphrase);
  const initial = await local.prepareUpload(0);
  await local.markSynced({ serverRevision: 1, localRevision: initial.localRevision });
  let remote = remoteValue(1, initial.envelope), uploads = 0;
  const client = { session: () => ({ id: userID }), getVault: async () => structuredClone(remote),
    putVault: async (_scope, envelope) => {
      uploads++; remote = remoteValue(2, envelope); return { conflict: false, revision: 2 };
    } };
  assert.deepEqual(await synchronizeVault({ client, vault: local }), { status: "up_to_date", revision: 1 });
  assert.equal((await repository.loadSync()).serverContentHash, initial.envelope.contentHash);
  await local.upsert({ id: recordA, type: "host", data: { title: "Local", address: "local.invalid" } });
  assert.deepEqual(await synchronizeVault({ client, vault: local }), { status: "uploaded", revision: 2 });
  assert.equal(uploads, 1);
  assert.equal((await repository.loadSync()).serverContentHash, remote.envelope.contentHash);
});

test("locking during fingerprint metadata lookup does not write stale sync state", async () => {
  const repository = memoryRepository();
  const local = localVault(repository, [deviceA]);
  await local.create(passphrase);
  const initial = await local.prepareUpload(0);
  const priorLoad = repository.loadSync, priorSave = repository.saveSync;
  let enter, release, saves = 0;
  const started = new Promise(resolve => { enter = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  repository.loadSync = async () => { enter(); await held; return priorLoad(); };
  repository.saveSync = async value => { saves++; return priorSave(value); };
  const pending = local.markSynced({ serverRevision: 1, localRevision: initial.localRevision,
    serverContentHash: initial.envelope.contentHash });
  await started;
  local.lock();
  release();
  await assert.rejects(pending, /local_vault_locked/u);
  assert.equal(saves, 0);
  assert.equal(await priorLoad(), null);
});

test("a changed account session cannot commit delayed upload metadata", async () => {
  const indexedDB = new IDBFactory(), repository = createIndexedDBVaultRepository(indexedDB).forAccount(userID);
  let armed = false, enter, release, epoch = "1";
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, async saveSyncIfCurrent(...args) {
    if (armed) { enter(); await held; }
    return repository.saveSyncIfCurrent(...args);
  } };
  const vault = localVault(delayed, [deviceA]);
  await vault.create(passphrase);
  await vault.bindAccountOwnership(userID);
  const client = { session: () => ({ id: userID }),
    publicationIdentity: () => ({ accountID: userID, deviceID: deviceA, sessionEpoch: epoch }),
    getVault: async () => remoteValue(0),
    putVault: async () => ({ conflict: false, revision: 1 }) };
  armed = true;
  const pending = synchronizeVault({ client, vault });
  await started;
  epoch = "2";
  release();
  await assert.rejects(pending, /authentication_required/u);
  assert.equal(await repository.loadSync(), null);
});

test("a changed session cannot pin a delayed legacy Personal fingerprint", async () => {
  const indexedDB = new IDBFactory(), repository = createIndexedDBVaultRepository(indexedDB).forAccount(userID);
  let armed = false, enter, release, epoch = "1";
  const started = new Promise(resolve => { enter = resolve; }), held = new Promise(resolve => { release = resolve; });
  const delayed = { ...repository, async saveSyncIfCurrent(...args) {
    if (armed) { enter(); await held; }
    return repository.saveSyncIfCurrent(...args);
  } };
  const vault = localVault(delayed, [deviceA]);
  await vault.create(passphrase);
  const initial = await vault.prepareUpload(0);
  await vault.markSynced({ serverRevision: 1, localRevision: initial.localRevision });
  const before = await repository.loadSync();
  const client = { session: () => ({ id: userID }),
    publicationIdentity: () => ({ accountID: userID, deviceID: deviceA, sessionEpoch: epoch }),
    getVault: async () => remoteValue(1, initial.envelope) };
  armed = true;
  const pending = synchronizeVault({ client, vault });
  await started;
  epoch = "2";
  release();
  await assert.rejects(pending, /authentication_required/u);
  assert.deepEqual(await repository.loadSync(), before);
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
