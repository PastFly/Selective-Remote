import assert from "node:assert/strict";
import test from "node:test";
import { VaultMigrationStore } from "../src/vault-migration-store.mjs";
const input = { vaultID: "synthetic" };
test("default OFF and production refusal happen before database access", async () => {
  for (const config of [
    {},
    {
      enabled: true,
      environment: "production",
      allowedVaultIDs: ["synthetic"],
    },
    { enabled: true, environment: "staging", allowedVaultIDs: [] },
  ]) {
    const store = new VaultMigrationStore(
      {
        connect() {
          throw Error("database_touched");
        },
      },
      config,
    );
    for (const method of [
      "preview",
      "start",
      "putPart",
      "validate",
      "activate",
      "discard",
      "readPart",
    ])
      await assert.rejects(store[method](input), /migration_staging_only/);
  }
});
test("deadlock victims retry the entire rolled-back staging transaction with bounded attempts", async () => {
  let n = 0;
  const calls = [];
  const pool = {
    connect: async () => ({
      query: async (sql) => {
        calls.push(sql);
        if (sql.startsWith("LOCK") && n++ === 0)
          throw Object.assign(Error("deadlock"), { code: "40P01" });
        return { rows: [] };
      },
      release() {},
    }),
  };
  const store = new VaultMigrationStore(pool, {
    environment: "staging",
    enabled: true,
    allowedVaultIDs: ["synthetic"],
  });
  assert.equal(
    await store.transaction(
      { ...input, schemaVersion: 2, capability: "resource_acl_v2" },
      async () => 42,
    ),
    42,
  );
  assert.equal(calls.filter((s) => s === "ROLLBACK").length, 1);
  assert.equal(calls.filter((s) => s === "COMMIT").length, 1);
});
