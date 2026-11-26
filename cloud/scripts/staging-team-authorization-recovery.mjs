// Invoked by the installed root operator in its verified Cloud image.
import pg from 'pg';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createConfiguredMigrationFence } from '../src/configured-migration-fence.mjs';
import { loadFenceAnchorConfig } from '../src/fence-anchor-config.mjs';
import { reconcileV1TeamAuthorization } from '../src/publication-fence-coordinator.mjs';
import { readStagingControllerIdentity } from '../src/staging-activation-policy.mjs';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;

export async function runStagingTeamAuthorizationRecovery(options, request, env = process.env) {
  const { identityPath, identity, anchorDeploymentID, fencePath } = options;
  if (env.PUBLICATION_ENVIRONMENT !== 'staging' || !env.DATABASE_URL ||
      !fencePath || env.PUBLICATION_FENCE_PATH !== fencePath ||
      !request || Object.keys(request).sort().join(',') !== 'intentID,operation' ||
      request.operation !== 'reconcile-team-authorization' ||
      typeof request.intentID !== 'string' || !uuid.test(request.intentID)) {
    throw new Error('staging_team_recovery_scope');
  }
  const deployed = await readStagingControllerIdentity(identityPath);
  if (!identity || ['sourceSHA','imageDigest','controllerDigest'].some(key => deployed[key] !== identity[key])) {
    throw new Error('staging_team_recovery_identity');
  }
  const anchor = loadFenceAnchorConfig(env, env.DATABASE_URL);
  if (!anchor || anchor.deploymentID !== anchorDeploymentID) {
    throw new Error('staging_team_recovery_anchor');
  }
  const { fence, close } = createConfiguredMigrationFence({ fencePath, anchor });
  const pool = new pg.Pool({
    connectionString: env.DATABASE_URL, max: 1, connectionTimeoutMillis: 5000, statement_timeout: 30000,
  });
  try {
    return await reconcileV1TeamAuthorization({ pool, fence, intentID: request.intentID });
  } finally {
    try { await pool.end(); } finally { await close(); }
  }
}

async function runInput(options) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of process.stdin) {
    bytes += chunk.length;
    if (bytes > 1024) throw new Error('staging_team_recovery_scope');
    chunks.push(chunk);
  }
  let request;
  try { request = JSON.parse(Buffer.concat(chunks)); }
  catch { throw new Error('staging_team_recovery_scope'); }
  process.stdout.write(JSON.stringify(await runStagingTeamAuthorizationRecovery(options, request)));
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 3) throw new Error('staging_team_recovery_scope');
    await runInput(JSON.parse(process.argv[2]));
  } catch (error) {
    const code = /^[a-z_]+$/.test(error?.message ?? '') ? error.message : 'staging_team_recovery_failed';
    process.stderr.write(code + '\n');
    process.exitCode = 1;
  }
}
