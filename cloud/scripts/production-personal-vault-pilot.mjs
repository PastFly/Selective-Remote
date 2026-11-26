import pg from 'pg';
import { loadConfig } from '../src/config.mjs';
import { createConfiguredMigrationFence } from '../src/configured-migration-fence.mjs';
import { currentCapabilities, verifyDeploymentCompatibility } from '../src/deployment-compatibility.mjs';
import { productionPilotClosed, productionPilotOpened } from '../src/migration-fence-journal.mjs';
import { isUUID } from '../src/security.mjs';
import { holdV1CommitReadback } from '../src/v1-commit-fence.mjs';
import { holdV1TeamAuthorizationReadback, lockV1TeamAuthorizationWriter } from '../src/v1-team-authorization.mjs';
import { personalWritePilotIsCurrent } from '../src/v1-write-fence.mjs';

let pool, configured, client, unlock, inTransaction = false, releaseError;
try {
  const args = process.argv.slice(2);
  const [action, pilotID, ownerID, vaultID, minutes] = args;
  const identifier = value => isUUID(value) && value === value.toLowerCase();
  const open = action === 'open' && args.length === 5 && identifier(ownerID) && identifier(vaultID)
    && /^(?:[1-9]|[1-5][0-9]|60)$/.test(minutes);
  if (!identifier(pilotID) || !(open || (action === 'close' && args.length === 2))) throw Error('invalid_personal_pilot_arguments');
  const config = loadConfig();
  if (!config.productionTeamEnabled || currentCapabilities.v1ProductionTeamVersion !== 1 || !config.deployment.anchor ||
      (open && (!config.productionPersonalPilotEnabled || currentCapabilities.v1ProductionPersonalPilotVersion !== 1))) {
    throw Error('personal_pilot_environment_unavailable');
  }
  configured = createConfiguredMigrationFence(config.deployment);
  pool = new pg.Pool({ connectionString: config.databaseURL, max: 1, connectionTimeoutMillis: 5000 });
  client = await pool.connect();
  try { unlock = await lockV1TeamAuthorizationWriter(client); }
  catch (error) { releaseError = error; throw error; }
  const query = (sql, values) => client.query(sql, values);
  await query('BEGIN');
  inTransaction = true;
  await holdV1TeamAuthorizationReadback(query);
  await holdV1CommitReadback(query);
  const evidence = await verifyDeploymentCompatibility({ query, fence: configured.fence,
    candidate: currentCapabilities, productionTeamEnabled: true });
  const active = evidence.personalWritePilot;
  if (open) {
    const result = await query(`SELECT 1 FROM personal_vaults v JOIN users u ON u.id = v.user_id
      WHERE v.id = $1 AND u.id = $2 AND u.email_verified_at IS NOT NULL AND u.disabled_at IS NULL`, [vaultID, ownerID]);
    if (result.rowCount !== 1) throw Error('personal_pilot_scope_unavailable');
    const duration = Number(minutes) * 60_000;
    if (active) {
      if (!personalWritePilotIsCurrent(active) || active.type !== productionPilotOpened || active.pilotID !== pilotID
          || active.ownerID !== ownerID || active.vaultID !== vaultID || active.expiresAt - active.issuedAt !== duration) {
        throw Error('personal_pilot_already_open');
      }
    } else {
      const issuedAt = Date.now();
      await configured.fence.append({ version: 2, type: productionPilotOpened, pilotID, ownerID, vaultID,
        issuedAt, expiresAt: issuedAt + duration });
    }
  } else if (active?.type === productionPilotOpened && active.pilotID === pilotID) {
    await configured.fence.append({ version: 2, type: productionPilotClosed, pilotID });
  } else if (!(await configured.fence.readRecords()).some(row => row.type === productionPilotClosed && row.pilotID === pilotID)) {
    throw Error('personal_pilot_not_found');
  }
  await query('COMMIT');
  inTransaction = false;
  process.stdout.write(open ? 'personal_pilot_opened\n' : 'personal_pilot_closed\n');
} catch (error) {
  if (inTransaction) {
    try { await client.query('ROLLBACK'); } catch (rollbackError) { releaseError = rollbackError; }
  }
  process.stderr.write((/^[a-z_]+$/.test(error?.message ?? '') ? error.message : 'personal_pilot_failed') + '\n');
  process.exitCode = 1;
} finally {
  try { await unlock?.(); } catch (error) { releaseError = error; process.exitCode = 1; }
  client?.release(releaseError);
  await pool?.end();
  await configured?.close();
}
