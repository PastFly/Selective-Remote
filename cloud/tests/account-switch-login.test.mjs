import assert from "node:assert/strict";
import test from "node:test";
import * as vaultSync from "../public/vault-sync.js";

const firstID = "11111111-1111-4111-8111-111111111111";
const secondID = "22222222-2222-4222-8222-222222222222";

test("login client exposes only authoritative bounded device errors", async () => {
  for (const [status, code, expected] of [
    [409, "device_conflict", "device_conflict"],
    [400, "invalid_device", "invalid_device"],
    [500, "device_conflict", "login_failed"],
    [409, "23505", "login_failed"],
    [500, "internal_error", "login_failed"],
  ]) {
    const client = vaultSync.createAuthenticatedVaultClient({
      fetchValue: async () => new Response(JSON.stringify({ error: code }), { status }),
    });
    await assert.rejects(client.login({ email: "synthetic@example.test", password: "synthetic password", deviceID: firstID }),
      error => error.message === expected);
    assert.equal(client.session(), null);
  }
});

test("login retries at most once, only for device_conflict", async () => {
  assert.equal(typeof vaultSync.loginWithDeviceConflictRetry, "function");
  for (const code of ["device_conflict", "invalid_device", "invalid_credentials", "login_failed", "rate_limited"]) {
    let attempts = 0, replacements = 0, accepted = 0;
    await assert.rejects(vaultSync.loginWithDeviceConflictRetry({
      input: { email: "synthetic@example.test", password: "synthetic password" },
      accountDevices: {
        async deviceID() { return firstID; },
        async remember(_email, id) { return id; },
        async accepted() { accepted += 1; },
        async replaceAfterConflict() { replacements += 1; return secondID; },
      },
      async ensureIdentity(id) { return { publicKey: { syntheticID: id } }; },
      async login() { attempts += 1; throw new Error(code); },
    }), error => error.message === code);
    assert.equal(attempts, code === "device_conflict" ? 2 : 1);
    assert.equal(replacements, code === "device_conflict" ? 1 : 0);
    assert.equal(accepted, 0);
  }
});

test("missing optional Team identity still permits Personal login", async () => {
  assert.equal(typeof vaultSync.loginWithDeviceConflictRetry, "function");
  const user = { id: secondID };
  let accepted = 0;
  const result = await vaultSync.loginWithDeviceConflictRetry({
    input: { email: "synthetic@example.test", password: "synthetic password" },
    accountDevices: {
      async deviceID() { return firstID; }, async remember(_email, id) { return id; },
      async accepted(_email, id) { assert.equal(id, firstID); accepted += 1; },
      async replaceAfterConflict() { assert.fail("No conflict occurred"); },
    },
    async ensureIdentity() { throw new Error("synthetic_team_storage_unavailable"); },
    async login(input) { assert.equal(input.publicKey, null); return user; },
  });
  assert.deepEqual(result, { user, identity: null });
  assert.equal(accepted, 1);
});
