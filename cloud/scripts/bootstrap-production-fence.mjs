// The protected controller runs this command with both ingress services closed.
// The reference digest comes from inspection of a rehearsed, independently restored backup.
import {createHash, randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import pg from 'pg';
import {loadConfig} from '../src/config.mjs';
import {createConfiguredMigrationFence} from '../src/configured-migration-fence.mjs';
import {loadMigrations, pendingMigrations, applyMigrations} from '../src/migrations.mjs';
import {assertV1CommitFence, holdV1CommitReadback, installV1CommitFence, requireIndependentV1Anchor} from '../src/v1-commit-fence.mjs';
import {readV1VaultState} from '../src/v1-data-fence.mjs';
import {assertV1TeamAuthorizationFence, holdV1TeamAuthorizationReadback,
  installV1TeamAuthorizationFence, readV1TeamAuthorizationDigest} from '../src/v1-team-authorization.mjs';
import {FENCE_MAX_BYTES,validateFenceEvent} from '../src/migration-fence-journal.mjs';
import {currentCapabilities, verifyDeploymentCompatibility} from '../src/deployment-compatibility.mjs';

const migrations = fileURLToPath(new URL('../migrations/', import.meta.url));
const fail = code => { throw Error(code); };

async function baseline(query) {
  const ledger = await query('SELECT version,name,checksum_sha256 FROM public.schema_migrations ORDER BY version');
  const version = ledger.rows.length;
  const expected = await loadMigrations(migrations);
  if (![22,23].includes(version) || expected.length !== 23 ||
      ledger.rows.some((row,i) => Number(row.version) !== i + 1) ||
      pendingMigrations(expected, ledger.rows).length !== 23 - version) fail('deployment_schema_floor');
  const {rows:[state]} = await query(`SELECT NOT pg_catalog.pg_is_in_recovery()
    AND pg_catalog.current_setting('fsync')='on' AND pg_catalog.current_setting('full_page_writes')='on'
    AND pg_catalog.current_setting('server_version_num')::int BETWEEN 160000 AND 169999 AS durable,
    EXISTS(SELECT 1 FROM public.shared_vaults WHERE format_state IS DISTINCT FROM 'V1_ACTIVE'
      UNION ALL SELECT 1 FROM public.vault_migration_attempts
      UNION ALL SELECT 1 FROM public.team_publication_operations) AS publication`);
  if (!state?.durable || state.publication !== false) fail('deployment_production_baseline_unavailable');
  const vaults = await readV1VaultState(query);
  const authorization = await readV1TeamAuthorizationDigest(query);
  const digest = createHash('sha256').update('selective-remote/production-v1-baseline/v1\0')
    .update(JSON.stringify([vaults, authorization])).digest('hex');
  return {version, vaults, authorization, digest};
}

async function stable(pool, read, {readOnly=false}={}) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ' + (readOnly ? ' READ ONLY' : ''));
    const result = await read((sql, args) => client.query(sql,args));
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally { client.release(); }
}

function prefix(records, expected) {
  // A retry can finish the original baseline only while every retained byte still
  // describes the independently reviewed database. Ordinary history is never reset.
  const events = [
    {version:2,type:'V1_BASELINE',baselineID:records[0]?.baselineID ?? randomUUID(),vaults:expected.vaults},
    {version:2,type:'V1_WRITER_FLOOR',writerProtocol:1},
    {version:2,type:'V1_TEAM_AUTHORIZATION_BASELINE',authorizationProtocol:2,digest:expected.authorization},
  ].map(validateFenceEvent);
  const bytes = events.reduce((sum,event) => sum + Buffer.byteLength(JSON.stringify(event)) + 1, 0);
  if (bytes > FENCE_MAX_BYTES) fail('deployment_fence_capacity');
  if (records.length > events.length || records.some((event,i) =>
    JSON.stringify(event) !== JSON.stringify(events[i]))) fail('deployment_production_baseline_history');
  return events;
}

export async function bootstrapProductionFence({pool, fence, mode, expectedDigest}) {
  if (!['inspect','check','apply'].includes(mode) ||
      mode !== 'inspect' && !/^[a-f0-9]{64}$/.test(expectedDigest ?? '')) fail('invalid_deployment_arguments');
  requireIndependentV1Anchor(fence);
  const read = async (query, locked = false) => {
    if (locked) {
      await holdV1CommitReadback(query);
      await holdV1TeamAuthorizationReadback(query);
    }
    const result = await baseline(query);
    if (mode !== 'inspect' && result.digest !== expectedDigest) fail('deployment_production_baseline_mismatch');
    const records = await fence.readRecords();
    const events = prefix(records, result);
    if (records.length) {
      if (result.version !== 23) fail('deployment_schema_floor');
      if (!locked) {
        await assertV1CommitFence(query);
        await assertV1TeamAuthorizationFence(query);
      }
    }
    return { ...result, records, events };
  };
  const before = await stable(pool,read,{readOnly:true});
  if (mode !== 'apply') return {schemaVersion:before.version,baselineDigest:before.digest};
  const query=(sql,args)=>pool.query(sql,args);
  const {rows:[drain]} = await query(`SELECT count(*)::int AS clients FROM pg_catalog.pg_stat_activity
    WHERE datname=pg_catalog.current_database() AND backend_type='client backend' AND pid<>pg_catalog.pg_backend_pid()`);
  if (drain.clients !== 0) fail('v1_writer_not_drained');
  await fence.assertWritable();
  if (before.version === 22) await applyMigrations(pool,migrations,{info(){}});
  // A previous interrupted install can leave complete guard functions without a
  // journal floor. An existing malformed function/trigger must always fail readback.
  const guards = await query(`SELECT to_regprocedure('public.selective_remote_require_framed_v1_writer()') IS NOT NULL AS writer,
    to_regprocedure('public.selective_remote_require_v1_team_authorization()') IS NOT NULL AS team`);
  if (!guards.rows[0].writer && !before.records.length) await installV1CommitFence(pool);
  await assertV1CommitFence(query);
  if (!guards.rows[0].team && !before.records.length) await installV1TeamAuthorizationFence(pool);
  await assertV1TeamAuthorizationFence(query);
  await stable(pool, async lockedQuery => {
    const confirmed = await read(lockedQuery,true);
    for (const event of confirmed.events.slice(confirmed.records.length)) await fence.append(event);
  });
  const result = await verifyDeploymentCompatibility({query, fence, candidate:currentCapabilities, productionTeamEnabled:true});
  if (result.personalWritePilot || result.teamAuthorizationProtocol !== 2 || result.writerFloor !== 1) fail('deployment_production_baseline_unavailable');
  return {schemaVersion:result.schemaVersion, writerFloor:result.writerFloor, teamAuthorizationProtocol:result.teamAuthorizationProtocol};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let pool, configured;
  try {
    const [mode, expectedDigest,...extra] = process.argv.slice(2);
    if (extra.length || mode === 'inspect' && expectedDigest !== undefined) fail('invalid_deployment_arguments');
    const config = loadConfig();
    if (!config.productionTeamEnabled || config.deployment.fencePath !== '/publication-fence/journal' ||
        !config.deployment.anchor || currentCapabilities.v1ProductionTeamVersion !== 1) fail('deployment_production_scope');
    configured = createConfiguredMigrationFence(config.deployment);
    pool = new pg.Pool({connectionString:config.databaseURL, max:1, connectionTimeoutMillis:5000, options:'-c synchronous_commit=on'});
    const result = await bootstrapProductionFence({pool,fence:configured.fence,mode,expectedDigest});
    process.stdout.write(JSON.stringify(result)+'\n');
  } catch (error) {
    process.stderr.write((/^[a-z_]+$/.test(error.message) ? error.message : 'deployment_production_baseline_failed')+'\n');
    process.exitCode=1;
  } finally {
    await pool?.end();
    await configured?.close();
  }
}
