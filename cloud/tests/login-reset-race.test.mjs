import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, writeFile, access, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';
import { isolatedPublicationDatabase, publicationRuntimeFixture, stopPublicationRuntime } from './publication-runtime-fixture.mjs';
import { syntheticHttpAnchor, syntheticHttpAnchorAvailable } from './synthetic-http-anchor-fixture.mjs';
import { PostgresStore } from '../src/postgres-store.mjs';
import { CloudService } from '../src/service.mjs';
import { hashPassword, verifyPassword, hashPasswordResetToken } from '../src/security.mjs';
import { installV1CommitFence } from '../src/v1-commit-fence.mjs';
import { readV1VaultState } from '../src/v1-data-fence.mjs';

const databaseURL = process.env.TEST_DATABASE_URL;
const oldPassword = 'old synthetic password';
const newPassword = 'new synthetic password';
const resetToken = 'z'.repeat(43);
const config = { sessionPepper: 's'.repeat(32), passwordResetTokenPepper: 'p'.repeat(32), sessionTTLDays: 30 };

async function seed(pool) {
  const userID = randomUUID(), deviceID = randomUUID(), email = 'race@example.test';
  const passwordHash = await hashPassword(oldPassword);
  await pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,$2,'race_user',now())", [userID, email]);
  await pool.query("INSERT INTO account_identities(user_id,provider,subject,password_hash) VALUES($1,'password',$2,$3)", [userID, email, passwordHash]);
  await pool.query("INSERT INTO password_reset_tokens(user_id,token_hash,expires_at) VALUES($1,$2,now()+interval '1 hour')", [userID, hashPasswordResetToken(resetToken, config.passwordResetTokenPepper)]);
  return { userID, passwordHash, login: { email, password: oldPassword, device: { id: deviceID, name: 'Synthetic', platform: 'test' } } };
}

test('a password reset completing during verification rejects the stale login', { skip: !databaseURL, timeout: 30000 }, async () => {
  const db = await isolatedPublicationDatabase(databaseURL);
  try {
    const { userID, login } = await seed(db.pool);
    let resume, entered;
    const paused = new Promise(resolve => { resume = resolve; });
    const reached = new Promise(resolve => { entered = resolve; });
    const store = new PostgresStore(null, db.pool);
    const service = new CloudService(store, config, null, console, async (password, hash) => {
      const valid = await verifyPassword(password, hash);
      entered();
      await paused;
      return valid;
    });
    const attempt = service.login(login);
    await reached;
    try { assert.deepEqual(await service.resetPassword({ token: resetToken, password: newPassword }), { reset: true }); }
    finally { resume(); }
    await assert.rejects(attempt, { message: 'invalid_credentials' });
    assert.equal(Number((await db.pool.query('SELECT count(*) FROM sessions WHERE user_id=$1', [userID])).rows[0].count), 0);
  } finally { await db.cleanup(); }
});

test('a reset queued behind session creation revokes that session', { skip: !databaseURL, timeout: 30000 }, async () => {
  const db = await isolatedPublicationDatabase(databaseURL);
  let releaseInsert;
  try {
    const { login } = await seed(db.pool);
    let inserted, resetAtUpdate;
    const paused = new Promise(resolve => { releaseInsert = resolve; });
    const reached = new Promise(resolve => { inserted = resolve; });
    const resetReached = new Promise(resolve => { resetAtUpdate = resolve; });
    const pool = {
      query: (...args) => db.pool.query(...args),
      async connect() {
        const client = await db.pool.connect();
        return {
          async query(sql, values) {
            if (sql.includes('UPDATE account_identities SET password_hash')) resetAtUpdate();
            const result = await client.query(sql, values);
            if (sql.includes('INSERT INTO sessions')) { inserted(); await paused; }
            return result;
          },
          release: () => client.release(),
        };
      },
    };
    const service = new CloudService(new PostgresStore(null, pool), config);
    const loginAttempt = service.login(login);
    await reached;
    const resetAttempt = service.resetPassword({ token: resetToken, password: newPassword });
    await resetReached;
    // A completed reset here would leave the yet-uncommitted session outside
    // its UPDATE, allowing that session to survive the password change.
    assert.equal(await Promise.race([resetAttempt.then(() => 'done'), new Promise(r => setTimeout(() => r('blocked'), 500))]), 'blocked');
    releaseInsert();
    const issued = await loginAttempt;
    assert.deepEqual(await resetAttempt, { reset: true });
    assert.equal(await service.authenticate(issued.token), null);
  } finally {
    releaseInsert?.();
    await db.cleanup();
  }
});

test('a revoked device cannot obtain an in-flight session', { skip: !databaseURL, timeout: 30000 }, async () => {
  const db = await isolatedPublicationDatabase(databaseURL);
  try {
    const { userID, login } = await seed(db.pool);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'Synthetic','test')", [login.device.id, userID]);
    let resume, entered;
    const paused = new Promise(resolve => { resume = resolve; });
    const reached = new Promise(resolve => { entered = resolve; });
    const store = new PostgresStore(null, db.pool);
    const service = new CloudService(store, config, null, console, async (password, hash) => {
      const valid = await verifyPassword(password, hash); entered(); await paused; return valid;
    });
    const attempt = service.login(login);
    await reached;
    try { assert.equal(await store.revokeDevice(userID, login.device.id), true); }
    finally { resume(); }
    await assert.rejects(attempt, { message: 'invalid_device' });
    assert.equal(Number((await db.pool.query('SELECT count(*) FROM sessions WHERE user_id=$1', [userID])).rows[0].count), 0);
  } finally { await db.cleanup(); }
});

test('a device revocation queued behind session creation revokes that session', { skip: !databaseURL, timeout: 30000 }, async () => {
  const db = await isolatedPublicationDatabase(databaseURL);
  let releaseInsert;
  try {
    const { userID, login } = await seed(db.pool);
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'Synthetic','test')", [login.device.id, userID]);
    let inserted, revocationAtUpdate;
    const paused = new Promise(resolve => { releaseInsert = resolve; });
    const reached = new Promise(resolve => { inserted = resolve; });
    const revocationReached = new Promise(resolve => { revocationAtUpdate = resolve; });
    const pool = {
      query: (...args) => db.pool.query(...args),
      async connect() {
        const client = await db.pool.connect();
        return {
          async query(sql, values) {
            if (sql.includes('UPDATE devices SET revoked_at')) revocationAtUpdate();
            const result = await client.query(sql, values);
            if (sql.includes('INSERT INTO sessions')) { inserted(); await paused; }
            return result;
          },
          release: () => client.release(),
        };
      },
    };
    const store = new PostgresStore(null, pool);
    const service = new CloudService(store, config);
    const attempt = service.login(login);
    await reached;
    const revocation = store.revokeDevice(userID, login.device.id);
    await revocationReached;
    assert.equal(await Promise.race([revocation.then(() => 'done'), new Promise(r => setTimeout(() => r('blocked'), 500))]), 'blocked');
    releaseInsert();
    const issued = await attempt;
    assert.equal(await revocation, true);
    assert.equal(await service.authenticate(issued.token), null);
  } finally {
    releaseInsert?.();
    await db.cleanup();
  }
});

test('account deletion waits for in-flight session creation without deadlocking', { skip: !databaseURL, timeout: 30000 }, async () => {
  const db = await isolatedPublicationDatabase(databaseURL);
  let releaseInsert;
  try {
    const { userID, login } = await seed(db.pool);
    let inserted, deletionAtLock;
    const paused = new Promise(resolve => { releaseInsert = resolve; });
    const reached = new Promise(resolve => { inserted = resolve; });
    const deletionReached = new Promise(resolve => { deletionAtLock = resolve; });
    const pool = {
      query: (...args) => db.pool.query(...args),
      async connect() {
        const client = await db.pool.connect();
        return {
          async query(sql, values) {
            if (sql.includes('SELECT id FROM users WHERE id = $1 AND disabled_at IS NULL FOR UPDATE')) deletionAtLock();
            const result = await client.query(sql, values);
            if (sql.includes('INSERT INTO sessions')) { inserted(); await paused; }
            return result;
          },
          release: () => client.release(),
        };
      },
    };
    const store = new PostgresStore(null, pool), service = new CloudService(store, config);
    const attempt = service.login(login);
    await reached;
    const deletion = store.deleteAccount(userID);
    await deletionReached;
    assert.equal(await Promise.race([deletion.then(() => 'done'), new Promise(r => setTimeout(() => r('blocked'), 500))]), 'blocked');
    releaseInsert();
    const issued = await attempt;
    assert.deepEqual(await deletion, { deleted: true });
    assert.equal(await service.authenticate(issued.token), null);
  } finally {
    releaseInsert?.();
    await db.cleanup();
  }
});

test('HTTP rejects a reset-raced login without logging password hashes', { skip: !databaseURL || !syntheticHttpAnchorAvailable, timeout: 60000 }, async () => {
  const db = await isolatedPublicationDatabase(databaseURL);
  const directory = await mkdtemp(join(tmpdir(), 'sr-login-reset-http-'));
  let fixture, anchor, runtime, output = '';
  try {
    const { userID, passwordHash, login } = await seed(db.pool);
    fixture = await publicationRuntimeFixture(db.databaseURL);
    anchor = await syntheticHttpAnchor(fixture.path);
    await installV1CommitFence(db.pool);
    await anchor.fence.append({ version: 2, type: 'V1_BASELINE', baselineID: randomUUID(), vaults: await readV1VaultState((sql, values) => db.pool.query(sql, values)) });
    await anchor.fence.append({ version: 2, type: 'V1_WRITER_FLOOR', writerProtocol: 1 });
    // Test-only barrier immediately before the real createSession call: the
    // server, password verifier, reset endpoint, PostgreSQL and anchor are real.
    const hook = join(directory, 'hook.mjs');
    await writeFile(hook, `import { writeFile, access } from 'node:fs/promises';\nimport { setTimeout as delay } from 'node:timers/promises';\nimport { PostgresStore } from ${JSON.stringify(new URL('../src/postgres-store.mjs', import.meta.url).href)};\nconst original=PostgresStore.prototype.createSession;\nPostgresStore.prototype.createSession=async function(input){await writeFile(process.env.SR_TEST_HOOK_DIR+'/entered','');for(let i=0;i<600;i++){try{await access(process.env.SR_TEST_HOOK_DIR+'/resume');return original.call(this,input)}catch(error){if(error.code!=='ENOENT')throw error;await delay(50)}}throw Error('test_hook_timeout')};\n`);
    const sock = createServer();
    await new Promise(resolve => sock.listen(0, '127.0.0.1', resolve));
    const port = sock.address().port;
    await new Promise(resolve => sock.close(resolve));
    const origin = `http://127.0.0.1:${port}`;
    const child = spawn(process.execPath, ['--import', hook, 'src/server.mjs'], {
      cwd: fileURLToPath(new URL('../', import.meta.url)), stdio: ['ignore', 'pipe', 'pipe'],
      env: { PATH: process.env.PATH, USER: process.env.USER, DATABASE_URL: db.databaseURL, CLOUD_HOST: '127.0.0.1', CLOUD_PORT: String(port), CLOUD_PUBLIC_ORIGIN: origin,
        SESSION_TOKEN_PEPPER: config.sessionPepper, EMAIL_VERIFICATION_TOKEN_PEPPER: 'e'.repeat(32), PASSWORD_RESET_TOKEN_PEPPER: config.passwordResetTokenPepper,
        TEAM_INVITATION_TOKEN_PEPPER: 'i'.repeat(32), TEAM_OUTBOX_ENCRYPTION_KEY: 'o'.repeat(32), ABUSE_TOKEN_PEPPER: 'a'.repeat(32),
        PROXY_SHARED_SECRET: 'b'.repeat(64), PUBLICATION_FENCE_PATH: fixture.path, SR_TEST_HOOK_DIR: directory, ...anchor.env },
    });
    runtime = { child };
    for (const stream of [child.stdout, child.stderr]) stream.on('data', chunk => { output += chunk.toString(); });
    let ready = false;
    for (let i = 0; i < 100; i++) {
      if (child.exitCode !== null) throw Error('test_cloud_start_failed');
      try { if ((await fetch(origin + '/readyz')).ok) { ready = true; break; } } catch {}
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.equal(ready, true);
    const post = (path, body) => fetch(origin + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
    const loginRequest = post('/v1/auth/login', login);
    let entered = false;
    for (let i = 0; i < 200; i++) {
      try { await access(join(directory, 'entered')); entered = true; break; } catch {}
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    assert.equal(entered, true);
    const reset = await post('/v1/auth/reset-password', { token: resetToken, password: newPassword });
    assert.equal(reset.status, 200);
    await writeFile(join(directory, 'resume'), '');
    const response = await loginRequest;
    assert.equal(response.status, 401);
    assert.deepEqual(await response.json(), { error: 'invalid_credentials' });
    assert.equal(Number((await db.pool.query('SELECT count(*) FROM sessions WHERE user_id=$1', [userID])).rows[0].count), 0);
    const newHash = (await db.pool.query("SELECT password_hash FROM account_identities WHERE user_id=$1 AND provider='password'", [userID])).rows[0].password_hash;
    await stopPublicationRuntime(runtime); runtime = null;
    assert.equal(output.includes(passwordHash), false);
    assert.equal(output.includes(newHash), false);
    assert.equal(output.includes(oldPassword), false);
    assert.equal(output.includes(newPassword), false);
  } finally {
    await writeFile(join(directory, 'resume'), '').catch(() => {});
    await stopPublicationRuntime(runtime);
    await anchor?.cleanup(); await fixture?.cleanup(); await db.cleanup();
    await rm(directory, { recursive: true, force: true });
  }
});
