import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const composePath = fileURLToPath(new URL("../compose.postgres-bind.yaml", import.meta.url));
const validatorPath = fileURLToPath(new URL("../scripts/validate-postgres-storage.sh", import.meta.url));
const modelValidatorPath = fileURLToPath(new URL("../scripts/validate-postgres-bind-model.mjs", import.meta.url));
const sourceValidatorPath = fileURLToPath(new URL("../scripts/validate-postgres-bind-source.mjs", import.meta.url));
const starterPath = fileURLToPath(new URL("../scripts/start-staging-guarded.sh", import.meta.url));
const guidePath = fileURLToPath(new URL("../POSTGRES-BIND-STAGING.md", import.meta.url));

test("storage scripts have valid shell syntax and safe help", () => {
  for (const path of [validatorPath, starterPath]) {
    const syntax = spawnSync("bash", ["-n", path], { encoding: "utf8" });
    assert.equal(syntax.status, 0, syntax.stderr);
    const help = spawnSync("bash", [path, "--help"], { encoding: "utf8" });
    assert.equal(help.status, 0, help.stderr);
    assert.match(help.stdout, /Usage:/);
  }
  const validator = readFile(validatorPath, "utf8");
  return validator.then((source) => {
    assert.match(source, /stat -f '%d'/);
    assert.match(source, /stat -f '%u'/);
    assert.match(source, /stat -f '%g'/);
    assert.match(source, /stat -f '%Lp'/);
  });
});

test("Compose profile replaces the PG volume and disables daemon auto-start", async () => {
  const source = await readFile(composePath, "utf8");
  assert.match(source, /volumes:\s*!override/);
  assert.match(source, /POSTGRES_DATA_HOST_PATH:\?POSTGRES_DATA_HOST_PATH is required/);
  assert.match(source, /target: \/var\/lib\/postgresql\/data/);
  assert.match(source, /create_host_path: false/);
  assert.equal((source.match(/restart: "on-failure:3"/g) || []).length, 3);
  assert.doesNotMatch(source, /5432:|8080:/);
});

test("guarded starter validates before Compose config and start", async () => {
  const source = await readFile(starterPath, "utf8");
  const sourceGuard = source.indexOf("validate-postgres-bind-source.mjs");
  const storageGuard = source.indexOf('validate-postgres-storage.sh" --check');
  const config = source.indexOf("config --quiet");
  const model = source.indexOf("validate-postgres-bind-model.mjs");
  const start = source.indexOf("up -d");
  assert.ok(
    sourceGuard >= 0 &&
      sourceGuard < storageGuard &&
      storageGuard < config &&
      config < model &&
      model < start,
  );
  assert.match(source, /--project-directory/);
  assert.match(source, /compose_files/);
  assert.doesNotMatch(source, /\.env|POSTGRES_PASSWORD|DATABASE_URL/);
});

async function makeFixture() {
  // macOS exposes /var through /private/var. Canonicalize the fixture root so
  // the test does not manufacture a path that our production symlink guard is
  // specifically expected to reject.
  const root = await realpath(await mkdtemp(join(tmpdir(), "sr-pg-storage-")));
  const bin = join(root, "bin");
  const mountRoot = join(root, "postgres-mount");
  const dataPath = join(mountRoot, "selective-remote");
  const sourceDevice = join(root, "expected-device");
  await mkdir(bin);
  await mkdir(mountRoot);
  await mkdir(dataPath, { mode: 0o700 });
  await writeFile(sourceDevice, "fixture");

  await writeFile(join(bin, "mountpoint"), "#!/usr/bin/env bash\nexit 0\n", { mode: 0o700 });
  await writeFile(join(bin, "findmnt"), `#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" -o TARGET "*) printf '%s\\n' "$MOCK_MOUNT_ROOT" ;;
  *" -o SOURCE "*) printf '%s\\n' "$MOCK_SOURCE" ;;
  *" -o FSTYPE "*) printf '%s\\n' "\${MOCK_FSTYPE:-ext4}" ;;
  *" -o OPTIONS "*) printf 'rw,relatime\\n' ;;
  *) exit 64 ;;
esac
`, { mode: 0o700 });
  await chmod(join(bin, "findmnt"), 0o700);

  return { root, bin, mountRoot, dataPath, sourceDevice };
}

function validatorEnv(fixture, overrides = {}) {
  return {
    ...process.env,
    PATH: `${fixture.bin}:${process.env.PATH}`,
    MOCK_MOUNT_ROOT: fixture.mountRoot,
    MOCK_SOURCE: fixture.sourceDevice,
    MOCK_FSTYPE: "ext4",
    POSTGRES_DATA_MOUNT_ROOT: fixture.mountRoot,
    POSTGRES_DATA_HOST_PATH: fixture.dataPath,
    POSTGRES_DATA_EXPECTED_SOURCE: fixture.sourceDevice,
    POSTGRES_DATA_EXPECTED_FSTYPE: "ext4",
    POSTGRES_DATA_UID: String(process.getuid()),
    POSTGRES_DATA_GID: String(process.getgid()),
    ...overrides,
  };
}

test("validator accepts an exact reviewed fixture", async () => {
  const fixture = await makeFixture();
  try {
    const result = spawnSync("bash", [validatorPath, "--check"], {
      encoding: "utf8",
      env: validatorEnv(fixture),
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /POSTGRES_STORAGE_OK/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("validator rejects an absent mount and unexpected filesystem", async () => {
  const fixture = await makeFixture();
  try {
    await writeFile(join(fixture.bin, "mountpoint"), `#!/usr/bin/env bash
if [[ "\${MOCK_MOUNTED:-yes}" == yes ]]; then exit 0; fi
exit 1
`, { mode: 0o700 });
    let result = spawnSync("bash", [validatorPath, "--check"], {
      encoding: "utf8",
      env: validatorEnv(fixture, { MOCK_MOUNTED: "no" }),
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /is not mounted/);

    result = spawnSync("bash", [validatorPath, "--check"], {
      encoding: "utf8",
      env: validatorEnv(fixture, { MOCK_MOUNTED: "yes", MOCK_FSTYPE: "xfs" }),
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /filesystem type does not match/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("source validator requires the exact reviewed profile as the final file", async () => {
  const root = await mkdtemp(join(tmpdir(), "sr-pg-source-"));
  const ordinary = join(root, "ordinary.yaml");
  const altered = join(root, "altered.yaml");
  try {
    await writeFile(ordinary, "services: {}\n");
    await writeFile(
      altered,
      (await readFile(composePath, "utf8")).replace(
        "create_host_path: false",
        "create_host_path: true",
      ),
    );

    let result = spawnSync(
      "node",
      [sourceValidatorPath, ordinary, composePath],
      { encoding: "utf8" },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /POSTGRES_BIND_SOURCE_OK/);

    result = spawnSync(
      "node",
      [sourceValidatorPath, composePath, ordinary],
      { encoding: "utf8" },
    );
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must be the final Compose file/);

    result = spawnSync("node", [sourceValidatorPath, ordinary, altered], {
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /exactly one exact reviewed/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("rendered-model validator accepts only the exact bind contract", () => {
  const source = "/srv/postgres/selective-remote";
  const valid = {
    services: {
      postgres: {
        restart: "on-failure:3",
        ports: [],
        volumes: [{
          type: "bind",
          source,
          target: "/var/lib/postgresql/data",
          bind: {},
        }],
      },
      cloud: {
        restart: "on-failure:3",
        ports: [],
        environment: { ALLOW_REGISTRATION: "false" },
      },
      caddy: { restart: "on-failure:3" },
    },
  };
  let result = spawnSync("node", [modelValidatorPath], {
    encoding: "utf8",
    input: JSON.stringify(valid),
    env: { ...process.env, POSTGRES_DATA_HOST_PATH: source },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /POSTGRES_BIND_MODEL_OK/);

  const explicitFalse = structuredClone(valid);
  explicitFalse.services.postgres.volumes[0].bind = {
    create_host_path: false,
  };
  result = spawnSync("node", [modelValidatorPath], {
    encoding: "utf8",
    input: JSON.stringify(explicitFalse),
    env: { ...process.env, POSTGRES_DATA_HOST_PATH: source },
  });
  assert.equal(result.status, 0, result.stderr);

  const unsafe = structuredClone(valid);
  unsafe.services.postgres.volumes[0].bind.create_host_path = true;
  result = spawnSync("node", [modelValidatorPath], {
    encoding: "utf8",
    input: JSON.stringify(unsafe),
    env: { ...process.env, POSTGRES_DATA_HOST_PATH: source },
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /unsafe bind options/);
});

test("validator rejects wrong device, missing path and symlink path", async () => {
  const fixture = await makeFixture();
  try {
    const wrongDevice = join(fixture.root, "wrong-device");
    await writeFile(wrongDevice, "wrong");
    let result = spawnSync("bash", [validatorPath, "--check"], {
      encoding: "utf8",
      env: validatorEnv(fixture, { POSTGRES_DATA_EXPECTED_SOURCE: wrongDevice }),
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /device does not match/);

    const missing = join(fixture.mountRoot, "missing");
    result = spawnSync("bash", [validatorPath, "--check"], {
      encoding: "utf8",
      env: validatorEnv(fixture, { POSTGRES_DATA_HOST_PATH: missing }),
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /data path is missing/);

    const target = join(fixture.mountRoot, "real-target");
    const link = join(fixture.mountRoot, "linked-target");
    await mkdir(target, { mode: 0o700 });
    await symlink(target, link);
    result = spawnSync("bash", [validatorPath, "--check"], {
      encoding: "utf8",
      env: validatorEnv(fixture, { POSTGRES_DATA_HOST_PATH: link }),
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must not be a symlink/);
  } finally {
    await rm(fixture.root, { recursive: true, force: true });
  }
});

test("guide preserves mount, backup and no-live-unmount gates", async () => {
  const guide = await readFile(guidePath, "utf8");
  assert.match(guide, /direct child of a verified mount/);
  assert.match(guide, /automatic source-directory creation is disabled/);
  assert.match(guide, /do not auto-start around the guard/);
  assert.match(guide, /encrypted off-host copy/);
  assert.match(guide, /Never test mount loss by unmounting a live database/);
});
