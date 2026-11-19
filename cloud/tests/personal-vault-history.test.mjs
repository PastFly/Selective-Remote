import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { PostgresStore } from '../src/postgres-store.mjs';
import { CloudService } from '../src/service.mjs';
import { isolatedPublicationDatabase } from './publication-runtime-fixture.mjs';

test('Personal Vault history is scoped to the session account and optionally the writing device', {
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
      `INSERT INTO vault_revisions(vault_id,revision,envelope_version,wrapped_key,ciphertext,nonce,auth_tag,content_hash,updated_by_device_id)
       VALUES($1,5,1,'{}','Y2lwaGVydGV4dA','bm9uY2U','dGFn','aGFzaA',$2)`,
      [vault, writer],
    );
    const service = new CloudService(new PostgresStore(null, db.pool), {});
    const readAs = (user_id, device_id, thisDevice) =>
      service.getVaultRevision({ user_id, device_id }, 5, thisDevice);
    const result = await readAs(owner, writer, true);
    assert.equal(result.revision, 5);
    assert.equal(result.id, vault);
    assert.equal(result.ciphertext, 'Y2lwaGVydGV4dA');
    assert.deepEqual(await readAs(owner, reader, false), result);
    assert.equal(await readAs(owner, reader, true), null);
    assert.equal(await readAs(other, otherDevice, false), null);
  } finally {
    await db.cleanup();
  }
});
