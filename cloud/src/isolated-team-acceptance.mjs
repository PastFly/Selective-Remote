import { isUUID } from './security.mjs';
import { isPrivatePersonalPilotEnvironment } from './v1-write-fence.mjs';
import { teamAuthorizationProtocol } from './v1-team-authorization.mjs';

// The ordinary server entry point, including the image's default command, stays closed.
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

const reads = new Set(['teams', 'team-invitations', 'teams/:id/vaults', 'teams/:id/members',
  'teams/:id/invitations', 'teams/:id/device-admission-policy', 'teams/:id/activity', 'teams/:id/access-vaults',
  'teams/:id/vaults/:id', 'teams/:id/vaults/:id/key-devices', 'teams/:id/vaults/:id/access-context',
  'teams/:id/members/:id/devices']);
const creates = new Set(['devices/bootstrap-key', 'device-trust', 'teams', 'team-invitations/accept',
  'teams/:id/invitations', 'teams/:id/invitations/:id/wrappers', 'teams/:id/vaults',
  'teams/:id/vaults/:id/wrappers', 'teams/:id/members/:id/devices/:id']);
const routes = new Map([['GET', reads], ['POST', creates], ['PATCH', new Set(['teams/:id/members/:id'])],
  ['PUT', new Set(['teams/:id/vaults/:id'])]]);

export function isolatedTeamRouteAllowed(policy, evidence, userID, method, path) {
  if (!isolatedTeamWindowOpen(policy, evidence) || !policy.ids.includes(userID) || !path.startsWith('/v1/')) return false;
  const parts = path.slice(4).split('/');
  if (parts.includes(':id')) return false;
  return routes.get(method)?.has(parts.map(part => isUUID(part) ? ':id' : part).join('/')) === true;
}
