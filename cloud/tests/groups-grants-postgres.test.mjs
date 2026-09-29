import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { randomUUID } from "node:crypto";
import { applyMigrations, loadMigrations } from "../src/migrations.mjs";

const directory = fileURLToPath(new URL("../migrations/", import.meta.url));
const databaseURL = process.env.TEST_DATABASE_URL;

test("migration 018 defines the dormant access-policy schema", async () => {
  const migrations = await loadMigrations(directory);
  assert.equal(migrations.at(-1)?.version, 18);
  const sql = migrations.at(-1)?.sql ?? "";
  for (const name of ["team_policy_revisions", "team_access_groups", "team_access_group_members", "vault_access_grants", "policy_kind", "access_policy_version"]) {
    assert.match(sql, new RegExp(name));
  }
});

test("fresh PostgreSQL keeps legacy Vaults V1 and groups Team-scoped", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 2 });
  try {
    await applyMigrations(pool, directory, { info() {} });
    const vaultColumn = await pool.query(`SELECT column_default FROM information_schema.columns
      WHERE table_name = 'shared_vaults' AND column_name = 'format_state'`);
    assert.match(vaultColumn.rows[0]?.column_default ?? "", /V1_ACTIVE/);
    const groupVaultColumn = await pool.query(`SELECT 1 FROM information_schema.columns
      WHERE table_name = 'team_access_groups' AND column_name = 'vault_id'`);
    assert.equal(groupVaultColumn.rowCount, 0);
    const tables = await pool.query(`SELECT to_regclass('team_access_groups') AS groups,
      to_regclass('vault_access_grants') AS grants`);
    assert.equal(tables.rows[0].groups, "team_access_groups");
    assert.equal(tables.rows[0].grants, "vault_access_grants");
  } finally {
    await pool.end();
  }
});


test("PostgreSQL enforces scoped grants, Credential mask, and Team group lifetime", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 2 });
  const client = await pool.connect();
  const suffix = randomUUID().slice(0, 12);
  async function rejectsStatement(sql, args, expected) {
    await client.query("SAVEPOINT invalid_policy_write");
    await assert.rejects(client.query(sql, args), expected);
    await client.query("ROLLBACK TO SAVEPOINT invalid_policy_write");
    await client.query("RELEASE SAVEPOINT invalid_policy_write");
  }
  try {
    await applyMigrations(pool, directory, { info() {} });
    await client.query("BEGIN");
    const user = (await client.query(`INSERT INTO users (email, username, display_name, email_verified_at)
      VALUES ($1, $2, 'Access fixture', now()) RETURNING id`,
    [`access-${suffix}@example.com`, `access_${suffix}`])).rows[0].id;
    const team = (await client.query("INSERT INTO teams (name, created_by_user_id) VALUES ('Access fixture', $1) RETURNING id", [user])).rows[0].id;
    const member = (await client.query("INSERT INTO team_memberships (team_id, user_id, role) VALUES ($1, $2, 'owner') RETURNING id, epoch", [team, user])).rows[0];
    const vault = (await client.query(`INSERT INTO shared_vaults
      (team_id, name, created_by_user_id, format_state, format_schema_version)
      VALUES ($1, 'Access fixture', $2, 'V2_PREPARING', 2) RETURNING id`, [team, user])).rows[0].id;
    const resource = randomUUID();
    await client.query(`INSERT INTO vault_resource_registry
      (id, team_id, vault_id, policy_class, policy_kind)
      VALUES ($1, $2, $3, 'secret', 'CREDENTIAL')`, [resource, team, vault]);
    const group = (await client.query(`INSERT INTO team_access_groups
      (team_id, name, created_by_user_id) VALUES ($1, 'Operators', $2) RETURNING id`, [team, user])).rows[0].id;
    const edge = (await client.query(`INSERT INTO team_access_group_members
      (team_id, group_id, user_id, membership_id, membership_epoch, created_by_user_id)
      VALUES ($1, $2, $3, $4, $5, $3) RETURNING id`,
    [team, group, user, member.id, member.epoch])).rows[0].id;
    const insertGrant = `INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, target_kind, target_id,
       permission_mask, created_by_user_id)
      VALUES ($1, $2, 'GROUP', $3, 'RESOURCE', $4, $5, $6) RETURNING id`;
    await rejectsStatement(insertGrant, [team, vault, group, resource, 4, user], /credential_edit_requires_reveal/);
    const grant = (await client.query(insertGrant, [team, vault, group, resource, 6, user])).rows[0].id;
    await rejectsStatement(insertGrant, [team, vault, group, resource, 6, user], /duplicate key/);
    await rejectsStatement("UPDATE team_access_groups SET deleted_at = now(), version = 2 WHERE id = $1", [group], /access_group_active_grants_or_tombstone/);
    await client.query("UPDATE vault_access_grants SET revoked_at = now(), version = 2 WHERE id = $1", [grant]);
    await client.query("UPDATE team_access_group_members SET removed_at = now(), version = 2 WHERE id = $1", [edge]);
    await client.query("UPDATE team_access_groups SET deleted_at = now(), version = 2 WHERE id = $1", [group]);
    assert.equal((await client.query("SELECT team_id FROM team_access_groups WHERE id = $1", [group])).rows[0].team_id, team);
    assert.equal((await client.query("SELECT access_policy_version FROM shared_vaults WHERE id = $1", [vault])).rows[0].access_policy_version, "2");
    await client.query("ROLLBACK");
  } finally {
    await client.query("ROLLBACK").catch(() => {});
    client.release();
    await pool.end();
  }
});
