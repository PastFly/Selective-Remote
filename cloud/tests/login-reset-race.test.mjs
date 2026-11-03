import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { isolatedPublicationDatabase } from './publication-runtime-fixture.mjs';
import { PostgresStore } from '../src/postgres-store.mjs';
import { CloudService } from '../src/service.mjs';
import { hashPassword, verifyPassword, hashPasswordResetToken } from '../src/security.mjs';

const databaseURL = process.env.TEST_DATABASE_URL;
const oldPassword = 'old synthetic password';
const newPassword = 'new synthetic password';
const resetToken = 'z'.repeat(43);
const config = { sessionPepper: 's'.repeat(32), passwordResetTokenPepper: 'p'.repeat(32), sessionTTLDays: 30 };

async function seed(pool) {
  const userID = randomUUID(), deviceID = randomUUID(), email = 'race@example.test';
  await pool.query("INSERT INTO users(id,email,username,email_verified_at) VALUES($1,$2,'race_user',now())", [userID, email]);
  await pool.query("INSERT INTO account_identities(user_id,provider,subject,password_hash) VALUES($1,'password',$2,$3)", [userID, email, await hashPassword(oldPassword)]);
  await pool.query("INSERT INTO password_reset_tokens(user_id,token_hash,expires_at) VALUES($1,$2,now()+interval '1 hour')", [userID, hashPasswordResetToken(resetToken, config.passwordResetTokenPepper)]);
  return { userID, login: { email, password: oldPassword, device: { id: deviceID, name: 'Synthetic', platform: 'test' } } };
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
