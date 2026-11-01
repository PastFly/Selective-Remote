import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { verifyDeploymentCompatibility } from '../src/deployment-compatibility.mjs';
import * as deployment from '../src/deployment-compatibility.mjs';

const candidate = JSON.parse(await readFile(new URL('../deployment-compatibility.json', import.meta.url), 'utf8'));
const tuple = () => ({ teamID: randomUUID(), vaultID: randomUUID(), generationID: randomUUID(),
  sequence: 2, headerHash: 'a'.repeat(64), manifestHash: 'b'.repeat(64), schemaFloor: 22 });
function scenario({ schema = '22', committed = [], pending = [], rows = committed, afterQuery } = {}) {
  const events = [];
  const fence = {
    async snapshot() { events.push('snapshot'); return { schemaFloor: Math.max(19, ...committed.map(v => v.schemaFloor)), committed, pending, outcomes: [] }; },
    async verifySchemaFloor(version) { events.push('floor'); assert.ok(version >= 19); if (committed.some(v => version < v.schemaFloor)) throw Error('deployment_schema_floor'); return true; },
    async verify() { events.push('verify'); if (pending.length) throw Error('deployment_fence_pending'); return true; },
  };
  const query = async (sql) => {
    if (sql.includes('schema_migrations')) { events.push('schema'); return { rows: [{ version: schema }] }; }
    events.push('publications'); afterQuery?.(); return { rows };
  };
  return { fence, query, events };
}

test('old/missing capability cannot query the DB or open traffic', async () => {
  for (const unsupported of [null, {}, { ...candidate, fenceVersion: 1 }, { ...candidate, readerProjectionVersion: 0 }, { ...candidate, wholePublicationVersion: 0 }, { ...candidate, maxSchemaVersion: 19 }]) {
    const s = scenario();
    await assert.rejects(verifyDeploymentCompatibility({ ...s, candidate: unsupported }), /deployment_code_floor/);
    assert.deepEqual(s.events, []);
  }
});

test('a pending outcome stops traffic before DB access', async () => {
  const s = scenario({ pending: [{ intentID: randomUUID() }] });
  await assert.rejects(verifyDeploymentCompatibility({ ...s, candidate }), /deployment_fence_pending/);
  assert.deepEqual(s.events, ['snapshot']);
});

test('old and unknown newer schemas deny before publication queries', async () => {
  for (const schema of ['12', '18', '23']) {
    const s = scenario({ schema });
    await assert.rejects(verifyDeploymentCompatibility({ ...s, candidate }), /deployment_schema_floor/);
    assert.ok(!s.events.includes('publications'));
  }
});

test('matching committed generation passes but missing/older/forked or unfenced rows deny', async () => {
  const a = tuple();
  assert.deepEqual(await verifyDeploymentCompatibility({ ...scenario({ committed: [a] }), candidate }), { compatible: true, schemaVersion: 22 });
  for (const rows of [[], [{ ...a, sequence: 1 }], [{ ...a, headerHash: 'c'.repeat(64) }], [{ ...a, manifestHash: 'd'.repeat(64) }], [{ ...a, generationID: randomUUID() }], [a, tuple()]]) {
    await assert.rejects(verifyDeploymentCompatibility({ ...scenario({ committed: [a], rows }), candidate }), /deployment_fence_mismatch/);
  }
  await assert.rejects(verifyDeploymentCompatibility({ ...scenario({ rows: [a] }), candidate }), /deployment_fence_mismatch/);
});

test('pending appended during DB query cannot be hidden by an earlier snapshot', async () => {
  const pending = [], s = scenario({ pending, afterQuery: () => pending.push({ intentID: randomUUID() }) });
  await assert.rejects(verifyDeploymentCompatibility({ ...s, candidate }), /deployment_fence_pending/);
});

test('compatibility checks read the independent journal before and after the DB only', async () => {
  const s = scenario({ committed: [tuple()] });
  await verifyDeploymentCompatibility({ ...s, candidate });
  assert.deepEqual(s.events, ['snapshot', 'schema', 'publications', 'snapshot']);
});

test('concurrent requests queued before a check share work and reject excess waiters', async () => {
  assert.equal(typeof deployment.createDeploymentGuard, 'function');
  let release;
  const held = new Promise(resolve => { release = resolve; });
  let calls = 0, pending = false;
  const guard = deployment.createDeploymentGuard(async () => {
    calls += 1;
    if (calls === 1) await held;
    if (pending) throw Error('deployment_fence_pending');
  }, { maxWaiters: 2, maxCooldownMs: 0 });
  const first = guard(), second = guard();
  const excess = assert.rejects(guard(), /deployment_guard_busy/);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(calls, 1);
  release();
  await Promise.all([first, second, excess]);
  pending = true;
  await assert.rejects(guard(), /deployment_fence_pending/);
  assert.equal(calls, 2);
  pending = false;
  await guard();
  assert.equal(calls, 3);
});

test('a request arriving after a database restore receives a fresh compatibility check', async () => {
  const committed = [tuple()];
  let rows = [...committed], releaseFirst, firstRead;
  const readReached = new Promise(resolve => { firstRead = resolve; });
  const held = new Promise(resolve => { releaseFirst = resolve; });
  let checks = 0;
  const fence = { async snapshot() { return { schemaFloor: 22, committed, pending: [], outcomes: [] }; } };
  const query = async sql => {
    if (sql.includes('schema_migrations')) return { rows: [{ version: '22' }] };
    const result = [...rows];
    if (checks === 1) { firstRead(); await held; }
    return { rows: result };
  };
  const guard = deployment.createDeploymentGuard(async () => {
    checks += 1;
    return verifyDeploymentCompatibility({ query, fence, candidate });
  }, { maxCooldownMs: 0 });
  const first = guard();
  await readReached;
  rows = [];
  const late = assert.rejects(guard(), /deployment_fence_mismatch/);
  releaseFirst();
  await first;
  await late;
  assert.equal(checks, 2);
});

test('a stalled check fails closed within a deadline and cannot accumulate unbounded waiters', async () => {
  let release;
  const held = new Promise(resolve => { release = resolve; });
  let checks = 0;
  const guard = deployment.createDeploymentGuard(async () => { checks += 1; await held; },
    { maxWaiters: 1, maxCooldownMs: 0, maxWaitMs: 20 });
  await assert.rejects(guard(), /deployment_guard_timeout/);
  await assert.rejects(guard(), /deployment_guard_busy/);
  assert.equal(checks, 1);
  release();
  await new Promise(resolve => setImmediate(resolve));
  await guard();
  assert.equal(checks, 2);
});

test('repeated checks yield time to the server without reusing a completed decision', async () => {
  assert.equal(typeof deployment.createDeploymentGuard, 'function');
  let clock = 0, checks = 0;
  const delays = [];
  const guard = deployment.createDeploymentGuard(async () => { checks += 1; clock += 20; }, {
    now: () => clock,
    delay: async ms => { delays.push(ms); clock += ms; },
  });
  await guard();
  await guard();
  assert.deepEqual(delays, [20]);
  assert.equal(checks, 2);
});

test('only explicit empty-journal maintenance can upgrade a pre019 DB; never traffic', async () => {
  const s = scenario({ schema: '12' });
  assert.deepEqual(await verifyDeploymentCompatibility({ ...s, candidate, mode: 'maintenance-upgrade' }), { compatible: true, schemaVersion: 12, maintenanceOnly: true });
  assert.ok(!s.events.includes('publications'));
  const a = tuple();
  await assert.rejects(verifyDeploymentCompatibility({ ...scenario({ schema: '12', committed: [a] }), candidate, mode: 'maintenance-upgrade' }), /deployment_schema_floor/);
  await assert.rejects(verifyDeploymentCompatibility({ ...scenario(), candidate, mode: 'unknown' }), /invalid_deployment_mode/);
});
