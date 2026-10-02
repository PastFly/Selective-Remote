import test from 'node:test';
import assert from 'node:assert/strict';
import { validateBenchmarkTarget } from '../scripts/benchmark-publication-read.mjs';

test('publication benchmark accepts only explicitly named loopback synthetic test databases', () => {
  const value = 'postgres://migration_test@127.0.0.1:55439/pr_a_publication_benchmark_test';
  assert.equal(validateBenchmarkTarget(value, ['100', '1000']).connectionString, value);
  for (const target of [undefined, 'postgres://user@cloud.pastfly.ru/test',
    'postgres://user@127.0.0.1/production', 'postgres://user@127.0.0.1/other_test',
    'https://127.0.0.1/pr_a_publication_benchmark_test',
    value + '?host=cloud.pastfly.ru', value + '#other']) {
    assert.throws(() => validateBenchmarkTarget(target, ['100']), /isolated_test_database_required/);
  }
  for (const count of ['1', '100.0', 'NaN', '1001']) {
    assert.throws(() => validateBenchmarkTarget(value, [count]), /invalid_benchmark_count/);
  }
});
