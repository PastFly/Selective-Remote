import test from 'node:test';
import assert from 'node:assert/strict';
import { dropDisposablePublicationDatabase } from './publication-runtime-fixture.mjs';

const name = `prc_http_123_${'a'.repeat(32)}_test`;
const busy = () => Object.assign(new Error('database is still in use'), { code: '55006' });

test('temporary test database cleanup retries a transient remaining connection', async () => {
  const calls = [];
  const admin = { async query(sql) { calls.push(sql); if (calls.length < 3) throw busy(); } };
  await dropDisposablePublicationDatabase(admin, name, { delay: async () => {} });
  assert.equal(calls.length, 3);
  assert.ok(calls.every(sql => sql === `DROP DATABASE "${name}"`));
});

test('test database cleanup reports a persistent busy database without terminating users', async () => {
  let attempts = 0;
  const admin = { async query() { attempts++; throw busy(); } };
  await assert.rejects(dropDisposablePublicationDatabase(admin, name, { delay: async () => {} }), error => error.code === '55006');
  assert.equal(attempts, 6);
});

test('test database cleanup refuses names outside its generated temporary scope', async () => {
  let calls = 0;
  await assert.rejects(dropDisposablePublicationDatabase({ async query() { calls++; } }, 'production'), /disposable_test_database_required/u);
  assert.equal(calls, 0);
});

test('test database cleanup does not retry unrelated failures', async () => {
  let attempts = 0;
  await assert.rejects(dropDisposablePublicationDatabase({ async query() {
    attempts++; throw Object.assign(new Error('permission denied'), { code: '42501' });
  } }, name, { delay: async () => {} }), error => error.code === '42501');
  assert.equal(attempts, 1);
});
