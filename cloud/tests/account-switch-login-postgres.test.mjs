import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:http";
import { randomUUID, webcrypto } from "node:crypto";
import { fileURLToPath } from "node:url";
import test from "node:test";
import pg from "pg";
import { applyMigrations } from "../src/migrations.mjs";
import { PostgresStore } from "../src/postgres-store.mjs";
import { CloudService } from "../src/service.mjs";
import { hashPassword, validateDevicePublicKey } from "../src/security.mjs";
import { publicOperationError } from "../src/service-error.mjs";
import { createAccountDeviceCoordinator } from "../public/vault-local.js";
import { ensureTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import * as vaultSync from "../public/vault-sync.js";

const databaseURL = process.env.TEST_DATABASE_URL;
const options = { skip: !databaseURL, timeout: 60000 };
const password = "synthetic account switch password";

const loginFlow = vaultSync.loginWithDeviceConflictRetry;

async function fixture(t) {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 3 });
  t.after(() => pool.end());
  await applyMigrations(pool, fileURLToPath(new URL("../migrations/", import.meta.url)), { info() {} });
  const store = new PostgresStore(null, pool);
  const service = new CloudService(store, { sessionPepper: "synthetic-pepper-".repeat(3), sessionTTLDays: 1 });
  const identityRecords = new Map(), mappings = new Map();
  const identityRepository = {
    async load(id) { return identityRecords.get(id) ?? null; },
    async save(value) { identityRecords.set(value.deviceID, value); },
    async saveIfAbsent(value) {
      if (!identityRecords.has(value.deviceID)) identityRecords.set(value.deviceID, value);
      return identityRecords.get(value.deviceID);
    },
  };
  const ensureIdentity = (deviceID) => ensureTeamDeviceIdentity({ repository: identityRepository, deviceID, cryptoValue: webcrypto });
  const legacyID = randomUUID(), replacementID = randomUUID();
  let replacements = 0;
  const accountDevices = createAccountDeviceCoordinator({
    repository: {
      async loadAccountDevice(key) { return mappings.get(key) ?? null; },
      async saveAccountDeviceIfAbsent(key, value) {
        if (!mappings.has(key)) mappings.set(key, value);
        return mappings.get(key);
      },
      async replaceAccountDevice(key, expected, next) {
        const current = mappings.get(key);
        if (current?.deviceID !== expected.deviceID || current?.registrationAccepted !== expected.registrationAccepted) return current;
        mappings.set(key, next);
        return next;
      },
    },
    legacyDeviceID: async () => legacyID,
    cryptoValue: webcrypto,
    randomUUID() { replacements += 1; return replacementID; },
  });
  const passwordHash = await hashPassword(password);
  async function account(label, id) {
    const identity = await ensureIdentity(id), suffix = randomUUID().replaceAll("-", "");
    const email = `${label}-${suffix}@example.test`;
    const user = await store.createUser({
      email, username: `${label}_${suffix.slice(0, 12)}`, displayName: "Synthetic account",
      passwordHash, device: { id, name: "Synthetic approved browser", platform: "web", appVersion: "0.32", publicKey: validateDevicePublicKey(identity.publicKey) },
      verificationHash: suffix.repeat(2), verificationExpiresAt: new Date(Date.now() + 60000),
    });
    await pool.query("UPDATE users SET email_verified_at = now() WHERE id = $1", [user.id]);
    return { ...user, identity };
  }
  const a = await account("switch_a", legacyID), b = await account("switch_b", randomUUID());
  const attempts = [], failures = [];
  t.after(() => t.diagnostic(`Synthetic HTTP failure codes: ${failures.join(",") || "none"}`));
  const server = createServer(async (request, response) => {
    try {
      if (request.url === "/v1/auth/login") {
        let body = "";
        for await (const chunk of request) body += chunk;
        const input = JSON.parse(body);
        attempts.push({ email: input.email, deviceID: input.device.id });
        const result = await service.login(input);
        response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(result));
      } else if (request.url === "/v1/auth/logout") {
        const session = await service.authenticate(String(request.headers.authorization ?? "").replace(/^Bearer /u, ""));
        if (session) await store.revokeSession(session.session_id);
        response.writeHead(204).end();
      } else throw new Error("unexpected_synthetic_route");
    } catch (error) {
      const safe = publicOperationError(error);
      failures.push(safe?.code ?? error.code ?? "unknown");
      response.writeHead(safe?.status ?? 500, { "content-type": "application/json" }).end(JSON.stringify({ error: safe?.code ?? "internal_error" }));
    }
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  t.after(() => new Promise(resolve => server.close(resolve)));
  const client = vaultSync.createAuthenticatedVaultClient({ fetchValue: (path, init) => fetch(`http://127.0.0.1:${server.address().port}${path}`, init) });
  const login = (user, overrides = {}) => loginFlow({
    input: { email: user.email, password, ...overrides }, accountDevices, ensureIdentity,
    login: (input) => client.login(input),
  });
  return { pool, client, a, b, legacyID, replacementID, accountDevices, ensureIdentity,
    identityRecords, login, attempts, failures, replacements: () => replacements };
}

test("actual PostgreSQL and browser client switch approved accounts with one bounded device retry", options, async t => {
  const f = await fixture(t);
  assert.equal((await f.login(f.a)).user.id, f.a.id);
  const original = (await f.pool.query("SELECT * FROM devices WHERE id = $1", [f.legacyID])).rows[0];
  await f.client.logout();
  assert.equal(f.client.session(), null);
  const switched = await f.login(f.b);
  assert.equal(switched.user.id, f.b.id);
  assert.notDeepEqual(switched.identity.publicKey, f.a.identity.publicKey);
  assert.deepEqual(f.attempts.map(row => row.deviceID), [f.legacyID, f.legacyID, f.replacementID]);
  assert.deepEqual(f.failures, ["device_conflict"]);
  assert.equal(f.replacements(), 1);
  const untouched = (await f.pool.query("SELECT * FROM devices WHERE id = $1", [f.legacyID])).rows[0];
  assert.deepEqual(untouched, original);
  const replacement = (await f.pool.query("SELECT * FROM devices WHERE id = $1", [f.replacementID])).rows[0];
  assert.equal(replacement.user_id, f.b.id);
  assert.equal(replacement.key_approved_at, null);
  assert.equal(replacement.revoked_at, null);
  await f.client.logout();
  assert.equal((await f.login(f.a)).user.id, f.a.id);
  await f.client.logout();
  assert.equal((await f.login(f.b)).user.id, f.b.id);
  assert.deepEqual(f.attempts.slice(-2).map(row => row.deviceID), [f.legacyID, f.replacementID]);
  assert.equal(f.replacements(), 1);
});

test("an accepted account mapping is never rotated on cross-account conflict", options, async t => {
  const f = await fixture(t);
  await f.accountDevices.remember(f.b.email, f.legacyID);
  await f.accountDevices.accepted(f.b.email, f.legacyID);
  await assert.rejects(f.login(f.b), /^Error: device_conflict$/u);
  assert.equal(f.attempts.length, 1);
  assert.equal(f.replacements(), 0);
  assert.equal(await f.accountDevices.deviceID(f.b.email), f.legacyID);
  assert.equal(f.client.session(), null);
});

test("invalid credentials cannot reveal a device conflict or rotate the browser identity", options, async t => {
  const f = await fixture(t);
  await assert.rejects(f.login(f.b, { password: "wrong synthetic password" }), /^Error: invalid_credentials$/u);
  assert.deepEqual(f.failures, ["invalid_credentials"]);
  assert.equal(f.replacements(), 0);
  assert.equal(f.attempts.length, 1);
});

for (const failure of ["revoked", "key mismatch"]) {
  test(`same-account ${failure} remains rejected without rotating identity`, options, async t => {
    const f = await fixture(t);
    if (failure === "revoked") await f.pool.query("UPDATE devices SET revoked_at = now() WHERE id = $1", [f.legacyID]);
    else {
      const alternate = await f.ensureIdentity(randomUUID());
      f.identityRecords.set(f.legacyID, { ...alternate, deviceID: f.legacyID });
    }
    const original = (await f.pool.query("SELECT * FROM devices WHERE id = $1", [f.legacyID])).rows[0];
    await assert.rejects(f.login(f.a), /^Error: invalid_device$/u);
    assert.equal(f.attempts.length, 1);
    assert.equal(f.replacements(), 0);
    assert.deepEqual((await f.pool.query("SELECT * FROM devices WHERE id = $1", [f.legacyID])).rows[0], original);
    assert.equal(f.client.session(), null);
  });
}
