import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { applyMigrations } from "../src/migrations.mjs";

const databaseURL = process.env.TEST_DATABASE_URL;
const migrationsDirectory = fileURLToPath(new URL("../migrations/", import.meta.url));

test("signed device trust records are additive, unique and bounded in PostgreSQL", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 2 });
  try {
    await applyMigrations(pool, migrationsDirectory, { info() {} });
    const v2Before = Number((await pool.query(`SELECT count(*) AS count FROM shared_vaults
      WHERE format_state = 'V2_ACTIVE'`)).rows[0].count);
    const account = (await pool.query(`INSERT INTO users (email) VALUES ($1) RETURNING id`,
      [`trust-${randomUUID()}@example.test`])).rows[0].id;
    const device = randomUUID();
    await pool.query(`INSERT INTO devices (id, user_id, name, platform)
      VALUES ($1, $2, 'Test', 'web')`, [device, account]);
    const root = Buffer.alloc(65, 7); root[0] = 4;
    const fingerprint = Buffer.alloc(32, 9);
    await pool.query(`INSERT INTO device_trust_roots_v1
      (account_id, root_public_key, fingerprint) VALUES ($1, $2, $3)`, [account, root, fingerprint]);
    await assert.rejects(pool.query(`INSERT INTO device_trust_roots_v1
      (account_id, root_public_key, fingerprint) VALUES ($1, $2, $3)`, [account, root, fingerprint]),
    (error) => error.code === "23505");
    const signature = Buffer.alloc(64, 1);
    await pool.query(`INSERT INTO device_trust_certificates_v1
      (account_id, device_id, key_version, certificate_bytes, signature)
      VALUES ($1, $2, 1, $3, $4)`, [account, device, Buffer.from("cert"), signature]);
    await assert.rejects(pool.query(`INSERT INTO device_trust_certificates_v1
      (account_id, device_id, key_version, certificate_bytes, signature)
      VALUES ($1, $2, 1, $3, $4)`, [account, device, Buffer.from("cert"), signature]),
    (error) => error.code === "23505");
    await assert.rejects(pool.query(`INSERT INTO device_trust_certificates_v1
      (account_id, device_id, key_version, certificate_bytes, signature)
      VALUES ($1, $2, 2, $3, $4)`, [account, device, Buffer.alloc(65536), signature]),
    (error) => error.code === "23514");
    await pool.query(`INSERT INTO device_trust_directories_v1
      (account_id, version, directory_bytes, signature) VALUES ($1, 1, $2, $3)`,
    [account, Buffer.from("directory"), signature]);
    await assert.rejects(pool.query(`INSERT INTO device_trust_directories_v1
      (account_id, version, directory_bytes, signature) VALUES ($1, 1, $2, $3)`,
    [account, Buffer.from("directory"), signature]), (error) => error.code === "23505");
    const vaultState = await pool.query(`SELECT count(*)::int AS count FROM shared_vaults
      WHERE format_state = 'V2_ACTIVE'`);
    assert.equal(vaultState.rows[0].count, v2Before);
  } finally { await pool.end(); }
});
