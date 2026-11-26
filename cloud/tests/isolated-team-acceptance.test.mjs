import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { isolatedTeamAcceptance, isolatedTeamWindowOpen, isolatedTeamRouteAllowed, verifyIsolatedTeamAccounts } from '../src/isolated-team-acceptance.mjs';

const config = { host: '127.0.0.1', publicOrigin: 'https://127.0.0.1:28453', allowRegistration: false,
  publication: { environment: 'staging', enabled: false, allowedVaultIDs: [] },
  wholePublication: { enabled: false }, deployment: { anchor: {} } };
const ids = [randomUUID(), randomUUID()];
const now = Date.now();
const args = ['--isolated-team-acceptance'];
const env = { STAGING_TEAM_ACCOUNT_IDS: ids.join(','), STAGING_TEAM_EXPIRES_AT: new Date(now + 60000).toISOString() };
const policy = isolatedTeamAcceptance(config, args, env, now);
const evidence = { writerFloor: 1, teamAuthorizationProtocol: 2 };

test('the operator must explicitly select a bounded private two-account fixture', () => {
  assert.equal(isolatedTeamAcceptance(config, [], {}), null);
  const named = { ...config, publicOrigin:'https://pr255-staging.pastfly.ru:28453' };
  assert.deepEqual(isolatedTeamAcceptance(named, args, env, now), policy);
  for (const [settings, argv, variables] of [
    [config, [], env], [config, args, {}], [config, args, { ...env, STAGING_TEAM_ACCOUNT_IDS: [ids[0], ids[0]].join(',') }],
    [config, args, { ...env, STAGING_TEAM_ACCOUNT_IDS: [...ids, randomUUID()].join(',') }],
    [config, args, { ...env, STAGING_TEAM_EXPIRES_AT: new Date(now).toISOString() }],
    [config, args, { ...env, STAGING_TEAM_EXPIRES_AT: new Date(now + 7200001).toISOString() }],
    [{ ...config, host: '0.0.0.0' }, args, env], [{ ...config, publicOrigin: 'https://cloud.example.test' }, args, env],
    [{ ...config, allowRegistration: true }, args, env], [{ ...config, deployment: {} }, args, env],
    [{ ...config, publication: { ...config.publication, environment: 'production' } }, args, env],
    [{ ...config, wholePublication: { enabled: true } }, args, env],
  ]) assert.throws(() => isolatedTeamAcceptance(settings, argv, variables, now), /invalid_isolated_team_acceptance/);
});

test('the fixture may contain only its two verified synthetic users', async () => {
  const rows = ids.map((id, i) => ({ id, email: 'member' + i + '@example.test', email_verified_at: new Date(), disabled_at: null }));
  const verify = rows => verifyIsolatedTeamAccounts(policy, async () => ({ rows }));
  await verify(rows);
  for (const invalid of [[rows[0]], [...rows, rows[0]],
    ...[{ id: randomUUID() }, { email: 'person@example.org' }, { email_verified_at: null }, { disabled_at: new Date() }]
      .map(patch => [rows[0], { ...rows[1], ...patch }])]) {
    await assert.rejects(verify(invalid), /invalid_isolated_team_accounts/);
  }
});

test('journal evidence, expiry, authenticated accounts and actual V1 routes bound each request', () => {
  assert.equal(isolatedTeamWindowOpen(policy, evidence, policy.expiresAt), false);
  for (const bad of [{}, { ...evidence, writerFloor: 0 }, { ...evidence, teamAuthorizationProtocol: 1 },
    { ...evidence, personalWritePilot: {} }]) assert.equal(isolatedTeamWindowOpen(policy, bad), false);
  const path = '/v1/teams/' + randomUUID() + '/vaults/' + randomUUID();
  for (const id of ids) {
    assert.equal(isolatedTeamRouteAllowed(policy, evidence, id, 'PUT', path), true);
    for (const [method, target] of [['PUT', '/v1/vault'], ['PATCH', path], ['POST', path + '/access-commit'],
      ['GET', path + '/publication/header'], ['GET', '/v1/teams/:id/vaults/:id']]) {
      assert.equal(isolatedTeamRouteAllowed(policy, evidence, id, method, target), false);
    }
  }
  assert.equal(isolatedTeamRouteAllowed(policy, evidence, randomUUID(), 'GET', '/v1/teams'), false);
  assert.equal(isolatedTeamRouteAllowed(null, evidence, ids[0], 'GET', '/v1/teams'), false);
});
