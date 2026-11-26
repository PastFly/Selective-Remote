import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';
import { decryptVaultEnvelope, encryptVaultPayload, generateVaultKey, wrapVaultKey } from '../public/vault-crypto.js';
import { productionPilotOpened } from '../src/migration-fence-journal.mjs';

const run = promisify(execFile);

// Run on the TLS registration fixture after both accounts have confirmed email.
// Each operator invocation is a separate process using the same independent anchor.
export async function verifyProductionPersonalPilot({ cwd, production, startServer, fetchValue, call, tokens, fence, db, ownerID, vaultID, teamPath }) {
  const enabled = { ...production, CLOUD_PRODUCTION_PERSONAL_PILOT_ENABLED:'true' };
  const operator = (env, ...args) => run(process.execPath, ['scripts/production-personal-vault-pilot.mjs', ...args],
    { cwd, env, timeout:20_000, encoding:'utf8' });
  const pilotID = randomUUID();
  const openArgs = ['open', pilotID, ownerID, vaultID, '2'];
  const admission = '/v1/vault/write-availability';
  const secondVault = await (await call(tokens[1], '/v1/vault')).json();
  await assert.rejects(operator(production, ...openArgs), error => error.stderr.trim() === 'personal_pilot_environment_unavailable');
  await assert.rejects(operator(enabled, 'open', pilotID, ownerID, secondVault.id, '1'), error => error.stderr.trim() === 'personal_pilot_scope_unavailable');
  await startServer(enabled);
  assert.equal((await call(tokens[0], admission)).status, 503);
  await Promise.all([operator(enabled, ...openArgs), operator(enabled, ...openArgs)]);
  const initial = (await fence.snapshot()).personalWritePilot;
  assert.equal(initial.type, productionPilotOpened);
  assert.equal(initial.pilotID, pilotID);
  await assert.rejects(operator(enabled, 'open', pilotID, ownerID, vaultID, '3'), error => error.stderr.trim() === 'personal_pilot_already_open');
  assert.deepEqual((await fence.snapshot()).personalWritePilot, initial);
  const meta = await fetchValue('/v1/meta');
  assert.equal(meta.headers.get('x-selective-personal-vault-write-status'), 'pilot');
  assert.equal((await meta.json()).registrationEnabled, true);
  assert.equal((await fetchValue(admission)).status, 401);
  assert.equal((await call(tokens[0], admission)).status, 204);
  assert.equal((await call(tokens[1], admission)).status, 503);
  assert.equal((await call(tokens[1], teamPath + '/members')).status, 200);

  const vaultKey = await generateVaultKey();
  const wrappedKey = await wrapVaultKey(vaultKey, randomUUID() + randomUUID());
  const payload = { schemaVersion:1, records:[{id:randomUUID(), type:'host', title:'Synthetic scoped write'}], tombstones:[] };
  const envelope = await encryptVaultPayload({vaultKey, payload, baseRevision:0, wrappedKey});
  const write = token => call(token, '/v1/vault', 'PUT', {protocol:'framed-v1', envelope});
  assert.equal((await write(tokens[1])).status, 503);
  assert.equal((await write(tokens[0])).status, 200);
  assert.equal((await write(tokens[0])).status, 409);
  await startServer(enabled);
  const stored = await (await call(tokens[0], '/v1/vault')).json();
  assert.equal(stored.revision, 1);
  assert.deepEqual(await decryptVaultEnvelope(vaultKey, stored), payload);
  const receipts = await fence.readRecords();
  assert.equal(receipts.filter(row => row.type === productionPilotOpened && row.pilotID === pilotID).length, 1);
  assert.equal(receipts.filter(row => row.type === 'V1_PENDING_INTENT' && row.pilotID === pilotID).length, 1);
  await startServer(production);
  assert.equal((await call(tokens[0], admission)).status, 503);
  assert.equal((await write(tokens[0])).status, 503);
  // A disabled/rollback runtime must still be able to explicitly close.
  await operator(production, 'close', pilotID);
  await operator(production, 'close', pilotID);
  await assert.rejects(operator(enabled, ...openArgs), error => error.stderr.trim() === 'deployment_fence_conflict');
  await startServer(enabled);
  assert.equal((await call(tokens[0], admission)).status, 503);
  assert.equal((await write(tokens[0])).status, 503);

  // A retained expiry may be older than either process on a restart.
  const expiredID = randomUUID(), expiresAt = Date.now() - 1;
  await fence.append({version:2, type:productionPilotOpened, pilotID:expiredID, ownerID, vaultID,
    issuedAt:expiresAt - 60_000, expiresAt});
  assert.equal((await call(tokens[0], admission)).status, 503);
  assert.equal((await write(tokens[0])).status, 503);
  await operator(production, 'close', expiredID);
  // The request passes HTTP preflight, then waits for the actual Vault row.
  // Expiry and a concurrent close must prevent that request committing.
  const racing = randomUUID(), deadline = Date.now() + 3000;
  await fence.append({version:2, type:productionPilotOpened, pilotID:racing, ownerID, vaultID,
    issuedAt:deadline - 60_000, expiresAt:deadline});
  const occupied = await db.pool.connect();
  let pendingWrite, pendingClose;
  try {
    await occupied.query('BEGIN');
    await occupied.query('SELECT id FROM personal_vaults WHERE id = $1 FOR UPDATE', [vaultID]);
    pendingWrite = write(tokens[0]);
    let waiting = false;
    while (Date.now() < deadline) {
      const waitingWriter = await db.pool.query(`SELECT 1 FROM pg_stat_activity WHERE datname = current_database()
        AND wait_event_type = 'Lock' AND query LIKE 'SELECT id, revision FROM personal_vaults%'`);
      if (waitingWriter.rowCount) { waiting = true; break; }
      await delay(15);
    }
    assert.ok(waiting, 'owner reached the guarded row lock before expiry');
    pendingClose = operator(production, 'close', racing);
    await delay(Math.max(0, deadline - Date.now() + 5));
  } finally {
    await occupied.query('ROLLBACK');
    occupied.release();
  }
  assert.equal((await pendingWrite).status, 503);
  await pendingClose;
  const after = await fence.snapshot();
  assert.equal(after.personalWritePilot, undefined);
  assert.equal(after.v1Pending.length, 0);
  assert.equal(after.v1Committed.find(vault => vault.vaultID === vaultID).revision, 1);
  assert.equal(after.v1Committed.find(vault => vault.vaultID === secondVault.id).revision, 0);
}
