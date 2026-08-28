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
  ]);
  for (const migration of migrations) assert.match(migration.checksum, /^[0-9a-f]{64}$/);
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
      if (sql.includes("to_regclass")) return { rows: [{ exists: true }] };
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
