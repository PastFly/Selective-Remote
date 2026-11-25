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

test("anchored password recovery consumes only the latest retained request", () => {
  const userID = randomUUID(), resetID = randomUUID(), identityID = randomUUID(), sessionID = randomUUID();
  const baseline = { version: 2, type: "V1_BASELINE", baselineID: randomUUID(), vaults: [] };
  const floor = { version: 2, type: "V1_WRITER_FLOOR", writerProtocol: 1 };
  const issued = { version: 2, type: "V1_PASSWORD_RESET_ISSUED", userID, resetID };
  const completed = { version: 2, type: "V1_PASSWORD_RESET_COMPLETED", userID, resetID, identityID, sessionIDs: [sessionID] };
  assert.throws(() => reduceFenceEvents([baseline, floor, completed]), /deployment_fence_conflict/);
  assert.throws(() => reduceFenceEvents([baseline, floor, issued, { ...completed, resetID: randomUUID() }]), /deployment_fence_conflict/);
  assert.throws(() => validateFenceEvent({ ...completed, passwordHash: "synthetic" }), /invalid_deployment_fence/);
  const result = reduceFenceEvents([baseline, floor, issued, completed]);
  assert.equal(result.passwordIdentityIDs[userID], identityID);
  assert.equal(result.passwordResetIDs?.[userID], undefined);
  assert.deepEqual(result.revokedSessionIDs, [sessionID]);
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

test("anchored Personal recovery keeps credential, token and device decisions through failed primary commits", {
  skip: !process.env.TEST_DATABASE_URL || !syntheticHttpAnchorAvailable,
  timeout: 60000,
}, async () => {
  const primaryURL = new URL(process.env.TEST_DATABASE_URL);
  const anchorURL = new URL(process.env.SR_TEST_ANCHOR_TLS_URL);
  assert.notEqual(Number(primaryURL.port || 5432), Number(anchorURL.port || 5432));
  assert.ok(anchorURL.pathname.endsWith("_test"));
  const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
  let journal, independent;
  try {
    const userID = randomUUID(), deviceID = randomUUID(), beforeIdentity = randomUUID();
    const email = "recovery-proof@example.test";
    const beforeHash = "synthetic-before-recovery-hash", freshHash = "synthetic-fresh-recovery-hash";
    await db.pool.query(
      "INSERT INTO users(id,email,username,email_verified_at) VALUES($1,$2,'recovery_proof_test',now())",
      [userID, email],
    );
    await db.pool.query(
      "INSERT INTO account_identities(id,user_id,provider,subject,password_hash) VALUES($1,$2,'password',$3,$4)",
      [beforeIdentity, userID, email, beforeHash],
    );
    await db.pool.query("INSERT INTO personal_vaults(user_id) VALUES($1)", [userID]);

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
    const interrupted = new PostgresStore(null, {
      async connect() {
        const client = await db.pool.connect();
        return {
          query(sql, values) {
            if (sql === "COMMIT") throw new Error("synthetic_commit_failure");
            return client.query(sql, values);
          },
          release() { client.release(); },
        };
      },
    }, { v1Fence: fence });

    const login = (verifiedPasswordHash, id = deviceID, ownerID = userID) => ({
      userID: ownerID, verifiedPasswordHash,
      device: { id, name: "Test Mac", platform: "macos", appVersion: "0.32.6" },
      sessionHash: randomUUID(), expiresAt: new Date(Date.now() + 3600000),
    });
    const request = digit => ({ userID, tokenHash: digit.repeat(64), expiresAt: new Date(Date.now() + 3600000) });
    const consume = digit => ({ userID, tokenHash: digit.repeat(64), passwordHash: freshHash });
    const initial = login(beforeHash);
    await store.createSession(initial);
    assert.equal((await store.session(initial.sessionHash)).device_id, deviceID);

    assert.equal(await store.replacePasswordResetToken(request("1")), true);
    assert.deepEqual(await store.passwordResetIdentity("1".repeat(64)), { user_id: userID });
    await assert.rejects(interrupted.replacePasswordResetToken(request("2")), /synthetic_commit_failure/);
    assert.equal(await store.passwordResetIdentity("1".repeat(64)), null);
    assert.equal(await store.consumePasswordResetToken(consume("1")), false);

    assert.equal(await store.replacePasswordResetToken(request("3")), true);
    await assert.rejects(interrupted.consumePasswordResetToken(consume("3")), /synthetic_commit_failure/);
    const stale = await db.pool.query("SELECT id, password_hash FROM account_identities WHERE user_id = $1", [userID]);
    assert.deepEqual(stale.rows, [{ id: beforeIdentity, password_hash: beforeHash }]);
    assert.equal(await store.passwordResetIdentity("3".repeat(64)), null);
    assert.equal(await store.session(initial.sessionHash), null);
    await assert.rejects(store.createSession(login(beforeHash)), { message: "invalid_credentials" });

    assert.equal(await store.replacePasswordResetToken(request("4")), true);
    assert.equal(await store.consumePasswordResetToken(consume("4")), true);
    const identity = await db.pool.query("SELECT id FROM account_identities WHERE user_id = $1", [userID]);
    assert.equal((await fence.snapshot()).passwordIdentityIDs[userID], identity.rows[0].id);
    const active = login(freshHash);
    await store.createSession(active);
    const session = await store.session(active.sessionHash);
    assert.equal(session.device_id, deviceID);
    assert.deepEqual(await store.putVault(session, {
      baseRevision: 0, envelopeVersion: 1, wrappedKey: {},
      ciphertext: "bmV3", nonce: "bm9uY2U", authTag: "dGFn", contentHash: "aGFzaA",
    }), { conflict: false, revision: 1 });

    await assert.rejects(interrupted.revokeDevice(userID, deviceID), /synthetic_commit_failure/);
    assert.equal(await store.session(active.sessionHash), null);
    await assert.rejects(store.createSession(login(freshHash)), { message: "invalid_device" });
    const replacement = login(freshHash, randomUUID());
    await store.createSession(replacement);
    assert.equal((await store.session(replacement.sessionHash)).device_id, replacement.device.id);

    // Use a disposable account without Vault data to exercise the authorization
    // record independently of the separate V1 Vault deletion policy.
    const otherID = randomUUID();
    await db.pool.query(
      "INSERT INTO users(id,email,username,email_verified_at) VALUES($1,'delete-proof@example.test','delete_proof_test',now())",
      [otherID],
    );
    await db.pool.query(
      "INSERT INTO account_identities(user_id,provider,subject,password_hash) VALUES($1,'password','delete-proof@example.test',$2)",
      [otherID, beforeHash],
    );
    await assert.rejects(interrupted.deleteAccount(otherID), /synthetic_commit_failure/);
    assert.ok((await fence.snapshot()).revokedAccountIDs.includes(otherID));
    await assert.rejects(store.createSession(login(beforeHash, randomUUID(), otherID)), { message: "invalid_credentials" });
  } finally {
    await independent?.cleanup();
    await journal?.cleanup();
    await db.cleanup();
  }
});
