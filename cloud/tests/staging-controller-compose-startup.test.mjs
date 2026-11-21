import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { promisify } from 'node:util';
import { runControllerTrafficStage, verifyControllerFixture } from '../scripts/verify-staging-controller.mjs';
import { currentCapabilities } from '../src/deployment-compatibility.mjs';

const execute = promisify(execFile);
const docker = args => execute('docker', args, { encoding: 'utf8', timeout: 120_000 });
const cloudImage = 'node:22.18.0-alpine@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b';
const caddyImage = 'caddy:2.9.1-alpine@sha256:b4e3952384eb9524a887633ce65c752dd7c71314d2c2acf98cd5c715aaa534f0';
const cloudServer = `
  import { createServer } from 'node:http';

  createServer((request, response) => {
    const readiness = request.url === '/readyz';
    const available = readiness && process.env.SR_TEST_READY === 'true';
    const status = readiness ? (available ? 'ready' : 'unavailable') : 'ok';
    response.writeHead(readiness && !available ? 503 : 200, { 'Content-Type': 'application/json' });
    response.end(JSON.stringify({ status }));
  }).listen(8080, '0.0.0.0');
`;

async function setupCompose(t, ready) {
  const directory = await mkdtemp(join(tmpdir(), 'sr-controller-compose-'));
  const composeFile = join(directory, 'compose.json');
  const caddyfile = join(directory, 'Caddyfile');
  const project = `sr-controller-${randomUUID()}`;
  const compose = ['compose', '--project-name', project, '--file', composeFile];
  t.after(async () => {
    try {
      await docker([...compose, 'down', '--volumes', '--remove-orphans']);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  await writeFile(caddyfile, 'http://:8080 {\n reverse_proxy cloud:8080\n}\n');
  const caddyConfig = { type: 'bind', source: caddyfile, target: '/etc/caddy/Caddyfile', read_only: true };
  await writeFile(composeFile, JSON.stringify({ services: {
    cloud: {
      image: cloudImage,
      command: ['node', '--input-type=module', '--eval', cloudServer],
      environment: { SR_TEST_READY: String(ready) },
      healthcheck: {
        test: ['CMD', 'node', '--eval', "fetch('http://127.0.0.1:8080/healthz').then(response => process.exit(response.ok ? 0 : 1)).catch(() => process.exit(1))"],
        interval: '1s',
        retries: 15,
        timeout: '2s',
      },
    },
    caddy: { image: caddyImage, volumes: [caddyConfig], depends_on: ['cloud'] },
  } }));
  await docker([...compose, 'pull']);

  const services = async status => {
    const { stdout } = await docker([...compose, 'ps', '--status', status, '--services']);
    return stdout.trim().split(/\s+/).filter(Boolean).sort();
  };
  const reports = [];
  const deploy = () => verifyControllerFixture({
    candidate: {},
    report: event => reports.push(event),
    runCommand: async ({ stage }) => {
      if (stage === 'candidate-metadata') return currentCapabilities;
      if (['attest', 'storage', 'assert-project', 'check', 'migrate'].includes(stage)) return;
      if (stage === 'verify-cloud-ready') assert.deepEqual(await services('running'), ['cloud']);
      return runControllerTrafficStage(stage, { docker, compose, inspectProject: async () => {} });
    },
  });

  return { deploy, reports, services, compose };
}

test('controller starts Caddy only after Cloud readiness and closes both services on HTTP 503', {
  skip: process.env.SR_TEST_DOCKER_COMPOSE !== '1',
  timeout: 300_000,
}, async t => {
  await t.test('ready Cloud is reachable through Caddy', async t => {
    const fixture = await setupCompose(t, true);
    assert.deepEqual(await fixture.deploy(), { compatible: true, trafficOpened: true });
    assert.deepEqual(await fixture.services('running'), ['caddy', 'cloud']);

    // Caddy has no Compose health check, so give its listener time to bind.
    const probe = [...fixture.compose, 'exec', '-T', 'caddy', 'wget', '-qO-', 'http://127.0.0.1:8080/readyz'];
    let response;
    for (let attempt = 0; attempt < 10; attempt++) {
      try {
        response = await docker(probe);
        break;
      } catch (error) {
        if (attempt === 9) throw error;
        await delay(250);
      }
    }
    assert.deepEqual(JSON.parse(response.stdout), { status: 'ready' });
  });

  await t.test('unready Cloud is stopped before Caddy is created', async t => {
    const fixture = await setupCompose(t, false);
    await assert.rejects(fixture.deploy(), error => error.code === 1 && error.stderr.trim() === 'deployment_cloud_not_ready');
    assert.deepEqual(await fixture.services('running'), []);
    assert.deepEqual(await fixture.services('exited'), ['cloud']);
    assert.ok(!fixture.reports.some(({ stage }) => ['open-traffic', 'complete'].includes(stage)));
  });
});
