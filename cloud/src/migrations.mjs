import { createHash } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const migrationPattern = /^(\d{3,})_[a-z0-9][a-z0-9_-]*\.sql$/;
const advisoryLockName = "selective_remote_schema_migrations_v1";

export async function loadMigrations(directory) {
  const names = (await readdir(directory))
    .filter((name) => migrationPattern.test(name))
    .sort((left, right) => left.localeCompare(right));
  const migrations = [];
  const versions = new Set();

  for (const name of names) {
    const version = Number.parseInt(name.match(migrationPattern)[1], 10);
    if (versions.has(version)) throw new Error(`duplicate_migration_version:${version}`);
    versions.add(version);
    const sql = await readFile(join(directory, name), "utf8");
    migrations.push({
      version,
      name,
      sql,
      checksum: createHash("sha256").update(sql).digest("hex"),
    });
  }

  if (migrations.length === 0) throw new Error("no_migrations_found");
  return migrations;
}

export function pendingMigrations(migrations, appliedRows) {
  const applied = new Map(appliedRows.map((row) => [Number(row.version), row]));
  for (const migration of migrations) {
    const row = applied.get(migration.version);
    if (!row) continue;
    if (row.name !== migration.name || row.checksum_sha256 !== migration.checksum) {
      throw new Error(`applied_migration_changed:${migration.name}`);
    }
  }
  return migrations.filter((migration) => !applied.has(migration.version));
}

export async function applyMigrations(pool, directory, logger = console) {
  const migrations = await loadMigrations(directory);
  const client = await pool.connect();
  let locked = false;
  try {
    await client.query("SELECT pg_advisory_lock(hashtext($1))", [advisoryLockName]);
    locked = true;
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version bigint PRIMARY KEY,
        name text NOT NULL UNIQUE,
        checksum_sha256 text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
      )
    `);
    const applied = await client.query(
      "SELECT version, name, checksum_sha256 FROM schema_migrations ORDER BY version",
    );

    for (const migration of pendingMigrations(migrations, applied.rows)) {
      if (migration.version === 1) {
        const initialState = await initialSchemaState(client);
        if (initialState === "complete") {
          await recordMigration(client, migration);
          logger.info(`Baselined migration ${migration.name}`);
          continue;
        }
        if (initialState === "partial") throw new Error("incomplete_initial_schema");
      }

      if (migration.version === 1) {
        // The existing initial migration owns its transaction. It is idempotent,
        // so a process interruption before recording it can be safely retried.
        await client.query(migration.sql);
        await recordMigration(client, migration);
      } else {
        await client.query("BEGIN");
        try {
          await client.query(migration.sql);
          await recordMigration(client, migration);
          await client.query("COMMIT");
        } catch (error) {
          await client.query("ROLLBACK");
          throw error;
        }
      }
      logger.info(`Applied migration ${migration.name}`);
    }
  } finally {
    if (locked) {
      try { await client.query("SELECT pg_advisory_unlock(hashtext($1))", [advisoryLockName]); }
      catch {}
    }
    client.release();
  }
}

async function initialSchemaState(client) {
  const result = await client.query(`
    SELECT
      to_regclass('public.users') IS NOT NULL AS users,
      to_regclass('public.account_identities') IS NOT NULL AS account_identities,
      to_regclass('public.devices') IS NOT NULL AS devices,
      to_regclass('public.sessions') IS NOT NULL AS sessions,
      to_regclass('public.personal_vaults') IS NOT NULL AS personal_vaults,
      to_regclass('public.vault_revisions') IS NOT NULL AS vault_revisions,
      EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'users' AND column_name = 'email_verified_at'
      ) AS users_email_verified_at,
      EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'personal_vaults' AND column_name = 'wrapped_key'
      ) AS personal_vaults_wrapped_key
  `);
  const state = result.rows[0] ?? {};
  const tables = [
    state.users,
    state.account_identities,
    state.devices,
    state.sessions,
    state.personal_vaults,
    state.vault_revisions,
  ];
  if (tables.every((value) => value === false)) return "absent";
  if (tables.every((value) => value === true)
    && state.users_email_verified_at === true
    && state.personal_vaults_wrapped_key === true) return "complete";
  return "partial";
}

async function recordMigration(client, migration) {
  await client.query(
    "INSERT INTO schema_migrations (version, name, checksum_sha256) VALUES ($1, $2, $3)",
    [migration.version, migration.name, migration.checksum],
  );
}
