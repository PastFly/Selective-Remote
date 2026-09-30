// Disposable, synthetic PG16 fixtures only; never points at the production URL.
import pg from "pg";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import {
  seedMigration,
  addSyntheticDevices,
} from "../tests/vault-v2-migration-db-fixtures.mjs";
import { legacy, record, uuid } from "../tests/vault-v2-migration-fixtures.mjs";
import { applyMigrations } from "../src/migrations.mjs";
import { VaultMigrationStore } from "../src/vault-migration-store.mjs";
import { MigrationFence } from "../src/migration-fence.mjs";
import { prepareLegacyMigration } from "../public/vault-v2-migration.js";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
const connectionString = process.env.TEST_DATABASE_URL;
if (!connectionString) throw Error("isolated_test_database_required");
const pool = new pg.Pool({ connectionString, max: 3 });
try {
  if (
    !(
      await pool.query("SELECT current_database() AS name")
    ).rows[0].name.includes("test")
  )
    throw Error("isolated_test_database_required");
  await applyMigrations(
    pool,
    fileURLToPath(new URL("../migrations/", import.meta.url)),
    { info() {} },
  );
  for (const count of process.argv.slice(2).length
    ? process.argv.slice(2).map(Number)
    : [100, 1000]) {
    if (![100, 1000].includes(count)) throw Error("invalid_benchmark_count");
    const f = await seedMigration(pool),
      dir = await mkdtemp(join(tmpdir(), "sel-migration-scale-")),
      fence = new MigrationFence(join(dir, "fence"));
    await addSyntheticDevices(pool, f);
    const groups = [];
    for (let n = 0; n < 3; n++) {
      const group = uuid();
      await pool.query(
        "INSERT INTO team_access_groups(id,team_id,name,created_by_user_id) VALUES($1,$2,$3,$4)",
        [group, f.scope.teamID, "synthetic " + n, f.accountID],
      );
      await pool.query(
        "INSERT INTO team_access_group_members(team_id,group_id,user_id,membership_id,membership_epoch,created_by_user_id) VALUES($1,$2,$3,$4,1,$3)",
        [f.scope.teamID, group, f.accountID, f.recipient.membershipID],
      );
      groups.push(group);
    }
    const doc = legacy(
        Array.from({ length: count }, () =>
          record("host", {
            name: "synthetic",
            hostname: "example.invalid",
            port: 22,
          }),
        ),
      ),
      resources = doc.records.map((r, n) => ({
        id: r.id,
        kind: "HOST",
        parentFolderID: null,
        sourceOrdinal: n,
      }));
    const policy = resources.map((r, n) => ({
      id: uuid(),
      teamID: f.scope.teamID,
      vaultID: f.scope.vaultID,
      principalKind: "GROUP",
      principalID: groups[n % 3],
      targetKind: "RESOURCE",
      targetID: r.id,
      mask: 13,
      revokedAt: null,
    }));
    let activationQueries = 0;
    const store = new VaultMigrationStore(pool, { ...f.config, fence }),
      start = await store.start({ ...f.input, resources, policy });
    const prepareAt = performance.now();
    const out = await prepareLegacyMigration({
      ...f,
      scope: start.scope,
      document: doc,
      policy: start.policy,
      recipientTargets: (r, p) => start.recipients[r.id][p],
      persistCheckpoint: async () => {},
    });
    const prepareMs = performance.now() - prepareAt;
    const uploadAt = performance.now();
    for (const [n, object] of out.objects.entries())
      await store.putPart(
        f.input,
        object,
        n === 0 ? out.checkpoint : undefined,
      );
    await store.validate(f.input, out.manifest);
    const uploadMs = performance.now() - uploadAt;
    const proxy = {
      async connect() {
        const c = await pool.connect();
        return {
          query(...args) {
            activationQueries++;
            return c.query(...args);
          },
          release() {
            c.release();
          },
        };
      },
    };
    const activateStore = new VaultMigrationStore(proxy, {
      ...f.config,
      fence,
    });
    const hash = await store.manifestHash(f.input),
      at = performance.now();
    await activateStore.activate(f.input, hash);
    const activationMs = performance.now() - at;
    const explain = await pool.query(
      "EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT resource_id,part,sha256 FROM vault_migration_parts WHERE attempt_id=$1 ORDER BY resource_id,part",
      [f.input.attemptID],
    );
    console.log(
      JSON.stringify({
        resources: count,
        groups: 3,
        devices: start.recipients[resources[0].id].GENERAL.length,
        wrappers: out.objects.reduce((n, o) => n + o.wrappers.length, 0),
        prepareMs,
        uploadMs,
        stagingBytes: Buffer.byteLength(JSON.stringify(out.objects)),
        activationMs,
        activationQueries,
        commitmentPlan: explain.rows[0]["QUERY PLAN"][0].Plan["Node Type"],
        commitmentMs: explain.rows[0]["QUERY PLAN"][0]["Execution Time"],
      }),
    );
  }
} finally {
  await pool.end();
}
