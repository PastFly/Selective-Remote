import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { randomBytes, randomUUID, webcrypto } from "node:crypto";
import { mkdir, mkdtemp, realpath, rm, rmdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import test from "node:test";
import { encryptResourcePart, generateResourceCEK, wrapResourceCEK } from "../public/resource-crypto-v2.js";
import { generateTeamDeviceIdentity } from "../public/team-vault-crypto.js";
import { currentCapabilities, verifyDeploymentCompatibility } from "../src/deployment-compatibility.mjs";
import { PostgresStore } from "../src/postgres-store.mjs";
import {
    reconcileV1TeamAuthorization,
} from "../src/publication-fence-coordinator.mjs";
import { installV1CommitFence } from "../src/v1-commit-fence.mjs";
import { readV1VaultState } from "../src/v1-data-fence.mjs";
import {
    holdV1TeamAuthorizationFence, installV1TeamAuthorizationFence,
    readV1TeamAuthorizationDigest, teamAuthorizationProtocol,
} from "../src/v1-team-authorization.mjs";
import { isolatedPublicationDatabase, publicationRuntimeFixture } from "./publication-runtime-fixture.mjs";
import { syntheticHttpAnchor, syntheticHttpAnchorAvailable } from "./synthetic-http-anchor-fixture.mjs";

const exec = promisify(execFile);

test("authorization format upgrade keeps the TLS anchor and resumes after the new SQL guards commit", {
    skip: !process.env.TEST_DATABASE_URL || !syntheticHttpAnchorAvailable,
    timeout: 60000,
}, async () => {
    const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
    let runtime, anchor;
    try {
        const { upgradeTeamAuthorizationFormat } = await import("../src/v1-team-authorization.mjs");
        assert.equal(typeof upgradeTeamAuthorizationFormat, "function");
        const q = (sql, params) => db.pool.query(sql, params);
        const userID = randomUUID(), teamID = randomUUID(), vaultID = randomUUID();
        await q("INSERT INTO users(id,email,username) VALUES($1,'upgrade@example.test','upgrade_fixture')", [userID]);
        await q("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'Upgrade fixture',$2)", [teamID, userID]);
        await q(`INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,format_state,format_schema_version)
            VALUES($1,$2,'Registry fixture',$3,'V2_PREPARING',2)`, [vaultID, teamID, userID]);
        runtime = await publicationRuntimeFixture(db.databaseURL);
        anchor = await syntheticHttpAnchor(runtime.path);
        const { fence } = anchor;
        await installV1CommitFence(db.pool);
        await installV1TeamAuthorizationFence(db.pool, 1);
        await fence.append({ version: 2, type:"V1_BASELINE", baselineID:randomUUID(), vaults:await readV1VaultState(q) });
        await fence.append({ version: 2, type:"V1_WRITER_FLOOR", writerProtocol:1 });
        const previousDigest = await readV1TeamAuthorizationDigest(q, 1);
        await fence.append({ version: 2, type:"V1_TEAM_AUTHORIZATION_BASELINE", authorizationProtocol:1, digest:previousDigest });
        const initial = await fence.anchor.read();
        const input = { pool:db.pool, fence };
        const stage = () => upgradeTeamAuthorizationFormat({ ...input, preflight:true });
        assert.equal((await stage()).authorizationProtocol, 1);
        await q(`INSERT INTO vault_resource_mutation_receipts_v2(team_id,vault_id,idempotency_key,operation,request_sha256,result)
            VALUES($1,$2,'synthetic','create_identity',repeat('0',64),'{}')`, [teamID,vaultID]);
        await assert.rejects(stage(), /deployment_team_authorization_untracked_state/u);
        await q("DELETE FROM vault_resource_mutation_receipts_v2");
        assert.deepEqual(await fence.anchor.read(), initial);
        const unavailableFence = {
            anchor: fence.anchor, snapshot: () => fence.snapshot(), assertWritable: () => fence.assertWritable(),
            append: async () => { throw new Error("synthetic_anchor_unavailable"); },
        };
        await assert.rejects(upgradeTeamAuthorizationFormat({ ...input, fence: unavailableFence }), /synthetic_anchor_unavailable/u);
        assert.equal((await fence.snapshot()).v1TeamAuthorization.protocol, 1);
        assert.deepEqual(await fence.anchor.read(), initial);
        await assert.rejects(q("TRUNCATE vault_resource_mutation_receipts_v2"), /v1_team_authorization_writer_required/u);
        await assert.rejects(verifyDeploymentCompatibility({ query:q, fence, candidate:currentCapabilities }), /deployment_code_floor/u);
        assert.equal((await upgradeTeamAuthorizationFormat(input)).authorizationProtocol, 2);
        const final = await fence.anchor.read();
        assert.equal(final.position, initial.position + 1);
        assert.equal((await upgradeTeamAuthorizationFormat(input)).authorizationProtocol, 2);
        assert.deepEqual(await fence.anchor.read(), final);
        assert.equal((await verifyDeploymentCompatibility({ query:q, fence, candidate:currentCapabilities })).compatible,true);
    } finally {
        await anchor?.cleanup();
        await runtime?.cleanup();
        await db.cleanup();
    }
});

test("protected Team recovery checks Vaults, account deletion and resource rights across PostgreSQL restores with the TLS anchor retained", {
    skip: !process.env.TEST_DATABASE_URL || !syntheticHttpAnchorAvailable,
    timeout: 60000,
}, async () => {
    const db = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
    const directory = await realpath(await mkdtemp(join(tmpdir(), "sr-team-authorization-restore-")));
    let runtime, anchor, restored, beforePair, committedCopy, beforeDeletion, rotationCopy, rotationRuntime, rotationAnchor;
    try {
        const owner = randomUUID(), member = randomUUID(), team = randomUUID(), device = randomUUID();
        await db.pool.query(`INSERT INTO users(id,email,username,email_verified_at)
            VALUES($1,'team-auth-owner@example.test','team_auth_owner',now()),
            ($2,'team-auth-member@example.test','team_auth_member',now())`, [owner, member]);
        const memberKeys = await generateTeamDeviceIdentity(webcrypto);
        await db.pool.query(`INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at)
            VALUES($1,$2,'synthetic','web',$3,'p256-ecdh-v1',now(),now())`, [device, member, JSON.stringify(memberKeys.publicKey)]);
        await db.pool.query("INSERT INTO teams(id,name,created_by_user_id) VALUES($1,'Synthetic authorization team',$2)", [team, owner]);
        const membership = randomUUID();
        const ownerMembership = (await db.pool.query(`INSERT INTO team_memberships(team_id,user_id,role)
            VALUES($1,$2,'owner') RETURNING id`, [team, owner])).rows[0].id;
        await db.pool.query(`INSERT INTO team_memberships(id,team_id,user_id,role)
            VALUES($1,$2,$3,'editor')`, [membership, team, member]);
        const memberVault = (await db.pool.query(
            "INSERT INTO personal_vaults(user_id) VALUES($1) RETURNING id", [member],
        )).rows[0].id;
        const memberSession = randomBytes(32).toString("hex");
        await db.pool.query(`INSERT INTO sessions(user_id,device_id,token_hash,expires_at)
            VALUES($1,$2,$3,now()+interval '1 hour')`, [member, device, memberSession]);
        const wrappedVault = randomUUID();
        await db.pool.query(`INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,revision,
            envelope_version,ciphertext,nonce,auth_tag,content_hash,updated_by_device_id)
            VALUES($1,$2,'Synthetic wrapped Vault',$3,1,1,'synthetic','nonce','tag','hash',$4)`,
            [wrappedVault, team, owner, device]);
        await db.pool.query(`INSERT INTO shared_vault_key_wrappers(vault_id,key_generation,membership_id,
            membership_epoch,device_id,wrapper_version,ephemeral_public_key,ciphertext,nonce,auth_tag,context_hash,created_by_device_id)
            VALUES($1,1,$2,1,$3,1,'{}',repeat('A',43),repeat('B',16),repeat('C',22),repeat('D',43),$3)`,
            [wrappedVault, membership, device]);
        const ownerDevice = randomUUID(), unusedDevice = randomUUID(), preparingVault = randomUUID();
        const ownerKeys = await generateTeamDeviceIdentity(webcrypto);
        const unusedKeys = await generateTeamDeviceIdentity(webcrypto);
        await db.pool.query(`INSERT INTO devices(id,user_id,name,platform,public_key,public_key_algorithm,key_registered_at,key_approved_at)
            VALUES($1,$2,'synthetic main','web',$3,'p256-ecdh-v1',now(),now()),
              ($4,$2,'synthetic spare','web',$5,'p256-ecdh-v1',now(),now())`,
            [ownerDevice, owner, JSON.stringify(ownerKeys.publicKey), unusedDevice, JSON.stringify(unusedKeys.publicKey)]);
        await db.pool.query(`INSERT INTO team_membership_device_admissions(membership_id,membership_epoch,device_id)
            VALUES($1,1,$2),($1,1,$3),($4,1,$5)`, [ownerMembership, ownerDevice, unusedDevice, membership, device]);
        await db.pool.query(`INSERT INTO shared_vaults(id,team_id,name,created_by_user_id,format_state,format_schema_version)
            VALUES($1,$2,'Synthetic preparing Vault',$3,'V2_PREPARING',2)`, [preparingVault, team, owner]);
        const archivedTeam = (await db.pool.query(`INSERT INTO teams(name,created_by_user_id,archived_at)
            VALUES('Synthetic archived Team',$1,now()) RETURNING id`, [member])).rows[0].id;
        await db.pool.query("INSERT INTO team_memberships(team_id,user_id,role) VALUES($1,$2,'owner')",
            [archivedTeam, member]);
        const groupID = (await db.pool.query(`INSERT INTO team_access_groups(team_id,name,created_by_user_id)
            VALUES($1,'Synthetic group',$2) RETURNING id`, [team, member])).rows[0].id;
        await db.pool.query(`INSERT INTO team_access_group_members(team_id,group_id,user_id,membership_id,membership_epoch,created_by_user_id)
            VALUES($1,$2,$3,$4,1,$5),($1,$2,$5,$6,1,$3)`, [team, groupID, member, membership, owner, ownerMembership]);
        await db.pool.query(`INSERT INTO vault_access_grants(team_id,vault_id,principal_kind,principal_id,
            membership_id,membership_epoch,target_kind,target_id,permission_mask,created_by_user_id)
            VALUES($1,$2,'GROUP',$3,NULL,NULL,'VAULT',$2,1,$4),
                  ($1,$2,'USER',$4,$5,1,'VAULT',$2,1,$6)`, [team, preparingVault, groupID, member, membership, owner]);
        const cancelledPublication = randomUUID();
        await db.pool.query(`INSERT INTO team_publication_cancellations(operation_id,team_id,actor_user_id,actor_device_id,confirmed_by_session)
            VALUES($1,$2,$3,$4,$5)`, [cancelledPublication, team, member, device, randomUUID()]);

        const legacyStore = new PostgresStore(db.databaseURL, db.pool, {
            v1Fence: { anchor: {}, snapshot: async () => { throw new Error("deployment_fence_locked"); } },
        });
        assert.equal(await legacyStore.updateUsername(member, "team_auth_legacy_member"), "team_auth_legacy_member");
        assert.equal(await legacyStore.consumeEmailVerificationToken(randomBytes(32).toString("hex")), null);

        runtime = await publicationRuntimeFixture(db.databaseURL);
        anchor = await syntheticHttpAnchor(runtime.path);
        const { fence } = anchor;
        const query = (sql, params) => db.pool.query(sql, params);
        const verifiedCandidate = { ...currentCapabilities, v1TeamAuthorizationProtocol: teamAuthorizationProtocol };
        await installV1CommitFence(db.pool);
        await fence.append({ version: 2, type: "V1_BASELINE", baselineID: randomUUID(), vaults: await readV1VaultState(query) });
        await fence.append({ version: 2, type: "V1_WRITER_FLOOR", writerProtocol: 1 });
        const baseline = await readV1TeamAuthorizationDigest(query);
        await installV1TeamAuthorizationFence(db.pool);
        await db.pool.query("UPDATE devices SET last_seen_at=last_seen_at+interval '10 seconds' WHERE id=$1", [device]);
        assert.equal(await readV1TeamAuthorizationDigest(query), baseline);
        await fence.append({ version: 2, type: "V1_TEAM_AUTHORIZATION_BASELINE", authorizationProtocol: teamAuthorizationProtocol, digest: baseline });
        const { v1TeamAuthorizationProtocol: _older, v1TeamAuthorizationRegistrationVersion: _registered, v1ProductionTeamVersion: _prodTeam, v1ProductionPersonalPilotVersion: _prodPilot, ...oldCandidate } = verifiedCandidate;
        await assert.rejects(verifyDeploymentCompatibility({ fence, query: () => assert.fail("old candidate reached SQL"), candidate: oldCandidate }), /deployment_code_floor/u);
        await assert.rejects(verifyDeploymentCompatibility({ fence, query: () => assert.fail("old candidate reached SQL"),
            candidate: { ...verifiedCandidate, v1TeamAuthorizationProtocol: 1 } }), /deployment_code_floor/u);
        await assert.rejects(verifyDeploymentCompatibility({ fence, query: () => assert.fail("old schema candidate reached SQL"),
            candidate: { ...verifiedCandidate, maxSchemaVersion: 22 } }), /deployment_code_floor/u);
        await assert.rejects(verifyDeploymentCompatibility({ fence, candidate: verifiedCandidate, query: sql => {
            assert.match(sql, /schema_migrations/u);
            return { rows: [{ version: 22 }] };
        } }), /deployment_schema_floor/u);
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate, productionTeamEnabled:true })).productionTeamEnabled, true);

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
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate, productionTeamEnabled:true })).productionTeamEnabled, true);

        restored = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
        await exec("pg_restore", ["--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl", "--dbname", restored.databaseURL, archive]);
        const restoredQuery = (sql, params) => restored.pool.query(sql, params);
        assert.equal(await readV1TeamAuthorizationDigest(restoredQuery), baseline);
        await assert.rejects(
            verifyDeploymentCompatibility({ fence, query: restoredQuery, candidate: verifiedCandidate, productionTeamEnabled:true }),
            /deployment_team_authorization_mismatch/u,
        );

        const promoted = await store.updateTeamMembershipRole({ ...change, idempotencyKey: randomUUID(), role: "editor" });
        assert.equal(promoted.membership.role, "editor");
        await assert.rejects(
            verifyDeploymentCompatibility({ fence, query: restoredQuery, candidate: verifiedCandidate, productionTeamEnabled:true }),
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

        const precedingArchive = join(directory, "before-paired-commit.dump");
        await exec("pg_dump", ["--format=custom", "--no-owner", "--no-acl", "--file", precedingArchive, db.databaseURL]);
        beforePair = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
        await exec("pg_restore", ["--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl",
            "--dbname", beforePair.databaseURL, precedingArchive]);

        let loseCommitBeforeWrite = false;
        const lostReplyStore = new PostgresStore(db.databaseURL, {
            async connect() {
                const client = await db.pool.connect();
                return {
                    async query(sql, params) {
                        if (sql === "COMMIT" && loseCommitBeforeWrite) {
                            await client.query("ROLLBACK");
                            throw new Error("synthetic_lost_commit_response");
                        }
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

        assert.equal(authorizationIntent.vaultIntentID, vaultIntent.intentID);
        assert.equal(authorizationIntent.vaultIntentDigest, vaultIntent.intentDigest);
        const recoveryInput = { pool: db.pool, fence, intentID: authorizationIntent.intentID };
        const priorHistory = await fence.readRecords();
        const priorAnchor = await fence.anchor.read();
        await assert.rejects(reconcileV1TeamAuthorization({
            ...recoveryInput, fence: { readRecords: () => assert.fail("unanchored history read") },
        }), /deployment_anchor_required/u);
        await assert.rejects(reconcileV1TeamAuthorization({
            ...recoveryInput, intentID: vaultIntent.intentID,
        }), /deployment_fence_intent_not_found/u);

        const identity = { sourceSHA: "a".repeat(40), imageDigest: "sha256:" + "b".repeat(64), controllerDigest: "c".repeat(64) };
        const identityPath = join(directory, "controller-identity.json");
        await writeFile(identityPath, JSON.stringify(identity), { mode: 0o600 });
        const options = { identity, identityPath, anchorDeploymentID: anchor.env.PUBLICATION_FENCE_ANCHOR_ID, fencePath: runtime.path };
        const recoveryScript = fileURLToPath(new URL("../scripts/staging-team-authorization-recovery.mjs", import.meta.url));
        const request = { operation: "reconcile-team-authorization", intentID: authorizationIntent.intentID };
        const recover = async (databaseURL, overrides = {}, requestBody = request, environment = "staging") => {
            const command = exec(process.execPath, [recoveryScript, JSON.stringify({ ...options, ...overrides })], {
                env: {
                    ...anchor.env, DATABASE_URL: databaseURL,
                    PUBLICATION_ENVIRONMENT: environment, PUBLICATION_FENCE_PATH: runtime.path,
                },
            });
            command.child.stdin.on("error", () => {});
            command.child.stdin.end(JSON.stringify(requestBody));
            try { return JSON.parse((await command).stdout); }
            catch(error) { throw new Error(error.stderr?.trim() || "synthetic_recovery_failed"); }
        };
        await assert.rejects(recover(db.databaseURL, { anchorDeploymentID: randomUUID() }), /staging_team_recovery_anchor/u);
        await assert.rejects(recover(db.databaseURL, { identity: { ...identity, sourceSHA: "d".repeat(40) } }), /staging_team_recovery_identity/u);
        await assert.rejects(recover(db.databaseURL, {}, { ...request, committed: true }), /staging_team_recovery_scope/u);
        await assert.rejects(recover(db.databaseURL, {}, request, "production"), /staging_team_recovery_scope/u);
        const journalLock = runtime.path + ".lock";
        await mkdir(journalLock, { mode: 0o700 });
        try {
            await assert.rejects(recover(db.databaseURL), /deployment_fence_locked/u);
        } finally {
            await rmdir(journalLock);
        }
        await assert.rejects(recover(restored.databaseURL), /deployment_fence_mismatch/u);
        assert.deepEqual(await recover(beforePair.databaseURL), { status: "pending", intentID: authorizationIntent.intentID });
        const incompleteReadback = {
            async connect() {
                const client = await db.pool.connect();
                return {
                    query: async (sql, values) => sql.includes("AS current_envelope_hash")
                        ? { rows: [] } : client.query(sql, values),
                    release: error => client.release(error),
                };
            },
        };
        assert.equal(await readV1TeamAuthorizationDigest(query), authorizationIntent.nextDigest);
        await assert.rejects(reconcileV1TeamAuthorization({ ...recoveryInput, pool: incompleteReadback }), /deployment_fence_mismatch/u);
        assert.deepEqual(await fence.readRecords(), priorHistory);
        assert.deepEqual(await fence.anchor.read(), priorAnchor);
        const beforePairQuery = (sql, params) => beforePair.pool.query(sql, params);
        await assert.rejects(verifyDeploymentCompatibility({ fence, query: beforePairQuery, candidate: verifiedCandidate }), /deployment_fence_pending/u);

        const committedArchive = join(directory, "after-paired-commit.dump");
        await exec("pg_dump", ["--format=custom", "--no-owner", "--no-acl", "--file", committedArchive, db.databaseURL]);
        committedCopy = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
        await exec("pg_restore", ["--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl",
            "--dbname", committedCopy.databaseURL, committedArchive]);
        const confirmed = { status: "confirmed", intentID: authorizationIntent.intentID };
        assert.deepEqual(await recover(committedCopy.databaseURL), confirmed);
        const recovered = await fence.readRecords();
        assert.deepEqual(recovered.slice(priorHistory.length).map(({ type, intentID }) => [type, intentID]), [
            ["V1_CONFIRMED_COMMIT", vaultIntent.intentID],
            ["V1_TEAM_AUTHORIZATION_CONFIRMED", authorizationIntent.intentID],
        ]);
        assert.equal((await fence.anchor.read()).position, priorAnchor.position + 2);
        assert.deepEqual(await recover(committedCopy.databaseURL), confirmed);
        assert.deepEqual(await fence.readRecords(), recovered);
        const committedQuery = (sql, params) => committedCopy.pool.query(sql, params);
        assert.equal((await verifyDeploymentCompatibility({ fence, query: committedQuery, candidate: verifiedCandidate })).compatible, true);
        await assert.rejects(verifyDeploymentCompatibility({ fence, query: beforePairQuery, candidate: verifiedCandidate }), /deployment_v1_data_mismatch/u);

        assert.equal((await store.createSharedVault(createVault)).vault.id, vaultIntent.vaultID);
        assert.equal((await fence.snapshot()).v1TeamAuthorization.pending, null);
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate, productionTeamEnabled:true })).productionTeamEnabled, true);

        const secondVault = { ...createVault, name: "Synthetic restart recovery Vault", idempotencyKey: randomUUID() };
        await assert.rejects(lostReplyStore.createSharedVault(secondVault), /synthetic_lost_commit_response/u);
        const secondPending = await fence.snapshot();
        const secondPair = secondPending.v1TeamAuthorization.pending;
        const secondVaultIntent = secondPending.v1Pending[0];
        assert.equal(secondPair.vaultIntentID, secondVaultIntent.intentID);
        const interruptedFence = {
            anchor: fence.anchor, readRecords: () => fence.readRecords(), snapshot: () => fence.snapshot(),
            append(event) {
                if (event.type === "V1_TEAM_AUTHORIZATION_CONFIRMED") throw new Error("synthetic_controller_interruption");
                return fence.append(event);
            },
        };
        await assert.rejects(reconcileV1TeamAuthorization({
            pool: db.pool, fence: interruptedFence, intentID: secondPair.intentID,
        }), /synthetic_controller_interruption/u);
        const interrupted = await fence.snapshot();
        assert.equal(interrupted.v1Pending.length, 0);
        assert.equal(interrupted.v1TeamAuthorization.pending.intentID, secondPair.intentID);
        await assert.rejects(verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate }), /deployment_fence_pending/u);
        const interruptedAnchor = await fence.anchor.read();
        const secondRequest = { ...request, intentID: secondPair.intentID };
        assert.deepEqual(await recover(db.databaseURL, {}, secondRequest), { status: "confirmed", intentID: secondPair.intentID });
        assert.equal((await fence.anchor.read()).position, interruptedAnchor.position + 1);
        assert.equal((await store.createSharedVault(secondVault)).vault.id, secondVaultIntent.vaultID);
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate, productionTeamEnabled:true })).productionTeamEnabled, true);

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
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate, productionTeamEnabled:true })).productionTeamEnabled, true);

        const scope = { actorUserID: owner, actorDeviceID: ownerDevice, teamID: team, vaultID: preparingVault };
        const folderCreate = { ...scope, resourceID: randomUUID(), policyClass: "folder", idempotencyKey: randomUUID() };
        const resourceCreate = { ...scope, resourceID: randomUUID(), policyClass: "general", idempotencyKey: randomUUID() };
        assert.equal((await store.registerResourceIdentity(folderCreate)).id, folderCreate.resourceID);
        assert.equal((await store.registerResourceIdentity(resourceCreate)).id, resourceCreate.resourceID);
        const move = { ...scope, resourceID: resourceCreate.resourceID, parentFolderID: folderCreate.resourceID,
            expectedVersion: 1, idempotencyKey: randomUUID() };
        assert.equal((await store.moveResourceIdentity(move)).parent_folder_id, folderCreate.resourceID);
        const tombstone = { ...scope, resourceID: resourceCreate.resourceID, expectedVersion: 2, idempotencyKey: randomUUID() };
        assert.ok((await store.tombstoneResourceIdentity(tombstone)).deleted_at);
        await assert.rejects(store.getResourceIdentity(tombstone), /resource_not_found/u);
        assert.deepEqual(await store.tombstoneResourceIdentity(tombstone), await store.tombstoneResourceIdentity(tombstone));

        const cryptoResource = { ...resourceCreate, resourceID: randomUUID(), idempotencyKey: randomUUID() };
        await store.registerResourceIdentity(cryptoResource);
        const beforePublication = join(directory, "before-resource-publication.dump");
        await exec("pg_dump", ["--format=custom", "--no-owner", "--no-acl", "--file", beforePublication, db.databaseURL]);
        await exec("pg_restore", ["--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl",
            "--dbname", restored.databaseURL, beforePublication]);
        const restoredRights = new PostgresStore(restored.databaseURL, restored.pool, {
            v1Fence: fence, retainTeamAuthorization: true,
        });
        const context = { teamID: team, vaultID: preparingVault, resourceID: cryptoResource.resourceID, part: "GENERAL",
            keyVersion: 1, policyVersion: 3, registryVersion: 1, resourceVersion: 1, manifestVersion: 1 };
        const ownerRecipient = [ownerMembership, ownerDevice, ownerKeys.publicKey];
        const spareRecipient = [ownerMembership, unusedDevice, unusedKeys.publicKey];
        const memberRecipient = [membership, device, memberKeys.publicKey];
        const makePublication = async (context, recipients) => {
            const cek = generateResourceCEK(webcrypto);
            return { ...scope, resourceID: context.resourceID,
                expectedManifestVersion: context.manifestVersion - 1, idempotencyKey: randomUUID(),
                ciphertext: await encryptResourcePart({ plaintext: Buffer.from("synthetic"), cek, context, cryptoValue: webcrypto }),
                wrappers: await Promise.all(recipients.map(([membershipID, deviceID, recipientPublicKey]) => wrapResourceCEK({
                    context: { ...context, membershipID, membershipEpoch: 1, deviceID },
                    cek, recipientPublicKey, cryptoValue: webcrypto,
                }))),
            };
        };
        const publication = await makePublication(context, [ownerRecipient, spareRecipient, memberRecipient]);
        assert.equal(Number((await store.publishResourceCryptoVersion(publication)).manifest_version), 1);
        await assert.rejects(restoredRights.publishResourceCryptoVersion(publication), /deployment_team_authorization_mismatch/u);
        await assert.rejects(query("DELETE FROM vault_resource_mutation_receipts_v2 WHERE idempotency_key=$1",
            [publication.idempotencyKey]), /v1_team_authorization_writer_required/u);
        assert.equal(await store.revokeDevice(owner, unusedDevice), true);
        const rightsArchive = join(directory, "before-resource-wrapper-revocation.dump");
        await exec("pg_dump", ["--format=custom", "--no-owner", "--no-acl", "--file", rightsArchive, db.databaseURL]);
        await exec("pg_restore", ["--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl",
            "--dbname", restored.databaseURL, rightsArchive]);
        const revokeWrapper = { ...scope, resourceID: cryptoResource.resourceID, part: context.part, keyVersion: 1,
            membershipID: ownerMembership, membershipEpoch: 1, deviceID: unusedDevice, expectedManifestVersion: 1,
            idempotencyKey: randomUUID() };
        const revoked = await store.revokeResourceWrapper(revokeWrapper);
        assert.ok(revoked.obsolete_at);
        assert.deepEqual(await store.revokeResourceWrapper(revokeWrapper), revoked);
        await assert.rejects(restoredRights.getResourceIdentity(cryptoResource), /deployment_team_authorization_mismatch/u);
        await assert.rejects(restoredRights.revokeResourceWrapper(revokeWrapper), /deployment_team_authorization_mismatch/u);
        await assert.rejects(verifyDeploymentCompatibility({ fence, query: restoredQuery, candidate: verifiedCandidate, productionTeamEnabled:true }),
            /deployment_team_authorization_mismatch/u);
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate, productionTeamEnabled:true })).productionTeamEnabled, true);

        await assert.rejects(store.deleteAccount(owner), /account_owns_teams/u);
        assert.equal((await store.session(memberSession)).user_id, member);
        const deletionArchive = join(directory, "before-account-deletion.dump");
        await exec("pg_dump", ["--format=custom", "--no-owner", "--no-acl", "--file", deletionArchive, db.databaseURL]);
        beforeDeletion = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
        await exec("pg_restore", ["--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl",
            "--dbname", beforeDeletion.databaseURL, deletionArchive]);
        const deletionBefore = await fence.snapshot();
        await assert.rejects(lostReplyStore.deleteAccount(member), /synthetic_lost_commit_response/u);
        const deletionPending = await fence.snapshot();
        const deletionPair = deletionPending.v1TeamAuthorization.pending;
        const deletionIntent = deletionPending.v1Pending[0];
        assert.equal(deletionPair.vaultIntentID, deletionIntent.intentID);
        assert.equal(deletionIntent.vault.vaultID, memberVault);
        assert.deepEqual(deletionIntent.changes.map(item => item.vaultID), [wrappedVault]);
        assert.ok(deletionPending.revokedAccountIDs.includes(member));
        const staleStore = new PostgresStore(beforeDeletion.databaseURL, beforeDeletion.pool, {
            v1Fence: fence, retainTeamAuthorization: true,
        });
        assert.equal(await staleStore.session(memberSession), null);
        const deletionRequest = { ...request, intentID: deletionPair.intentID };
        const accountAnchor = await fence.anchor.read();
        assert.deepEqual(await recover(beforeDeletion.databaseURL, {}, deletionRequest), {
            status: "pending", intentID: deletionPair.intentID,
        });
        assert.deepEqual(await fence.anchor.read(), accountAnchor);
        const deletedArchive = join(directory, "after-account-deletion.dump");
        await exec("pg_dump", ["--format=custom", "--no-owner", "--no-acl", "--file", deletedArchive, db.databaseURL]);
        await exec("pg_restore", ["--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl",
            "--dbname", committedCopy.databaseURL, deletedArchive]);
        assert.deepEqual(await recover(committedCopy.databaseURL, {}, deletionRequest), {
            status: "confirmed", intentID: deletionPair.intentID,
        });
        assert.equal((await fence.anchor.read()).position, accountAnchor.position + 1);
        assert.deepEqual(await recover(committedCopy.databaseURL, {}, deletionRequest), {
            status: "confirmed", intentID: deletionPair.intentID,
        });
        assert.equal((await fence.anchor.read()).position, accountAnchor.position + 1);
        const deletionAfter = await fence.snapshot();
        assert.ok(!deletionAfter.v1Committed.some(item => item.vaultID === memberVault));
        const beforeWrapper = deletionBefore.v1Committed.find(item => item.vaultID === wrappedVault);
        const afterWrapper = deletionAfter.v1Committed.find(item => item.vaultID === wrappedVault);
        assert.equal(afterWrapper.revision, beforeWrapper.revision);
        assert.equal(afterWrapper.ciphertextHash, beforeWrapper.ciphertextHash);
        assert.notEqual(afterWrapper.envelopeHash, beforeWrapper.envelopeHash);
        assert.equal((await committedQuery("SELECT id FROM users WHERE id=$1", [member])).rowCount, 0);
        assert.equal((await committedQuery("SELECT actor_user_id FROM team_publication_cancellations WHERE operation_id=$1", [cancelledPublication])).rows[0].actor_user_id, member);
        await assert.rejects(committedQuery(`INSERT INTO team_publication_cancellations(operation_id,team_id,actor_user_id,actor_device_id,confirmed_by_session)
            VALUES($1,$2,$3,$4,$5)`, [randomUUID(), team, member, device, randomUUID()]), /publication_scope_mismatch/u);
        assert.deepEqual((await committedQuery(`SELECT device_id FROM vault_resource_key_wrappers_v2
            WHERE resource_id=$1 AND obsolete_at IS NULL`, [cryptoResource.resourceID])).rows, [{ device_id: ownerDevice }]);
        assert.equal((await committedQuery("SELECT device_id FROM vault_resource_key_wrappers_v2 WHERE device_id=$1",
            [device])).rowCount, 0);
        assert.equal((await committedQuery("SELECT user_id FROM team_memberships WHERE id=$1 AND revoked_at IS NOT NULL", [membership])).rows[0].user_id, null);
        assert.equal((await committedQuery("SELECT user_id FROM team_memberships WHERE team_id=$1 AND revoked_at IS NOT NULL", [archivedTeam])).rows[0].user_id, null);
        assert.equal((await committedQuery("SELECT created_by_user_id FROM team_access_groups WHERE id=$1", [groupID])).rows[0].created_by_user_id, null);
        assert.deepEqual((await committedQuery(`SELECT user_id,created_by_user_id,removed_at IS NOT NULL AS removed
            FROM team_access_group_members WHERE group_id=$1 ORDER BY removed`, [groupID])).rows, [
            { user_id: owner, created_by_user_id: null, removed: false },
            { user_id: null, created_by_user_id: owner, removed: true },
        ]);
        assert.deepEqual((await committedQuery(`SELECT principal_kind,created_by_user_id,revoked_at IS NOT NULL AS revoked
            FROM vault_access_grants WHERE vault_id=$1 ORDER BY principal_kind`, [preparingVault])).rows, [
            { principal_kind: "GROUP", created_by_user_id: null, revoked: false },
            { principal_kind: "USER", created_by_user_id: owner, revoked: true },
        ]);
        assert.equal((await committedQuery("SELECT rotation_required FROM shared_vaults WHERE id=$1", [wrappedVault])).rows[0].rotation_required, true);
        assert.equal((await verifyDeploymentCompatibility({ fence, query: committedQuery, candidate: verifiedCandidate })).compatible, true);
        const staleQuery = (sql, params) => beforeDeletion.pool.query(sql, params);
        await assert.rejects(verifyDeploymentCompatibility({ fence, query: staleQuery, candidate: verifiedCandidate }), /deployment_v1_data_mismatch/u);
        assert.equal(await staleStore.session(memberSession), null);
        assert.deepEqual(await store.deleteAccount(account.id), { deleted: true });
        assert.equal((await verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate, productionTeamEnabled:true })).productionTeamEnabled, true);

        rotationCopy = await isolatedPublicationDatabase(process.env.TEST_DATABASE_URL);
        await exec("pg_restore", ["--exit-on-error", "--clean", "--if-exists", "--no-owner", "--no-acl",
            "--dbname", rotationCopy.databaseURL, deletionArchive]);
        rotationRuntime = await publicationRuntimeFixture(rotationCopy.databaseURL);
        rotationAnchor = await syntheticHttpAnchor(rotationRuntime.path);
        const rotationFence = rotationAnchor.fence;
        const rotationQuery = (sql, params) => rotationCopy.pool.query(sql, params);
        await rotationFence.append({ version: 2, type: "V1_BASELINE", baselineID: randomUUID(),
            vaults: await readV1VaultState(rotationQuery) });
        await rotationFence.append({ version: 2, type: "V1_WRITER_FLOOR", writerProtocol: 1 });
        await rotationFence.append({ version: 2, type: "V1_TEAM_AUTHORIZATION_BASELINE",
            authorizationProtocol: teamAuthorizationProtocol, digest: await readV1TeamAuthorizationDigest(rotationQuery) });
        const rotationStore = new PostgresStore(rotationCopy.databaseURL, rotationCopy.pool, {
            v1Fence: rotationFence, retainTeamAuthorization: true,
        });
        assert.equal(await rotationStore.revokeDevice(owner, ownerDevice), true);
        const beforeDeniedDeletion = await rotationFence.anchor.read();
        await assert.rejects(rotationStore.deleteAccount(member), /account_team_keys_need_rotation/u);
        assert.deepEqual(await rotationFence.anchor.read(), beforeDeniedDeletion);
        assert.equal((await rotationStore.session(memberSession)).user_id, member);

        const unfinishedAccount = await store.createUser({
            email: "synthetic-unfinished-deletion@example.test", username: "synthetic_unfinished_deletion",
            displayName: "Synthetic unfinished deletion", passwordHash, device: { ...newDevice, id: randomUUID() },
            verificationHash: randomBytes(32).toString("hex"), verificationExpiresAt: expiresAt,
        });
        loseCommitBeforeWrite = true;
        await assert.rejects(lostReplyStore.deleteAccount(unfinishedAccount.id), /synthetic_lost_commit_response/u);
        const unfinished = await fence.snapshot();
        const uncommitted = unfinished.v1TeamAuthorization.pending;
        assert.ok(unfinished.revokedAccountIDs.includes(unfinishedAccount.id));
        assert.equal(unfinished.v1Pending[0].intentID, uncommitted.vaultIntentID);
        assert.equal((await query("SELECT id FROM users WHERE id=$1", [unfinishedAccount.id])).rowCount, 1);
        const uncommittedHistory = await fence.readRecords();
        assert.equal(await readV1TeamAuthorizationDigest(query), uncommitted.previousDigest);
        assert.deepEqual(await reconcileV1TeamAuthorization({
            ...recoveryInput, intentID: uncommitted.intentID,
        }), { status: "pending", intentID: uncommitted.intentID });
        assert.deepEqual(await fence.readRecords(), uncommittedHistory);
        await assert.rejects(verifyDeploymentCompatibility({ fence, query, candidate: verifiedCandidate }), /deployment_fence_pending/u);
    } finally {
        await rotationAnchor?.cleanup();
        await rotationRuntime?.cleanup();
        await rotationCopy?.cleanup();
        await beforeDeletion?.cleanup();
        await committedCopy?.cleanup();
        await beforePair?.cleanup();
        await restored?.cleanup();
        await anchor?.cleanup();
        await runtime?.cleanup();
        await db.cleanup();
        await rm(directory, { recursive: true, force: true });
    }
});
