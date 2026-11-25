import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import test from "node:test";
import { currentCapabilities, verifyDeploymentCompatibility } from "../src/deployment-compatibility.mjs";
import { PostgresStore } from "../src/postgres-store.mjs";
import { PublicationFenceCoordinator, readCommittedV1Outcome } from "../src/publication-fence-coordinator.mjs";
import { installV1CommitFence } from "../src/v1-commit-fence.mjs";
import { readV1VaultState } from "../src/v1-data-fence.mjs";
import {
    holdV1TeamAuthorizationFence, installV1TeamAuthorizationFence,
    readCommittedV1TeamAuthorizationOutcome, readV1TeamAuthorizationDigest,
} from "../src/v1-team-authorization.mjs";
import { isolatedPublicationDatabase, publicationRuntimeFixture } from "./publication-runtime-fixture.mjs";
import { syntheticHttpAnchor, syntheticHttpAnchorAvailable } from "./synthetic-http-anchor-fixture.mjs";

const exec = promisify(execFile);

test("the retained Team authorization state refuses a PostgreSQL restore from before a role reduction", {
    skip: !process.env.TEST_DATABASE_URL || !syntheticHttpAnchorAvailable,
    timeout: 60000,
}, async () => {
    const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
    const directory = await mkdtemp(join(tmpdir(), "sr-team-authorization-restore-"));
    let runtime, anchor, restored;
    try {
        const owner = randomUUID(), member = randomUUID(), team = randomUUID(), device = randomUUID();
        await db.pool.query(`INSERT INTO users(id,email,username,email_verified_at)
            VALUES($1,'team-auth-owner@example.test','team_auth_owner',now()),
            ($2,'team-auth-member@example.test','team_auth_member',now())`, [owner, member]);
        await db.pool.query("INSERT INTO devices(id,user_id,name,platform) VALUES($1,$2,'synthetic','web')", [device, member]);
        await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'Synthetic authorization team',$2)", [team, owner]);
        const membership = randomUUID();
        await db.pool.query(`INSERT INTO team_memberships(team_id,user_id,role)
            VALUES($1,$2,'owner')`, [team, owner]);
        await db.pool.query(`INSERT INTO team_memberships(id,team_id,user_id,role)
            VALUES($1,$2,$3,'editor')`, [membership, team, member]);

        const legacyStore = new PostgresStore(db.databaseURL, db.pool, {
            v1Fence: { anchor: {}, snapshot: async () => { throw new Error("deployment_fence_locked"); } },
        });
        assert.equal(await legacyStore.updateUsername(member, "team_auth_legacy_member"), "team_auth_legacy_member");
        assert.equal(await legacyStore.consumeEmailVerificationToken(randomBytes(32).toString("hex")), null);

        runtime = await publicationRuntimeFixture(db.databaseURL);
        anchor = await syntheticHttpAnchor(runtime.path);
        const { fence } = anchor;
        const query = (sql, params) => db.pool.query(sql, params);
        const verifiedCandidate = { ...currentCapabilities, v1TeamAuthorizationProtocol: 1 };
        await installV1CommitFence(db.pool);
        await fence.append({ version: 2, type: "V1_BASELINE", baselineID: randomUUID(), vaults: await readV1VaultState(query) });
        await fence.append({ version: 2, type: "V1_WRITER_FLOOR", writerProtocol: 1 });
        const baseline = await readV1TeamAuthorizationDigest(query);
        await installV1TeamAuthorizationFence(db.pool);
        await db.pool.query("UPDATE devices SET last_seen_at=last_seen_at+interval '10 seconds' WHERE id=$1", [device]);
        assert.equal(await readV1TeamAuthorizationDigest(query), baseline);
        await fence.append({ version: 2, type: "V1_TEAM_AUTHORIZATION_BASELINE", authorizationProtocol: 1, digest: baseline });
        const { v1TeamAuthorizationProtocol: _older, ...oldCandidate } = verifiedCandidate;
        await assert.rejects(verifyDeploymentCompatibility({ fence, query: () => assert.fail("old candidate reached SQL"), candidate: oldCandidate }), /deployment_code_floor/u);
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate })).compatible, true);

        const archive = join(directory, "before-team-role-change.dump");
        await exec("pg_dump", ["--format=custom", "--no-owner", "--no-acl", "--file", archive, db.databaseURL]);
        await assert.rejects(
            db.pool.query("UPDATE team_memberships SET role='viewer' WHERE team_id=$1 AND user_id=$2", [team, member]),
            /v1_team_authorization_writer_required/u,
        );
        await assert.rejects(db.pool.query("TRUNCATE team_memberships CASCADE"), /v1_team_authorization_writer_required/u);
        const store = new PostgresStore(db.databaseURL, db.pool, { v1Fence: fence, retainTeamAuthorization: true });
        const change = { actorUserID: owner, teamID: team, membershipID: membership, idempotencyKey: randomUUID(), role: "viewer" };
        const result = await store.updateTeamMembershipRole(change);
        assert.equal(result.membership.role, "viewer");
        const roleChanged = await fence.snapshot();
        assert.equal(roleChanged.v1TeamAuthorizationOutcomes.length, 1);
        assert.equal(roleChanged.v1TeamAuthorizationOutcomes[0].type, "V1_TEAM_AUTHORIZATION_CONFIRMED");
        assert.equal((await store.updateTeamMembershipRole(change)).membership.role, "viewer");
        assert.deepEqual((await fence.snapshot()).v1TeamAuthorizationOutcomes, roleChanged.v1TeamAuthorizationOutcomes);
        const updated = await readV1TeamAuthorizationDigest(query);
        assert.notEqual(updated, baseline);
        assert.equal(roleChanged.v1TeamAuthorization.digest, updated);
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate })).compatible, true);

        restored = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
        await exec("pg_restore", ["--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl", "--dbname", restored.databaseURL, archive]);
        const restoredQuery = (sql, params) => restored.pool.query(sql, params);
        assert.equal(await readV1TeamAuthorizationDigest(restoredQuery), baseline);
        await assert.rejects(
            verifyDeploymentCompatibility({ fence, query: restoredQuery, candidate: verifiedCandidate }),
            /deployment_team_authorization_mismatch/u,
        );

        const promoted = await store.updateTeamMembershipRole({ ...change, idempotencyKey: randomUUID(), role: "editor" });
        assert.equal(promoted.membership.role, "editor");
        await assert.rejects(
            verifyDeploymentCompatibility({ fence, query: restoredQuery, candidate: verifiedCandidate }),
            /deployment_team_authorization_mismatch/u,
        );
        assert.equal((await store.updateTeamMembershipRole(change)).membership.role, "viewer");
        assert.equal((await query("SELECT role FROM team_memberships WHERE id=$1", [membership])).rows[0].role, "editor");

        const newDevice = { id: randomUUID(), name: "Synthetic browser", platform: "web", appVersion: "test", publicKey: null };
        const verificationHash = randomBytes(32).toString("hex");
        const sessionHash = randomBytes(32).toString("hex");
        const passwordHash = randomUUID();
        const expiresAt = new Date(Date.now() + 60_000);
        const account = await store.createUser({
            email: "synthetic-authorization-signup@example.test", username: "synthetic_authorization_signup",
            displayName: "Synthetic signup", passwordHash, device: newDevice, verificationHash, verificationExpiresAt: expiresAt,
        });
        assert.equal((await store.consumeEmailVerificationToken(verificationHash)).id, account.id);
        assert.equal(await store.updateUsername(account.id, "synthetic_auth_after_signup"), "synthetic_auth_after_signup");
        await store.createSession({ userID: account.id, verifiedPasswordHash: passwordHash, device: newDevice, sessionHash, expiresAt });
        assert.equal((await store.session(sessionHash)).user_id, account.id);
        const afterSignup = await fence.snapshot();
        assert.equal(afterSignup.v1Committed.find(vault => vault.ownerID === account.id)?.revision, 0);
        assert.equal(afterSignup.v1TeamAuthorization.digest, await readV1TeamAuthorizationDigest(query));
        assert.equal(afterSignup.v1TeamAuthorizationOutcomes.length, 5);
        assert.equal(await store.revokeDevice(account.id, newDevice.id), true);
        assert.equal(await store.session(sessionHash), null);
        assert.ok((await fence.snapshot()).revokedDeviceIDs.includes(newDevice.id));

        const lostReplyStore = new PostgresStore(db.databaseURL, {
            async connect() {
                const client = await db.pool.connect();
                return {
                    async query(sql, params) {
                        const result = await client.query(sql, params);
                        if (sql === "COMMIT") throw new Error("synthetic_lost_commit_response");
                        return result;
                    },
                    release: error => client.release(error),
                };
            },
        }, { v1Fence: fence, retainTeamAuthorization: true });
        const createVault = { actorUserID: owner, teamID: team, name: "Synthetic Team Vault", idempotencyKey: randomUUID() };
        await assert.rejects(lostReplyStore.createSharedVault(createVault), /synthetic_lost_commit_response/u);
        const uncertain = await fence.snapshot();
        const vaultIntent = uncertain.v1Pending[0];
        const authorizationIntent = uncertain.v1TeamAuthorization.pending;
        assert.equal(uncertain.v1Pending.length, 1);
        assert.ok(authorizationIntent);
        await assert.rejects(store.createSharedVault(createVault), /deployment_fence_pending/u);

        const recovery = new PublicationFenceCoordinator({ fence });
        assert.deepEqual(await recovery.reconcile({
            intentID: vaultIntent.intentID, readCommittedOutcome: intent => readCommittedV1Outcome({ query, intent }),
        }), { status: "confirmed", intentID: vaultIntent.intentID });
        await assert.rejects(verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate }), /deployment_fence_pending/u);
        assert.deepEqual(await recovery.reconcile({
            intentID: authorizationIntent.intentID, readCommittedOutcome: intent => readCommittedV1TeamAuthorizationOutcome({ query, intent }),
        }), { status: "confirmed", intentID: authorizationIntent.intentID });
        assert.equal((await store.createSharedVault(createVault)).vault.id, vaultIntent.vaultID);
        assert.equal((await fence.snapshot()).v1TeamAuthorization.pending, null);
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate })).compatible, true);

        const vaultID = vaultIntent.vaultID, folder = randomUUID(), resource = randomUUID();
        const client = await db.pool.connect();
        const transactionQuery = (sql, params) => client.query(sql, params);
        try {
            await client.query("BEGIN");
            await holdV1TeamAuthorizationFence(client, fence);
            // V2 preparation is experimental. Keep the registry exercise
            // inside this rolled-back transaction, outside the retained V1 floor.
            await client.query("UPDATE shared_vaults SET format_state='V2_PREPARING',format_schema_version=2 WHERE id=$1", [vaultID]);
            await client.query(`INSERT INTO vault_resource_registry(id,team_id,vault_id,policy_class)
                VALUES($1,$2,$3,'folder'),($4,$2,$3,'general')`, [folder, team, vaultID, resource]);
            const beforeMove = await readV1TeamAuthorizationDigest(transactionQuery);
            await client.query(`UPDATE vault_resource_registry
                SET parent_folder_id=$1,resource_version=resource_version+1 WHERE id=$2`, [folder, resource]);
            const afterMove = await readV1TeamAuthorizationDigest(transactionQuery);
            assert.notEqual(afterMove, beforeMove, "resource hierarchy changes the authorization digest independently of a mutation receipt");
            await client.query("UPDATE shared_vaults SET access_policy_version=access_policy_version+1 WHERE id=$1", [vaultID]);
            assert.notEqual(await readV1TeamAuthorizationDigest(transactionQuery), afterMove, "Vault policy version is retained");
        } finally {
            try { await client.query("ROLLBACK"); } finally { client.release(); }
        }
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate })).compatible, true);
    } finally {
        await restored?.cleanup();
        await anchor?.cleanup();
        await runtime?.cleanup();
        await db.cleanup();
        await rm(directory, { recursive: true, force: true });
    }
});
