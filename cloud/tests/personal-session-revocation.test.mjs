import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";
import { createConfiguredMigrationFence } from "../src/configured-migration-fence.mjs";
import { loadFenceAnchorConfig } from "../src/fence-anchor-config.mjs";
import { reduceFenceEvents, validateFenceEvent } from "../src/migration-fence-journal.mjs";
import { PostgresStore } from "../src/postgres-store.mjs";
import { installV1CommitFence } from "../src/v1-commit-fence.mjs";
import { readV1VaultState } from "../src/v1-data-fence.mjs";
import { isolatedPublicationDatabase, publicationRuntimeFixture } from "./publication-runtime-fixture.mjs";
import { syntheticHttpAnchor, syntheticHttpAnchorAvailable } from "./synthetic-http-anchor-fixture.mjs";

test("Personal session revocations require an armed journal and carry no credentials", () => {
  const revoked = { version: 2, type: "V1_SESSION_REVOKED", sessionID: randomUUID() };
  const baseline = { version: 2, type: "V1_BASELINE", baselineID: randomUUID(), vaults: [] };
  const floor = { version: 2, type: "V1_WRITER_FLOOR", writerProtocol: 1 };
  assert.throws(() => validateFenceEvent({ ...revoked, token: "fixture" }), /invalid_deployment_fence/);
  assert.throws(() => reduceFenceEvents([baseline, revoked]), /deployment_fence_conflict/);
  assert.deepEqual(reduceFenceEvents([baseline, floor, revoked, revoked]).revokedSessionIDs, [revoked.sessionID]);
});

test("Personal logout denial survives a failed primary update and is read from the independent anchor", {
  skip: !process.env.TEST_DATABASE_URL || !syntheticHttpAnchorAvailable,
  timeout: 60000,
}, async () => {
  const primaryURL = new URL(process.env.TEST_DATABASE_URL);
  const anchorURL = new URL(process.env.SR_TEST_ANCHOR_TLS_URL);
  assert.notEqual(Number(primaryURL.port || 5432), Number(anchorURL.port || 5432));
  assert.ok(anchorURL.pathname.endsWith("_test"));
  const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  let journal, independent, reopened;
  try {
    const userID = randomUUID(), deviceID = randomUUID();
    await db.pool.query(
      "INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'logout-proof@example.test','logout_proof_test',now())",
      [userID],
    );
    await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'test','macos')", [deviceID, userID]);
    await db.pool.query("INSERT INTO personal_vaults(user_id) VALUES($1)", [userID]);
    const sessions = await Promise.all([0, 1].map(async () => {
      const id = randomUUID(), tokenHash = randomUUID();
      await db.pool.query(
        "INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 day')",
        [id, userID, deviceID, tokenHash],
      );
      return { id, tokenHash };
    }));
    const [loggedOut, active] = sessions;

    journal = await publicationRuntimeFixture(db.databaseURL);
    independent = await syntheticHttpAnchor(journal.path);
    const fence = independent.fence;
    await installV1CommitFence(db.pool);
    await fence.append({
      version: 2, type: "V1_BASELINE", baselineID: randomUUID(),
      vaults: await readV1VaultState(db.pool.query.bind(db.pool)),
    });
    await fence.append({ version: 2, type: "V1_WRITER_FLOOR", writerProtocol: 1 });
    const store = new PostgresStore(null, db.pool, { v1Fence: fence });
    const originalSession = await store.session(loggedOut.tokenHash);
    assert.equal(originalSession.session_id, loggedOut.id);
    const originalHead = await fence.anchor.read();

    const unavailablePrimary = {
      async connect() {
        const client = await db.pool.connect();
        return {
          query(sql, values) {
            if (sql.startsWith("UPDATE sessions SET revoked_at")) throw new Error("synthetic_primary_update_failure");
            return client.query(sql, values);
          },
          release() { client.release(); },
        };
      },
    };
    const interrupted = new PostgresStore(null, unavailablePrimary, { v1Fence: fence });
    await assert.rejects(interrupted.revokeSession(loggedOut.id), /synthetic_primary_update_failure/);
    const { rows } = await db.pool.query("SELECT revoked_at FROM sessions WHERE id = $1", [loggedOut.id]);
    assert.equal(rows[0].revoked_at, null);
    const afterLogout = await fence.anchor.read();
    assert.equal(afterLogout.position, originalHead.position + 1);

    const config = loadFenceAnchorConfig(independent.env, db.databaseURL);
    reopened = createConfiguredMigrationFence({ fencePath: journal.path, anchor: config });
    const restartedStore = new PostgresStore(null, db.pool, { v1Fence: reopened.fence });
    assert.deepEqual(await reopened.fence.anchor.read(), afterLogout);
    assert.deepEqual((await reopened.fence.snapshot()).revokedSessionIDs, [loggedOut.id]);
    assert.equal(await restartedStore.session(loggedOut.tokenHash), null);
    const envelope = {
      baseRevision: 0, envelopeVersion: 1, wrappedKey: {},
      ciphertext: "bmV3", nonce: "bm9uY2U", authTag: "dGFn", contentHash: "aGFzaA",
    };
    await assert.rejects(restartedStore.putVault(originalSession, envelope), { message: "unauthorized" });
    assert.equal(Number((await restartedStore.getVault(userID)).revision), 0);
    await restartedStore.revokeSession(loggedOut.id);
    assert.deepEqual(await reopened.fence.anchor.read(), afterLogout);
    const current = await restartedStore.session(active.tokenHash);
    assert.equal(current.session_id, active.id);
    assert.deepEqual(await restartedStore.putVault(current, envelope), { conflict: false, revision: 1 });
  } finally {
    await reopened?.close();
    await independent?.cleanup();
    await journal?.cleanup();
    await db.cleanup();
  }
});
