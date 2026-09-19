import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import * as vaultSync from "../public/vault-sync.js";
import { ensureTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import * as portal from "../public/app.js";

const { createAuthenticatedVaultClient } = vaultSync;

const deviceID = "84f6c860-0d26-4ef5-8652-27cb8b991b70";

test("browser registration sends JSON without persisting or returning a password", async () => {
  let request;
  const client = createAuthenticatedVaultClient({
    async fetchValue(...values) {
      request = values;
      return { ok: true, status: 201, async json() { return { verificationRequired: true }; } };
    },
  });

  const result = await client.register({
    displayName: "Leonid",
    username: "leonid",
    email: "owner@example.com",
    password: "a sufficiently long password",
    deviceID,
    invitationToken: "opaque-invitation-token",
  });
  assert.deepEqual(result, { verificationRequired: true });
  assert.equal(request[0], "/v1/auth/register");
  assert.equal(request[1].method, "POST");
  assert.equal(request[1].headers["Content-Type"], "application/json");
  assert.equal(request[1].cache, "no-store");
  const body = JSON.parse(request[1].body);
  assert.equal(body.email, "owner@example.com");
  assert.equal(body.username, "leonid");
  assert.equal(body.device.id, deviceID);
  assert.equal(body.invitationToken, "opaque-invitation-token");
  assert.equal("password" in result, false);
});

test("browser surfaces bounded registration and login errors", async () => {
  const registrationClient = createAuthenticatedVaultClient({
    fetchValue: async () => ({ ok: false, status: 403, async json() { return { error: "registration_disabled" }; } }),
  });
  await assert.rejects(
    registrationClient.register({ displayName: "Owner", username: "owner", email: "owner@example.com", password: "a sufficiently long password", deviceID }),
    /registration_disabled/,
  );

  const loginClient = createAuthenticatedVaultClient({
    fetchValue: async () => ({ ok: false, status: 403, async json() { return { error: "email_not_verified" }; } }),
  });
  await assert.rejects(
    loginClient.login({ email: "owner@example.com", password: "a sufficiently long password", deviceID }),
    /email_not_verified/,
  );

  const collisionClient = createAuthenticatedVaultClient({
    fetchValue: async () => ({ ok: false, status: 409, async json() { return { error: "device_conflict" }; } }),
  });
  await assert.rejects(
    collisionClient.register({ displayName: "Owner", username: "owner", email: "owner@example.com", password: "a sufficiently long password", deviceID }),
    /device_conflict/u,
  );
});

test("same-browser registration retries one device collision with a distinct Team identity", async () => {
  assert.equal(typeof vaultSync.registerWithDeviceConflictRetry, "function");
  const replacementDeviceID = "22222222-2222-4222-8222-222222222222";
  const registrations = [];
  const identities = new Map();
  const identityRepository = {
    async load(id) { return identities.get(id) ?? null; },
    async save(value) { identities.set(value.deviceID, value); },
    async saveIfAbsent(value) {
      if (!identities.has(value.deviceID)) identities.set(value.deviceID, value);
      return identities.get(value.deviceID);
    },
  };
  let mappedDeviceID = null;
  const accountDevices = {
    async deviceID() { return mappedDeviceID ?? deviceID; },
    async remember(_email, id) { mappedDeviceID ??= id; return mappedDeviceID; },
    async accepted(_email, id) { assert.equal(id, replacementDeviceID); },
    async replaceAfterConflict(_email, expected) {
      assert.equal(expected, deviceID);
      mappedDeviceID = replacementDeviceID;
      return mappedDeviceID;
    },
  };
  const result = await vaultSync.registerWithDeviceConflictRetry({
    input: {
      displayName: "Browser Test",
      username: "browser-test",
      email: "new@example.com",
      password: "a sufficiently long password",
    },
    accountDevices,
    ensureIdentity: (id) => ensureTeamDeviceIdentity({ repository: identityRepository, deviceID: id, cryptoValue: webcrypto }),
    async register(input) {
      registrations.push(input);
      if (registrations.length === 1) throw new Error("device_conflict");
      return { verificationRequired: true };
    },
  });

  assert.deepEqual(result, { verificationRequired: true });
  assert.deepEqual(registrations.map(({ deviceID: id }) => id), [deviceID, replacementDeviceID]);
  assert.equal(mappedDeviceID, replacementDeviceID);
  assert.equal(identities.size, 2);
  assert.notDeepEqual(registrations[0].publicKey, registrations[1].publicKey);
});

test("registration never retries more than once or retries another failure", async () => {
  assert.equal(typeof vaultSync.registerWithDeviceConflictRetry, "function");
  for (const [code, expectedCalls] of [["device_conflict", 2], ["registration_failed", 1]]) {
    let calls = 0;
    let replacements = 0;
    await assert.rejects(vaultSync.registerWithDeviceConflictRetry({
      input: { email: "new@example.com" },
      accountDevices: {
        async deviceID() { return deviceID; },
        async remember(_email, id) { return id; },
        async accepted() {},
        async replaceAfterConflict() { replacements += 1; return "22222222-2222-4222-8222-222222222222"; },
      },
      async ensureIdentity(id) { return { publicKey: { kty: "EC", crv: "P-256", x: id, y: id } }; },
      async register() { calls += 1; throw new Error(code); },
    }), new RegExp(code, "u"));
    assert.equal(calls, expectedCalls);
    assert.equal(replacements, code === "device_conflict" ? 1 : 0);
  }
});

test("a device conflict for an accepted account mapping stays privacy-safe without rotating identity", async () => {
  let registrations = 0;
  let replacements = 0;
  let accepted = 0;
  const result = await vaultSync.registerWithDeviceConflictRetry({
    input: { email: "known@example.com" },
    accountDevices: {
      async deviceID() { return deviceID; },
      async remember(_email, id) { return id; },
      async accepted() { accepted += 1; },
      async replaceAfterConflict() { replacements += 1; return null; },
    },
    async ensureIdentity() { return { publicKey: { kty: "EC", crv: "P-256", x: "x", y: "y" } }; },
    async register() { registrations += 1; throw new Error("device_conflict"); },
  });

  assert.deepEqual(result, { verificationRequired: true });
  assert.equal(registrations, 1);
  assert.equal(replacements, 1);
  assert.equal(accepted, 0);
});

test("password recovery uses a generic no-store response", async () => {
  let request;
  const client = createAuthenticatedVaultClient({
    fetchValue: async (...values) => {
      request = values;
      return { ok: true, status: 202, async json() { return { accepted: true }; } };
    },
  });
  assert.deepEqual(await client.requestPasswordReset("owner@example.com"), { accepted: true });
  assert.equal(request[0], "/v1/auth/request-password-reset");
  assert.equal(request[1].cache, "no-store");
  assert.deepEqual(JSON.parse(request[1].body), { email: "owner@example.com" });
});

test("authenticated account deletion clears the in-memory session", async () => {
  const calls = [];
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
    calls.push([path, options]);
    if (path === "/v1/auth/login") return new Response(JSON.stringify({
      token: "t".repeat(43), user: { id: deviceID, email: "owner@example.com", username: "owner", displayName: "Owner" }, deviceID,
    }), { status: 200, headers: { "Content-Type": "application/json" } });
    if (path === "/v1/me" && options.method === "DELETE") {
      return new Response(JSON.stringify({ deleted: true }), { status: 200, headers: { "Content-Type": "application/json" } });
    }
    throw new Error(`unexpected:${path}`);
  } });
  await client.login({ email: "owner@example.com", password: "a sufficiently long password", deviceID });
  assert.deepEqual(await client.deleteAccount({ email: "owner@example.com", password: "a sufficiently long password" }), { deleted: true });
  assert.equal(client.session(), null);
  assert.deepEqual(JSON.parse(calls.at(-1)[1].body), { email: "owner@example.com", password: "a sufficiently long password" });
  assert.match(calls.at(-1)[1].headers.Authorization, /^Bearer /u);
});

test("authenticated account settings check and update username and password", async () => {
  const calls = [];
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
    calls.push([path, options]);
    if (path === "/v1/auth/login") return new Response(JSON.stringify({
      token: "t".repeat(43), user: { id: deviceID, email: "owner@example.com", username: "owner", displayName: "Owner" }, deviceID,
    }), { status: 200, headers: { "Content-Type": "application/json" } });
    if (path.startsWith("/v1/account/username-availability")) return new Response(JSON.stringify({ username: "new.owner", available: true }), { status: 200 });
    if (path === "/v1/account/username") return new Response(JSON.stringify({ username: "new.owner" }), { status: 200 });
    if (path === "/v1/account/password") return new Response(JSON.stringify({ changed: true }), { status: 200 });
    throw new Error(`unexpected:${path}`);
  } });
  await client.login({ email: "owner@example.com", password: "a sufficiently long password", deviceID });
  assert.deepEqual(await client.usernameAvailability("New.Owner"), { username: "new.owner", available: true });
  assert.equal((await client.updateUsername({ username: "new.owner", password: "a sufficiently long password" })).username, "new.owner");
  assert.deepEqual(await client.changePassword({ currentPassword: "a sufficiently long password", newPassword: "a completely new password" }), { changed: true });
  assert.equal(calls.at(-1)[1].method, "PATCH");
});

test("portal exposes visible login and registration modes and never promises emailed passwords", async () => {
  const [html, server] = await Promise.all([
    readFile(new URL("../public/index.html", import.meta.url), "utf8"),
    readFile(new URL("../src/server.mjs", import.meta.url), "utf8"),
  ]);
  assert.match(html, /id="cloud-login-tab"/u);
  assert.match(html, /id="cloud-register-tab"/u);
  assert.match(html, /id="cloud-registration-form"/u);
  assert.match(html, /id="cloud-recovery-form"/u);
  assert.match(html, /Пароли по почте не отправляются/u);
  assert.doesNotMatch(html, /отправим[^<]*(?:логин|пароль)/iu);
  assert.match(server, /\["\.html", "\.js", "\.css"\][^\n]*"no-store"/u);
  assert.match(server, /HttpOnly; SameSite=Strict/u);
  assert.match(server, /cookie && !\["GET", "HEAD"\]\.includes\(method\) && !hasTrustedOrigin\(request\)/u);
  assert.match(server, /origin === config\.publicOrigin/u);
});

test("accepted registration copy is privacy-safe and claims neither account creation nor mail delivery", () => {
  assert.equal(typeof portal.registrationAcceptedMessage, "function");
  const message = portal.registrationAcceptedMessage();
  assert.equal(message, "Проверьте почту. Если для этого адреса требуется подтверждение, мы отправим дальнейшие инструкции.");
  assert.doesNotMatch(message, /аккаунт создан|ссылка отправлена|@/iu);
});
