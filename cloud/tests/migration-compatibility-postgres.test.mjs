import assert from 'node:assert/strict';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {mkdtemp, mkdir, copyFile, writeFile, rm} from 'node:fs/promises';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import pg from 'pg';
import {loadMigrations, applyMigrations} from '../src/migrations.mjs';
import {MigrationFence} from '../src/migration-fence.mjs';
import {seedMigration} from './vault-v2-migration-db-fixtures.mjs';

const database = process.env.TEST_DATABASE_URL;
const execute = promisify(execFile);
const migrationDirectory = fileURLToPath(new URL('../migrations/', import.meta.url));
const operatorPath = fileURLToPath(new URL('../scripts/vault-v2-migration-staging.mjs', import.meta.url));

// This file is intended for cloud/tests/. It creates its OWN database using the
// disposable TEST_DATABASE_URL role; it never resets/downgrades the supplied DB.
// PostgreSQL's CI service role has CREATEDB through its initial superuser role.
// No temporary-schema fallback: initialSchemaState deliberately inspects public.*.
async function withFreshDatabase(work) {
  const admin = new pg.Pool({connectionString: database, max: 1});
  const name = `prc_compat_${process.pid}_${randomUUID().replaceAll('-', '')}`;
  assert.match(name, /^prc_compat_[0-9]+_[a-f0-9]{32}$/);
  assert.ok(name.length <= 63);
  let created = false, pool;
  try {
    const role = (await admin.query(
      'SELECT rolcreatedb OR rolsuper AS allowed FROM pg_roles WHERE rolname=current_user',
    )).rows[0];
    assert.equal(role?.allowed, true,
      'Isolated compatibility integration requires a disposable PostgreSQL role with CREATEDB; no shared-database fallback');
    assert.match((await admin.query('SHOW server_version')).rows[0].server_version, /^16\./);
    // Identifier is generated above, not supplied by a caller or connection URL.
    await admin.query(`CREATE DATABASE "${name}" TEMPLATE template0`);
    created = true;
    const connection = new URL(database);
    connection.pathname = `/${name}`;
    pool = new pg.Pool({connectionString: connection.href, max: 2});
    await work({pool, databaseURL: connection.href});
  } finally {
    try {
      await pool?.end();
      if (created) await admin.query(`DROP DATABASE "${name}" WITH (FORCE)`);
    } finally {
      await admin.end();
    }
  }
}

async function runOperator({databaseURL, fencePath, vaultID}) {
  const options = {
    env: {
      ...process.env,
      MIGRATION_ENVIRONMENT: 'staging',
      MIGRATION_SYNTHETIC_ENABLED: 'YES',
      MIGRATION_SYNTHETIC_VAULT_IDS: vaultID,
      MIGRATION_STAGING_DATABASE_URL: databaseURL,
      MIGRATION_FENCE_PATH: fencePath,
    },
    encoding: 'utf8', timeout: 30000, maxBuffer: 64 * 1024,
  };
  // execFile has no input option: supply the guarded request through the child
  // stdin, without placing connection strings or payloads in argv/log output.
  const running = execute(process.execPath, [operatorPath], options);
  running.child.stdin.end(JSON.stringify({operation: 'check-compatibility'}));
  try {
    const result = await running;
    return {status: 0, stdout: result.stdout, stderr: result.stderr};
  } catch (error) {
    if (error.code !== 1) throw Error('compatibility_operator_process_failed');
    return {status: error.code, stdout: error.stdout, stderr: error.stderr};
  }
}

async function check({pool, databaseURL, fencePath, vaultID, errorCode, publicationQueries}) {
  const cli = await runOperator({databaseURL, fencePath, vaultID});
  if (errorCode) {
    assert.equal(cli.status, 1);
    assert.equal(cli.stderr.trim(), errorCode);
    assert.equal(cli.stdout, '');
  } else {
    assert.equal(cli.status, 0);
    assert.equal(cli.stderr, '');
    assert.deepEqual(JSON.parse(cli.stdout), {compatible: true});
  }
  const {verifyMigrationCompatibility} = await import('../src/migration-compatibility.mjs');
  const queries = [];
  const operation = verifyMigrationCompatibility({
    query: (sql, values) => { queries.push(sql); return pool.query(sql, values); },
    fence: new MigrationFence(fencePath),
  });
  if (errorCode) await assert.rejects(operation, error => error.message === errorCode);
  else assert.deepEqual(await operation, {compatible: true});
  assert.equal(queries.filter(sql => /vault_migration_attempts/u.test(sql)).length, publicationQueries);
  assert.equal(queries.filter(sql => /schema_migrations/u.test(sql)).length, 1);

}

// Only seed the actual relational tuple read by compatibility. This deliberately
// does NOT claim operator activation, reader cryptography, or migration E2E.
// All DDL/FKs/triggers remain enabled; Task3/7 supply real activation evidence.
async function seedCompatibilityTuple(pool) {
  const fixture = await seedMigration(pool);
  const {teamID, vaultID, attemptID, actorUserID, actorDeviceID} = fixture.input;
  const manifestHash = 'a'.repeat(64);
  const resources = [{id: randomUUID(), kind: 'HOST', parentFolderID: null, sourceOrdinal: 0}];
  await pool.query(`INSERT INTO vault_migration_attempts
    (id,team_id,vault_id,actor_user_id,actor_device_id,state,source_revision,
     source_hash,snapshot_hash,snapshot,policy,resources,scope,manifest,manifest_hash)
    VALUES($1,$2,$3,$4,$5,'V2_ACTIVE',1,$6,$7,'{}'::jsonb,'[]'::jsonb,$8::jsonb,
           '{}'::jsonb,'{"syntheticCompatibilityTuple":true}'::jsonb,$9)`,
  [attemptID, teamID, vaultID, actorUserID, actorDeviceID, 'synthetic-source',
    'b'.repeat(64), JSON.stringify(resources), manifestHash]);
  await pool.query(`UPDATE shared_vaults SET format_state='V2_ACTIVE',format_schema_version=2,
    active_publication_attempt_id=$2,envelope_version=NULL,ciphertext=NULL,nonce=NULL,
    auth_tag=NULL,content_hash=NULL,updated_by_device_id=NULL WHERE id=$1`, [vaultID, attemptID]);
  return {teamID, vaultID, attemptID, manifestHash};
}

test('PG16 normal migrations 12→18→19→20 enforce fence floor before publication queries in helper and guarded CLI',
  {skip: !database, timeout: 120000}, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'prc-compatibility-pg-'));
    try {
      await withFreshDatabase(async ({pool, databaseURL}) => {
        const prefixDirectory = join(directory, 'migrations');
        await mkdir(prefixDirectory);
        const migrations = await loadMigrations(migrationDirectory), copied = new Set();
        const emptyFence = join(directory, 'empty.fence');
        // Explicit fixture initialization, not automatic recovery of missing history.
        await writeFile(emptyFence, '', {mode: 0o600});
        let tuple, floor19, floor20, fork20;
        const unusedVaultID = randomUUID();
        for (const version of [12, 18, 19, 20]) {
          for (const migration of migrations.filter(m => m.version <= version)) {
            if (copied.has(migration.name)) continue;
            await copyFile(join(migrationDirectory, migration.name), join(prefixDirectory, migration.name));
            copied.add(migration.name);
          }
          await applyMigrations(pool, prefixDirectory, {info() {}});
          assert.equal(Number((await pool.query('SELECT max(version) AS version FROM schema_migrations')).rows[0].version), version);
          if (version < 19) {
            assert.equal((await pool.query("SELECT to_regclass('public.vault_migration_attempts') AS relation")).rows[0].relation, null);
            await check({pool, databaseURL, fencePath: emptyFence, vaultID: unusedVaultID,
              errorCode: 'deployment_schema_floor', publicationQueries: 0});
            continue;
          }
          if (version === 19) {
            await check({pool, databaseURL, fencePath: emptyFence, vaultID: unusedVaultID, publicationQueries: 1});
            tuple = await seedCompatibilityTuple(pool);
            floor19 = join(directory, 'floor19.fence');
            floor20 = join(directory, 'floor20.fence');
            fork20 = join(directory, 'fork20.fence');
            await new MigrationFence(floor19).intent({...tuple, schemaFloor: 19});
            await new MigrationFence(floor20).intent({...tuple, schemaFloor: 20});
            await new MigrationFence(fork20).intent({...tuple, manifestHash: 'c'.repeat(64), schemaFloor: 20});
            await check({pool, databaseURL, fencePath: floor19, vaultID: tuple.vaultID, publicationQueries: 1});
            await check({pool, databaseURL, fencePath: floor20, vaultID: tuple.vaultID,
              errorCode: 'deployment_schema_floor', publicationQueries: 0});
          } else {
            // The same fixture survives the actual19→20 migration; no table mocks.
            await check({pool, databaseURL, fencePath: floor19, vaultID: tuple.vaultID, publicationQueries: 1});
            await check({pool, databaseURL, fencePath: floor20, vaultID: tuple.vaultID, publicationQueries: 1});
            await check({pool, databaseURL, fencePath: fork20, vaultID: tuple.vaultID,
              errorCode: 'deployment_fence_mismatch', publicationQueries: 1});
          }
        }
      });
    } finally {
      await rm(directory, {recursive: true, force: true});
    }
  });
