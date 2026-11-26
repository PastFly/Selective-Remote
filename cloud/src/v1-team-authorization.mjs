import { createHash } from "node:crypto";
import { assertWriterTriggers, holdV1CommitReadback, requireIndependentV1Anchor } from "./v1-commit-fence.mjs";
import { assertV1DataFloor } from "./v1-data-fence.mjs";
import { readActivePublications, readMigrationSchemaVersion } from "./migration-compatibility.mjs";

const maxRowsPerTable = 20_000;
const digestPattern = /^[a-f0-9]{64}$/u;
export const teamAuthorizationProtocol = 2;
export const teamAuthorizationSchemaFloor = 23;

// All identifiers and row expressions below are fixed by the Cloud schema.
// Signed trust records and invitation state are part of the authorization
// decision. Mutation receipts prevent an older database from replaying a
// consumed request even when permission values have since returned to their
// previous state. Login telemetry and encrypted Vault content use their own state.
const legacyProjection = [
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
const addedProjection = [
    ["vault_resource_ciphertext_versions", ["team_id", "vault_id", "resource_id", "part", "key_version",
        "policy_version", "registry_version", "resource_version", "manifest_version", "lifecycle", "obsolete_at"]],
    ["vault_resource_key_wrappers_v2"],
    ["vault_resource_manifest_pointers_v2"],
    ["vault_resource_mutation_receipts_v2"],
];
const projections = [...legacyProjection, ...addedProjection];

function projectionFor(protocol) {
    if (protocol === 1) return legacyProjection;
    if (protocol === teamAuthorizationProtocol) return projections;
    throw new Error("deployment_code_floor");
}

// PostgreSQL binary records preserve timestamps and bytes independently of
// session formatting. Each table contributes a bounded digest, with no rows,
// wrapped keys, invitation tokens or credentials returned to Cloud.
const projectionQuery = ([table, fields]) => `
    SELECT '${table}' AS table_name, count(*)::int AS row_count,
      pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to(
        COALESCE(string_agg(row_digest, '' ORDER BY row_digest COLLATE "C"), ''), 'UTF8'
      )), 'hex') AS table_digest
    FROM (
      SELECT pg_catalog.encode(pg_catalog.sha256(pg_catalog.record_send(
        ${fields ? `ROW(${fields.map(field => 'r.' + field).join(", ")})` : "r"}
      )), 'hex') AS row_digest
      FROM public.${table} r LIMIT ${maxRowsPerTable + 1}
    ) AS rows`;
const projectionSQL = new Map([1, teamAuthorizationProtocol].map(protocol => [protocol, `
    SELECT * FROM (${projectionFor(protocol).map(projectionQuery).join(" UNION ALL ")}) AS authorization_rows
    ORDER BY table_name COLLATE "C"`]));

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

async function requireTeamAuthorizationSchema(query) {
    const result = await query("SELECT 1 FROM public.schema_migrations WHERE version = $1", [teamAuthorizationSchemaFloor]);
    if (result.rows.length !== 1) throw new Error("deployment_schema_floor");
}

async function installGuards(query, projection) {
    for (const [table, fields] of projection) {
        const update = fields ? "UPDATE OF " + fields.join(", ") : "UPDATE";
        await query(`CREATE TRIGGER ${rowTrigger} BEFORE INSERT OR DELETE OR ${update} ON public.${table}
            FOR EACH ROW EXECUTE FUNCTION public.${functionName}()`);
        await query(`CREATE TRIGGER ${truncateTrigger} BEFORE TRUNCATE ON public.${table}
            FOR EACH STATEMENT EXECUTE FUNCTION public.${functionName}()`);
    }
}

// Installation belongs to isolated maintenance. A retained floor must never
// reinstall these triggers to make a restored database pass compatibility.
export async function installV1TeamAuthorizationFence(pool, protocol = teamAuthorizationProtocol) {
    const projection = projectionFor(protocol);
    const client = await pool.connect();
    try {
        await client.query("BEGIN");
        const query = (sql, values) => client.query(sql, values);
        if (protocol === teamAuthorizationProtocol) await requireTeamAuthorizationSchema(query);
        await client.query(`LOCK TABLE ${guardedTables} IN ACCESS EXCLUSIVE MODE`);
        await client.query(`CREATE FUNCTION public.${functionName}()
            RETURNS trigger LANGUAGE plpgsql AS $$${functionBody}$$`);
        await installGuards(query, projection);
        await client.query("COMMIT");
    } catch (error) {
        try { await client.query("ROLLBACK"); } catch {}
        throw error;
    } finally {
        client.release();
    }
}

export async function assertV1TeamAuthorizationFence(query, protocol = teamAuthorizationProtocol) {
    const projection = projectionFor(protocol);
    if (protocol === teamAuthorizationProtocol) await requireTeamAuthorizationSchema(query);
    const expected = new Map(projection.flatMap(([table, fields]) => [
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

export async function readV1TeamAuthorizationDigest(query, protocol = teamAuthorizationProtocol) {
    const names = new Set(projectionFor(protocol).map(([table]) => table));
    const result = await query(projectionSQL.get(protocol));
    if (!Array.isArray(result?.rows) || result.rows.length !== names.size) {
        throw new Error("deployment_team_authorization_mismatch");
    }
    const digest = createHash("sha256").update(`selective-remote/v1-team-authorization-pg16/v${protocol}\0`);
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
    if (authorization?.protocol !== teamAuthorizationProtocol || typeof authorization.digest !== "string" || !digestPattern.test(authorization.digest)
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

async function assertUpgradeSource(query, authorization, schemaVersion) {
    let guardProtocol = 1;
    if (schemaVersion === teamAuthorizationSchemaFloor) {
        try {
            await assertV1TeamAuthorizationFence(query);
            guardProtocol = teamAuthorizationProtocol;
        } catch (error) {
            if (error.message !== "v1_team_authorization_fence_missing") throw error;
        }
    }
    if (guardProtocol === 1) await assertV1TeamAuthorizationFence(query, 1);
    if (await readV1TeamAuthorizationDigest(query, 1) !== authorization.digest) {
        throw new Error("deployment_team_authorization_mismatch");
    }
    // Format 1 made no commitment to these tables. A nonempty projection
    // could be an older restore with stale permissions or replay receipts.
    const presence = await query(`SELECT EXISTS (
        ${addedProjection.map(([table]) => `SELECT 1 FROM public.${table}`).join(" UNION ALL ")}
    ) AS has_rows`);
    if (presence.rows[0]?.has_rows !== false) throw new Error("deployment_team_authorization_untracked_state");
    return guardProtocol;
}

async function assertDurablePrimary(query) {
    const result = await query(`SELECT NOT pg_catalog.pg_is_in_recovery()
        AND pg_catalog.current_setting('fsync') = 'on'
        AND pg_catalog.current_setting('full_page_writes') = 'on' AS durable`);
    if (result.rows[0]?.durable !== true) throw new Error("deployment_postgres_durability_required");
}

// Only the protected staging controller calls this operation. SQL changes are
// durable before the anchor advances. The same operation can resume from a
// database that has already installed all its guards under the old digest.
export async function upgradeTeamAuthorizationFormat({ pool, fence, preflight = false }) {
    requireIndependentV1Anchor(fence);
    const client = await pool.connect();
    const query = (sql, values) => client.query(sql, values);
    let unlock, inTransaction = false, discard, durable = false;
    try {
        unlock = await lockV1TeamAuthorizationWriter(client);
        for (;;) {
            inTransaction = true;
            await query("BEGIN");
            await query(`LOCK TABLE public.schema_migrations, ${guardedTables} IN ACCESS EXCLUSIVE MODE`);
            await holdV1CommitReadback(query);
            const state = await fence.snapshot();
            const authorization = state.v1TeamAuthorization;
            if (state.pending.length || state.v1Pending?.length || authorization?.pending || state.personalWritePilot) {
                throw new Error("deployment_fence_pending");
            }
            if (state.writerFloor !== 1 || !authorization || ![1, teamAuthorizationProtocol].includes(authorization.protocol)) {
                throw new Error("deployment_code_floor");
            }
            const schemaVersion = await readMigrationSchemaVersion(query);
            if (schemaVersion !== teamAuthorizationSchemaFloor && (!preflight || schemaVersion !== 22)) {
                throw new Error("deployment_schema_floor");
            }
            await assertDurablePrimary(query);
            await assertV1DataFloor(query, state);
            if (state.committed.length || (await readActivePublications(query, schemaVersion)).length) {
                throw new Error("deployment_team_authorization_untracked_state");
            }
            if (authorization.protocol === teamAuthorizationProtocol) {
                await assertV1TeamAuthorizationFence(query);
                await assertV1TeamAuthorization(query, authorization);
                return { authorizationProtocol: teamAuthorizationProtocol, upgraded: false };
            }
            const guardProtocol = await assertUpgradeSource(query, authorization, schemaVersion);
            if (preflight) return { authorizationProtocol: 1, upgraded: false };
            await fence.assertWritable();
            if (!durable) {
                await query("SET LOCAL synchronous_commit = 'on'");
                if (guardProtocol === 1) await installGuards(query, addedProjection);
                await assertV1TeamAuthorizationFence(query);
                // Generate WAL even when the guards were installed by a
                // prior process. This keeps the ledger contents unchanged
                // and its synchronous commit flushes earlier schema and DDL.
                const result = await query("UPDATE public.schema_migrations SET version = version WHERE version = $1",
                    [teamAuthorizationSchemaFloor]);
                if (result.rowCount !== 1) throw new Error("deployment_schema_floor");
                await query("COMMIT");
                inTransaction = false;
                durable = true;
                continue;
            }
            if (guardProtocol !== teamAuthorizationProtocol) throw new Error("v1_team_authorization_fence_missing");
            const nextDigest = await readV1TeamAuthorizationDigest(query);
            await fence.append({ version: 2, type: "V1_TEAM_AUTHORIZATION_FORMAT_UPGRADED",
                previousDigest: authorization.digest, nextDigest });
            return { authorizationProtocol: teamAuthorizationProtocol, upgraded: true };
        }
    } catch (error) {
        if (!unlock) discard = error;
        throw error;
    } finally {
        try {
            if (inTransaction) await query("ROLLBACK");
            await unlock?.();
        } catch (error) {
            discard = error;
        }
        client.release(discard);
    }
}
