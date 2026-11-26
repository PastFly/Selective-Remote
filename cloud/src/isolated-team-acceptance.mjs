import { isUUID } from './security.mjs';
import { v1TeamRouteAllowed } from './v1-team-routes.mjs';
import { isPrivatePersonalPilotEnvironment } from './v1-write-fence.mjs';
import { teamAuthorizationProtocol } from './v1-team-authorization.mjs';

// A closed-signup, loopback-only fixture gets the V1 operations used by the two clients.
export function isolatedTeamAcceptance(config, args, env, now = Date.now()) {
  const accounts = env.STAGING_TEAM_ACCOUNT_IDS;
  const expires = env.STAGING_TEAM_EXPIRES_AT;
  if (!args.includes('--isolated-team-acceptance') && accounts === undefined && expires === undefined) return null;
  const ids = accounts?.split(',') ?? [];
  const expiresAt = Date.parse(expires);
  if (args.length !== 1 || args[0] !== '--isolated-team-acceptance'
      || !isPrivatePersonalPilotEnvironment(config) || config.publication.allowedVaultIDs.length
      || config.host !== '127.0.0.1' || !['127.0.0.1', 'pr255-staging.pastfly.ru'].includes(new URL(config.publicOrigin).hostname)
      || !config.deployment.anchor || ids.length !== 2 || new Set(ids).size !== 2
      || !ids.every(id => isUUID(id) && id === id.toLowerCase())
      || !Number.isFinite(expiresAt) || expires !== new Date(expiresAt).toISOString()
      || expiresAt <= now || expiresAt - now > 2 * 60 * 60 * 1000) throw Error('invalid_isolated_team_acceptance');
  return Object.freeze({ ids: Object.freeze(ids), expiresAt });
}

export async function verifyIsolatedTeamAccounts(policy, query) {
  if (!policy) return;
  const { rows } = await query(`SELECT id, email, email_verified_at, disabled_at FROM users ORDER BY id LIMIT 3`);
  if (rows.length !== 2 || !rows.every(row => policy.ids.includes(row.id) && row.email.endsWith('@example.test')
      && row.email_verified_at && !row.disabled_at)) throw Error('invalid_isolated_team_accounts');
}

export function isolatedTeamWindowOpen(policy, evidence, now = Date.now()) {
  return Boolean(policy && now < policy.expiresAt && evidence.writerFloor === 1
    && evidence.teamAuthorizationProtocol === teamAuthorizationProtocol && !evidence.personalWritePilot);
}

export function isolatedTeamRouteAllowed(policy, evidence, userID, method, path) {
  return isolatedTeamWindowOpen(policy, evidence) && policy.ids.includes(userID) && v1TeamRouteAllowed(method, path);
}
