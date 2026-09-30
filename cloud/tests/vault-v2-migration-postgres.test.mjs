import assert from "node:assert/strict";
import test from "node:test";
import pg from "pg";
import { fileURLToPath } from "node:url";
import { loadMigrations, applyMigrations } from "../src/migrations.mjs";
export const migrationDirectory = fileURLToPath(
  new URL("../migrations/", import.meta.url),
);
test("migration publication schema exists and latest version is 19", async () => {
  const m = await loadMigrations(migrationDirectory);
  assert.equal(m.at(-1).version, 19);
});
test(
  "PG16 applies publication foundation without activating existing Vaults",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const pool = new pg.Pool({
      connectionString: process.env.TEST_DATABASE_URL,
    });
    try {
      await applyMigrations(pool, migrationDirectory, { info() {} });
      assert.match(
        (await pool.query("SHOW server_version")).rows[0].server_version,
        /^16\./,
      );
      assert.equal(
        (
          await pool.query(
            "SELECT to_regclass('vault_migration_attempts') AS name",
          )
        ).rows[0].name,
        "vault_migration_attempts",
      );
      assert.match(
        (
          await pool.query(
            "SELECT column_default FROM information_schema.columns WHERE table_name='shared_vaults' AND column_name='format_state'",
          )
        ).rows[0].column_default,
        /V1_ACTIVE/,
      );
    } finally {
      await pool.end();
    }
  },
);
import { seedMigration } from "./vault-v2-migration-db-fixtures.mjs";
import { VaultMigrationStore } from "../src/vault-migration-store.mjs";
import { prepareLegacyMigration } from "../public/vault-v2-migration.js";
import { legacy, record } from "./vault-v2-migration-fixtures.mjs";
export async function readyCandidate(
  pool,
  doc = legacy([record("credential", { title: "test", secret: "SECRET" })]),
  extra = {},
) {
  const f = await seedMigration(pool),
    store = new VaultMigrationStore(pool, { ...f.config, ...extra }),
    resources = doc.records.map((r, n) => ({
      id: r.id,
      kind: r.type === "credential" ? "CREDENTIAL" : "HOST",
      parentFolderID: null,
      sourceOrdinal: n,
    }));
  const started = await store.start({ ...f.input, resources });
  const out = await prepareLegacyMigration({
    ...f,
    scope: started.scope,
    document: doc,
    policy: started.policy,
    recipientTargets: (r, p) => started.recipients[r.id][p],
    persistCheckpoint: async () => {},
  });
  for (const object of out.objects)
    await store.putPart(f.input, object, out.checkpoint);
  await store.validate(f.input, out.manifest);
  return { ...f, store, out, started };
}
test(
  "preparation is private; activation retires all legacy payloads and is irreversible/idempotent",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const pool = new pg.Pool({
      connectionString: process.env.TEST_DATABASE_URL,
      max: 5,
    });
    try {
      await applyMigrations(pool, migrationDirectory, { info() {} });
      const f = await readyCandidate(pool);
      const v = () =>
        pool.query(
          "SELECT format_state,ciphertext,active_publication_attempt_id FROM shared_vaults WHERE id=$1",
          [f.input.vaultID],
        );
      assert.equal((await v()).rows[0].ciphertext, "LEGACY_ENCRYPTED_DATA");
      assert.equal(
        (
          await pool.query(
            "SELECT * FROM active_vault_migration_parts WHERE vault_id=$1",
            [f.input.vaultID],
          )
        ).rowCount,
        0,
      );
      await assert.rejects(
        pool.query(
          "UPDATE vault_migration_parts SET sha256=$2 WHERE attempt_id=$1",
          [f.input.attemptID, "f".repeat(64)],
        ),
        /immutable_migration_object/,
      );
      const result = await f.store.activate(
        f.input,
        f.started.manifestHash || (await f.store.manifestHash(f.input)),
      );
      assert.equal(result.state, "V2_ACTIVE");
      assert.equal((await v()).rows[0].ciphertext, null);
      assert.equal(
        (
          await pool.query(
            "SELECT * FROM active_vault_migration_parts WHERE vault_id=$1",
            [f.input.vaultID],
          )
        ).rowCount,
        2,
      );
      assert.deepEqual(
        await f.store.activate(f.input, result.manifestHash),
        result,
      );
      await assert.rejects(
        pool.query(
          "UPDATE shared_vaults SET format_state='V1_ACTIVE',format_schema_version=1,active_publication_attempt_id=NULL WHERE id=$1",
          [f.input.vaultID],
        ),
        /irreversible_v2/,
      );
      await assert.rejects(
        pool.query("UPDATE shared_vaults SET ciphertext='OLD' WHERE id=$1", [
          f.input.vaultID,
        ]),
      );
      assert.equal(
        (
          await f.store.readPart({
            ...f.input,
            resourceID: f.out.resources[0].id,
            part: "SECRET",
          })
        ).part,
        "SECRET",
      );
      await assert.rejects(
        f.store.readPart({
          ...f.input,
          capability: null,
          resourceID: f.out.resources[0].id,
          part: "SECRET",
        }),
        /upgrade_required/,
      );
    } finally {
      await pool.end();
    }
  },
);
test(
  "direct SQL stale source/device/group/rotation snapshots block activation and preserve v1",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const pool = new pg.Pool({
      connectionString: process.env.TEST_DATABASE_URL,
    });
    try {
      await applyMigrations(pool, migrationDirectory, { info() {} });
      for (const mutate of [
        (f) =>
          pool.query("UPDATE shared_vaults SET revision=2 WHERE id=$1", [
            f.input.vaultID,
          ]),
        (f) =>
          pool.query(
            "DELETE FROM team_membership_device_admissions WHERE membership_id=$1",
            [f.recipient.membershipID],
          ),
        (f) =>
          pool.query(
            "UPDATE shared_vaults SET rotation_required=true WHERE id=$1",
            [f.input.vaultID],
          ),
        (f) =>
          pool.query(
            "INSERT INTO team_access_groups(team_id,name,created_by_user_id) VALUES($1,'extra',$2)",
            [f.input.teamID, f.input.actorUserID],
          ),
      ]) {
        const f = await readyCandidate(pool);
        const hash = await f.store.manifestHash(f.input);
        await mutate(f);
        await assert.rejects(f.store.activate(f.input, hash));
        assert.equal(
          (
            await pool.query(
              "SELECT format_state FROM shared_vaults WHERE id=$1",
              [f.input.vaultID],
            )
          ).rows[0].format_state,
          "V1_ACTIVE",
        );
      }
    } finally {
      await pool.end();
    }
  },
);
import { PostgresStore } from "../src/postgres-store.mjs";
test(
  "legacy authorized API returns upgrade required and outsiders get no enumeration",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const pool = new pg.Pool({
      connectionString: process.env.TEST_DATABASE_URL,
    });
    try {
      const f = await readyCandidate(pool);
      await f.store.activate(f.input, await f.store.manifestHash(f.input));
      const p = new PostgresStore(null, pool);
      await assert.rejects(
        p.getSharedVault(
          f.input.teamID,
          f.input.vaultID,
          f.input.actorUserID,
          f.input.actorDeviceID,
        ),
        /vault_upgrade_required/,
      );
      await assert.rejects(
        p.getSharedVault(
          f.input.teamID,
          f.input.vaultID,
          crypto.randomUUID(),
          crypto.randomUUID(),
        ),
        /team_not_found/,
      );
    } finally {
      await pool.end();
    }
  },
);
test(
  "all activation faults rollback pointer, retirement and audit; double activation converges",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const pool = new pg.Pool({
      connectionString: process.env.TEST_DATABASE_URL,
      max: 5,
    });
    try {
      for (const stage of [
        "pre_activation",
        "active_attempt",
        "active_pointer",
        "shared_vault_key_wrappers",
        "shared_vault_revisions",
        "team_invitation_vault_wrappers",
        "activation_audit",
      ]) {
        const f = await readyCandidate(pool),
          hash = await f.store.manifestHash(f.input);
        f.store.faultAt = (s) => {
          if (s === stage) throw Error("injected");
        };
        await assert.rejects(f.store.activate(f.input, hash), /injected/);
        assert.equal(
          (
            await pool.query(
              "SELECT ciphertext FROM shared_vaults WHERE id=$1",
              [f.input.vaultID],
            )
          ).rows[0].ciphertext,
          "LEGACY_ENCRYPTED_DATA",
        );
        assert.equal(
          (
            await pool.query(
              "SELECT count(*) FROM team_audit_events WHERE target_vault_id=$1 AND action='migration.activated'",
              [f.input.vaultID],
            )
          ).rows[0].count,
          "0",
        );
        f.store.faultAt = () => {};
        const results = await Promise.all([
          f.store.activate(f.input, hash),
          f.store.activate(f.input, hash),
        ]);
        assert.deepEqual(results[0], results[1]);
      }
    } finally {
      await pool.end();
    }
  },
);
test(
  "changed upload, plaintext checkpoint/object, manifest tamper and cross scope fail closed; discard preserves V1",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const pool = new pg.Pool({
      connectionString: process.env.TEST_DATABASE_URL,
    });
    try {
      const f = await seedMigration(pool),
        store = new VaultMigrationStore(pool, f.config),
        doc = legacy([record("host")]),
        resources = [
          {
            id: doc.records[0].id,
            kind: "HOST",
            parentFolderID: null,
            sourceOrdinal: 0,
          },
        ],
        start = await store.start({ ...f.input, resources }),
        out = await prepareLegacyMigration({
          ...f,
          scope: start.scope,
          document: doc,
          policy: start.policy,
          recipientTargets: (r, p) => start.recipients[r.id][p],
          persistCheckpoint: async () => {},
        });
      const { migrationHash } = await import("../src/migration-policy.mjs");
      const injected = { ...out.objects[0], plaintext: "PRIVATE" };
      delete injected.sha256;
      injected.sha256 = await migrationHash(injected);
      await assert.rejects(
        store.putPart(f.input, injected, out.checkpoint),
        /invalid_migration_object/,
      );
      await assert.rejects(
        store.putPart(f.input, out.objects[0], {
          ...out.checkpoint,
          plaintext: "PRIVATE",
        }),
        /invalid_migration_checkpoint/,
      );
      await store.putPart(f.input, out.objects[0], out.checkpoint);
      assert.deepEqual(
        await store.putPart(f.input, out.objects[0], out.checkpoint),
        out.objects[0],
      );
      await assert.rejects(
        store.putPart(
          { ...f.input, teamID: crypto.randomUUID() },
          out.objects[0],
          out.checkpoint,
        ),
      );
      await assert.rejects(
        store.validate(f.input, { ...out.manifest, signature: "A".repeat(86) }),
      );
      assert.equal(
        (
          await pool.query(
            "SELECT state FROM vault_migration_attempts WHERE id=$1",
            [f.input.attemptID],
          )
        ).rows[0].state,
        "FAILED_PRE_ACTIVATION",
      );
      await store.start({ ...f.input, resources });
      await store.validate(f.input, out.manifest);
      await store.discard(f.input);
      assert.equal(
        (
          await pool.query(
            "SELECT format_state,ciphertext FROM shared_vaults WHERE id=$1",
            [f.input.vaultID],
          )
        ).rows[0].ciphertext,
        "LEGACY_ENCRYPTED_DATA",
      );
      assert.equal(
        (
          await pool.query(
            "SELECT count(*) FROM vault_migration_parts WHERE attempt_id=$1",
            [f.input.attemptID],
          )
        ).rows[0].count,
        "0",
      );
    } finally {
      await pool.end();
    }
  },
);
test(
  "concurrent legacy SQL write cannot cross cutover; readers see only complete generations",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const pool = new pg.Pool({
      connectionString: process.env.TEST_DATABASE_URL,
      max: 5,
    });
    let unblock;
    try {
      const f = await readyCandidate(pool),
        hash = await f.store.manifestHash(f.input);
      let reached;
      const atPointer = new Promise((r) => {
        reached = r;
      });
      const release = new Promise((r) => {
        unblock = r;
      });
      f.store.faultAt = async (stage) => {
        if (stage === "active_pointer") {
          reached();
          await release;
        }
      };
      const activation = f.store.activate(f.input, hash);
      await atPointer;
      assert.equal(
        (
          await pool.query("SELECT ciphertext FROM shared_vaults WHERE id=$1", [
            f.input.vaultID,
          ])
        ).rows[0].ciphertext,
        "LEGACY_ENCRYPTED_DATA",
      );
      assert.equal(
        (
          await pool.query(
            "SELECT count(*) FROM active_vault_migration_parts WHERE vault_id=$1",
            [f.input.vaultID],
          )
        ).rows[0].count,
        "0",
      );
      const writer = await pool.connect();
      const pid = (await writer.query("SELECT pg_backend_pid() AS pid")).rows[0]
        .pid;
      const write = writer.query(
        "UPDATE shared_vaults SET revision=revision+1 WHERE id=$1",
        [f.input.vaultID],
      );
      const rejected = assert.rejects(write, /irreversible_v2/);
      let waiting = false;
      for (let n = 0; n < 100; n++) {
        waiting = (
          await pool.query(
            "SELECT wait_event_type='Lock' AS waiting FROM pg_stat_activity WHERE pid=$1",
            [pid],
          )
        ).rows[0]?.waiting;
        if (waiting) break;
        await new Promise((r) => setTimeout(r, 5));
      }
      assert.equal(waiting, true);
      unblock();
      await activation;
      await rejected;
      writer.release();
      assert.equal(
        (
          await pool.query(
            "SELECT count(*) FROM active_vault_migration_parts WHERE vault_id=$1",
            [f.input.vaultID],
          )
        ).rows[0].count,
        "2",
      );
    } finally {
      unblock?.();
      await pool.end();
    }
  },
);
test(
  "cutover removes seeded legacy revision/wrapper material and rejects old SQL resurrection",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const pool = new pg.Pool({
      connectionString: process.env.TEST_DATABASE_URL,
    });
    try {
      const f = await seedMigration(pool),
        v = f.input.vaultID;
      await pool.query(
        "INSERT INTO shared_vault_revisions(vault_id,revision,key_generation,envelope_version,ciphertext,nonce,auth_tag,content_hash,updated_by_device_id) VALUES($1,1,1,1,$2,$3,$4,$5,$6)",
        [
          v,
          "LEGACY_REVISION",
          "A".repeat(16),
          "A".repeat(22),
          "A".repeat(43),
          f.deviceID,
        ],
      );
      const insert =
        "INSERT INTO shared_vault_key_wrappers(vault_id,key_generation,membership_id,membership_epoch,device_id,wrapper_version,ephemeral_public_key,ciphertext,nonce,auth_tag,context_hash,created_by_device_id) VALUES($1,1,$2,1,$3,1,$4,$5,$6,$7,$8,$3)";
      const args = [
        v,
        f.recipient.membershipID,
        f.deviceID,
        f.identity.publicKey,
        "A".repeat(43),
        "A".repeat(16),
        "A".repeat(22),
        "A".repeat(43),
      ];
      await pool.query(insert, args);
      const store = new VaultMigrationStore(pool, f.config),
        doc = legacy([record("host")]),
        resources = [
          {
            id: doc.records[0].id,
            kind: "HOST",
            parentFolderID: null,
            sourceOrdinal: 0,
          },
        ],
        start = await store.start({ ...f.input, resources }),
        out = await prepareLegacyMigration({
          ...f,
          scope: start.scope,
          document: doc,
          policy: start.policy,
          recipientTargets: (r, p) => start.recipients[r.id][p],
          persistCheckpoint: async () => {},
        });
      await store.putPart(f.input, out.objects[0], out.checkpoint);
      const valid = await store.validate(f.input, out.manifest);
      await store.activate(f.input, valid.manifestHash);
      for (const table of [
        "shared_vault_revisions",
        "shared_vault_key_wrappers",
      ])
        assert.equal(
          (
            await pool.query(
              `SELECT count(*) FROM ${table} WHERE vault_id=$1`,
              [v],
            )
          ).rows[0].count,
          "0",
        );
      await assert.rejects(
        pool.query(insert, args),
        /legacy_vault_format_required/,
      );
    } finally {
      await pool.end();
    }
  },
);
test(
  "post-activation signed directory changes fail closed until fix-forward publication",
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const pool = new pg.Pool({
      connectionString: process.env.TEST_DATABASE_URL,
    });
    try {
      const f = await readyCandidate(pool);
      await f.store.activate(f.input, await f.store.manifestHash(f.input));
      const { signDeviceDirectory } = await import(
        "../public/device-trust-v1.js"
      );
      const { validateSignedDeviceDirectory } = await import(
        "../src/device-trust-policy.mjs"
      );
      const checkpoint = await signDeviceDirectory({
        root: f.root,
        accountID: f.accountID,
        version: 2,
        certificates: [f.recipient.certificate],
      });
      const b = await validateSignedDeviceDirectory({
        rootPublicKey: f.root.publicKey,
        checkpoint,
        accountID: f.accountID,
      });
      await pool.query(
        "INSERT INTO device_trust_directories_v1(account_id,version,directory_bytes,signature,directory_json) VALUES($1,2,$2,$3,$4)",
        [f.accountID, b.directoryBytes, b.directorySignature, checkpoint],
      );
      await assert.rejects(
        f.store.readPart({
          ...f.input,
          resourceID: f.out.resources[0].id,
          part: "SECRET",
        }),
        /migration_active_policy_stale/,
      );
    } finally {
      await pool.end();
    }
  },
);
