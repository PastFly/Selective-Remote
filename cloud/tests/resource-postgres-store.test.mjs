import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import { PostgresStore } from "../src/postgres-store.mjs";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import { generateResourceCEK, encryptResourcePart, wrapResourceCEK } from "../public/resource-crypto-v2.js";

const teamID = "11111111-1111-4111-8111-111111111111";
const vaultID = "22222222-2222-4222-8222-222222222222";
const resourceID = "33333333-3333-4333-8333-333333333333";
const membershipID = "44444444-4444-4444-8444-444444444444";
const deviceID = "55555555-5555-4555-8555-555555555555";
const actorUserID = "66666666-6666-4666-8666-666666666666";
const context = { teamID, vaultID, resourceID, part: "METADATA", keyVersion: 1,
  policyVersion: 1, registryVersion: 1, resourceVersion: 1, manifestVersion: 1 };

async function input() {
  const cek = generateResourceCEK(webcrypto);
  const identity = await generateTeamDeviceIdentity(webcrypto);
  const ciphertext = await encryptResourcePart({ plaintext: new TextEncoder().encode("private"),
    cek, context, cryptoValue: webcrypto });
  const wrapper = await wrapResourceCEK({ cek, context: { ...context, membershipID,
    membershipEpoch: 1, deviceID }, recipientPublicKey: identity.publicKey, cryptoValue: webcrypto });
  return { actorUserID, actorDeviceID: deviceID, teamID, vaultID, resourceID,
    expectedManifestVersion: 0, ciphertext, wrappers: [wrapper] };
}

function fake(respond) {
  const queries = [];
  const client = { async query(sql, parameters = []) {
    queries.push({ sql, parameters });
    return respond(sql, parameters);
  }, release() { queries.push({ sql: "RELEASE" }); } };
  return { store: new PostgresStore("unused", { async connect() { return client; } }), queries };
}

test("dormant publish locks registry, inserts ciphertext and wrappers, then advances pointer", async () => {
  const f = fake((sql) => {
    if (sql.includes("AS registry_actor_role")) return { rows: [{ registry_actor_role: "owner" }] };
    if (sql.includes("AS crypto_resource_version")) return { rows: [{ crypto_resource_version: 1 }] };
    if (sql.includes("AS current_manifest_version")) return { rows: [] };
    if (sql.includes("RETURNING manifest_version")) return { rows: [{ manifest_version: 1 }] };
    return { rows: [] };
  });
  assert.equal((await f.store.publishResourceCryptoVersion(await input())).manifest_version, 1);
  const statements = f.queries.map(({ sql }) => sql);
  const at = (needle) => statements.findIndex((sql) => sql.includes(needle));
  assert.ok(at("BEGIN") < at("AS registry_actor_role"));
  assert.ok(at("AS crypto_resource_version") < at("INSERT INTO vault_resource_ciphertext_versions"));
  assert.ok(at("INSERT INTO vault_resource_ciphertext_versions") < at("INSERT INTO vault_resource_key_wrappers_v2"));
  assert.ok(at("INSERT INTO vault_resource_key_wrappers_v2") < at("INSERT INTO vault_resource_manifest_pointers_v2"));
  assert.ok(at("INSERT INTO vault_resource_manifest_pointers_v2") < at("COMMIT"));
  assert.match(statements[at("AS crypto_resource_version")], /FOR UPDATE/u);
});

test("a wrapper insert failure rolls back without publishing a pointer", async () => {
  const f = fake((sql) => {
    if (sql.includes("AS registry_actor_role")) return { rows: [{ registry_actor_role: "owner" }] };
    if (sql.includes("AS crypto_resource_version")) return { rows: [{ crypto_resource_version: 1 }] };
    if (sql.includes("AS current_manifest_version")) return { rows: [] };
    if (sql.includes("INSERT INTO vault_resource_key_wrappers_v2")) throw new Error("wrapper rejected");
    return { rows: [] };
  });
  await assert.rejects(f.store.publishResourceCryptoVersion(await input()), /wrapper rejected/u);
  assert.ok(f.queries.some(({ sql }) => sql === "ROLLBACK"));
  assert.ok(!f.queries.some(({ sql }) => sql.includes("INSERT INTO vault_resource_manifest_pointers_v2")));
});

test("ciphertext failure and interrupted commit leave publication uncommitted", async () => {
  for (const failure of ["INSERT INTO vault_resource_ciphertext_versions", "COMMIT"]) {
    const f = fake((sql) => {
      if (sql.includes("AS registry_actor_role")) return { rows: [{ registry_actor_role: "owner" }] };
      if (sql.includes("AS crypto_resource_version")) return { rows: [{ crypto_resource_version: 1 }] };
      if (sql.includes("AS current_manifest_version")) return { rows: [] };
      if (sql.includes("RETURNING manifest_version")) return { rows: [{ manifest_version: 1 }] };
      if (sql.includes(failure)) throw new Error("simulated interruption");
      return { rows: [] };
    });
    await assert.rejects(f.store.publishResourceCryptoVersion(await input()), /simulated interruption/u);
    assert.ok(f.queries.some(({ sql }) => sql === "ROLLBACK"));
  }
});

test("stale manifest and v1 custodian cannot publish", async () => {
  const f = fake((sql) => {
    if (sql.includes("AS registry_actor_role")) return { rows: [{ registry_actor_role: "owner" }] };
    if (sql.includes("AS crypto_resource_version")) return { rows: [{ crypto_resource_version: 1 }] };
    if (sql.includes("AS current_manifest_version")) return { rows: [{ current_manifest_version: 2,
      current_key_version: 2 }] };
    return { rows: [] };
  });
  await assert.rejects(f.store.publishResourceCryptoVersion(await input()), /resource_manifest_conflict/u);
  assert.ok(!f.queries.some(({ sql }) => sql.includes("INSERT INTO vault_resource_ciphertext_versions")));
  const v1 = fake(() => ({ rows: [] }));
  await assert.rejects(v1.store.publishResourceCryptoVersion(await input()), /team_not_found/u);
});
