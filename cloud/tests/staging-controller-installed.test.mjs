import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { appendFile, chmod, chown, copyFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const execute = promisify(execFile);
const cloud = fileURLToPath(new URL('../', import.meta.url));
const root = '/opt/selective-remote-controller';
const state = '/var/lib/selective-remote-controller';
const checkout = '/opt/selective-remote';
const runtime = 'runtime/node-v22.18.0-linux-x64/bin/node';
const sources = [
  'scripts/staging-controller.sh',
  'scripts/verify-staging-controller.mjs',
  'src/fence-anchor-config.mjs',
  'src/security.mjs',
  'src/staging-registration.mjs',
];
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const command = (file, args) => execute(file, args, { encoding: 'utf8', timeout: 90_000 });
const docker = (...args) => command('/usr/bin/docker', args);

test('installed controller verifies pinned files and image without changing services', {
  skip: process.env.SR_TEST_INSTALLED_CONTROLLER !== '1',
  timeout: 240_000,
}, async t => {
  assert.equal(process.getuid(), 0);
  assert.equal(process.version, 'v22.18.0');
  const created = [];
  const tag = `sr-test-controller-${randomUUID()}`;
  let imageBuilt = false;
  t.after(async () => {
    try {
      if (imageBuilt) await docker('image', 'rm', tag);
    } finally {
      for (const directory of created.reverse()) await rm(directory, { recursive: true });
    }
  });
  // mkdir without recursive mode refuses all pre-existing installations.
  for (const directory of [root, state, checkout]) {
    await mkdir(directory, { mode: 0o700 });
    created.push(directory);
  }
  const fixture = await mkdtemp('/opt/sr-test-installed-controller-');
  created.push(fixture);

  const sourceSHA = 'a'.repeat(40);
  await writeFile(join(fixture, 'Dockerfile'), `FROM scratch\nCOPY marker /marker\nLABEL org.opencontainers.image.revision="${sourceSHA}"\n`);
  await writeFile(join(fixture, 'marker'), tag);
  await docker('build', '--network=none', '--tag', tag, fixture);
  imageBuilt = true;
  const { stdout: inspectedImage } = await docker('image', 'inspect', '--format', '{{.Id}}', tag);
  const imageDigest = inspectedImage.trim();

  for (const file of sources) {
    await mkdir(dirname(join(root, file)), { recursive: true, mode: 0o700 });
    await copyFile(join(cloud, file), join(root, file));
  }
  await mkdir(dirname(join(root, runtime)), { recursive: true, mode: 0o700 });
  await copyFile(process.execPath, join(root, runtime));
  await chmod(join(root, runtime), 0o755);
  const runtimePin = `${sha256(await readFile(join(root, runtime)))}  ${runtime}\n`;
  await writeFile(join(root, 'runtime-node.sha256'), runtimePin, { mode: 0o600 });
  const lines = await Promise.all([...sources, runtime, 'runtime-node.sha256'].map(async file =>
    `${sha256(await readFile(join(root, file)))}  ${file}\n`));
  const manifest = lines.join('');
  await writeFile(join(root, 'bundle.sha256'), manifest, { mode: 0o600 });

  const cloudDirectory = join(checkout, 'cloud');
  await mkdir(cloudDirectory, { mode: 0o700 });
  const envPath = join(cloudDirectory, '.env');
  const composePath = join(cloudDirectory, 'compose.publication-fence.yaml');
  const environment = 'FIXTURE_PRIVATE_VALUE=do-not-print-this-marker\n';
  await writeFile(envPath, environment, { mode: 0o600 });
  await copyFile(join(cloud, 'compose.publication-fence.yaml'), composePath);
  const publication = join(state, 'publication');
  await mkdir(publication, { mode: 0o770 });
  await chown(publication, 0, 1);
  await chmod(publication, 0o770);
  const fencePath = join(publication, 'journal');
  await writeFile(fencePath, '', { mode: 0o660 });

  const controllerDigest = sha256(manifest);
  await writeFile(join(root, 'settings.json'), JSON.stringify({
    version: 1, teamSafetyStopVersion: 1, sourceSHA, imageDigest, controllerDigest,
    cloudDirectory, envPath, envDigest: sha256(environment), network: 'cloud_private',
    fencePath, backupDirectory: fixture,
    composeFiles: [{ path: composePath, sha256: sha256(await readFile(composePath)) }],
    storage: {
      POSTGRES_DATA_MOUNT_ROOT: '/mnt/controller-fixture',
      POSTGRES_DATA_HOST_PATH: '/mnt/controller-fixture/db',
      POSTGRES_DATA_EXPECTED_SOURCE: '/dev/controller-fixture',
      POSTGRES_DATA_EXPECTED_FSTYPE: 'ext4',
      POSTGRES_DATA_UID: '70',
      POSTGRES_DATA_GID: '70',
    },
  }), { mode: 0o600 });
  const verify = () => command('/bin/bash', [join(cloud, 'scripts/start-staging-guarded.sh'), '--verify-installation']);
  const containers = () => docker('ps', '--all', '--no-trunc', '--quiet', '--filter', 'label=com.docker.compose.project=cloud');
  const before = await containers();

  const valid = await verify();
  assert.equal(valid.stderr, '');
  assert.deepEqual(JSON.parse(valid.stdout), { installationVerified: true, sourceSHA, imageDigest, controllerDigest });
  assert.deepEqual(await readdir(state), ['publication']);
  assert.equal(await readFile(fencePath, 'utf8'), '');

  await appendFile(envPath, 'CHANGED=1\n');
  await assert.rejects(verify(), error =>
    error.code === 1 && error.stderr.trim() === 'deployment_candidate_digest' && error.stdout === '');
  await writeFile(envPath, environment);
  await appendFile(composePath, '\n# changed fixture\n');
  await assert.rejects(verify(), error =>
    error.code === 1 && error.stderr.trim() === 'deployment_candidate_digest' && error.stdout === '');

  assert.deepEqual(await containers(), before);
  assert.deepEqual(await readdir(state), ['publication']);
  assert.equal(await readFile(fencePath, 'utf8'), '');
});
