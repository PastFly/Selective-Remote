import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { PostgresStore } from '../src/postgres-store.mjs';
import { CloudService } from '../src/service.mjs';
import { isolatedPublicationDatabase } from './publication-runtime-fixture.mjs';

test('Device-specific recovery waits for independently verified revision provenance', async () => {
  const calls = [];
  const row = { id: 'synthetic-vault', revision: 5 };
  const service = new CloudService({
    async getVaultRevision(...args) { calls.push(args); return row; },
  }, {});
  const session = { user_id: 'synthetic-owner', device_id: 'synthetic-device' };

  assert.equal(await service.getVaultRevision(session, 5, true), null);
  assert.deepEqual(calls, []);
  assert.equal((await service.getVaultRevision(session, 5, false)).revision, 5);
  assert.deepEqual(calls, [[session.user_id, 5]]);
});

test('Personal Vault history is scoped to the session account and the current Vault head', {
  skip: !process.env.TEST_DATABASE_URL,
}, async () => {
  const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  try {
    const owner = randomUUID(), other = randomUUID();
    const writer = randomUUID(), reader = randomUUID(), otherDevice = randomUUID();
    await db.pool.query(
      "INSERT INTO users(id,email,username) VALUES($1,'history-owner@example.test','history_owner'),($2,'history-other@example.test','history_other')",
      [owner, other],
    );
    await db.pool.query(
      "INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'writer','macos'),($3,$2,'reader','web'),($4,$5,'other','macos')",
      [writer, owner, reader, otherDevice, other],
    );
    const vault = (await db.pool.query(
      "INSERT INTO personal_vaults(user_id) VALUES($1),($2) RETURNING id",
      [owner, other],
    )).rows[0].id;
    await db.pool.query(
      `UPDATE personal_vaults SET revision=5,wrapped_key='{}',ciphertext='Y2lwaGVydGV4dA',
         nonce='bm9uY2U',auth_tag='dGFn',content_hash='aGFzaA',updated_by_device_id=$2
       WHERE id=$1`, [vault, writer],
    );
    await db.pool.query(
      `INSERT INTO vault_revisions(vault_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash,updated_by_device_id)
       VALUES($1,4,1,'{}','Y2lwaGVydGV4dA','bm9uY2U','dGFn','aGFzaA',$2),
             ($1,5,1,'{}','Y2lwaGVydGV4dA','bm9uY2U','dGFn','aGFzaA',$2),
             ($1,6,1,'{}','Y2lwaGVydGV4dA','bm9uY2U','dGFn','aGFzaA',$2)`,
      [vault, writer],
    );
    const service = new CloudService(new PostgresStore(null, db.pool), {});
    const readAs = (user_id, device_id, revision, thisDevice = false) =>
      service.getVaultRevision({ user_id, device_id }, revision, thisDevice);
    const result = await readAs(owner, writer, 5);
    assert.equal(result.revision, 5);
    assert.equal(result.id, vault);
    assert.equal(result.ciphertext, 'Y2lwaGVydGV4dA');
    assert.deepEqual(await readAs(owner, reader, 5), result);
    assert.equal((await readAs(owner, reader, 4)).revision, 4);
    assert.equal(await readAs(owner, writer, 6), null);
    assert.equal(await readAs(owner, writer, 5, true), null);
    assert.equal(await readAs(other, otherDevice, 5), null);
  } finally {
    await db.cleanup();
  }
});
