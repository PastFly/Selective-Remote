import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { verifyDeploymentCompatibility } from '../src/deployment-compatibility.mjs';

const candidate = JSON.parse(await readFile(new URL('../deployment-compatibility.json', import.meta.url), 'utf8'));
const tuple = () => ({ teamID: randomUUID(), vaultID: randomUUID(), generationID: randomUUID(),
  sequence: 2, headerHash: 'a'.repeat(64), manifestHash: 'b'.repeat(64), schemaFloor: 22 });
function scenario({ schema = '22', committed = [], pending = [], rows = committed, afterQuery } = {}) {
  const events = [];
  const fence = {
    async snapshot() { events.push('snapshot'); return { schemaFloor: 19, committed, pending, outcomes: [] }; },
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

test('only explicit empty-journal maintenance can upgrade a pre019 DB; never traffic', async () => {
  const s = scenario({ schema: '12' });
  assert.deepEqual(await verifyDeploymentCompatibility({ ...s, candidate, mode: 'maintenance-upgrade' }), { compatible: true, schemaVersion: 12, maintenanceOnly: true });
  assert.ok(!s.events.includes('publications'));
  const a = tuple();
  await assert.rejects(verifyDeploymentCompatibility({ ...scenario({ schema: '12', committed: [a] }), candidate, mode: 'maintenance-upgrade' }), /deployment_schema_floor/);
  await assert.rejects(verifyDeploymentCompatibility({ ...scenario(), candidate, mode: 'unknown' }), /invalid_deployment_mode/);
});
