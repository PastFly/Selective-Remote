// Pure demo model. It does not authorize access or model the current Cloud server.
const actionSets = Object.freeze({
  host: ['View', 'Connect', 'Edit', 'Manage Access'],
  credential: ['View metadata', 'Reveal', 'Edit', 'Manage Access'],
  snippet: ['View', 'Run', 'Edit', 'Manage Access'],
  forwarding: ['View', 'Run', 'Edit', 'Manage Access'],
  folder: ['View', 'Manage Access'],
});

export const actionsFor = (type) => actionSets[type] ?? [];

export function presetFor(type, preset) {
  const actions = actionsFor(type);
  if (preset === 'view') return actions.slice(0, 1);
  if (preset === 'connect' || preset === 'operate') return actions.slice(0, Math.min(2, actions.length));
  if (preset === 'edit') return actions.filter((action) => action === actions[0] || action === 'Edit');
  if (preset === 'manage') return actions.filter((action) => action === actions[0] || action === 'Manage Access');
  return [];
}

function covers(origin, target) {
  if (origin.id === target.id) return true;
  return origin.type === 'folder' && origin.vault === target.vault &&
    (target.folder === origin.title || target.folder.startsWith(`${origin.title} /`));
}

function recipientCovers(groups, grantRecipient, principalId) {
  if (grantRecipient === principalId) return true;
  return groups.some((group) => group.id === grantRecipient && group.memberIds.includes(principalId));
}

export function effectiveAccess(model, resourceId, principalId) {
  const target = model.resources.find((item) => item.id === resourceId);
  if (!target) return { actions: [], paths: [] };
  const paths = model.grants.flatMap((grant) => {
    const origin = model.resources.find((item) => item.id === grant.resourceId);
    if (!origin || !covers(origin, target) || !recipientCovers(model.groups, grant.recipient, principalId)) return [];
    const valid = actionsFor(target.type);
    // Folder View gives discovery of descendants, never execution or secret reveal.
    const inherited = origin.id !== target.id;
    const actions = inherited
      ? grant.actions.includes('View') ? valid.slice(0, 1) : []
      : grant.actions.filter((action) => valid.includes(action));
    if (!actions.length) return [];
    return [{ grantId: grant.id, origin: grant.recipient, inheritedFrom: origin.id === target.id ? null : origin.id, actions }];
  });
  const actionUnion = new Set(paths.flatMap((path) => path.actions));
  return { actions: actionsFor(target.type).filter((action) => actionUnion.has(action)), paths };
}

export function revokePreview(model, resourceIds, recipient, onlyGrantId = null) {
  const selected = new Set(resourceIds);
  const removedGrantIds = model.grants
    .filter((grant) => selected.has(grant.resourceId) && grant.recipient === recipient && (!onlyGrantId || grant.id === onlyGrantId))
    .map((grant) => grant.id);
  const removed = new Set(removedGrantIds);
  const remainingGrants = model.grants.filter((grant) => !removed.has(grant.id));
  const affectedResources = model.resources.filter((item) =>
    resourceIds.some((id) => {
      const selectedResource = model.resources.find((entry) => entry.id === id);
      return selectedResource && covers(selectedResource, item);
    }));
  const group = model.groups.find((entry) => entry.id === recipient);
  const affectedPrincipals = group ? [recipient, ...group.memberIds] : [recipient];
  const impacts = affectedResources.flatMap((item) => affectedPrincipals.map((principalId) => {
    const before = effectiveAccess(model, item.id, principalId);
    const after = effectiveAccess({ ...model, grants: remainingGrants }, item.id, principalId);
    return { resourceId: item.id, principalId, before: before.actions, after: after.actions,
      remainingPathIds: after.paths.map((path) => path.grantId) };
  }));
  return { removedGrantIds, remainingGrants, impacts };
}

export function grantPreview(model, resourceIds, recipient, actionById) {
  const newGrants = resourceIds.map((resourceId) => ({
    id: `preview-${resourceId}`, resourceId, recipient, actions: actionById[resourceId] ?? [],
  }));
  const selectedResources = model.resources.filter((item) => resourceIds.includes(item.id));
  const affectedResources = model.resources.filter((item) => selectedResources.some((selected) => covers(selected, item)));
  const group = model.groups.find((entry) => entry.id === recipient);
  const affectedPrincipals = group ? [recipient, ...group.memberIds] : [recipient];
  const impacts = affectedResources.flatMap((item) => affectedPrincipals.map((principalId) => {
    const before = effectiveAccess(model, item.id, principalId);
    const after = effectiveAccess({ ...model, grants: [...model.grants, ...newGrants] }, item.id, principalId);
    return { resourceId: item.id, principalId, before: before.actions, after: after.actions,
      remainingPathIds: after.paths.map((path) => path.grantId) };
  }));
  return { impacts, newGrants };
}
