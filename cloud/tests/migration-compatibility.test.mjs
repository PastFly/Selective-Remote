import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { randomUUID } from "node:crypto";
import { MigrationFence } from "../src/migration-fence.mjs";
import { verifyMigrationCompatibility } from "../src/migration-compatibility.mjs";

async function fixture(t, floor) {
  const dir = await mkdtemp(join(tmpdir(), "compatibility-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const path = join(dir, "fence"), fence = new MigrationFence(path);
  const intent = { teamID: randomUUID(), vaultID: randomUUID(), attemptID: randomUUID(), manifestHash: "a".repeat(64), schemaFloor: floor };
  // Retained on-disk evidence can come from an earlier process.
  await writeFile(path, floor === undefined ? "" : JSON.stringify(intent) + "\n");
  return { fence, intent };
}

for (const [floor, versions] of [[undefined, [12, 18]], [20, [12, 18, 19]]]) {
  for (const version of versions) test(`schema ${version} is denied before publication query with floor ${floor ?? "empty"}`, async (t) => {
    const { fence } = await fixture(t, floor), queries = [];
    const query = async (sql) => {
      queries.push(sql);
      assert.match(sql, /FROM schema_migrations$/);
      return { rows: [{ version: String(version) }] };
    };
    await assert.rejects(verifyMigrationCompatibility({ query, fence }), /deployment_schema_floor/);
    assert.equal(queries.length, 1);
  });
}

for (const version of [19, 20]) test(`schema ${version} checks retained floor before matching publication`, async (t) => {
  const { fence, intent } = await fixture(t, version), events = [];
  const query = async (sql) => {
    if (sql.includes("schema_migrations")) { events.push("schema"); return { rows: [{ version: String(version) }] }; }
    events.push("publications");
    return { rows: [intent] };
  };
  const observedFence = {
    async verifySchemaFloor(schema) { events.push("floor"); return fence.verifySchemaFloor(schema); },
    async verify(input) { events.push("full verify"); return fence.verify(input); },
  };
  assert.deepEqual(await verifyMigrationCompatibility({ query, fence: observedFence }), { compatible: true });
  assert.deepEqual(events, ["schema", "floor", "publications", "full verify"]);
  await assert.rejects(verifyMigrationCompatibility({
    fence,
    query: async (sql) => ({ rows: sql.includes("schema_migrations") ? [{ version: String(version) }] : [{ ...intent, attemptID: randomUUID() }] }),
  }), /deployment_fence_mismatch/);
});

test("malformed schema responses cannot coerce into compatibility or query publications", async (t) => {
  const { fence } = await fixture(t);
  for (const version of [null, undefined, "", " 19", "19 ", "019", "1.9e1", "19.0", [19], true, {}, NaN, Infinity, 19.5, "9007199254740992"]) {
    let queries = 0;
    await assert.rejects(verifyMigrationCompatibility({ fence, query: async () => { queries++; return { rows: [{ version }] }; } }), /deployment_schema_floor/);
    assert.equal(queries, 1);
  }
  for (const response of [null, {}, { rows: [] }, { rows: null }, { rows: [null] }, { rows: [{ version: "19" }, { version: "20" }] }]) {
    let queries = 0;
    await assert.rejects(verifyMigrationCompatibility({ fence, query: async () => { queries++; return response; } }), /deployment_schema_floor/);
    assert.equal(queries, 1);
  }
});

test("absent schema metadata denies at schema boundary; connection failures stay failures", async (t) => {
  const { fence } = await fixture(t);
  const missing = Object.assign(Error("relation unavailable"), { code: "42P01" });
  await assert.rejects(verifyMigrationCompatibility({ fence, query: async () => { throw missing; } }), /deployment_schema_floor/);
  const unavailable = Object.assign(Error("connection unavailable"), { code: "08006" });
  await assert.rejects(verifyMigrationCompatibility({ fence, query: async () => { throw unavailable; } }), (e) => e === unavailable);
});

test("a stricter fence appended during the DB await is not skipped", async (t) => {
  const { fence } = await fixture(t);
  const intent = { teamID: randomUUID(), vaultID: randomUUID(), attemptID: randomUUID(), manifestHash: "b".repeat(64), schemaFloor: 20 };
  const query = async (sql) => {
    if (sql.includes("schema_migrations")) return { rows: [{ version: "19" }] };
    await fence.intent(intent);
    return { rows: [intent] };
  };
  await assert.rejects(verifyMigrationCompatibility({ fence, query }), /deployment_schema_floor/);
});

test("publication errors do not fall back to an empty accepted result", async (t) => {
  const { fence } = await fixture(t, 20), error = Object.assign(Error("publication table unavailable"), { code: "42P01" });
  await assert.rejects(verifyMigrationCompatibility({ fence, query: async (sql) => {
    if (sql.includes("schema_migrations")) return { rows: [{ version: "20" }] };
    throw error;
  } }), (e) => e === error);
});

for (const floor of [19, 20]) test(`newer database schema22 satisfies retained floor${floor}`, async (t) => {
  const { fence, intent } = await fixture(t, floor);
  assert.deepEqual(await verifyMigrationCompatibility({ fence, query: async (sql) => ({ rows: sql.includes("schema_migrations") ? [{ version: "22" }] : [intent] }) }), { compatible: true });
});

test("a newly appended requirement also needs its exact publication even above its floor", async (t) => {
  const { fence } = await fixture(t);
  const intent = { teamID: randomUUID(), vaultID: randomUUID(), attemptID: randomUUID(), manifestHash: "b".repeat(64), schemaFloor: 20 };
  await assert.rejects(verifyMigrationCompatibility({ fence, query: async (sql) => {
    if (sql.includes("schema_migrations")) return { rows: [{ version: 22 }] };
    await fence.intent(intent);
    return { rows: [] };
  } }), /deployment_fence_mismatch/);
});
