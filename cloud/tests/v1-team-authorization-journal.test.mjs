import assert from "node:assert/strict";
import test from "node:test";
import { fenceIntentDigest, reduceFenceEvents } from "../src/migration-fence-journal.mjs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MigrationFence } from "../src/migration-fence.mjs";
import { createPublicationFenceTransaction, PublicationFenceCoordinator } from "../src/publication-fence-coordinator.mjs";
import { syntheticAnchoredFence } from "./synthetic-v1-anchor-fixture.mjs";

const original = "1".repeat(64);
const updated = "2".repeat(64);
const events = [
    { version: 2, type: "V1_BASELINE", baselineID: "11111111-1111-4111-8111-111111111111", vaults: [] },
    { version: 2, type: "V1_WRITER_FLOOR", writerProtocol: 1 },
];
const baseline = {
    version: 2, type: "V1_TEAM_AUTHORIZATION_BASELINE", authorizationProtocol: 1, digest: original,
};
const stage = {
    version: 2, type: "V1_TEAM_AUTHORIZATION_PENDING",
    intentID: "22222222-2222-4222-8222-222222222222", previousDigest: original, nextDigest: updated,
};
const confirmation = () => ({
    version: 2, type: "V1_TEAM_AUTHORIZATION_CONFIRMED",
    intentID: stage.intentID, intentDigest: fenceIntentDigest(stage),
});

test("the retained Team authorization digest advances only after a matched confirmation", () => {
    const retained = [...events, baseline, stage];
    const state = reduceFenceEvents(retained).v1TeamAuthorization;
    const confirm = confirmation();
    assert.deepEqual(state, {
        protocol: 1, digest: original, pending: { ...stage, intentDigest: confirm.intentDigest },
    });
    const expected = { protocol: 1, digest: updated, pending: null };
    assert.deepEqual(reduceFenceEvents([...retained, confirm]).v1TeamAuthorization, expected);
    assert.deepEqual(reduceFenceEvents([...retained, confirm, stage, confirm]).v1TeamAuthorization, expected);
});

test("Team authorization history rejects a stale baseline, overlapping transition and unrelated confirmation", () => {
    assert.throws(() => reduceFenceEvents([baseline]), /deployment_fence_conflict/u);
    const retained = [...events, baseline];
    assert.throws(() => reduceFenceEvents([...retained, { ...stage, previousDigest: updated, nextDigest: "3".repeat(64) }]), /deployment_fence_conflict/u);
    assert.throws(() => reduceFenceEvents([...retained, stage, { ...stage, intentID: "33333333-3333-4333-8333-333333333333" }]), /deployment_fence_conflict/u);
    const confirm = confirmation();
    assert.throws(() => reduceFenceEvents([...retained, stage, { ...confirm, intentDigest: original }]), /deployment_fence_conflict/u);
    assert.throws(() => reduceFenceEvents([...retained, stage, confirm, { ...baseline, digest: updated }]), /deployment_fence_conflict/u);
});

test("authorization format upgrades once from the current settled format-1 digest", () => {
    const upgrade = { version: 2, type: "V1_TEAM_AUTHORIZATION_FORMAT_UPGRADED",
        previousDigest: updated, nextDigest: "3".repeat(64) };
    const retained = [...events, baseline, stage, confirmation()];
    const upgraded = reduceFenceEvents([...retained, upgrade, upgrade]);
    assert.deepEqual(upgraded.v1TeamAuthorization, { protocol: 2, digest: upgrade.nextDigest, pending: null });
    assert.equal(upgraded.schemaFloor, 23);
    assert.equal(upgraded.v1TeamAuthorizationOutcomes.length, 1);
    assert.throws(() => reduceFenceEvents([...events, baseline, stage, upgrade]), /deployment_fence_conflict/u);
    assert.throws(() => reduceFenceEvents([...events, baseline, upgrade]), /deployment_fence_conflict/u);
    assert.throws(() => reduceFenceEvents([...events, { ...baseline, authorizationProtocol: 2 }, upgrade]), /deployment_fence_conflict/u);
});

test("a proven abort retains the previous authorization digest and closes the pending transition", () => {
    const confirm = confirmation();
    const abort = { ...confirm, type: "V1_TEAM_AUTHORIZATION_ABORTED" };
    assert.deepEqual(reduceFenceEvents([...events, baseline, stage, abort]).v1TeamAuthorization, {
        protocol: 1, digest: original, pending: null,
    });
    assert.throws(() => reduceFenceEvents([...events, baseline, stage, abort, confirm]), /deployment_fence_conflict/u);
});

test("paired Team terminal evidence requires the exact retained Vault outcome", () => {
    const vault = {
        version: 2, type: "V1_PENDING_INTENT",
        intentID: "44444444-4444-4444-8444-444444444444",
        operationID: "55555555-5555-4555-8555-555555555555",
        vaultKind: "TEAM", ownerID: "66666666-6666-4666-8666-666666666666",
        vaultID: "77777777-7777-4777-8777-777777777777",
        baseRevision: 0, revision: 1, ciphertextHash: original, envelopeHash: updated,
    };
    const vaultIntentDigest = fenceIntentDigest(vault);
    const paired = { ...stage, vaultIntentID: vault.intentID, vaultIntentDigest };
    const confirmed = { ...confirmation(), intentDigest: fenceIntentDigest(paired) };
    const aborted = { ...confirmed, type: "V1_TEAM_AUTHORIZATION_ABORTED" };
    const vaultConfirmed = {
        version: 2, type: "V1_CONFIRMED_COMMIT", intentID: vault.intentID, intentDigest: vaultIntentDigest,
    };
    const vaultAborted = { ...vaultConfirmed, type: "V1_PROVEN_ABORT" };
    const prefix = [...events, baseline];
    const retained = [...prefix, vault, paired];
    assert.throws(() => reduceFenceEvents([...prefix, paired]), /deployment_fence_conflict/u);
    assert.throws(() => reduceFenceEvents([...prefix, vault, { ...paired, vaultIntentDigest: original }]), /deployment_fence_conflict/u);
    assert.throws(() => reduceFenceEvents([...retained, confirmed]), /deployment_fence_conflict/u);
    assert.throws(() => reduceFenceEvents([...retained, vaultAborted, confirmed]), /deployment_fence_conflict/u);
    assert.throws(() => reduceFenceEvents([...retained, vaultConfirmed, aborted]), /deployment_fence_conflict/u);
    assert.equal(reduceFenceEvents([...retained, vaultConfirmed, confirmed]).v1TeamAuthorization.digest, updated);
    assert.equal(reduceFenceEvents([...retained, vaultAborted, aborted]).v1TeamAuthorization.digest, original);
});

test("the journal requires an independent anchor and an unresolved Team write blocks readiness", async () => {
    const directory = await mkdtemp(join(tmpdir(), "sr-team-authorization-"));
    try {
        const path = join(directory, "journal");
        await writeFile(path, "");
        const fence = await syntheticAnchoredFence(path);
        for (const event of events) await fence.append(event);
        await assert.rejects(new MigrationFence(path).append(baseline), /deployment_anchor_required/u);
        await fence.append(baseline);
        await fence.append(stage);
        await assert.rejects(fence.assertWritable(), /deployment_fence_pending/u);
        await fence.append(confirmation());
        assert.equal(await fence.assertWritable(), true);
    } finally {
        await rm(directory, { recursive: true, force: true });
    }
});

test("a proven account deletion rollback closes both projections and restores authentication together", async () => {
    const directory = await mkdtemp(join(tmpdir(), "sr-account-deletion-abort-"));
    try {
        const path = join(directory, "journal");
        await writeFile(path, "");
        const fence = await syntheticAnchoredFence(path);
        for (const event of [...events, { ...baseline, authorizationProtocol: 2 }]) await fence.append(event);
        const query = async sql => assert.equal(sql, "ROLLBACK");
        const transaction = createPublicationFenceTransaction({ fence, query });
        const userID = "88888888-8888-4888-8888-888888888888";
        const fields = { kind: "V1_ACCOUNT_DELETION", userID, vault: null, changes: [],
            authorizationIntentID: stage.intentID, previousDigest: original, nextDigest: updated };
        const intent = await transaction.beforeCommit(fields);
        const pending = await fence.snapshot();
        assert.deepEqual(pending.revokedAccountIDs, [userID]);
        assert.equal(pending.v1TeamAuthorization.pending.vaultIntentID, intent.intentID);
        await transaction.rollback();
        const retained = await fence.snapshot();
        assert.equal(retained.revokedAccountIDs, undefined);
        assert.deepEqual(retained.v1Pending, []);
        assert.deepEqual(retained.v1TeamAuthorization, { protocol: 2, digest: original, pending: null });
        assert.equal(retained.v1TeamAuthorizationOutcomes[0].type, "V1_TEAM_AUTHORIZATION_ABORTED");
        assert.deepEqual((await fence.readRecords()).slice(-2).map(event => event.type),
            ["V1_ACCOUNT_DELETION_PENDING_INTENT", "V1_PROVEN_ABORT"]);
    } finally {
        await rm(directory, { recursive: true, force: true });
    }
});

test("a lost Team COMMIT response requires positive readback and cannot be cleared by a later rollback", async () => {
    const directory = await mkdtemp(join(tmpdir(), "sr-team-authorization-commit-"));
    try {
        const path = join(directory, "journal");
        await writeFile(path, "");
        const fence = await syntheticAnchoredFence(path);
        for (const event of [...events, baseline]) await fence.append(event);
        const transaction = createPublicationFenceTransaction({
            fence, query: async (sql) => {
                if (sql === "COMMIT") throw new Error("synthetic_lost_commit_response");
                assert.equal(sql, "ROLLBACK");
            },
        });
        const { intentID } = await transaction.beforeCommit({
            kind: "V1_TEAM_AUTHORIZATION", previousDigest: original, nextDigest: updated,
        });
        await assert.rejects(transaction.commit(), /synthetic_lost_commit_response/u);
        await transaction.rollback();
        const coordinator = new PublicationFenceCoordinator({ fence });
        assert.deepEqual(await coordinator.reconcile({ intentID, readCommittedOutcome: async () => null }),
            { status: "pending", intentID });
        await assert.rejects(coordinator.reconcile({
            intentID, readCommittedOutcome: async () => ({ kind: "V1_TEAM_AUTHORIZATION", digest: original }),
        }), /deployment_fence_mismatch/u);
        assert.deepEqual(await coordinator.reconcile({
            intentID, readCommittedOutcome: async () => ({ kind: "V1_TEAM_AUTHORIZATION", digest: updated }),
        }), { status: "confirmed", intentID });
        assert.equal((await fence.snapshot()).v1TeamAuthorization.digest, updated);
        assert.deepEqual(await new PublicationFenceCoordinator({ fence }).reconcile({ intentID }), { status: "confirmed", intentID });
    } finally {
        await rm(directory, { recursive: true, force: true });
    }
});
