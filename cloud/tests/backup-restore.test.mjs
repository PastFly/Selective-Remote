import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { isolatedPublicationDatabase } from "./publication-runtime-fixture.mjs";

const backupPath = fileURLToPath(new URL("../scripts/backup-postgres.sh", import.meta.url));
const restorePath = fileURLToPath(new URL("../scripts/restore-postgres.sh", import.meta.url));
const deploymentGuidePath = fileURLToPath(new URL("../DEPLOY-UBUNTU.md", import.meta.url));

const readCloudStateSequence = `
if [[ -n "\${CLOUD_STATE_SEQUENCE:-}" ]]; then
  read -r state < "$CLOUD_STATE_SEQUENCE"
  tail -n +2 "$CLOUD_STATE_SEQUENCE" > "$CLOUD_STATE_SEQUENCE.next"
  mv "$CLOUD_STATE_SEQUENCE.next" "$CLOUD_STATE_SEQUENCE"
fi
`;

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
  assert.match(script, /write_sha256/);
  assert.match(script, /sha256sum/);
  assert.match(script, /shasum -a 256/);
  assert.match(script, /Refusing to overwrite/);
  assert.match(script, /backup_published/);
  assert.doesNotMatch(script, /POSTGRES_PASSWORD|DATABASE_URL|\.env\b/);
});

test("restore fails closed around confirmation, integrity and active writes", async () => {
  const script = await readFile(restorePath, "utf8");
  assert.match(script, /--confirm-restore/);
  assert.match(script, /calculate_sha256/);
  assert.match(script, /actual_hash.*recorded_hash/);
  assert.match(script, /shasum -a 256/);
  assert.match(script, /recorded_name.*backup_name/);
  assert.match(script, /generated backup format/);
  assert.match(script, /exactly one record/);
  assert.match(script, /pg_restore --list/);
  assert.match(script, /--clean --if-exists/);
  assert.match(script, /--exit-on-error --file=-/);
  assert.match(script, /--set=ON_ERROR_STOP=1 --file=-/);
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
  *"exec -T postgres pg_restore --list"*)
    cat >/dev/null
    if [[ -n "\${COMPOSE_STATE_AFTER_LIST:-}" ]]; then touch "$DOCKER_LOG.listed"; fi
    exit "\${ARCHIVE_LIST_EXIT:-0}"
    ;;
  *"ps --all --format {{.Service}} {{.State}}"*)
    state="\${COMPOSE_CLOUD_STATE:-exited}"
    if [[ -f "$DOCKER_LOG.listed" ]]; then state="$COMPOSE_STATE_AFTER_LIST"; fi
    ${readCloudStateSequence}
    printf 'postgres %s\\ncloud %s\\n' "\${COMPOSE_POSTGRES_STATE:-running}" "$state"
    exit "\${COMPOSE_STATUS_EXIT:-0}"
    ;;
  *"pg_restore --clean --if-exists"*)
    cat >/dev/null
    printf 'CREATE TABLE restore_probe(value integer);\\n'
    exit "\${ARCHIVE_SQL_EXIT:-0}"
    ;;
  *"psql --no-psqlrc --no-password --quiet"*)
    cat > "$DOCKER_LOG.sql"
    exit "\${RESTORE_PSQL_EXIT:-0}"
    ;;
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

    const restoreArgs = [restorePath, "--confirm-restore", join(backupDir, dumpName)];
    const failedStatus = spawnSync("bash", restoreArgs, {
      encoding: "utf8",
      env: { ...env, COMPOSE_STATUS_EXIT: "1" },
    });
    assert.equal(failedStatus.status, 69, failedStatus.stderr);
    assert.match(failedStatus.stderr, /Could not verify the state of the Cloud and PostgreSQL services/);
    assert.doesNotMatch(await readFile(dockerLog, "utf8"), /pg_restore --clean/);

    for (const state of ["running", "paused", "restarting", "removing"]) {
      const activeCloud = spawnSync("bash", restoreArgs, {
        encoding: "utf8",
        env: { ...env, COMPOSE_CLOUD_STATE: state },
      });
      assert.equal(activeCloud.status, 75, `Cloud state ${state}: ${activeCloud.stderr}`);
      assert.match(activeCloud.stderr, /Stop the Cloud service before restoring the database/);
    }
    assert.doesNotMatch(await readFile(dockerLog, "utf8"), /pg_restore --clean/);

    const restartedCloud = spawnSync("bash", restoreArgs, {
      encoding: "utf8",
      env: { ...env, COMPOSE_STATE_AFTER_LIST: "running" },
    });
    assert.equal(restartedCloud.status, 75, restartedCloud.stderr);
    assert.match(restartedCloud.stderr, /Stop the Cloud service before restoring the database/);
    assert.doesNotMatch(await readFile(dockerLog, "utf8"), /pg_restore --clean/);
    await rm(`${dockerLog}.listed`, { force: true });

    const pausedDatabase = spawnSync("bash", restoreArgs, {
      encoding: "utf8",
      env: { ...env, COMPOSE_POSTGRES_STATE: "paused" },
    });
    assert.equal(pausedDatabase.status, 69, pausedDatabase.stderr);
    assert.match(pausedDatabase.stderr, /PostgreSQL service must be running/);

    const dumpPath = join(backupDir, dumpName);
    const originalDump = await readFile(dumpPath);
    const originalChecksum = await readFile(`${dumpPath}.sha256`);
    const corruptedDump = Buffer.from("truncated");
    await writeFile(dumpPath, corruptedDump);
    assert.match(await readFile(dockerLog, "utf8"), /pg_dump --format=custom/);
    await writeFile(dockerLog, "");
    const mismatchedChecksum = spawnSync("bash", restoreArgs, { encoding: "utf8", env });
    assert.equal(mismatchedChecksum.status, 65, mismatchedChecksum.stderr);
    assert.match(mismatchedChecksum.stderr, /Backup checksum verification failed/);
    assert.doesNotMatch(await readFile(dockerLog, "utf8"), /pg_restore --list|pg_restore --clean/);

    const corruptedHash = createHash("sha256").update(corruptedDump).digest("hex");
    await writeFile(`${dumpPath}.sha256`, `${corruptedHash}  ${dumpName}\n`);
    const malformedArchive = spawnSync("bash", restoreArgs, {
      encoding: "utf8",
      env: { ...env, ARCHIVE_LIST_EXIT: "1" },
    });
    assert.equal(malformedArchive.status, 1, malformedArchive.stderr);
    assert.doesNotMatch(await readFile(dockerLog, "utf8"), /pg_restore --clean/);
    await writeFile(dumpPath, originalDump);
    await writeFile(`${dumpPath}.sha256`, originalChecksum);

    const stateSequence = join(root, "cloud-state-sequence");
    const lateStartEnv = { ...env, CLOUD_STATE_SEQUENCE: stateSequence };
    await writeFile(stateSequence, "exited\nexited\nrunning\n");
    const interruptedRestore = spawnSync("bash", restoreArgs, { encoding: "utf8", env: lateStartEnv });
    assert.equal(interruptedRestore.status, 75, interruptedRestore.stderr);
    assert.doesNotMatch(interruptedRestore.stdout, /Restore completed/);
    const interruptedSQL = await readFile(dockerLog + ".sql", "utf8");
    assert.match(interruptedSQL, /^BEGIN;\nCREATE TABLE restore_probe/u);
    assert.doesNotMatch(interruptedSQL, /^COMMIT;$/mu);

    const restore = spawnSync("bash", restoreArgs, { encoding: "utf8", env });
    assert.equal(restore.status, 0, restore.stderr);

    const calls = await readFile(dockerLog, "utf8");
    assert.match(calls, /pg_restore --list/);
    assert.match(calls, /pg_restore --clean --if-exists/);
    assert.match(await readFile(dockerLog + ".sql", "utf8"),
      /^BEGIN;\nCREATE TABLE restore_probe\(value integer\);\n+UPDATE public\.sessions\s+SET revoked_at = CURRENT_TIMESTAMP\s+WHERE revoked_at IS NULL;\n+COMMIT;\n$/u);

    const partialSQL = spawnSync("bash", restoreArgs, {
      encoding: "utf8",
      env: { ...env, ARCHIVE_SQL_EXIT: "8" },
    });
    assert.equal(partialSQL.status, 8, partialSQL.stderr);
    assert.doesNotMatch(partialSQL.stdout, /Restore completed/);
    assert.match(await readFile(dockerLog + ".sql", "utf8"),
      /^BEGIN;\nCREATE TABLE restore_probe\(value integer\);\n$/u);

    const failedSQL = spawnSync("bash", restoreArgs, {
      encoding: "utf8",
      env: { ...env, RESTORE_PSQL_EXIT: "3" },
    });
    assert.equal(failedSQL.status, 3, failedSQL.stderr);
    assert.doesNotMatch(failedSQL.stdout, /Restore completed/);

    await rm(dockerLog + ".sql", { force: true });
    const finalizeArgs = [restorePath, "--confirm-finalize-recovery"];
    const refusedFinalization = spawnSync("bash", finalizeArgs, {
      encoding: "utf8",
      env: { ...env, COMPOSE_CLOUD_STATE: "running" },
    });
    assert.equal(refusedFinalization.status, 75, refusedFinalization.stderr);
    await assert.rejects(stat(dockerLog + ".sql"), { code: "ENOENT" });

    await writeFile(stateSequence, "exited\nrunning\n");
    const interruptedFinalization = spawnSync("bash", finalizeArgs, { encoding: "utf8", env: lateStartEnv });
    assert.equal(interruptedFinalization.status, 75, interruptedFinalization.stderr);
    assert.doesNotMatch(interruptedFinalization.stdout, /Restored sessions revoked/);
    assert.doesNotMatch(await readFile(dockerLog + ".sql", "utf8"), /^COMMIT;$/mu);

    const finalized = spawnSync("bash", finalizeArgs, { encoding: "utf8", env });
    assert.equal(finalized.status, 0, finalized.stderr);
    assert.match(await readFile(dockerLog + ".sql", "utf8"),
      /^BEGIN;\n+UPDATE public\.sessions\s+SET revoked_at = CURRENT_TIMESTAMP\s+WHERE revoked_at IS NULL;\n+COMMIT;\n$/u);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("PostgreSQL restore commits application data and session revocation together", {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const root = await mkdtemp(join(tmpdir(), "selective-remote-restore-transaction-"));
  let db;
  try {
    db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
    const target = new URL(db.databaseURL);
    const database = target.pathname.slice(1);
    const user = randomUUID();
    const device = randomUUID();
    await db.pool.query("INSERT INTO users(id,email,username) VALUES($1,'restore@example.test','restore_test')", [user]);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'restore test','macos')", [device, user]);
    await db.pool.query(
      "INSERT INTO sessions(user_id,device_id,token_hash,expires_at) VALUES($1,$2,'synthetic-restore-session',now()+interval '1 day')",
      [user, device],
    );
    await db.pool.query("CREATE TABLE public.restore_probe(value text NOT NULL)");
    await db.pool.query("INSERT INTO public.restore_probe VALUES ('from backup')");

    await writeFile(join(root, "docker"), `#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "compose version") exit 0 ;;
  *"ps --all --format {{.Service}} {{.State}}"*)
    state=exited
    ${readCloudStateSequence}
    printf 'postgres running\\ncloud %s\\n' "$state"
    ;;
  *"exec -T postgres "*)
    while [[ "$1" != postgres ]]; do shift; done
    shift
    if [[ "$1" == pg_restore && "$2" == --clean && "\${FAIL_ARCHIVE_STREAM:-0}" == 1 ]]; then
      "$@"
      exit 8
    fi
    exec "$@"
    ;;
  *) exit 90 ;;
esac
`, { mode: 0o700 });
    const env = {
      ...process.env,
      PATH: root + ":" + process.env.PATH,
      PGHOST: target.hostname.replace(/^\[|\]$/gu, ""),
      PGPORT: target.port || "5432",
      PGDATABASE: database,
      PGUSER: decodeURIComponent(target.username),
      PGPASSWORD: decodeURIComponent(target.password),
      POSTGRES_DB: database,
      POSTGRES_USER: decodeURIComponent(target.username),
    };
    const archive = spawnSync("pg_dump", ["--format=custom", "--no-password"], {
      env, maxBuffer: 8 * 1024 * 1024,
    });
    assert.equal(archive.status, 0, "synthetic pg_dump must succeed");
    const filename = "selective-remote-cloud-20260101T000000Z.dump";
    const dump = join(root, filename);
    await writeFile(dump, archive.stdout, { mode: 0o600 });
    const hash = createHash("sha256").update(archive.stdout).digest("hex");
    await writeFile(dump + ".sha256", hash + "  " + filename + "\n", { mode: 0o600 });
    await db.pool.query("UPDATE public.restore_probe SET value='before restore'");

    const restoreArgs = [restorePath, "--confirm-restore", dump];
    const failed = spawnSync("bash", restoreArgs, { env: { ...env, FAIL_ARCHIVE_STREAM: "1" }, encoding: "utf8" });
    assert.equal(failed.status, 8, failed.stderr);
    assert.deepEqual((await db.pool.query("SELECT value FROM public.restore_probe")).rows, [{ value: "before restore" }]);
    assert.deepEqual((await db.pool.query("SELECT revoked_at IS NULL AS active FROM public.sessions")).rows, [{ active: true }]);

    const stateSequence = join(root, "cloud-state-sequence");
    const lateStartEnv = { ...env, CLOUD_STATE_SEQUENCE: stateSequence };
    await writeFile(stateSequence, "exited\nexited\nrunning\n");
    const interrupted = spawnSync("bash", restoreArgs, { env: lateStartEnv, encoding: "utf8" });
    assert.equal(interrupted.status, 75, interrupted.stderr);
    assert.deepEqual((await db.pool.query("SELECT value FROM public.restore_probe")).rows, [{ value: "before restore" }]);
    assert.deepEqual((await db.pool.query("SELECT revoked_at FROM public.sessions")).rows, [{ revoked_at: null }]);

    const restored = spawnSync("bash", restoreArgs, { env, encoding: "utf8" });
    assert.equal(restored.status, 0, restored.stderr);
    assert.deepEqual((await db.pool.query("SELECT value FROM public.restore_probe")).rows, [{ value: "from backup" }]);
    assert.deepEqual((await db.pool.query("SELECT revoked_at IS NULL AS active FROM public.sessions")).rows, [{ active: false }]);

    const externalRestore = spawnSync("pg_restore", [
      "--clean", "--if-exists", "--single-transaction", "--no-owner", "--no-privileges",
      "--no-password", "--dbname", database, dump,
    ], { env, encoding: "utf8" });
    assert.equal(externalRestore.status, 0, externalRestore.stderr);
    assert.deepEqual((await db.pool.query("SELECT revoked_at FROM public.sessions")).rows, [{ revoked_at: null }]);

    const finalizeArgs = [restorePath, "--confirm-finalize-recovery"];
    await writeFile(stateSequence, "exited\nrunning\n");
    const refusedFinalization = spawnSync("bash", finalizeArgs, { env: lateStartEnv, encoding: "utf8" });
    assert.equal(refusedFinalization.status, 75, refusedFinalization.stderr);
    assert.deepEqual((await db.pool.query("SELECT revoked_at FROM public.sessions")).rows, [{ revoked_at: null }]);

    const finalized = spawnSync("bash", finalizeArgs, { env, encoding: "utf8" });
    assert.equal(finalized.status, 0, finalized.stderr);
    const firstRevocation = (await db.pool.query("SELECT revoked_at FROM public.sessions")).rows;
    assert.ok(firstRevocation[0]?.revoked_at instanceof Date);
    assert.deepEqual((await db.pool.query("SELECT value FROM public.restore_probe")).rows, [{ value: "from backup" }]);
    const retried = spawnSync("bash", finalizeArgs, { env, encoding: "utf8" });
    assert.equal(retried.status, 0, retried.stderr);
    assert.deepEqual((await db.pool.query("SELECT revoked_at FROM public.sessions")).rows, firstRevocation);
  } finally {
    try { await db?.cleanup(); }
    finally { await rm(root, { recursive: true, force: true }); }
  }
});

test("deployment guide requires an off-host backup and restore drill", async () => {
  const guide = await readFile(deploymentGuidePath, "utf8");
  assert.match(guide, /off-host copy/);
  assert.match(guide, /restore drill/);
  assert.match(guide, /--confirm-restore/);
  assert.match(guide, /--confirm-finalize-recovery/);
  assert.match(guide, /registration remains disabled/i);
});
