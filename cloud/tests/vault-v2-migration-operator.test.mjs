import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, writeFile, symlink } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { uuid } from "./vault-v2-migration-fixtures.mjs";
import { MigrationFence } from "../src/migration-fence.mjs";
test("fence durably records exact manifest intents and refuses old schema or restored DB", async () => {
  const dir = await mkdtemp(join(tmpdir(), "migration-fence-")),
    path = join(dir, "fence"),
    f = new MigrationFence(path),
    intent = {
      teamID: uuid(),
      vaultID: uuid(),
      attemptID: uuid(),
      manifestHash: "a".repeat(64),
      schemaFloor: 19,
    };
  await Promise.all([f.intent(intent), f.intent(intent)]);
  const restored = { schemaVersion: 19, publications: [] };
  await assert.rejects(f.verify(restored), /deployment_fence_mismatch/);
  await assert.rejects(
    f.verify({ schemaVersion: 18, publications: [intent] }),
    /deployment_schema_floor/,
  );
  assert.equal(
    await f.verify({ schemaVersion: 19, publications: [intent] }),
    true,
  );
  const text = await readFile(path, "utf8");
  assert.equal(text.trim().split("\n").length, 1);
  assert.ok(!text.includes("ciphertext"));
  await assert.rejects(
    f.intent({ ...intent, manifestHash: "b".repeat(64) }),
    /deployment_fence_conflict/,
  );
});
test("corrupt fence, absent file and symlinks fail closed", async () => {
  const dir = await mkdtemp(join(tmpdir(), "migration-fence-")),
    path = join(dir, "fence");
  await assert.rejects(
    new MigrationFence(path).verify({ schemaVersion: 19, publications: [] }),
  );
  await writeFile(path, "broken\n");
  await assert.rejects(
    new MigrationFence(path).verify({ schemaVersion: 19, publications: [] }),
  );
  const link = join(dir, "link");
  await symlink(path, link);
  await assert.rejects(
    new MigrationFence(link).intent({
      teamID: uuid(),
      vaultID: uuid(),
      attemptID: uuid(),
      manifestHash: "a".repeat(64),
      schemaFloor: 19,
    }),
  );
});
import { spawnSync } from "node:child_process";
import { runStagingMigration } from "../scripts/vault-v2-migration-staging.mjs";
test("operator default and production are refused before connection or plaintext stdin processing", async () => {
  await assert.rejects(
    runStagingMigration(
      {
        environment: "production",
        enabled: true,
        allowedVaultIDs: [uuid()],
        databaseURL: "postgres://bad",
        fencePath: "/tmp/fence",
      },
      { operation: "preview" },
    ),
    /migration_staging_only/,
  );
  const p = spawnSync(
    process.execPath,
    [
      new URL("../scripts/vault-v2-migration-staging.mjs", import.meta.url)
        .pathname,
    ],
    {
      input: "PLAINTEXT_SECRET",
      env: { PATH: process.env.PATH },
      encoding: "utf8",
    },
  );
  assert.equal(p.status, 1);
  assert.equal(p.stderr.trim(), "migration_staging_only");
  assert.equal(p.stdout, "");
});
