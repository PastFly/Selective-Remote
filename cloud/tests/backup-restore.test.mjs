import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const backupPath = fileURLToPath(new URL("../scripts/backup-postgres.sh", import.meta.url));
const restorePath = fileURLToPath(new URL("../scripts/restore-postgres.sh", import.meta.url));
const deploymentGuidePath = fileURLToPath(new URL("../DEPLOY-UBUNTU.md", import.meta.url));

for (const [name, scriptPath] of [["backup", backupPath], ["restore", restorePath]]) {
  test(`${name} script has valid shell syntax and help works without Docker`, () => {
    const syntax = spawnSync("bash", ["-n", scriptPath], { encoding: "utf8" });
    assert.equal(syntax.status, 0, syntax.stderr);

    const help = spawnSync("bash", [scriptPath, "--help"], { encoding: "utf8" });
    assert.equal(help.status, 0, help.stderr);
    assert.match(help.stdout, /Usage:/);
  });
}

test("backup is private, validated and does not read or print secrets", async () => {
  const script = await readFile(backupPath, "utf8");
  assert.match(script, /umask 077/);
  assert.match(script, /backup_dir_mode/);
  assert.match(script, /stat_mode/);
  assert.match(script, /stat_owner/);
  assert.match(script, /stat -f '%Lp'/);
  assert.match(script, /mktemp/);
  assert.match(script, /pg_dump --format=custom/);
  assert.match(script, /pg_restore --list/);
  assert.match(script, /sha256sum/);
  assert.match(script, /Refusing to overwrite/);
  assert.match(script, /backup_published/);
  assert.doesNotMatch(script, /POSTGRES_PASSWORD|DATABASE_URL|\.env\b/);
});

test("restore fails closed around confirmation, integrity and active writes", async () => {
  const script = await readFile(restorePath, "utf8");
  assert.match(script, /--confirm-restore/);
  assert.match(script, /sha256sum --check --status/);
  assert.match(script, /recorded_name.*backup_name/);
  assert.match(script, /generated backup format/);
  assert.match(script, /exactly one record/);
  assert.match(script, /grep -Fxq "cloud"/);
  assert.match(script, /pg_restore --list/);
  assert.match(script, /--clean --if-exists/);
  assert.match(script, /--exit-on-error --single-transaction/);
  assert.doesNotMatch(script, /POSTGRES_PASSWORD|DATABASE_URL|\.env\b/);
});

test("backup and restore complete through a controlled Compose boundary", async () => {
  const root = await mkdtemp(join(tmpdir(), "selective-remote-backup-test-"));
  const binDir = join(root, "bin");
  const backupDir = join(root, "private-backups");
  const dockerPath = join(binDir, "docker");
  const dockerLog = join(root, "docker.log");
  await mkdir(binDir);
  await mkdir(backupDir, { mode: 0o700 });
  await writeFile(dockerPath, `#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$DOCKER_LOG"
case "$*" in
  "compose version") exit 0 ;;
  *"exec -T postgres pg_isready"*) exit 0 ;;
  *"pg_dump --format=custom"*) printf 'PGDMP-controlled-test-archive' ;;
  *"exec -T postgres pg_restore --list"*) cat >/dev/null ;;
  *"ps --status running --services"*) printf 'postgres\\n' ;;
  *"pg_restore --clean --if-exists"*) cat >/dev/null ;;
  *) printf 'Unexpected docker call: %s\\n' "$*" >&2; exit 90 ;;
esac
`, { mode: 0o700 });
  await chmod(dockerPath, 0o700);

  const env = {
    ...process.env,
    PATH: `${binDir}:${process.env.PATH}`,
    DOCKER_LOG: dockerLog,
  };

  try {
    const backup = spawnSync("bash", [backupPath, backupDir], { encoding: "utf8", env });
    assert.equal(backup.status, 0, backup.stderr);

    const entries = await readdir(backupDir);
    const dumpName = entries.find((name) => name.endsWith(".dump"));
    assert.ok(dumpName, "backup dump was not created");
    assert.ok(entries.includes(`${dumpName}.sha256`), "checksum was not created");
    assert.equal((await stat(join(backupDir, dumpName))).mode & 0o777, 0o600);

    const restore = spawnSync(
      "bash",
      [restorePath, "--confirm-restore", join(backupDir, dumpName)],
      { encoding: "utf8", env },
    );
    assert.equal(restore.status, 0, restore.stderr);

    const calls = await readFile(dockerLog, "utf8");
    assert.match(calls, /pg_dump --format=custom/);
    assert.match(calls, /pg_restore --list/);
    assert.match(calls, /pg_restore --clean --if-exists/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("deployment guide requires an off-host backup and restore drill", async () => {
  const guide = await readFile(deploymentGuidePath, "utf8");
  assert.match(guide, /off-host copy/);
  assert.match(guide, /restore drill/);
  assert.match(guide, /--confirm-restore/);
  assert.match(guide, /registration remains disabled/i);
});
