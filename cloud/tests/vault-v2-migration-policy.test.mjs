import assert from "node:assert/strict";
import test from "node:test";
import {
  migrationFixture,
  record,
  legacy,
  uuid,
} from "./vault-v2-migration-fixtures.mjs";
import { prepareLegacyMigration } from "../public/vault-v2-migration.js";
import {
  migrationRecipients,
  validateMigrationResources,
  verifyMigrationManifest,
  defaultMigrationPolicy,
} from "../src/migration-policy.mjs";
function setup() {
  const teamID = uuid(),
    vaultID = uuid(),
    member = { id: uuid(), userID: uuid(), epoch: 1, role: "owner" },
    resource = {
      id: uuid(),
      kind: "CREDENTIAL",
      parentFolderID: null,
      sourceOrdinal: 0,
    };
  return {
    resources: [resource],
    snapshot: {
      teamID,
      vaultID,
      memberships: [member],
      devices: [
        { membershipID: member.id, membershipEpoch: 1, deviceID: uuid() },
      ],
      groups: [],
      edges: [],
    },
  };
}
test("exact kind grants yield exact part devices and reject Edit without Reveal", () => {
  const f = setup();
  let policy = defaultMigrationPolicy(f);
  assert.deepEqual(migrationRecipients({ ...f, policy })[f.resources[0].id], {
    METADATA: f.snapshot.devices,
    SECRET: f.snapshot.devices,
  });
  policy[0].mask = 4;
  assert.throws(
    () => migrationRecipients({ ...f, policy }),
    /credential_edit_requires_reveal/,
  );
});
test("inheritance is View-only across multiple folders with epoch-bound groups", () => {
  const f = setup(),
    a = { id: uuid(), kind: "FOLDER", parentFolderID: null, sourceOrdinal: 1 },
    b = { id: uuid(), kind: "FOLDER", parentFolderID: a.id, sourceOrdinal: 2 };
  f.resources[0].parentFolderID = b.id;
  f.resources.push(a, b);
  const m = f.snapshot.memberships[0],
    group = uuid();
  f.snapshot.groups = [{ id: group }];
  f.snapshot.edges = [
    {
      groupID: group,
      membershipID: m.id,
      membershipEpoch: 1,
      userID: m.userID,
    },
  ];
  const policy = [
    {
      id: uuid(),
      teamID: f.snapshot.teamID,
      vaultID: f.snapshot.vaultID,
      principalKind: "GROUP",
      principalID: group,
      targetKind: "FOLDER",
      targetID: a.id,
      mask: 1,
      revokedAt: null,
    },
  ];
  const recipients = migrationRecipients({ ...f, policy });
  assert.deepEqual(recipients[f.resources[0].id], {
    METADATA: f.snapshot.devices,
    SECRET: [],
  });
  f.snapshot.edges[0].membershipEpoch = 2;
  assert.deepEqual(migrationRecipients({ ...f, policy })[f.resources[0].id], {
    METADATA: [],
    SECRET: [],
  });
});
test("desired policy rejects foreign scope/epoch and missing eligible devices; admin cannot alter owner", () => {
  const f = setup();
  const policy = defaultMigrationPolicy(f);
  for (const change of [
    { teamID: uuid() },
    { membershipEpoch: 2 },
    { targetID: uuid() },
  ])
    assert.throws(() =>
      migrationRecipients({ ...f, policy: [{ ...policy[0], ...change }] }),
    );
  assert.throws(
    () =>
      migrationRecipients({
        ...f,
        policy: [{ ...policy[0], mask: 1 }],
        actorRole: "admin",
      }),
    /team_access_denied/,
  );
  f.snapshot.devices = [];
  assert.throws(
    () => migrationRecipients({ ...f, policy }),
    /eligible_device_required/,
  );
});
test("graph rejects duplicate ordinal, cycle, nonfolder parent and excess count", () => {
  const r = {
    id: uuid(),
    kind: "HOST",
    parentFolderID: null,
    sourceOrdinal: 0,
  };
  assert.throws(
    () => validateMigrationResources([r, { ...r, id: uuid() }]),
    /invalid_migration_resources/,
  );
  assert.throws(() =>
    validateMigrationResources([{ ...r, parentFolderID: r.id }]),
  );
  assert.throws(() => validateMigrationResources(Array(1001).fill(r)));
});
test("manifest scope, resource and policy commitments and signature cannot be substituted", async () => {
  const f = await migrationFixture();
  const out = await prepareLegacyMigration({
    ...f,
    document: legacy([record("host")]),
    policy: [],
    recipientTargets: () => [f.recipient],
    persistCheckpoint: async () => {},
  });
  const expected = {
    scope: f.scope,
    policy: [],
    resources: out.resources,
    parts: out.manifest.payload.parts,
  };
  assert.equal(
    await verifyMigrationManifest({
      manifest: out.manifest,
      expected,
      rootPublicKey: f.root.publicKey,
    }),
    true,
  );
  await assert.rejects(
    verifyMigrationManifest({
      manifest: out.manifest,
      expected: { ...expected, scope: { ...f.scope, sourceRevision: 2 } },
      rootPublicKey: f.root.publicKey,
    }),
  );
  await assert.rejects(
    verifyMigrationManifest({
      manifest: { ...out.manifest, signature: "A".repeat(86) },
      expected,
      rootPublicKey: f.root.publicKey,
    }),
  );
});
test("default disclosure preserves each Team role and cannot carry arbitrary plaintext grant fields", () => {
  for (const [role, hostMask, credentialMask] of [
    ["owner", 13, 15],
    ["admin", 13, 15],
    ["editor", 5, 7],
    ["viewer", 1, 3],
  ]) {
    const f = setup();
    f.snapshot.memberships[0].role = role;
    f.resources.push({
      id: uuid(),
      kind: "HOST",
      parentFolderID: null,
      sourceOrdinal: 1,
    });
    const policy = defaultMigrationPolicy(f);
    assert.equal(policy[0].mask, credentialMask);
    assert.equal(policy[1].mask, hostMask);
    assert.throws(
      () =>
        migrationRecipients({
          ...f,
          policy: [{ ...policy[0], title: "PRIVATE" }],
        }),
      /invalid_migration_policy/,
    );
  }
});
