import assert from 'node:assert/strict';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { basename, dirname, resolve } from 'node:path';

const script = fileURLToPath(new URL('../scripts/whole-publication-benchmark.mjs', import.meta.url));
const benchmark = await import('../scripts/whole-publication-benchmark.mjs').catch(() => ({}));
const target = 'postgresql://migration_test@127.0.0.1:55439/pr_b_whole_publication_benchmark_test';
const allowed = { WHOLE_PUBLICATION_BENCHMARK: '1', TEST_DATABASE_URL: target };
const validate = env => {
  assert.equal(typeof benchmark.validateBenchmarkTarget, 'function', 'benchmark must export its real target guard');
  return benchmark.validateBenchmarkTarget(env);
};

test('benchmark requires a separate explicit opt-in before accepting a local test database', () => {
  for (const value of [undefined, '', 'true', 'yes', '0']) {
    assert.throws(() => validate({ ...allowed, WHOLE_PUBLICATION_BENCHMARK: value }), /benchmark_opt_in_required/);
  }
  assert.equal(validate(allowed).databaseName, 'pr_b_whole_publication_benchmark_test');
});

test('benchmark refuses external targets even when their database name ends in test', () => {
  for (const host of ['example.com', '10.0.0.1', '0.0.0.0', '127.0.0.2', 'localhost.example.com', '[::ffff:127.0.0.1]']) {
    assert.throws(() => validate({ ...allowed, TEST_DATABASE_URL: `postgresql://migration_test@${host}:55439/disposable_test` }), /loopback_test_database_required/);
  }
});

test('benchmark refuses ordinary databases, ambiguous URL options, and fallback DATABASE_URL', () => {
  for (const url of [target.slice(0, -5), target.replace('postgresql:', 'https:'), `${target}?host=example.com`,
    `${target}#fragment`, target.replace('pr_b_whole_publication_benchmark_test', 'nested/disposable_test'), 'not-a-url']) {
    assert.throws(() => validate({ ...allowed, TEST_DATABASE_URL: url }), /loopback_test_database_required/);
  }
  assert.throws(() => validate({ WHOLE_PUBLICATION_BENCHMARK: '1', DATABASE_URL: target }), /loopback_test_database_required/);
});

test('benchmark accepts only explicit loopback PostgreSQL test URLs', () => {
  for (const host of ['127.0.0.1', 'localhost', '[::1]']) {
    const url = `postgres://migration_test@${host}:55439/disposable_test`;
    assert.equal(validate({ ...allowed, TEST_DATABASE_URL: url }).connectionString, url);
  }
});

test('benchmark executable refuses unsafe input before attempting a connection', () => {
  const run = spawnSync(process.execPath, [script], {
    env: { PATH: process.env.PATH, WHOLE_PUBLICATION_BENCHMARK: '1', TEST_DATABASE_URL: 'postgresql://invalid.invalid/disposable_test' },
    encoding: 'utf8', timeout: 5000,
  });
  assert.equal(run.status, 1);
  assert.match(run.stderr, /loopback_test_database_required/);
  assert.doesNotMatch(run.stderr, /ENOTFOUND|ECONNREFUSED|getaddrinfo/);
});

test('benchmark output defaults to the actual platform temporary directory', () => {
  assert.equal(typeof benchmark.validateBenchmarkOutput, 'function');
  const output = benchmark.validateBenchmarkOutput({});
  assert.equal(dirname(output), resolve(tmpdir()));
  assert.match(basename(output), /^pr-b-whole-benchmark-[a-zA-Z0-9_-]+\.json$/);
  assert.equal(benchmark.validateBenchmarkOutput({ WHOLE_PUBLICATION_BENCHMARK_OUTPUT: 'pr-b-whole-benchmark-portable.json' }), resolve(tmpdir(), 'pr-b-whole-benchmark-portable.json'));
});

test('benchmark refuses arbitrary output paths even when the basename is valid', () => {
  assert.equal(typeof benchmark.validateBenchmarkOutput, 'function');
  for (const output of ['/Users/pr-b-whole-benchmark-bad.json', '/tmp/nested/pr-b-whole-benchmark-bad.json',
    resolve(tmpdir(), 'unrelated.json'), resolve(tmpdir(), 'pr-b-whole-benchmark-bad.log')]) {
    assert.throws(() => benchmark.validateBenchmarkOutput({ WHOLE_PUBLICATION_BENCHMARK_OUTPUT: output }), /benchmark_output_path_invalid/);
  }
});
