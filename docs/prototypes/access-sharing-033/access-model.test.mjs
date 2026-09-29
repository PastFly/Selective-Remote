import test from 'node:test';
import assert from 'node:assert/strict';
import { actionsFor, effectiveAccess, grantPreview, normalizeGrantActions, presetFor, revokePreview } from './access-model.mjs';

const resources = [
  { id: 'folder', type: 'folder', title: 'Production / ssh', vault: 'Production', folder: 'Production' },
  { id: 'host', type: 'host', title: 'production-01', vault: 'Production', folder: 'Production / ssh' },
  { id: 'credential', type: 'credential', title: 'ops', vault: 'Production', folder: 'Production / ssh' },
];
const groups = [{ id: 'support', name: 'Support', memberIds: ['alex'] }];
const grants = [
  { id: 'folder-grant', resourceId: 'folder', recipient: 'support', actions: ['View'] },
  { id: 'host-grant', resourceId: 'host', recipient: 'alex', actions: ['Edit'] },
];

test('member sees direct and group-inherited paths, with action union', () => {
  const result = effectiveAccess({ resources, groups, grants }, 'host', 'alex');
  assert.deepEqual(result.actions, ['View', 'Edit']);
  assert.deepEqual(result.paths.map((path) => path.grantId), ['folder-grant', 'host-grant']);
  assert.equal(result.paths[0].origin, 'support');
  assert.equal(result.paths[0].inheritedFrom, 'folder');
});

test('credential action set does not offer Use without Reveal', () => {
  assert.deepEqual(actionsFor('credential'), ['View metadata', 'Reveal', 'Edit', 'Manage Access']);
  assert.deepEqual(presetFor('credential', 'manage'), ['Manage Access']);
  assert.deepEqual(presetFor('credential', 'reveal'), ['View metadata', 'Reveal']);
  assert.deepEqual(presetFor('credential', 'edit'), ['View metadata', 'Reveal', 'Edit']);
  assert.deepEqual(normalizeGrantActions('credential', ['Edit']), ['Reveal', 'Edit']);
  assert.deepEqual(normalizeGrantActions('credential', ['Manage Access']), ['Manage Access']);
  assert.deepEqual(effectiveAccess({ resources, groups, grants }, 'credential', 'alex').actions, ['View metadata']);
});

test('V1 grant choices exclude UX-only and deferred execution rights', () => {
  assert.deepEqual(actionsFor('host'), ['View', 'Edit', 'Manage Access']);
  assert.deepEqual(actionsFor('snippet'), ['View', 'Edit', 'Manage Access']);
  assert.deepEqual(actionsFor('forwarding'), ['View']);
  assert.deepEqual(presetFor('host', 'connect'), []);
});

test('revoke preview removes only selected recipient grants and reports remaining paths', () => {
  const result = revokePreview({ resources, groups, grants }, ['host'], 'alex');
  assert.deepEqual(result.removedGrantIds, ['host-grant']);
  assert.deepEqual(result.impacts[0].before, ['View', 'Edit']);
  assert.deepEqual(result.impacts[0].after, ['View']);
  assert.deepEqual(result.impacts[0].remainingPathIds, ['folder-grant']);
  assert.equal(grants.length, 2);
});

test('revoking a group path does not erase a direct path', () => {
  const result = revokePreview({ resources, groups, grants }, ['folder'], 'support');
  assert.deepEqual(result.removedGrantIds, ['folder-grant']);
  assert.deepEqual(effectiveAccess({ resources, groups, grants: result.remainingGrants }, 'host', 'alex').actions, ['Edit']);
  const hostImpact = result.impacts.find((impact) => impact.resourceId === 'host' && impact.principalId === 'alex');
  assert.deepEqual(hostImpact.before, ['View', 'Edit']);
  assert.deepEqual(hostImpact.after, ['Edit']);
});

test('same View action survives group-path revoke when direct Host grant remains', () => {
  const overlapping = [
    { id: 'direct-host-view', resourceId: 'host', recipient: 'alex', actions: ['View'] },
    { id: 'support-host-view', resourceId: 'host', recipient: 'support', actions: ['View'] },
  ];
  const before = effectiveAccess({ resources, groups, grants: overlapping }, 'host', 'alex');
  assert.deepEqual(before.paths.filter((path) => path.actions.includes('View')).map((path) => path.grantId),
    ['direct-host-view', 'support-host-view']);
  const preview = revokePreview({ resources, groups, grants: overlapping }, ['host'], 'support', 'support-host-view');
  assert.deepEqual(preview.removedGrantIds, ['support-host-view']);
  const after = effectiveAccess({ resources, groups, grants: preview.remainingGrants }, 'host', 'alex');
  assert.ok(after.actions.includes('View'));
  assert.deepEqual(after.paths.filter((path) => path.actions.includes('View')).map((path) => path.grantId),
    ['direct-host-view']);
});

test('Folder Manage Access inherits policy authority without credential reveal', () => {
  const scoped = [{ id: 'folder-manage', resourceId: 'folder', recipient: 'support', actions: ['Manage Access'] }];
  assert.deepEqual(effectiveAccess({ resources, groups, grants: scoped }, 'credential', 'alex').actions,
    ['Manage Access']);
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
