import { isUUID } from './security.mjs';

const reads = new Set(['teams', 'team-invitations', 'teams/:id/vaults', 'teams/:id/members',
  'teams/:id/invitations', 'teams/:id/device-admission-policy', 'teams/:id/activity', 'teams/:id/access-vaults',
  'teams/:id/vaults/:id', 'teams/:id/vaults/:id/key-devices', 'teams/:id/vaults/:id/access-context',
  'teams/:id/members/:id/devices']);
const creates = new Set(['devices/bootstrap-key', 'device-trust', 'teams', 'team-invitations/accept',
  'teams/:id/invitations', 'teams/:id/invitations/:id/wrappers', 'teams/:id/vaults',
  'teams/:id/vaults/:id/wrappers', 'teams/:id/members/:id/devices/:id']);
const routes = new Map([['GET', reads], ['POST', creates], ['PATCH', new Set(['teams/:id/members/:id'])],
  ['PUT', new Set(['teams/:id/vaults/:id'])]]);

// Lifecycle, access-control and device operations use the retained authorization
// transaction. Publication routes have a separate protocol and admission.
const productionRoutes = new Map([
  ['GET', new Set(['teams/:id/access-groups', 'teams/:id/access-groups/:id/members',
    'teams/:id/vaults/:id/access-resources', 'teams/:id/vaults/:id/access-resources/:id',
    'teams/:id/vaults/:id/access-devices', 'teams/:id/vaults/:id/access-grants',
    'teams/:id/vaults/:id/who-has-access/:id', 'teams/:id/vaults/:id/effective-access/:id',
    'teams/:id/vaults/:id/resources-by-principal/user/:id', 'teams/:id/vaults/:id/resources-by-principal/group/:id'])],
  ['POST', new Set(['devices/:id', 'device-trust/requests', 'device-trust/requests/:id/approve',
    'device-trust/requests/:id/reject', 'device-trust/requests/:id/challenges',
    'device-trust/requests/:id/challenges/:id', 'device-trust/devices/:id/revoke', 'teams/:id/ownership-transfer',
    'teams/:id/access-groups', 'teams/:id/access-groups/:id/members', 'teams/:id/vaults/:id/access-preview',
    'teams/:id/vaults/:id/access-commit', 'teams/:id/vaults/:id/access-group-preview', 'teams/:id/vaults/:id/access-group-commit'])],
  ['PATCH', new Set(['teams/:id', 'teams/:id/access-groups/:id', 'teams/:id/vaults/:id'])],
  ['PUT', new Set(['teams/:id/device-admission-policy'])],
  ['DELETE', new Set(['devices/:id', 'teams/:id', 'teams/:id/invitations/:id', 'teams/:id/members/:id',
    'teams/:id/access-groups/:id', 'teams/:id/access-groups/:id/members/:id'])],
]);

export function v1TeamRouteAllowed(method, path, production = false) {
  if (!path.startsWith('/v1/')) return false;
  const parts = (production ? path.toLowerCase() : path).slice(4).split('/');
  if (parts.includes(':id')) return false;
  const route = parts.map(part => isUUID(part) ? ':id' : part).join('/');
  return routes.get(method)?.has(route) === true || (production && productionRoutes.get(method)?.has(route) === true);
}
