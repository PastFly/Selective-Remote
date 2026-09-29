import assert from "node:assert/strict";
import test from "node:test";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import pg from "pg";
import { applyMigrations } from "../src/migrations.mjs";

const databaseURL = process.env.TEST_DATABASE_URL;
const directory = fileURLToPath(new URL("../migrations/", import.meta.url));

test("PG16 access query shapes at 100 members and 1000 resources", {
  skip: databaseURL ? false : "TEST_DATABASE_URL is not configured",
}, async () => {
  const pool = new pg.Pool({ connectionString: databaseURL, max: 2 });
  const client = await pool.connect();
  const suffix = randomUUID().replaceAll("-", "").slice(0, 12);
  try {
    await applyMigrations(pool, directory, { info() {} });
    await client.query("BEGIN");
    const owner = (await client.query(`INSERT INTO users
      (email, username, display_name, email_verified_at)
      VALUES ($1, $2, 'Scale owner', now()) RETURNING id`,
    [`scale-owner-${suffix}@example.com`, `scale_owner_${suffix}`])).rows[0].id;
    const team = (await client.query(`INSERT INTO teams
      (name, created_by_user_id) VALUES ('Access scale', $1) RETURNING id`,
    [owner])).rows[0].id;
    await client.query(`INSERT INTO team_memberships (team_id, user_id, role)
      VALUES ($1, $2, 'owner')`, [team, owner]);
    const vault = (await client.query(`INSERT INTO shared_vaults
      (team_id, name, created_by_user_id, format_state, format_schema_version)
      VALUES ($1, 'Scale', $2, 'V2_PREPARING', 2) RETURNING id`,
    [team, owner])).rows[0].id;
    const group = (await client.query(`INSERT INTO team_access_groups
      (team_id, name, created_by_user_id)
      VALUES ($1, 'Scale group', $2) RETURNING id`,
    [team, owner])).rows[0].id;
    await client.query(`WITH created AS (
      INSERT INTO users (email, username, display_name, email_verified_at)
      SELECT 'scale-' || $1::text || '-' || n || '@example.com',
        'scale_' || $1::text || '_' || n, 'Scale member', now()
      FROM generate_series(1, 100) AS n RETURNING id
    ) INSERT INTO team_memberships (team_id, user_id, role)
      SELECT $2, id, 'viewer' FROM created`, [suffix, team]);
    await client.query(`INSERT INTO team_access_group_members
      (team_id, group_id, user_id, membership_id, membership_epoch,
       created_by_user_id)
      SELECT $1, $2, user_id, id, epoch, $3 FROM team_memberships
      WHERE team_id = $1`, [team, group, owner]);
    await client.query(`WITH resources AS (
      INSERT INTO vault_resource_registry
        (id, team_id, vault_id, policy_class, policy_kind)
      SELECT gen_random_uuid(), $1, $2, 'general', 'HOST'
      FROM generate_series(1, 1000) RETURNING id
    ) INSERT INTO vault_access_grants
      (team_id, vault_id, principal_kind, principal_id, target_kind,
       target_id, permission_mask, created_by_user_id)
      SELECT $1, $2, 'GROUP', $3, 'RESOURCE', id, 1, $4 FROM resources`,
    [team, vault, group, owner]);
    const resource = (await client.query(`SELECT id FROM vault_resource_registry
      WHERE vault_id = $1 LIMIT 1`, [vault])).rows[0].id;
    const shapes = [
      ["effective", `SELECT id, permission_mask FROM vault_access_grants
        WHERE team_id = $1 AND vault_id = $2 AND revoked_at IS NULL
          AND principal_kind = 'GROUP' AND principal_id = $3
          AND target_kind = 'RESOURCE' AND target_id = $4`,
      [team, vault, group, resource]],
      ["who_has", `SELECT member.user_id FROM team_access_group_members AS edge
        JOIN team_memberships AS member ON member.id = edge.membership_id
          AND member.epoch = edge.membership_epoch AND member.revoked_at IS NULL
        JOIN vault_access_grants AS access_grant
          ON access_grant.principal_kind = 'GROUP'
          AND access_grant.principal_id = edge.group_id
          AND access_grant.team_id = edge.team_id
          AND access_grant.target_kind = 'RESOURCE'
          AND access_grant.target_id = $3
          AND access_grant.vault_id = $2 AND access_grant.revoked_at IS NULL
        WHERE edge.team_id = $1 AND edge.removed_at IS NULL
        ORDER BY member.user_id LIMIT 50`, [team, vault, resource]],
      ["resources_by_principal", `SELECT id, target_id FROM vault_access_grants
        WHERE team_id = $1 AND vault_id = $2 AND principal_kind = 'GROUP'
          AND principal_id = $3 AND revoked_at IS NULL
        ORDER BY id LIMIT 50`, [team, vault, group]],
      ["group_list", `SELECT id, name FROM team_access_groups
        WHERE team_id = $1 AND deleted_at IS NULL
        ORDER BY id LIMIT 50`, [team]],
    ];
    for (const [name, sql, args] of shapes) {
      const rows = await client.query(`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ${sql}`, args);
      const plan = rows.rows[0]["QUERY PLAN"][0].Plan;
      assert.ok(plan["Actual Rows"] > 0, `${name} should return fixture rows`);
      assert.ok(plan["Actual Total Time"] < 1000, `${name} exceeded bounded scale budget`);
      console.log(`scale ${name}: ${plan["Actual Rows"]} rows, ${plan["Actual Total Time"]} ms, ${plan["Shared Hit Blocks"]} shared hits`);
    }
    await client.query("ROLLBACK");
  } finally {
    await client.query("ROLLBACK").catch(() => {});
    client.release();
    await pool.end();
  }
});
