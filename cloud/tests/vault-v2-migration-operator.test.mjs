import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, readFile, writeFile, symlink, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { uuid } from "./vault-v2-migration-fixtures.mjs";
import { MigrationFence } from "../src/migration-fence.mjs";
// The test knows it seeded an exact committed DB tuple. Production confirmation
// belongs to the trusted transaction/read-back adapter, never this test helper.
async function confirmSyntheticLegacyFixture(fence, record) {
  const pending = (await fence.snapshot()).pending.find(p => p.vaults[0]?.attemptID === record.attemptID);
  assert.ok(pending);
  await fence.append({ version: 2, type: "CONFIRMED_COMMIT", intentID: pending.intentID, intentDigest: pending.intentDigest });
}

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
  await writeFile(path, "", { mode: 0o600 });
  await Promise.all([f.intent(intent), f.intent(intent)]);
  await assert.rejects(f.verify({ schemaVersion: 19, publications: [intent] }), /deployment_fence_pending/);
  await confirmSyntheticLegacyFixture(f, intent);
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
  assert.equal(text.trim().split("\n").length, 2);
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

import { open as realOpen } from "node:fs/promises";
for (const failure of ["file", "directory"]) test(`fence retries durability after ${failure} fsync failure and handles short writes`, async () => {
  const dir = await mkdtemp(join(tmpdir(), "migration-sync-")), path = join(dir, "fence");
  await writeFile(path, "", { mode: 0o600 });
  let injected = false, fileSyncs = 0, dirSyncs = 0;
  const openFile = async (...args) => {
    const handle = await realOpen(...args), directory = args[0] === dir;
    return new Proxy(handle, { get(target, name) {
      if (name === "sync") return async () => {
        if (directory) dirSyncs++; else fileSyncs++;
        if (!injected && directory === (failure === "directory")) { injected = true; throw Object.assign(Error("fsync"), { code: "EIO" }); }
        return target.sync();
      };
      if (name === "write") return (buffer, offset, length, position) => target.write(buffer, offset, Math.min(length, 13), position);
      const value = target[name]; return typeof value === "function" ? value.bind(target) : value;
    }});
  };
  const f = new MigrationFence(path, { openFile }), intent = {teamID:uuid(),vaultID:uuid(),attemptID:uuid(),manifestHash:"a".repeat(64),schemaFloor:19};
  await assert.rejects(f.intent(intent), /fsync/);
  const previous = fileSyncs;
  await f.intent(intent);
  assert.ok(fileSyncs > previous);
  assert.ok(dirSyncs >= 1);
  await confirmSyntheticLegacyFixture(f, intent);
  assert.equal(await f.verify({schemaVersion:19,publications:[intent]}), true);
});

for (const floor of [19, 20]) test(`fence retains supported schema floor ${floor} and exact replay`, async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "migration-floor-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, "fence"), fence = new MigrationFence(path);
  const intent = { teamID: uuid(), vaultID: uuid(), attemptID: uuid(), manifestHash: "c".repeat(64), schemaFloor: floor };
  await writeFile(path, "", { mode: 0o600 });
  await fence.intent(intent);
  const before = await readFile(path, "utf8");
  await fence.intent(intent);
  assert.equal(await readFile(path, "utf8"), before);
  await assert.rejects(fence.verifySchemaFloor(floor - 1), /deployment_schema_floor/);
  assert.equal(await fence.verifySchemaFloor(floor), true);
  await assert.rejects(fence.verify({ schemaVersion: floor, publications: [intent] }), /deployment_fence_pending/);
  await confirmSyntheticLegacyFixture(fence, intent);
  assert.equal(await fence.verify({ schemaVersion: floor, publications: [intent] }), true);
  await assert.rejects(fence.verify({ schemaVersion: floor, publications: [{ ...intent, manifestHash: "d".repeat(64) }] }), /deployment_fence_mismatch/);
});

test("unsupported record floors cannot create or change the retained fence", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "migration-floor-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, "fence"), fence = new MigrationFence(path);
  await writeFile(path, "");
  const intent = { teamID: uuid(), vaultID: uuid(), attemptID: uuid(), manifestHash: "a".repeat(64) };
  for (const schemaFloor of [18, 21, 22, "19", "20", null, NaN, Infinity, 19.5, Number.MAX_SAFE_INTEGER + 1]) {
    await assert.rejects(fence.intent({ ...intent, schemaFloor }), /invalid_deployment_fence/);
    assert.equal(await readFile(path, "utf8"), "");
  }
});

test("an empty fence still rejects old or invalid schema versions", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "migration-floor-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, "fence"), fence = new MigrationFence(path);
  await writeFile(path, "");
  for (const schemaVersion of [0, 12, 18, "19", null, NaN, Infinity, 19.5, Number.MAX_SAFE_INTEGER + 1]) {
    await assert.rejects(fence.verify({ schemaVersion, publications: [] }), /deployment_schema_floor/);
    await assert.rejects(fence.verifySchemaFloor(schemaVersion), /deployment_schema_floor/);
  }
  assert.equal(await fence.verifySchemaFloor(19), true);
});

test("schema-only validation refuses missing, malformed and symlink fences", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "migration-floor-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, "fence"), fence = new MigrationFence(path);
  await assert.rejects(fence.verifySchemaFloor(20));
  await writeFile(path, "broken\n");
  await assert.rejects(fence.verifySchemaFloor(20));
  const link = join(dir, "link");
  await symlink(path, link);
  await assert.rejects(new MigrationFence(link).verifySchemaFloor(20));
});
