import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
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
  assert.match(script, /stat -c '%u'/);
  assert.match(script, /mktemp/);
  assert.match(script, /pg_dump --format=custom/);
  assert.match(script, /pg_restore --list/);
  assert.match(script, /sha256sum/);
  assert.match(script, /Refusing to overwrite/);
  assert.doesNotMatch(script, /POSTGRES_PASSWORD|DATABASE_URL|\.env\b/);
});

test("restore fails closed around confirmation, integrity and active writes", async () => {
  const script = await readFile(restorePath, "utf8");
  assert.match(script, /--confirm-restore/);
  assert.match(script, /sha256sum --check --status/);
  assert.match(script, /recorded_name.*backup_name/);
  assert.match(script, /generated backup format/);
  assert.match(script, /grep -Fxq "cloud"/);
  assert.match(script, /pg_restore --list/);
  assert.match(script, /--clean --if-exists/);
  assert.match(script, /--exit-on-error --single-transaction/);
  assert.doesNotMatch(script, /POSTGRES_PASSWORD|DATABASE_URL|\.env\b/);
});

test("deployment guide requires an off-host backup and restore drill", async () => {
  const guide = await readFile(deploymentGuidePath, "utf8");
  assert.match(guide, /off-host copy/);
  assert.match(guide, /restore drill/);
  assert.match(guide, /--confirm-restore/);
  assert.match(guide, /registration remains disabled/i);
});
