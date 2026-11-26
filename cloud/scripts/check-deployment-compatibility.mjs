import pg from 'pg';
import { readFile } from 'node:fs/promises';
import { loadConfig } from '../src/config.mjs';
import { createConfiguredMigrationFence } from '../src/configured-migration-fence.mjs';
import { currentCapabilities, supportsTeamAuthorizationRuntime, verifyDeploymentCompatibility } from '../src/deployment-compatibility.mjs';

let pool,configuredFence;
try {
  const args = process.argv.slice(2);
  const mode = args.includes('--maintenance-upgrade') ? 'maintenance-upgrade' : 'traffic';
  const candidateIndex = args.indexOf('--candidate');
  const accepted = candidateIndex === -1 ? args : args.filter((_, i) => i !== candidateIndex && i !== candidateIndex + 1);
  const requireClosedPilot = accepted.includes('--require-closed-pilot');
  if (candidateIndex !== -1 && (!args[candidateIndex + 1] || args[candidateIndex + 1].startsWith('--')) ||
      new Set(accepted).size !== accepted.length ||
      accepted.some(arg => arg !== '--maintenance-upgrade' && arg !== '--require-closed-pilot'))
    throw Error('invalid_deployment_arguments');
  const config = loadConfig();
  if (!config.deployment.fencePath) {
    if (candidateIndex !== -1 || requireClosedPilot || config.productionTeamEnabled) throw Error('missing_deployment_fence');
    process.stdout.write('{"protected":false,"publicationEnabled":false}\n');
  } else {
    const candidate = candidateIndex === -1 ? currentCapabilities : JSON.parse(await readFile(args[candidateIndex + 1], 'utf8'));
    pool = new pg.Pool({ connectionString: config.databaseURL, max: 1 });
    configuredFence=createConfiguredMigrationFence(config.deployment);
    const { personalWritePilot: pilot, ...result } = await verifyDeploymentCompatibility({ query: (text, values) => pool.query(text, values),
      fence: configuredFence.fence, candidate, mode, productionTeamEnabled: config.productionTeamEnabled, teamAuthorizationEnabled: supportsTeamAuthorizationRuntime(config, candidate) });
    if (requireClosedPilot && pilot) throw Error('deployment_pilot_open');
    process.stdout.write(JSON.stringify(result) + '\n');
  }
} catch (error) {
  process.stderr.write(/^[a-z_]+$/.test(error?.message ?? '') ? error.message + '\n' : 'deployment_compatibility_failed\n');
  process.exitCode = 1;
} finally {
  await configuredFence?.close();
  await pool?.end();
}
