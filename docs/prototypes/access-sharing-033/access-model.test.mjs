import test from 'node:test';
import assert from 'node:assert/strict';
import { actionsFor, effectiveAccess, grantPreview, presetFor, revokePreview } from './access-model.mjs';

const resources = [
  { id: 'folder', type: 'folder', title: 'Production / ssh', vault: 'Production', folder: 'Production' },
  { id: 'host', type: 'host', title: 'production-01', vault: 'Production', folder: 'Production / ssh' },
  { id: 'credential', type: 'credential', title: 'ops', vault: 'Production', folder: 'Production / ssh' },
];
const groups = [{ id: 'support', name: 'Support', memberIds: ['alex'] }];
const grants = [
  { id: 'folder-grant', resourceId: 'folder', recipient: 'support', actions: ['View'] },
  { id: 'host-grant', resourceId: 'host', recipient: 'alex', actions: ['Connect'] },
];

test('member sees direct and group-inherited paths, with action union', () => {
  const result = effectiveAccess({ resources, groups, grants }, 'host', 'alex');
  assert.deepEqual(result.actions, ['View', 'Connect']);
  assert.deepEqual(result.paths.map((path) => path.grantId), ['folder-grant', 'host-grant']);
  assert.equal(result.paths[0].origin, 'support');
  assert.equal(result.paths[0].inheritedFrom, 'folder');
});

test('credential action set does not offer Use without Reveal', () => {
  assert.deepEqual(actionsFor('credential'), ['View metadata', 'Reveal', 'Edit', 'Manage Access']);
  assert.deepEqual(presetFor('credential', 'manage'), ['View metadata', 'Manage Access']);
  assert.deepEqual(effectiveAccess({ resources, groups, grants }, 'credential', 'alex').actions, ['View metadata']);
});

test('revoke preview removes only selected recipient grants and reports remaining paths', () => {
  const result = revokePreview({ resources, groups, grants }, ['host'], 'alex');
  assert.deepEqual(result.removedGrantIds, ['host-grant']);
  assert.deepEqual(result.impacts[0].before, ['View', 'Connect']);
  assert.deepEqual(result.impacts[0].after, ['View']);
  assert.deepEqual(result.impacts[0].remainingPathIds, ['folder-grant']);
  assert.equal(grants.length, 2);
});

test('revoking a group path does not erase a direct path', () => {
  const result = revokePreview({ resources, groups, grants }, ['folder'], 'support');
  assert.deepEqual(result.removedGrantIds, ['folder-grant']);
  assert.deepEqual(effectiveAccess({ resources, groups, grants: result.remainingGrants }, 'host', 'alex').actions, ['Connect']);
  const hostImpact = result.impacts.find((impact) => impact.resourceId === 'host' && impact.principalId === 'alex');
  assert.deepEqual(hostImpact.before, ['View', 'Connect']);
  assert.deepEqual(hostImpact.after, ['Connect']);
});

test('same Connect action survives group-path revoke when direct Host grant remains', () => {
  const overlapping = [
    ...grants,
    { id: 'support-host-connect', resourceId: 'host', recipient: 'support', actions: ['Connect'] },
  ];
  const before = effectiveAccess({ resources, groups, grants: overlapping }, 'host', 'alex');
  assert.deepEqual(before.paths.filter((path) => path.actions.includes('Connect')).map((path) => path.grantId),
    ['host-grant', 'support-host-connect']);
  const preview = revokePreview({ resources, groups, grants: overlapping }, ['host'], 'support', 'support-host-connect');
  assert.deepEqual(preview.removedGrantIds, ['support-host-connect']);
  const after = effectiveAccess({ resources, groups, grants: preview.remainingGrants }, 'host', 'alex');
  assert.ok(after.actions.includes('Connect'));
  assert.deepEqual(after.paths.filter((path) => path.actions.includes('Connect')).map((path) => path.grantId),
    ['host-grant']);
});

test('group grant preview includes members and inherited descendants', () => {
  const result = grantPreview({ resources, groups, grants }, ['folder'], 'support', { folder: ['View'] });
  const credential = result.impacts.find((impact) => impact.resourceId === 'credential' && impact.principalId === 'alex');
  assert.deepEqual(credential.before, ['View metadata']);
  assert.deepEqual(credential.after, ['View metadata']);
  assert.equal(result.impacts.length, 6);
});

test('folder inheritance stops at Vault boundary and path component boundary', () => {
  const otherResources = [
    ...resources,
    { id: 'other-vault', type: 'host', title: 'other', vault: 'Operations', folder: 'Production / ssh' },
    { id: 'sibling', type: 'host', title: 'sibling', vault: 'Production', folder: 'Production / ssh-old' },
  ];
  for (const id of ['other-vault', 'sibling']) {
    assert.deepEqual(effectiveAccess({ resources: otherResources, groups, grants }, id, 'alex').actions, []);
  }
});
