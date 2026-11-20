import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("../scripts/backup-postgres.sh", import.meta.url));
const dumpName = "selective-remote-cloud-20261120T120000Z.dump";

test("simultaneous backups cannot publish over the same timestamp", { timeout: 15_000 }, async (t) => {
  const root = await mkdtemp(join(tmpdir(), "selective-remote-backup-race-"));
  const bin = join(root, "bin");
  const backups = join(root, "backups");
  const firstDumpStarted = join(root, "first-dump-started");
  const releaseFirstDump = join(root, "release-first-dump");
  await mkdir(bin);
  await mkdir(backups, { mode: 0o700 });
  await writeFile(join(bin, "date"), "#!/bin/bash\nprintf '20261120T120000Z\\n'\n", { mode: 0o700 });
  await writeFile(join(bin, "docker"), `#!/bin/bash
set -euo pipefail
case "$*" in
  "compose version"|*"exec -T postgres pg_isready"*) exit 0 ;;
  *"exec -T postgres pg_restore --list"*) cat >/dev/null ;;
  *"pg_dump --format=custom"*)
    if [[ "$BACKUP_WORKER" == first ]]; then
      touch "$FIRST_DUMP_STARTED"
      while [[ ! -f "$RELEASE_FIRST_DUMP" ]]; do sleep 0.02; done
    fi
    printf 'fixture from %s' "$BACKUP_WORKER"
    if [[ "$BACKUP_WORKER" == failed ]]; then exit 74; fi
    ;;
  *) exit 90 ;;
esac
`, { mode: 0o700 });

  const env = {
    ...process.env,
    PATH: `${bin}:${process.env.PATH}`,
    FIRST_DUMP_STARTED: firstDumpStarted,
    RELEASE_FIRST_DUMP: releaseFirstDump,
  };
  const first = spawn("bash", [script, backups], {
    env: { ...env, BACKUP_WORKER: "first" },
    stdio: "ignore",
  });
  const firstResult = new Promise((resolve, reject) => {
    first.once("error", reject);
    first.once("close", resolve);
  });
  t.after(async () => {
    await writeFile(releaseFirstDump, "");
    await firstResult;
    await rm(root, { recursive: true, force: true });
  });

  for (let attempt = 0; attempt < 100; attempt++) {
    if (await stat(firstDumpStarted, { throwIfNoEntry: false })) break;
    await delay(20);
  }
  assert.ok(await stat(firstDumpStarted, { throwIfNoEntry: false }), "first backup did not start dumping");
  const second = spawnSync("bash", [script, backups], {
    env: { ...env, BACKUP_WORKER: "second" },
    encoding: "utf8",
    timeout: 5_000,
  });
  assert.equal(second.status, 73, second.stderr);
  assert.match(second.stderr, /Refusing to overwrite/);

  await writeFile(releaseFirstDump, "");
  assert.equal(await firstResult, 0);
  const archive = await readFile(join(backups, dumpName), "utf8");
  assert.equal(archive, "fixture from first");
  const hash = createHash("sha256").update(archive).digest("hex");
  assert.equal(await readFile(join(backups, dumpName + ".sha256"), "utf8"), hash + "  " + dumpName + "\n");
  assert.deepEqual((await readdir(backups)).sort(), [dumpName, dumpName + ".sha256"]);

  const retryBackups = join(root, "retry-backups");
  await mkdir(retryBackups, { mode: 0o700 });
  const failed = spawnSync("bash", [script, retryBackups], {
    env: { ...env, BACKUP_WORKER: "failed" },
    encoding: "utf8",
  });
  assert.equal(failed.status, 74, failed.stderr);
  assert.deepEqual(await readdir(retryBackups), [], "failed backup left files or a lock");
  const retry = spawnSync("bash", [script, retryBackups], {
    env: { ...env, BACKUP_WORKER: "retry" },
    encoding: "utf8",
  });
  assert.equal(retry.status, 0, retry.stderr);
  assert.equal(await readFile(join(retryBackups, dumpName), "utf8"), "fixture from retry");
});
