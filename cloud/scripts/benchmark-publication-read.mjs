// Actual HTTP/PG + browser WebCrypto pipeline; synthetic isolated fixtures only.
import pg from 'pg';
import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { fileURLToPath } from 'node:url';
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:net';
import { seedMigration, addSyntheticDevices } from '../tests/vault-v2-migration-db-fixtures.mjs';
import { legacy, record, uuid } from '../tests/vault-v2-migration-fixtures.mjs';
import { applyMigrations } from '../src/migrations.mjs';
import { VaultMigrationStore } from '../src/vault-migration-store.mjs';
import { hashSessionToken } from '../src/security.mjs';
import { prepareLegacyMigration, prepareMigrationInventory } from '../public/vault-v2-migration.js';
import { createVaultPublicationClient } from '../public/vault-publication-client.js';

export function validateBenchmarkTarget(connectionString, argumentsValue = []) {
  let url;
  try { url = new URL(connectionString); } catch { throw Error('isolated_test_database_required'); }
  if (!['postgres:', 'postgresql:'].includes(url.protocol)
      || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
      || url.search || url.hash
      || !/^\/pr_a_publication_benchmark_[a-z0-9_]*test$/.test(url.pathname)) {
    throw Error('isolated_test_database_required');
  }
  const counts = argumentsValue.length ? argumentsValue : ['100', '1000'];
  if (counts.some(count => !['100', '1000'].includes(count))) throw Error('invalid_benchmark_count');
  return { connectionString, counts: counts.map(Number) };
}

async function launch(connectionString, vaultID) {
  const socket = createServer();
  await new Promise(resolve => socket.listen(0, '127.0.0.1', resolve));
  const port = socket.address().port;
  await new Promise(resolve => socket.close(resolve));
  // Keep these independent synthetic keys out of recorded metrics or child logs.
  const env = { ...process.env, DATABASE_URL: connectionString,
    SESSION_TOKEN_PEPPER: 's'.repeat(32), EMAIL_VERIFICATION_TOKEN_PEPPER: 'e'.repeat(32),
    PASSWORD_RESET_TOKEN_PEPPER: 'p'.repeat(32), TEAM_INVITATION_TOKEN_PEPPER: 't'.repeat(32),
    TEAM_OUTBOX_ENCRYPTION_KEY: 'o'.repeat(32), ABUSE_TOKEN_PEPPER: 'a'.repeat(32),
    PROXY_SHARED_SECRET: 'b'.repeat(64), PUBLICATION_READER_ENABLED: 'true',
    PUBLICATION_ENVIRONMENT: 'staging', PUBLICATION_ALLOWED_VAULT_IDS: vaultID,
    PUBLICATION_CURSOR_SECRET: 'z'.repeat(32), CLOUD_HOST: '127.0.0.1', CLOUD_PORT: String(port) };
  const child = spawn(process.execPath, ['src/server.mjs'], {
    cwd: fileURLToPath(new URL('../', import.meta.url)), env, stdio: ['ignore', 'ignore', 'ignore'],
  });
  const origin = 'http://127.0.0.1:' + port;
  try {
    for (let n = 0; n < 250; n++) {
      if (child.exitCode !== null) throw Error('synthetic_server_failed');
      try { if ((await fetch(origin + '/healthz')).ok) return { child, origin }; } catch {}
      await new Promise(resolve => setTimeout(resolve, 20));
    }
    throw Error('synthetic_server_readiness_timeout');
  } catch (error) { child.kill(); throw error; }
}

async function publishedFixture(pool, count) {
  const fixture = await seedMigration(pool);
  await addSyntheticDevices(pool, fixture, 8);
  const store = new VaultMigrationStore(pool, fixture.config);
  const document = legacy(Array.from({ length: count }, (_, n) => record('host', {
    name: 'synthetic ' + n, hostname: 'synthetic.example.test', port: 22,
  })));
  const preview = await store.preview(fixture.input);
  const scope = { ...fixture.scope, sourceRevision: preview.sourceRevision, sourceHash: preview.sourceHash,
    snapshotHash: preview.snapshotHash, policyVersion: preview.policyVersion };
  const inventory = await prepareMigrationInventory({ ...fixture, scope, document, persistCheckpoint: async () => {} });
  const started = await store.start({ ...fixture.input, resources: inventory.resources });
  const out = await prepareLegacyMigration({ ...fixture, scope: started.scope, document, policy: started.policy,
    checkpoint: inventory.checkpoint, recipientTargets: (resource, part) => started.recipients[resource.id][part],
    persistCheckpoint: async () => {}, readerPublication: {
      publisherAccountID: fixture.accountID, publisherKeyVersion: 1, custodianDeviceIDs: [fixture.deviceID],
      verifyIdentityReservations: async resources => store.verifyIdentityReservations({ ...fixture.input, resources }),
    } });
  for (const [index, object] of out.objects.entries()) {
    await store.putPart(fixture.input, object, index === 0 ? out.checkpoint : undefined);
  }
  await store.putReaderProjection(fixture.input, out.readerProjection, out.administrativeSidecar, out.checkpoint);
  await store.validate(fixture.input, out.manifest);
  await store.activate(fixture.input, await store.manifestHash(fixture.input));
  return { ...fixture, out };
}

function percentile(values, fraction) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)] ?? 0;
}
function processRSS(pid) {
  try { return Number(execFileSync('ps', ['-o', 'rss=', '-p', String(pid)], { encoding: 'utf8' }).trim()) * 1024; }
  catch { return 0; }
}

export async function runPublicationBenchmark(options) {
  const pool = new pg.Pool({ connectionString: options.connectionString, max: 3 });
  try {
    assert.equal((await pool.query('SHOW server_version_num')).rows[0].server_version_num.slice(0, 2), '16');
    await applyMigrations(pool, fileURLToPath(new URL('../migrations/', import.meta.url)), { info() {} });
    for (const count of options.counts) {
      const preparationAt = performance.now();
      const fixture = await publishedFixture(pool, count);
      const preparationMs = performance.now() - preparationAt;
      const token = 'synthetic-publication-benchmark-' + uuid();
      await pool.query("INSERT INTO sessions(user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,now()+interval '1 hour')",
        [fixture.accountID, fixture.deviceID, hashSessionToken(token, 's'.repeat(32))]);
      const runtime = await launch(options.connectionString, fixture.scope.vaultID);
      let timer;
      try {
        const latency = [], routes = {}, dbBytes = Buffer.byteLength(JSON.stringify(fixture.out.readerProjection));
        let responseBytes = 0, serverPeakRSS = 0, clientPeakRSS = process.memoryUsage().rss, payload = null, highWater = null;
        timer = setInterval(() => {
          serverPeakRSS = Math.max(serverPeakRSS, processRSS(runtime.child.pid));
          clientPeakRSS = Math.max(clientPeakRSS, process.memoryUsage().rss);
        }, 1000);
        const prefix = '/v1/teams/' + fixture.scope.teamID + '/vaults/' + fixture.scope.vaultID + '/publication';
        const request = async (route, query = {}) => {
          const params = new URLSearchParams();
          for (const key of ['generationID', 'headerHash', 'cursor', 'limit']) {
            if (query[key] !== null && query[key] !== undefined) params.set(key, String(query[key]));
          }
          const at = performance.now();
          const response = await fetch(runtime.origin + prefix + route + (params.size ? '?' + params : ''), {
            headers: { Authorization: 'Bearer ' + token }, cache: 'no-store',
          });
          assert.equal(response.headers.get('cache-control'), 'no-store');
          const bytes = new Uint8Array(await response.arrayBuffer());
          if (!response.ok) throw Error('synthetic_read_failed_' + response.status);
          latency.push(performance.now() - at);
          responseBytes += bytes.byteLength;
          const type = route.startsWith('/resources/') ? 'part' : route.slice(1);
          routes[type] = (routes[type] ?? 0) + 1;
          return JSON.parse(new TextDecoder().decode(bytes));
        };
        // Deliberately a memory cache surrogate: this metric covers actual HTTP, PG,
        // protocol verification/decryption/materialization, NOT browser IndexedDB fsync.
        const repository = {
          async load() { return { highWater, payload }; },
          async persist(_scope, value, guard) { guard(); highWater = value.highWater; payload = value.payload; },
          async clearPayload() { payload = null; },
        };
        const client = createVaultPublicationClient({
          transport: { header: () => request('/header'), publisher: (_scope, query) => request('/publisher', query),
            directory: (_scope, query) => request('/directory', query),
            part: (_scope, query) => request('/resources/' + query.resourceID + '/parts/' + query.part, query) },
          // Fixture trust uses its HTTPS identity; only this synthetic transport is
          // redirected to loopback HTTP. This benchmark makes no TLS/deployment claim.
          identity: () => ({ endpoint: fixture.endpoint, accountID: fixture.accountID, deviceID: fixture.deviceID,
            sessionEpoch: 'synthetic-benchmark-session' }), scope: fixture.scope, privateKey: fixture.identity.privateKey,
          publicKey: fixture.identity.publicKey,
          ownTrustRepository: fixture.pinnedTrust, publisherTrustRepository: fixture.pinnedTrust,
          repository, cryptoValue: webcrypto,
        });
        const at = performance.now();
        const view = await client.load();
        const materializationMs = performance.now() - at;
        assert.equal(view.models.length, count);
        assert.equal(view.stale, false);
        assert.ok(view.models.every(model => model.kind === 'HOST' && model.record.data.hostname === 'synthetic.example.test'));
        assert.equal(routes.part, count);
        assert.equal(highWater.hash, view.headerHash);
        client.dispose();
        console.log(JSON.stringify({ nodeVersion: process.version, resources: count, devices: 9,
          wrappers: fixture.out.objects.reduce((n, object) => n + object.wrappers.length, 0)
            + fixture.out.administrativeSidecar.wrappers.length,
          preparationMs, materializationMs, requests: latency.length, routes, responseBytes,
          requestP50Ms: percentile(latency, .5), requestP95Ms: percentile(latency, .95), requestP99Ms: percentile(latency, .99),
          clientPeakRSS, serverPeakRSS, projectionBytes: dbBytes,
          repeatedProjectionDBBytesEstimate: dbBytes * latency.length,
          cache: 'memory_surrogate_not_indexeddb', correctness: 'verified_actual_http_pg_webcrypto' }));
      } finally {
        clearInterval(timer);
        runtime.child.kill();
        if (runtime.child.exitCode === null) await new Promise(resolve => runtime.child.once('exit', resolve));
      }
    }
  } finally { await pool.end(); }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  await runPublicationBenchmark(validateBenchmarkTarget(process.env.TEST_DATABASE_URL, process.argv.slice(2)));
}
