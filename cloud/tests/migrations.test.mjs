import assert from "node:assert/strict";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { applyMigrations, loadMigrations, pendingMigrations } from "../src/migrations.mjs";

const migrationsDirectory = fileURLToPath(new URL("../migrations/", import.meta.url));

test("numbered migrations have stable checksums", async () => {
  const migrations = await loadMigrations(migrationsDirectory);
  assert.deepEqual(migrations.map(({ version, name }) => ({ version, name })), [
    { version: 1, name: "001_initial.sql" },
    { version: 2, name: "002_email_verification.sql" },
    { version: 3, name: "003_auth_rate_limits.sql" },
    { version: 4, name: "004_password_reset.sql" },
    { version: 5, name: "005_team_foundation.sql" },
    { version: 6, name: "006_team_vault_crypto.sql" },
  ]);
  for (const migration of migrations) assert.match(migration.checksum, /^[0-9a-f]{64}$/);
});

test("Team Vault crypto migration persists ciphertext, device wrappers and rotation subjects", async () => {
  const migrations = await loadMigrations(migrationsDirectory);
  const crypto = migrations.find(({ version }) => version === 6);

  assert.match(crypto.sql, /CREATE TABLE shared_vault_revisions/);
  assert.match(crypto.sql, /CREATE TABLE shared_vault_key_wrappers/);
  assert.match(crypto.sql, /public_key_algorithm = 'p256-ecdh-v1'/);
  assert.match(crypto.sql, /membership_epoch bigint NOT NULL/);
  assert.match(crypto.sql, /removed_device_id uuid/);
  assert.match(crypto.sql, /shared_vault_rotation_subject/);
  assert.doesNotMatch(crypto.sql, /\bplaintext\b|\bvault_key\s+text\b|\bprivate_key\b/);
});

test("Team foundation migration keeps authorization and invitation state durable", async () => {
  const migrations = await loadMigrations(migrationsDirectory);
  const team = migrations.find(({ version }) => version === 5);

  for (const table of [
    "teams",
    "team_memberships",
    "team_invitations",
    "team_outbox_jobs",
    "shared_vaults",
    "shared_vault_rotation_tasks",
    "team_audit_events",
    "team_mutation_receipts",
  ]) {
    assert.match(team.sql, new RegExp(`CREATE TABLE ${table}`));
  }
  assert.match(team.sql, /role IN \('owner', 'admin', 'editor', 'viewer'\)/);
  assert.match(team.sql, /team_memberships_one_active_user/);
  assert.match(team.sql, /token_hash text NOT NULL UNIQUE/);
  assert.match(team.sql, /token_hash ~ '\^\[0-9a-f\]\{64\}\$'/);
  assert.match(team.sql, /payload_ciphertext text NOT NULL/);
  assert.doesNotMatch(team.sql, /\btoken\s+text\b|\bplaintext\b|\bvault_key\b/);
  assert.doesNotMatch(team.sql, /CREATE (?:TABLE|INDEX) IF NOT EXISTS/);
});

test("password reset migration stores only hashed expiring one-time tokens", async () => {
  const migrations = await loadMigrations(migrationsDirectory);
  const reset = migrations.find(({ version }) => version === 4);

  assert.match(reset.sql, /token_hash text NOT NULL UNIQUE/);
  assert.match(reset.sql, /token_hash ~ '\^\[0-9a-f\]\{64\}\$'/);
  assert.match(reset.sql, /expires_at timestamptz NOT NULL/);
  assert.match(reset.sql, /consumed_at timestamptz/);
  assert.match(reset.sql, /invalidated_at timestamptz/);
  assert.doesNotMatch(reset.sql, /\bpassword(?:_hash)?\s+text\b|\btoken\s+text\b/);
});

test("rate limit migration stores only bounded HMAC-keyed counters", async () => {
  const migrations = await loadMigrations(migrationsDirectory);
  const rateLimits = migrations.find(({ version }) => version === 3);

  assert.match(rateLimits.sql, /key_hash text NOT NULL/);
  assert.match(rateLimits.sql, /key_hash ~ '\^\[0-9a-f\]\{64\}\$'/);
  assert.match(rateLimits.sql, /request_count bigint NOT NULL/);
  assert.match(rateLimits.sql, /PRIMARY KEY \(scope, key_hash\)/);
  assert.doesNotMatch(rateLimits.sql, /ip_address|email text|raw_key/);
});

test("email verification migration stores only hashed expiring tokens", async () => {
  const migrations = await loadMigrations(migrationsDirectory);
  const verification = migrations.find(({ version }) => version === 2);

  assert.match(verification.sql, /token_hash text NOT NULL UNIQUE/);
  assert.match(verification.sql, /token_hash ~ '\^\[0-9a-f\]\{64\}\$'/);
  assert.match(verification.sql, /expires_at timestamptz NOT NULL/);
  assert.match(verification.sql, /ON DELETE CASCADE/);
  assert.doesNotMatch(verification.sql, /\btoken\s+text\b/);
});

test("an edited applied migration is rejected", async () => {
  const migrations = await loadMigrations(migrationsDirectory);
  assert.throws(() => pendingMigrations(migrations, [{
    version: 1,
    name: "001_initial.sql",
    checksum_sha256: "0".repeat(64),
  }]), /applied_migration_changed/);
});

test("an existing initial schema is baselined without replaying migration SQL", async () => {
  const migrations = await loadMigrations(migrationsDirectory);
  const queries = [];
  const client = {
    async query(sql, parameters = []) {
      queries.push({ sql, parameters });
      if (sql.includes("FROM schema_migrations")) return { rows: [] };
      if (sql.includes("to_regclass")) return { rows: [{
        users: true,
        account_identities: true,
        devices: true,
        sessions: true,
        personal_vaults: true,
        vault_revisions: true,
        users_email_verified_at: true,
        personal_vaults_wrapped_key: true,
      }] };
      return { rows: [] };
    },
    release() {},
  };
  const pool = { async connect() { return client; } };

  await applyMigrations(pool, migrationsDirectory, { info() {} });

  assert.equal(queries.some(({ sql }) => sql === migrations[0].sql), false);
  const record = queries.find(({ sql }) => sql.startsWith("INSERT INTO schema_migrations"));
  assert.deepEqual(record.parameters, [1, "001_initial.sql", migrations[0].checksum]);
});

test("a partial initial schema is rejected instead of silently baselined", async () => {
  const client = {
    async query(sql) {
      if (sql.includes("FROM schema_migrations")) return { rows: [] };
      if (sql.includes("to_regclass")) return { rows: [{
        users: true,
        account_identities: false,
        devices: false,
        sessions: false,
        personal_vaults: false,
        vault_revisions: false,
        users_email_verified_at: false,
        personal_vaults_wrapped_key: false,
      }] };
      return { rows: [] };
    },
    release() {},
  };
  const pool = { async connect() { return client; } };

  await assert.rejects(
    applyMigrations(pool, migrationsDirectory, { info() {} }),
    /incomplete_initial_schema/,
  );
});
