import pg from 'pg';
import { readFile } from 'node:fs/promises';
import { loadConfig } from '../src/config.mjs';
import { MigrationFence } from '../src/migration-fence.mjs';
import { currentCapabilities, verifyDeploymentCompatibility } from '../src/deployment-compatibility.mjs';

let pool;
try {
  const args = process.argv.slice(2);
  const mode = args.includes('--maintenance-upgrade') ? 'maintenance-upgrade' : 'traffic';
  const candidateIndex = args.indexOf('--candidate');
  const accepted = args.filter((_, i) => i !== candidateIndex && i !== candidateIndex + 1);
  if (candidateIndex === -1 ? args.some(arg => arg !== '--maintenance-upgrade') :
      !args[candidateIndex + 1] || accepted.some(arg => arg !== '--maintenance-upgrade'))
    throw Error('invalid_deployment_arguments');
  const config = loadConfig();
  if (!config.deployment.fencePath) {
    if (candidateIndex !== -1) throw Error('missing_deployment_fence');
    process.stdout.write('{"protected":false,"publicationEnabled":false}\n');
  } else {
    const candidate = candidateIndex === -1 ? currentCapabilities : JSON.parse(await readFile(args[candidateIndex + 1], 'utf8'));
    pool = new pg.Pool({ connectionString: config.databaseURL, max: 1 });
    const result = await verifyDeploymentCompatibility({ query: (text, values) => pool.query(text, values),
      fence: new MigrationFence(config.deployment.fencePath), candidate, mode });
    process.stdout.write(JSON.stringify(result) + '\n');
  }
} catch (error) {
  process.stderr.write(/^[a-z_]+$/.test(error?.message ?? '') ? error.message + '\n' : 'deployment_compatibility_failed\n');
  process.exitCode = 1;
} finally {
  await pool?.end();
}
