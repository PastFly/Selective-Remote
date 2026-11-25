import { createHash } from "node:crypto";
import { assertWriterTriggers, requireIndependentV1Anchor } from "./v1-commit-fence.mjs";

const maxRowsPerTable = 20_000;
const digestPattern = /^[a-f0-9]{64}$/u;

// All identifiers and row expressions below are fixed by the Cloud schema.
// Signed trust records and invitation state are part of the authorization
// decision. Mutation receipts prevent an older database from replaying a
// consumed request even when permission values have since returned to their
// previous state. Login telemetry and encrypted Vault content use their own state.
const projections = [
    ["device_trust_certificates_v1"],
    ["device_trust_challenges_v1"],
    ["device_trust_directories_v1"],
    ["device_trust_mutation_receipts_v1"],
    ["device_trust_requests_v1"],
    ["device_trust_revocations_v1"],
    ["device_trust_roots_v1"],
    ["devices", ["id", "user_id", "platform", "public_key", "public_key_algorithm", "key_registered_at", "key_approved_at", "key_approved_by_device_id", "revoked_at"]],
    ["shared_vault_key_wrappers"],
    ["shared_vault_rotation_tasks"],
    ["shared_vaults", ["id", "team_id", "created_by_user_id", "format_state", "format_schema_version",
        "key_generation", "rotation_required", "archived_at", "access_policy_version"]],
    ["team_access_group_members"],
    ["team_access_groups"],
    ["team_access_mutation_receipts"],
    ["team_invitation_link_secrets"],
    ["team_invitation_vault_wrappers"],
    ["team_invitation_wrapper_devices"],
    ["team_invitation_wrapper_vaults"],
    ["team_invitations"],
    ["team_membership_device_admissions"],
    ["team_memberships"],
    ["team_mutation_receipts"],
    ["team_policy_revisions"],
    ["teams"],
    ["users", ["id", "email", "username", "email_verified_at", "disabled_at"]],
    ["vault_access_grants"],
    ["vault_resource_registry"],
];

// PostgreSQL binary records preserve timestamps and bytes independently of
// session formatting. Each table contributes a bounded digest, with no rows,
// wrapped keys, invitation tokens or credentials returned to Cloud.
const projectionQueries = projections.map(([table, fields]) => `
    SELECT '${table}' AS table_name, count(*)::int AS row_count,
      pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
        COALESCE(string_agg(row_digest, '' ORDER BY row_digest COLLATE "C"), ''), 'UTF8'
      )), 'hex') AS table_digest
    FROM (
      SELECT pg_catalog.encode(pg_catalog.sha256(pg_catalog.record_send(
        ${fields ? `ROW(${fields.map(field => 'r.' + field).join(", ")})` : "r"}
      )), 'hex') AS row_digest
      FROM public.${table} r LIMIT ${maxRowsPerTable + 1}
    ) AS rows`);
const projectionSQL = `
    SELECT * FROM (${projectionQueries.join(" UNION ALL ")}) AS authorization_rows
    ORDER BY table_name COLLATE "C"`;

const guardedTables = projections.map(([table]) => "public." + table).join(", ");
const rowTrigger = "selective_remote_v1_team_authorization_row";
const truncateTrigger = "selective_remote_v1_team_authorization_truncate";
const functionName = "selective_remote_require_v1_team_authorization";
const marker = "selective_remote.v1_team_authorization";
const functionBody = `
    BEGIN
      IF pg_catalog.current_setting('${marker}', true) IS DISTINCT FROM 'retained-v1' THEN
        RAISE EXCEPTION 'v1_team_authorization_writer_required' USING ERRCODE = 'P0001';
      END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
      RETURN NEW;
    END `;

// Installation belongs to isolated maintenance. A retained floor must never
// reinstall these triggers to make a restored database pass compatibility.
export async function installV1TeamAuthorizationFence(pool) {
    const client = await pool.connect();
    try {
        await client.query("BEGIN");
        await client.query(`LOCK TABLE ${guardedTables} IN ACCESS EXCLUSIVE MODE`);
        await client.query(`CREATE FUNCTION public.${functionName}()
            RETURNS trigger LANGUAGE plpgsql AS $$${functionBody}$$`);
        for (const [table, fields] of projections) {
            const update = fields ? "UPDATE OF " + fields.join(", ") : "UPDATE";
            await client.query(`CREATE TRIGGER ${rowTrigger} BEFORE INSERT OR DELETE OR ${update} ON public.${table}
                FOR EACH ROW EXECUTE FUNCTION public.${functionName}()`);
            await client.query(`CREATE TRIGGER ${truncateTrigger} BEFORE TRUNCATE ON public.${table}
                FOR EACH STATEMENT EXECUTE FUNCTION public.${functionName}()`);
        }
        await client.query("COMMIT");
    } catch (error) {
        try { await client.query("ROLLBACK"); } catch {}
        throw error;
    } finally {
        client.release();
    }
}

export async function assertV1TeamAuthorizationFence(query) {
    const expected = new Map(projections.flatMap(([table, fields]) => [
        [rowTrigger + ":" + table, { type: 31, columns: fields ?? [] }],
        [truncateTrigger + ":" + table, { type: 34, columns: [] }],
    ]));
    return assertWriterTriggers(query, {
        expected, triggers: [rowTrigger, truncateTrigger], functionBody, functionName,
        errorCode: "v1_team_authorization_fence_missing",
    });
}

const writerLockName = "selective-remote/v1-team-authorization";
export async function lockV1TeamAuthorizationWriter(client) {
    // The session lock survives COMMIT through journal confirmation. The
    // caller must discard this connection if unlocking fails.
    await client.query("SELECT pg_catalog.pg_advisory_lock(pg_catalog.hashtextextended($1, 0))", [writerLockName]);
    return async () => {
        const result = await client.query("SELECT pg_catalog.pg_advisory_unlock(pg_catalog.hashtextextended($1, 0)) AS unlocked", [writerLockName]);
        if (result.rows[0]?.unlocked !== true) throw new Error("deployment_team_authorization_lock_lost");
    };
}

export async function holdV1TeamAuthorizationReadback(query) {
    await query(`LOCK TABLE ${guardedTables} IN SHARE MODE`);
    await assertV1TeamAuthorizationFence(query);
}

export async function holdV1TeamAuthorizationFence(client, fence) {
    requireIndependentV1Anchor(fence);
    await fence.assertWritable();
    const { v1TeamAuthorization } = await fence.snapshot();
    const query = (text, values) => client.query(text, values);
    await query(`LOCK TABLE ${guardedTables} IN ROW EXCLUSIVE MODE`);
    await assertV1TeamAuthorizationFence(query);
    await assertV1TeamAuthorization(query, v1TeamAuthorization);
    await query("SELECT pg_catalog.set_config($1, $2, true)", [marker, "retained-v1"]);
    return v1TeamAuthorization.digest;
}

export async function readV1TeamAuthorizationDigest(query) {
    const result = await query(projectionSQL);
    const names = new Set(projections.map(([table]) => table));
    if (!Array.isArray(result?.rows) || result.rows.length !== names.size) {
        throw new Error("deployment_team_authorization_mismatch");
    }
    const digest = createHash("sha256").update("selective-remote/v1-team-authorization-pg16/v1\0");
    for (const { table_name, row_count, table_digest } of result.rows) {
        if (!names.delete(table_name) || !Number.isSafeInteger(row_count) || row_count < 0
            || row_count > maxRowsPerTable || typeof table_digest !== "string" || !digestPattern.test(table_digest)) {
            throw new Error("deployment_team_authorization_mismatch");
        }
        digest.update(JSON.stringify([table_name, row_count, table_digest]));
    }
    return digest.digest("hex");
}

export async function assertV1TeamAuthorization(query, authorization) {
    if (authorization?.pending) throw new Error("deployment_fence_pending");
    if (authorization?.protocol !== 1 || typeof authorization.digest !== "string" || !digestPattern.test(authorization.digest)
        || await readV1TeamAuthorizationDigest(query) !== authorization.digest) {
        throw new Error("deployment_team_authorization_mismatch");
    }
}

export async function readCommittedV1TeamAuthorizationOutcome({ query, intent }) {
    const digest = await readV1TeamAuthorizationDigest(query);
    if (digest === intent.previousDigest) return null;
    if (digest !== intent.nextDigest) throw new Error("deployment_fence_mismatch");
    return { kind: "V1_TEAM_AUTHORIZATION", digest };
}
