// Internal synthetic staging operator only. Deliberately absent from HTTP routing.
import {
  migrationHash,
  canonicalMigrationJSON,
  validateMigrationResources,
  defaultMigrationPolicy,
  migrationRecipients,
  verifyMigrationManifest,
  previewMigrationPolicy,
} from "./migration-policy.mjs";
import { validateSignedDeviceBundle } from "./device-trust-policy.mjs";
import {
  validateResourceCipherEnvelope,
  validateResourceKeyWrapper,
} from "../public/resource-crypto-v2.js";
import { requireAccessMutation } from "./team-policy.mjs";
const lockTables = [
  "devices",
  "device_trust_certificates_v1",
  "device_trust_directories_v1",
  "device_trust_revocations_v1",
  "device_trust_roots_v1",
  "shared_vault_key_wrappers",
  "shared_vault_revisions",
  "shared_vault_rotation_tasks",
  "shared_vaults",
  "team_access_group_members",
  "team_access_groups",
  "team_membership_device_admissions",
  "team_memberships",
  "team_invitation_vault_wrappers",
  "team_policy_revisions",
  "teams",
  "users",
  "vault_access_grants",
  "vault_migration_attempts",
  "vault_migration_parts",
  "vault_migration_resources",
  "vault_resource_ciphertext_versions",
  "vault_resource_key_wrappers_v2",
  "vault_resource_manifest_pointers_v2",
  "vault_resource_registry",
  "vault_resource_identity_reservations",
];
export class VaultMigrationStore {
  constructor(
    pool,
    {
      environment,
      enabled = false,
      allowedVaultIDs = [],
      fence = null,
      faultAt = () => {},
    } = {},
  ) {
    this.pool = pool;
    this.enabled = enabled === true && environment === "staging";
    this.allowed = new Set(allowedVaultIDs);
    this.fence = fence;
    this.faultAt = faultAt;
  }
  gate(input) {
    if (!this.enabled || !this.allowed.has(input?.vaultID))
      throw Error("migration_staging_only");
    if (input.schemaVersion !== 2 || input.capability !== "resource_acl_v2")
      throw Error("vault_upgrade_required");
  }
  async transaction(input, work, { write = true } = {}) {
    this.gate(input);
    for (let attempt = 0; ; attempt++) {
      const c = await this.pool.connect();
      let retry = false;
      try {
        await c.query(
          write ? "BEGIN" : "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY",
        );
        if (write)
          await c.query(
            `LOCK TABLE ${lockTables.join(",")} IN SHARE ROW EXCLUSIVE MODE`,
          );
        const result = await work(c);
        await c.query("COMMIT");
        return result;
      } catch (e) {
        await c.query("ROLLBACK").catch(() => {});
        if (attempt < 3 && ["40P01", "40001"].includes(e.code)) retry = true;
        else throw e;
      } finally {
        c.release();
      }
      if (retry)
        await new Promise((resolve) => setTimeout(resolve, 20 * (attempt + 1)));
    }
  }
  async snapshot(c, input, { active = false, mutation = true } = {}) {
    const { teamID, vaultID, actorUserID, actorDeviceID } = input;
    const membership = (
      await c.query(
        `SELECT m.id,m.user_id,m.role,m.epoch FROM team_memberships m JOIN teams t ON t.id=m.team_id AND t.archived_at IS NULL JOIN users u ON u.id=m.user_id AND u.disabled_at IS NULL WHERE m.team_id=$1 AND m.user_id=$2 AND m.revoked_at IS NULL`,
        [teamID, actorUserID],
      )
    ).rows[0];
    if (!membership) throw Error("team_not_found");
    if (mutation) requireAccessMutation(membership.role);
    const vault = (
      await c.query(
        "SELECT * FROM shared_vaults WHERE team_id=$1 AND id=$2 AND archived_at IS NULL",
        [teamID, vaultID],
      )
    ).rows[0];
    if (!vault) throw Error("team_not_found");
    if (!active && vault.format_state !== "V1_ACTIVE")
      throw Error("migration_already_active");
    if (!active && (vault.revision === "0" || vault.rotation_required))
      throw Error("migration_source_not_ready");
    const raw = {};
    const queries = {
      memberships: [
        "SELECT to_jsonb(m) AS data FROM team_memberships m WHERE team_id=$1 ORDER BY id",
        [teamID],
      ],
      teams: ["SELECT to_jsonb(t) AS data FROM teams t WHERE id=$1", [teamID]],
      users: [
        "SELECT jsonb_build_object('id',u.id,'disabled_at',u.disabled_at) AS data FROM users u WHERE id IN(SELECT user_id FROM team_memberships WHERE team_id=$1) ORDER BY id",
        [teamID],
      ],
      devices: [
        "SELECT to_jsonb(d)-'last_seen_at'-'name'-'app_version' AS data FROM devices d WHERE user_id IN(SELECT user_id FROM team_memberships WHERE team_id=$1) ORDER BY id",
        [teamID],
      ],
      admissions: [
        "SELECT to_jsonb(a) AS data FROM team_membership_device_admissions a WHERE membership_id IN(SELECT id FROM team_memberships WHERE team_id=$1) ORDER BY membership_id,membership_epoch,device_id",
        [teamID],
      ],
      roots: [
        "SELECT jsonb_build_object('accountID',account_id,'rootPublicKey',encode(root_public_key,'base64'),'fingerprint',encode(fingerprint,'hex'),'custodianDeviceID',custodian_device_id) AS data FROM device_trust_roots_v1 WHERE account_id IN(SELECT user_id FROM team_memberships WHERE team_id=$1) ORDER BY account_id",
        [teamID],
      ],
      certificates: [
        "SELECT to_jsonb(c) AS data FROM device_trust_certificates_v1 c WHERE account_id IN(SELECT user_id FROM team_memberships WHERE team_id=$1) ORDER BY account_id,device_id,key_version",
        [teamID],
      ],
      directories: [
        "SELECT to_jsonb(d) AS data FROM device_trust_directories_v1 d WHERE account_id IN(SELECT user_id FROM team_memberships WHERE team_id=$1) ORDER BY account_id,version",
        [teamID],
      ],
      revocations: [
        "SELECT to_jsonb(r) AS data FROM device_trust_revocations_v1 r WHERE account_id IN(SELECT user_id FROM team_memberships WHERE team_id=$1) ORDER BY account_id,device_id,key_version",
        [teamID],
      ],
      groups: [
        "SELECT to_jsonb(g) AS data FROM team_access_groups g WHERE team_id=$1 ORDER BY id",
        [teamID],
      ],
      edges: [
        "SELECT to_jsonb(e) AS data FROM team_access_group_members e WHERE team_id=$1 ORDER BY id",
        [teamID],
      ],
      teamPolicy: [
        "SELECT to_jsonb(p) AS data FROM team_policy_revisions p WHERE team_id=$1",
        [teamID],
      ],
      grants: [
        "SELECT to_jsonb(g) AS data FROM vault_access_grants g WHERE vault_id=$1 ORDER BY id",
        [vaultID],
      ],
      registry: [
        "SELECT to_jsonb(r) AS data FROM vault_resource_registry r WHERE vault_id=$1 ORDER BY id",
        [vaultID],
      ],
      pointers: [
        "SELECT to_jsonb(p) AS data FROM vault_resource_manifest_pointers_v2 p WHERE vault_id=$1 ORDER BY resource_id,part",
        [vaultID],
      ],
      rotation: [
        "SELECT to_jsonb(r) AS data FROM shared_vault_rotation_tasks r WHERE vault_id=$1 ORDER BY id",
        [vaultID],
      ],
    };
    for (const [key, [sql, args]] of Object.entries(queries))
      raw[key] = (await c.query(sql, args)).rows.map((r) => r.data);
    for (const [key, table] of [
      ["legacyWrappers", "shared_vault_key_wrappers"],
      ["revisions", "shared_vault_revisions"],
      ["ciphertexts", "vault_resource_ciphertext_versions"],
      ["wrappers", "vault_resource_key_wrappers_v2"],
      ["invitations", "team_invitation_vault_wrappers"],
    ]) {
      const rows = (
        await c.query(
          `SELECT to_jsonb(r) AS data FROM ${table} r WHERE vault_id=$1 ORDER BY to_jsonb(r)::text`,
          [vaultID],
        )
      ).rows.map((r) => r.data);
      raw[key] = await migrationHash(rows);
    }
    const sourceHash = await migrationHash({
      envelopeVersion: vault.envelope_version,
      ciphertext: vault.ciphertext,
      nonce: vault.nonce,
      authTag: vault.auth_tag,
      contentHash: vault.content_hash,
    });
    raw.vault = {
      id: vault.id,
      team_id: vault.team_id,
      revision: vault.revision,
      key_generation: vault.key_generation,
      rotation_required: vault.rotation_required,
      format_state: vault.format_state,
      access_policy_version: vault.access_policy_version,
      sourceHash,
    };
    const memberships = raw.memberships
      .filter(
        (m) =>
          !m.revoked_at &&
          !raw.users.find((u) => u.id === m.user_id)?.disabled_at,
      )
      .map((m) => ({
        id: m.id,
        userID: m.user_id,
        epoch: Number(m.epoch),
        role: m.role,
      }));
    const devices = [];
    for (const d of raw.devices) {
      if (
        d.revoked_at ||
        !d.public_key ||
        d.public_key_algorithm !== "p256-ecdh-v1"
      )
        continue;
      const m = memberships.find((m) => m.userID === d.user_id);
      if (
        !m ||
        !raw.admissions.some(
          (a) =>
            a.membership_id === m.id &&
            Number(a.membership_epoch) === m.epoch &&
            a.device_id === d.id,
        )
      )
        continue;
      const root = raw.roots.find((r) => r.accountID === d.user_id),
        certificate = raw.certificates
          .filter((r) => r.account_id === d.user_id && r.device_id === d.id)
          .at(-1)?.certificate_json,
        checkpoint = raw.directories
          .filter((r) => r.account_id === d.user_id)
          .at(-1)?.directory_json;
      if (
        !root?.custodianDeviceID ||
        !raw.devices.some(
          (d) => d.id === root.custodianDeviceID && !d.revoked_at,
        )
      )
        throw Error("root_custodian_required");
      const rootPublicKey = Buffer.from(
        root.rootPublicKey.replace(/\s/g, ""),
        "base64",
      ).toString("base64url");
      let publicKey;
      try {
        publicKey = JSON.parse(d.public_key);
      } catch {
        throw Error("device_trust_invalid");
      }
      await validateSignedDeviceBundle({
        rootPublicKey,
        certificate,
        checkpoint,
        accountID: d.user_id,
        deviceID: d.id,
        publicKey,
      });
      devices.push({
        membershipID: m.id,
        membershipEpoch: m.epoch,
        deviceID: d.id,
        accountID: d.user_id,
        publicKey,
        rootPublicKey,
        certificate,
        checkpoint,
      });
    }
    const actor = devices.find(
      (d) => d.deviceID === actorDeviceID && d.accountID === actorUserID,
    );
    if (!actor) throw Error("migration_device_admission_required");
    if (
      mutation &&
      raw.roots.find((r) => r.accountID === actorUserID)?.custodianDeviceID !==
        actorDeviceID
    )
      throw Error("root_custodian_required");
    return {
      teamID,
      vaultID,
      sourceRevision: Number(vault.revision),
      sourceHash,
      policyVersion: Number(vault.access_policy_version) + 1,
      raw,
      memberships,
      devices,
      groups: raw.groups
        .filter((g) => !g.deleted_at)
        .map((g) => ({ id: g.id })),
      edges: raw.edges
        .filter((e) => !e.removed_at)
        .map((e) => ({
          groupID: e.group_id,
          userID: e.user_id,
          membershipID: e.membership_id,
          membershipEpoch: Number(e.membership_epoch),
        })),
      actorRole: membership.role,
      actorRootPublicKey: actor.rootPublicKey,
    };
  }
  async preview(input) {
    return this.transaction(
      input,
      async (c) => {
        const snapshot = await this.snapshot(c, input);
        const snapshotHash = await migrationHash(snapshot);
        return {
          snapshot,
          snapshotHash,
          candidate: input.resources ? previewMigrationPolicy({resources:input.resources,policy:input.policy,snapshot}) : null,
          sourceRevision: snapshot.sourceRevision,
          sourceHash: snapshot.sourceHash,
          policyVersion: snapshot.policyVersion,
          oldClientImpact: "UPGRADE_REQUIRED_AFTER_ACTIVATION",
          productionActivation: "BLOCKED",
        };
      },
      { write: false },
    );
  }
  async attempt(c, input) {
    const a = (
      await c.query(
        "SELECT id,team_id,vault_id,actor_user_id,actor_device_id,state,source_revision,source_hash,snapshot_hash,snapshot,policy,resources,scope,manifest,manifest_hash FROM vault_migration_attempts WHERE id=$1 AND team_id=$2 AND vault_id=$3",
        [input.attemptID, input.teamID, input.vaultID],
      )
    ).rows[0];
    if (!a) throw Error("migration_not_found");
    if (
      a.actor_user_id !== input.actorUserID ||
      a.actor_device_id !== input.actorDeviceID
    )
      throw Error("team_access_denied");
    return a;
  }
  async current(c, input, a) {
    const s = await this.snapshot(c, input);
    if ((await migrationHash(s)) !== a.snapshot_hash)
      throw Error("migration_snapshot_stale");
    return s;
  }
  async start(input) {
    return this.transaction(input, async (c) => {
      const s = await this.snapshot(c, input),
        hash = await migrationHash(s);
      validateMigrationResources(input.resources);
      const policy =
        input.policy ??
        defaultMigrationPolicy({ resources: input.resources, snapshot: s });
      const recipients = migrationRecipients({
        resources: input.resources,
        policy,
        snapshot: s,
        actorRole: s.actorRole,
      });
      const existing = (
        await c.query("SELECT * FROM vault_migration_attempts WHERE id=$1", [
          input.attemptID,
        ])
      ).rows[0];
      if (existing) {
        const a = await this.attempt(c, input);
        if (
          a.snapshot_hash !== hash ||
          canonicalMigrationJSON(a.resources) !==
            canonicalMigrationJSON(input.resources) ||
          (input.policy &&
            canonicalMigrationJSON(a.policy) !==
              canonicalMigrationJSON(policy)) ||
          a.state === "DISCARDED"
        )
          throw Error("migration_replay_conflict");
        if (a.state === "FAILED_PRE_ACTIVATION")
          await c.query(
            "UPDATE vault_migration_attempts SET state='V2_PREPARING' WHERE id=$1",
            [a.id],
          );
        return {
          scope: a.scope,
          policy: a.policy,
          recipients: migrationRecipients({
            resources: a.resources,
            policy: a.policy,
            snapshot: s,
            actorRole: s.actorRole,
          }),
        };
      }
      const scope = {
        teamID: input.teamID,
        vaultID: input.vaultID,
        attemptID: input.attemptID,
        sourceRevision: s.sourceRevision,
        sourceHash: s.sourceHash,
        snapshotHash: hash,
        policyVersion: s.policyVersion,
      };
      await c.query(
        "INSERT INTO vault_migration_attempts(id,team_id,vault_id,actor_user_id,actor_device_id,source_revision,source_hash,snapshot_hash,snapshot,policy,resources,scope) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
        [
          input.attemptID,
          input.teamID,
          input.vaultID,
          input.actorUserID,
          input.actorDeviceID,
          s.sourceRevision,
          s.sourceHash,
          hash,
          s,
          JSON.stringify(policy),
          JSON.stringify(input.resources),
          scope,
        ],
      );
      for (const r of input.resources)
        await c.query(
          "INSERT INTO vault_migration_resources(id,attempt_id,team_id,vault_id,kind,parent_folder_id,source_ordinal) VALUES($1,$2,$3,$4,$5,$6,$7)",
          [
            r.id,
            input.attemptID,
            input.teamID,
            input.vaultID,
            r.kind,
            r.parentFolderID,
            r.sourceOrdinal,
          ],
        );
      await this.audit(c, input, "started", {
        resourceCount: input.resources.length,
        snapshotHash: hash,
      });
      await this.faultAt("start");
      return { scope, policy, recipients };
    });
  }
  async audit(c, input, action, metadata = {}) {
    await c.query(
      "INSERT INTO team_audit_events(team_id,actor_user_id,target_vault_id,action,metadata) VALUES($1,$2,$3,$4,$5)",
      [
        input.teamID,
        input.actorUserID,
        input.vaultID,
        "migration." + action,
        { attemptID: input.attemptID, ...metadata },
      ],
    );
  }
  async checkObject(object, a, s, expectedRecipients = null) {
    if (
      !object ||
      Object.keys(object).sort().join(",") !==
        "envelope,part,resourceID,sha256,wrappers"
    )
      throw Error("invalid_migration_object");
    const { sha256, ...body } = object;
    if (sha256 !== (await migrationHash(body)))
      throw Error("migration_object_hash");
    const ctx = validateResourceCipherEnvelope(object.envelope),
      r = a.resources.find((r) => r.id === object.resourceID);
    if (
      !r ||
      ctx.teamID !== a.team_id ||
      ctx.vaultID !== a.vault_id ||
      ctx.resourceID !== r.id ||
      ctx.part !== object.part ||
      ctx.policyVersion !== a.scope.policyVersion ||
      [
        "keyVersion",
        "registryVersion",
        "resourceVersion",
        "manifestVersion",
      ].some((k) => ctx[k] !== 1)
    )
      throw Error("invalid_migration_object");
    const recipients = (expectedRecipients ??
      migrationRecipients({
        resources: a.resources,
        policy: a.policy,
        snapshot: s,
        actorRole: s.actorRole,
        resourceIDs: [r.id],
      }))[r.id]?.[object.part];
    if (
      !recipients ||
      !Array.isArray(object.wrappers) ||
      object.wrappers.length !== recipients.length ||
      recipients.length > 100
    )
      throw Error("migration_wrapper_coverage");
    const seen = new Set();
    for (const w of object.wrappers) {
      const t = validateResourceKeyWrapper(w);
      if (
        t.teamID !== a.team_id ||
        t.vaultID !== a.vault_id ||
        t.resourceID !== r.id ||
        t.part !== object.part ||
        t.keyVersion !== 1 ||
        seen.has(t.deviceID) ||
        !recipients.some(
          (d) =>
            d.deviceID === t.deviceID &&
            d.membershipID === t.membershipID &&
            d.membershipEpoch === t.membershipEpoch,
        )
      )
        throw Error("migration_wrapper_coverage");
      seen.add(t.deviceID);
    }
  }
  async putPart(input, object, checkpoint) {
    return this.transaction(input, async (c) => {
      const a = await this.attempt(c, input),
        s = await this.current(c, input, a);
      await this.checkObject(object, a, s);
      const old = (
        await c.query(
          "SELECT object FROM vault_migration_parts WHERE attempt_id=$1 AND resource_id=$2 AND part=$3",
          [input.attemptID, object.resourceID, object.part],
        )
      ).rows[0];
      if (old) {
        if (
          canonicalMigrationJSON(old.object) !== canonicalMigrationJSON(object)
        )
          throw Error("migration_replay_conflict");
        return old.object;
      }
      if (a.state !== "V2_PREPARING") throw Error("migration_not_preparing");
      if (
        checkpoint !== undefined &&
        (Object.keys(checkpoint ?? {})
          .sort()
          .join(",") !== "ciphertext,nonce,version" ||
          checkpoint?.version !== 1 ||
          !/^[A-Za-z0-9_-]{16}$/.test(checkpoint.nonce) ||
          typeof checkpoint.ciphertext !== "string" ||
          checkpoint.ciphertext.length > 64 * 1024 * 1024)
      )
        throw Error("invalid_migration_checkpoint");
      await c.query(
        "INSERT INTO vault_migration_parts(attempt_id,resource_id,part,object,sha256) VALUES($1,$2,$3,$4,$5)",
        [
          input.attemptID,
          object.resourceID,
          object.part,
          object,
          object.sha256,
        ],
      );
      await this.faultAt("part");
      if (checkpoint !== undefined)
        await c.query(
          "UPDATE vault_migration_attempts SET checkpoint=$2 WHERE id=$1",
          [input.attemptID, checkpoint],
        );
      return object;
    });
  }
  async parts(c, a) {
    const rows = (
      await c.query(
        "SELECT object FROM vault_migration_parts WHERE attempt_id=$1",
        [a.id],
      )
    ).rows;
    return a.resources.flatMap((r) =>
      ["GENERAL", "METADATA", "SECRET"]
        .map(
          (p) =>
            rows.find(
              (x) => x.object.resourceID === r.id && x.object.part === p,
            )?.object,
        )
        .filter(Boolean),
    );
  }
  async verify(c, a, s, manifest) {
    const stored = (
      await c.query(
        "SELECT id,kind,parent_folder_id,source_ordinal FROM vault_migration_resources WHERE attempt_id=$1 ORDER BY source_ordinal",
        [a.id],
      )
    ).rows.map((r) => ({
      id: r.id,
      kind: r.kind,
      parentFolderID: r.parent_folder_id,
      sourceOrdinal: r.source_ordinal,
    }));
    if (
      canonicalMigrationJSON(stored) !==
      canonicalMigrationJSON(
        [...a.resources].sort((a, b) => a.sourceOrdinal - b.sourceOrdinal),
      )
    )
      throw Error("migration_resource_graph_changed");
    const parts = await this.parts(c, a);
    const expectedCount = a.resources.reduce(
      (n, r) => n + (r.kind === "CREDENTIAL" ? 2 : 1),
      0,
    );
    if (parts.length !== expectedCount)
      throw Error("migration_parts_incomplete");
    const recipients = migrationRecipients({
      resources: a.resources,
      policy: a.policy,
      snapshot: s,
      actorRole: s.actorRole,
    });
    for (const object of parts)
      await this.checkObject(object, a, s, recipients);
    await verifyMigrationManifest({
      manifest,
      expected: {
        scope: a.scope,
        policy: a.policy,
        resources: a.resources,
        parts: parts.map((o) => ({
          resourceID: o.resourceID,
          part: o.part,
          sha256: o.sha256,
        })),
      },
      rootPublicKey: s.actorRootPublicKey,
    });
    return parts;
  }
  async validate(input, manifest) {
    try {
      return await this.transaction(input, async (c) => {
        const a = await this.attempt(c, input),
          s = await this.current(c, input, a);
        const hash = await migrationHash(manifest);
        if (a.state === "V2_READY") {
          if (a.manifest_hash !== hash)
            throw Error("migration_replay_conflict");
          return { state: "V2_READY", manifestHash: hash };
        }
        if (a.state !== "V2_PREPARING") throw Error("migration_not_preparing");
        await this.verify(c, a, s, manifest);
        await this.faultAt("validate");
        await c.query(
          "UPDATE vault_migration_attempts SET state='V2_READY',manifest=$2,manifest_hash=$3 WHERE id=$1",
          [input.attemptID, manifest, hash],
        );
        await this.audit(c, input, "prepared", { manifestHash: hash });
        return { state: "V2_READY", manifestHash: hash };
      });
    } catch (e) {
      await this.recordFailure(input).catch(() => {});
      throw e;
    }
  }
  async recordFailure(input) {
    return this.transaction(input, async (c) => {
      await this.snapshot(c, input, { active: true });
      const a = await this.attempt(c, input);
      if (a.state === "V2_PREPARING") {
        await c.query(
          "UPDATE vault_migration_attempts SET state='FAILED_PRE_ACTIVATION' WHERE id=$1",
          [a.id],
        );
        await this.audit(c, input, "failed", {
          blocker: "PREPARATION_VALIDATION_FAILED",
        });
      }
    });
  }
  async manifestHash(input) {
    return this.transaction(
      input,
      async (c) => {
        await this.snapshot(c, input, { active: true });
        return (await this.attempt(c, input)).manifest_hash;
      },
      { write: false },
    );
  }
  async activate(input, manifestHash) {
    return this.transaction(input, async (c) => {
      const a = await this.attempt(c, input);
      if (a.manifest_hash !== manifestHash)
        throw Error("migration_replay_conflict");
      if (a.state === "V2_ACTIVE") {
        await this.snapshot(c, input, { active: true });
        return { state: "V2_ACTIVE", manifestHash };
      }
      const s = await this.current(c, input, a);
      if (a.state !== "V2_READY") throw Error("migration_not_ready");
      const commitments = (
        await c.query(
          "SELECT resource_id,part,sha256 FROM vault_migration_parts WHERE attempt_id=$1 ORDER BY resource_id,part",
          [a.id],
        )
      ).rows.map((r) => ({
        resourceID: r.resource_id,
        part: r.part,
        sha256: r.sha256,
      }));
      const expected = [...a.manifest.payload.parts].sort(
        (a, b) =>
          a.resourceID.localeCompare(b.resourceID) ||
          a.part.localeCompare(b.part),
      );
      if (
        canonicalMigrationJSON(commitments) !== canonicalMigrationJSON(expected)
      )
        throw Error("migration_parts_incomplete");
      await verifyMigrationManifest({
        manifest: a.manifest,
        expected: {
          scope: a.scope,
          policy: a.policy,
          resources: a.resources,
          parts: a.manifest.payload.parts,
        },
        rootPublicKey: s.actorRootPublicKey,
      });
      if (typeof this.fence?.intent !== "function")
        throw Error("deployment_fence_required");
      await this.fence.intent({
        teamID: input.teamID,
        vaultID: input.vaultID,
        attemptID: input.attemptID,
        manifestHash,
        schemaFloor: 19,
      });
      await this.faultAt("pre_activation");
      await c.query(
        "UPDATE vault_migration_attempts SET state='V2_ACTIVE' WHERE id=$1",
        [input.attemptID],
      );
      await this.faultAt("active_attempt");
      await c.query(
        "UPDATE shared_vaults SET format_state='V2_ACTIVE',format_schema_version=2,active_publication_attempt_id=$2,access_policy_version=$3,envelope_version=NULL,ciphertext=NULL,nonce=NULL,auth_tag=NULL,content_hash=NULL,updated_by_device_id=NULL WHERE id=$1",
        [input.vaultID, input.attemptID, a.scope.policyVersion],
      );
      await this.faultAt("active_pointer");
      for (const table of [
        "shared_vault_key_wrappers",
        "shared_vault_revisions",
        "team_invitation_vault_wrappers",
      ]) {
        await c.query(`DELETE FROM ${table} WHERE vault_id=$1`, [
          input.vaultID,
        ]);
        await this.faultAt(table);
      }
      await this.audit(c, input, "activated", { manifestHash });
      await this.faultAt("activation_audit");
      return { state: "V2_ACTIVE", manifestHash };
    });
  }
  async discard(input) {
    return this.transaction(input, async (c) => {
      await this.snapshot(c, input);
      const a = await this.attempt(c, input);
      if (a.state === "V2_ACTIVE") throw Error("migration_fix_forward_only");
      if (a.state === "DISCARDED") return { state: "DISCARDED" };
      await c.query(
        "UPDATE vault_migration_attempts SET state='DISCARDED' WHERE id=$1",
        [input.attemptID],
      );
      await c.query("DELETE FROM vault_migration_parts WHERE attempt_id=$1", [
        input.attemptID,
      ]);
      await c.query(
        "DELETE FROM vault_migration_resources WHERE attempt_id=$1",
        [input.attemptID],
      );
      await this.audit(c, input, "discarded");
      return { state: "DISCARDED" };
    });
  }
  async readPart(input) {
    return this.transaction(
      input,
      async (c) => {
        const s = await this.snapshot(c, input, {
          active: true,
          mutation: false,
        });
        const a = (
          await c.query(
            "SELECT a.* FROM vault_migration_attempts a JOIN shared_vaults v ON v.active_publication_attempt_id=a.id WHERE a.vault_id=$1 AND a.team_id=$2 AND a.state='V2_ACTIVE' AND v.format_state='V2_ACTIVE'",
            [input.vaultID, input.teamID],
          )
        ).rows[0];
        if (!a) throw Error("migration_not_active");
        if (
          [
            "memberships",
            "groups",
            "edges",
            "devices",
            "admissions",
            "roots",
            "certificates",
            "directories",
            "revocations",
            "teamPolicy",
            "grants",
          ].some(
            (key) =>
              canonicalMigrationJSON(s.raw[key]) !==
              canonicalMigrationJSON(a.snapshot.raw[key]),
          )
        )
          throw Error("migration_active_policy_stale");
        const recipients = migrationRecipients({
          resources: a.resources,
          policy: a.policy,
          snapshot: s,
          actorRole: "owner",
        });
        if (
          !recipients[input.resourceID]?.[input.part]?.some(
            (d) =>
              d.deviceID === input.actorDeviceID &&
              d.accountID === input.actorUserID,
          )
        )
          throw Error("team_access_denied");
        const obj = (
          await c.query(
            "SELECT object FROM active_vault_migration_parts WHERE attempt_id=$1 AND resource_id=$2 AND part=$3",
            [a.id, input.resourceID, input.part],
          )
        ).rows[0]?.object;
        if (!obj) throw Error("migration_part_not_found");
        await this.checkObject(obj, a, { ...s, actorRole: "owner" });
        return {
          ...obj,
          wrappers: obj.wrappers.filter(
            (w) => w.context.deviceID === input.actorDeviceID,
          ),
        };
      },
      { write: false },
    );
  }
}
