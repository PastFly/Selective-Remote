import pg from 'pg';
import { loadConfig } from '../src/config.mjs';
import { createConfiguredMigrationFence } from '../src/configured-migration-fence.mjs';
import { currentCapabilities, verifyDeploymentCompatibility } from '../src/deployment-compatibility.mjs';
import { productionPilotClosed, productionPilotOpened } from '../src/migration-fence-journal.mjs';
import { isUUID } from '../src/security.mjs';
import { lockV1TeamAuthorizationWriter } from '../src/v1-team-authorization.mjs';

let pool, configured, client, unlock, releaseError;
try {
  const [action, pilotID, ...rest] = process.argv.slice(2);
  if (action !== 'close' || !isUUID(pilotID) || rest.length) throw Error('invalid_personal_pilot_arguments');
  const config = loadConfig();
  if (!config.productionTeamEnabled || currentCapabilities.v1ProductionTeamVersion !== 1
      || !config.deployment.anchor) throw Error('personal_pilot_environment_unavailable');
  configured = createConfiguredMigrationFence(config.deployment);
  pool = new pg.Pool({ connectionString: config.databaseURL, max: 1, connectionTimeoutMillis: 5000 });
  client = await pool.connect();
  try { unlock = await lockV1TeamAuthorizationWriter(client); }
  catch (error) { releaseError = error; throw error; }
  const evidence = await verifyDeploymentCompatibility({ query: (sql, values) => client.query(sql, values),
    fence: configured.fence, candidate: currentCapabilities, productionTeamEnabled: true });
  if (evidence.writerFloor !== 1 || evidence.teamAuthorizationProtocol !== 2) throw Error('personal_pilot_history_unavailable');
  const active = evidence.personalWritePilot;
  if (active?.type === productionPilotOpened && active.pilotID === pilotID) {
    await configured.fence.append({ version: 2, type: productionPilotClosed, pilotID });
  } else if (!(await configured.fence.readRecords()).some(row => row.type === productionPilotClosed && row.pilotID === pilotID)) {
    throw Error('personal_pilot_not_found');
  }
  process.stdout.write('personal_pilot_closed\n');
} catch (error) {
  process.stderr.write((/^[a-z_]+$/.test(error?.message ?? '') ? error.message : 'personal_pilot_failed') + '\n');
  process.exitCode = 1;
} finally {
  try { await unlock?.(); } catch (error) { releaseError = error; process.exitCode = 1; }
  client?.release(releaseError);
  await pool?.end();
  await configured?.close();
}
