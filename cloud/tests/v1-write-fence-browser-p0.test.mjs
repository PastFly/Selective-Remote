import test from "node:test";
import assert from "node:assert/strict";
import { createAuthenticatedVaultClient, personalVaultScope } from "../public/vault-sync.js";

const user = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const device = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const binding = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
const envelope = { baseRevision: 0, envelopeVersion: 1, wrappedKey: { algorithm: "synthetic" }, ciphertext: "AA", nonce: "A".repeat(16), authTag: "A".repeat(22), contentHash: "A".repeat(43) };
const login = () => Response.json({ token: "a".repeat(43), user: { id: user, email: "test@example.invalid" }, deviceID: device }, { headers: { "X-Selective-Session-Binding": binding } });

test("Personal and Team clients surface only the exact temporary write stop", async () => {
  const { wrappedKey: _, ...base } = envelope;
  const teamEnvelope = { ...base, keyGeneration: 1 };
  for (const [status, code, expectedPersonal, expectedTeam] of [
    [503, "vault_write_temporarily_unavailable", "vault_write_temporarily_unavailable", "vault_write_temporarily_unavailable"],
    [400, "vault_write_temporarily_unavailable", "vault_upload_failed", "team_vault_upload_failed"],
    [503, "unrelated_internal_error", "vault_upload_failed", "team_vault_upload_failed"],
  ]) {
    const client = createAuthenticatedVaultClient({ fetchValue: async (path) => {
      if (path === "/v1/auth/login") return login();
      if (path === "/v1/meta") return Response.json({}, { headers: { "X-Selective-V1-Write-Fence": "1" } });
      return Response.json({ error: code }, { status });
    } });
    await client.login({ email: "test@example.invalid", password: "synthetic", deviceID: device });
    await assert.rejects(client.putVault(personalVaultScope, envelope), error => error.message === expectedPersonal);
    await assert.rejects(client.putTeamVault({ type: "team", teamID: user, vaultID: device }, teamEnvelope, "synthetic-idempotency-key"), error => error.message === expectedTeam);
  }
});

test("current browser refuses a Personal write when Cloud has no safe writer capability", async () => {
  let writes = 0;
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") return login();
    if (path === "/v1/meta") return Response.json({ apiVersion: 1, vaultSchemaVersion: 1 });
    if (path === "/v1/vault" && options.method === "PUT") { writes++; return Response.json({ conflict: false, revision: 1 }); }
    throw Error("unexpected_request");
  } });
  await client.login({ email: "test@example.invalid", password: "synthetic", deviceID: device });
  await assert.rejects(client.putVault(personalVaultScope, envelope), /vault_client_upgrade_required/u);
  assert.equal(writes, 0);
});

test("current browser sends a framed Personal write only to capable Cloud", async () => {
  let body, marker;
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") return login();
    if (path === "/v1/meta") return Response.json({}, { headers: { "X-Selective-V1-Write-Fence": "1" } });
    if (path === "/v1/vault" && options.method === "PUT") {
      body = JSON.parse(options.body); marker = options.headers["X-Selective-V1-Write-Fence"];
      return Response.json({ conflict: false, revision: 1 });
    }
    throw Error("unexpected_request");
  } });
  await client.login({ email: "test@example.invalid", password: "synthetic", deviceID: device });
  assert.deepEqual(await client.putVault(personalVaultScope, envelope), { conflict: false, revision: 1 });
  assert.equal(marker, "1");
  assert.deepEqual(body, { protocol: "framed-v1", envelope });
});

test("current browser blocks Team writes on an older Cloud", async () => {
  let writes = 0;
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") return login();
    if (path === "/v1/meta") return Response.json({});
    if (path.startsWith("/v1/teams/") && options.method === "PUT") { writes++; return Response.json({ conflict: false, revision: 1, keyGeneration: 1, rotationCompleted: false }); }
    throw Error("unexpected_request");
  } });
  await client.login({ email: "test@example.invalid", password: "synthetic", deviceID: device });
  const { wrappedKey: _, ...teamEnvelope } = envelope;
  await assert.rejects(client.putTeamVault({ type: "team", teamID: user, vaultID: device }, { ...teamEnvelope, keyGeneration: 1 }, "synthetic-idempotency-key"), /vault_client_upgrade_required/u);
  assert.equal(writes, 0);
});

test("a session change during capability check prevents the pending Personal upload", async () => {
  let enter, release, writes = 0;
  const started = new Promise(resolve => { enter = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") return login();
    if (path === "/v1/meta") { enter(); await held; return Response.json({}, { headers: { "X-Selective-V1-Write-Fence": "1" } }); }
    if (path === "/v1/vault" && options.method === "PUT") { writes++; return Response.json({ conflict: false, revision: 1 }); }
    throw Error("unexpected_request");
  } });
  await client.login({ email: "test@example.invalid", password: "synthetic", deviceID: device });
  const pending = client.putVault(personalVaultScope, envelope);
  await started;
  await client.login({ email: "test@example.invalid", password: "synthetic", deviceID: device });
  release();
  await assert.rejects(pending, /authentication_required/u);
  assert.equal(writes, 0);
});

test("capable browser preserves Team idempotency and frames the encrypted payload", async () => {
  let observed;
  const client = createAuthenticatedVaultClient({ fetchValue: async (path, options = {}) => {
    if (path === "/v1/auth/login") return login();
    if (path === "/v1/meta") return Response.json({}, { headers: { "X-Selective-V1-Write-Fence": "1" } });
    if (path.startsWith("/v1/teams/") && options.method === "PUT") {
      observed = { body: JSON.parse(options.body), headers: options.headers };
      return Response.json({ conflict: false, revision: 1, keyGeneration: 1, rotationCompleted: false });
    }
    throw Error("unexpected_request");
  } });
  await client.login({ email: "test@example.invalid", password: "synthetic", deviceID: device });
  const { wrappedKey: _, ...base } = envelope;
  const teamEnvelope = { ...base, keyGeneration: 1 };
  assert.deepEqual(await client.putTeamVault({ type: "team", teamID: user, vaultID: device }, teamEnvelope, "synthetic-idempotency-key"), { conflict: false, revision: 1, keyGeneration: 1, rotationCompleted: false });
  assert.equal(observed.headers["Idempotency-Key"], "synthetic-idempotency-key");
  assert.equal(observed.headers["X-Selective-V1-Write-Fence"], "1");
  assert.deepEqual(observed.body, { protocol: "framed-v1", envelope: teamEnvelope });
});
