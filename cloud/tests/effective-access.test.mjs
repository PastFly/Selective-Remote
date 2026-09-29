import assert from "node:assert/strict";
import test from "node:test";
import { compileEffectiveAccess } from "../src/effective-access.mjs";

const membership = { id: "member-1", userID: "user-1", epoch: 3 };
const target = { id: "host-1", kind: "HOST", teamID: "team-1", vaultID: "vault-1",
  parentFolderID: "folder-2", deletedAt: null };
const ancestors = [
  { id: "folder-2", kind: "FOLDER", teamID: "team-1", vaultID: "vault-1",
    parentFolderID: "folder-1", deletedAt: null },
  { id: "folder-1", kind: "FOLDER", teamID: "team-1", vaultID: "vault-1",
    parentFolderID: null, deletedAt: null },
];
const base = { target, ancestors, membership, groupIDs: ["group-1"],
  cryptoStatus: "NO", requiresCrypto: false };

test("direct, group and each ancestor path remain separately explainable", () => {
  const grants = [
    { id: "direct", teamID: "team-1", vaultID: "vault-1", principalKind: "USER",
      principalID: "user-1", membershipID: "member-1", membershipEpoch: 3,
      targetKind: "RESOURCE", targetID: "host-1", mask: 1, revokedAt: null },
    { id: "group", teamID: "team-1", vaultID: "vault-1", principalKind: "GROUP",
      principalID: "group-1", targetKind: "FOLDER", targetID: "folder-1",
      mask: 1, revokedAt: null },
    { id: "folder", teamID: "team-1", vaultID: "vault-1", principalKind: "USER",
      principalID: "user-1", membershipID: "member-1", membershipEpoch: 3,
      targetKind: "FOLDER", targetID: "folder-2", mask: 1, revokedAt: null },
    { id: "vault", teamID: "team-1", vaultID: "vault-1", principalKind: "USER",
      principalID: "user-1", membershipID: "member-1", membershipEpoch: 3,
      targetKind: "VAULT", targetID: "vault-1", mask: 1, revokedAt: null },
  ];
  const all = compileEffectiveAccess({ ...base, grants });
  assert.deepEqual(all.paths.map((path) => path.id), ["direct", "group", "folder", "vault"]);
  assert.equal(all.policyMask, 1);
  assert.equal(all.effectiveUsable, "YES");
  const afterGroupRevoke = compileEffectiveAccess({ ...base,
    grants: grants.map((grant) => grant.id === "group" ? { ...grant, revokedAt: "now" } : grant) });
  assert.deepEqual(afterGroupRevoke.paths.map((path) => path.id), ["direct", "folder", "vault"]);
  assert.equal(afterGroupRevoke.policyMask, 1);
});

test("stale membership epoch and unrelated Team/Vault grants cannot contribute", () => {
  const result = compileEffectiveAccess({ ...base, grants: [
    { id: "stale", teamID: "team-1", vaultID: "vault-1", principalKind: "USER",
      principalID: "user-1", membershipID: "member-1", membershipEpoch: 2,
      targetKind: "RESOURCE", targetID: "host-1", mask: 1 },
    { id: "foreign", teamID: "other-team", vaultID: "vault-1", principalKind: "GROUP",
      principalID: "group-1", targetKind: "RESOURCE", targetID: "host-1", mask: 1 },
  ] });
  assert.equal(result.policyAllowed, false);
  assert.equal(result.effectiveUsable, "NO");
});

test("broken or cyclic Folder ancestry fails closed", () => {
  assert.throws(() => compileEffectiveAccess({ ...base,
    ancestors: [{ ...ancestors[0], parentFolderID: "folder-2" }], grants: [] }),
  /invalid_access_ancestry/);
  assert.throws(() => compileEffectiveAccess({ ...base,
    ancestors: [{ ...ancestors[0], vaultID: "other-vault" }, ancestors[1]],
    grants: [] }), /invalid_access_ancestry/);
});

test("Credential inherited View maps only to ViewMetadata and no Reveal", () => {
  const credential = { ...target, kind: "CREDENTIAL" };
  const result = compileEffectiveAccess({ ...base, target: credential, grants: [
    { id: "folder-view", teamID: "team-1", vaultID: "vault-1",
      principalKind: "GROUP", principalID: "group-1", targetKind: "FOLDER",
      targetID: "folder-1", mask: 1 },
  ], cryptoStatus: "WRAP_PRESENT_UNVERIFIED", requiresCrypto: true });
  assert.equal(result.policyMask, 1);
  assert.equal(result.paths[0].permission, "ViewMetadata");
  assert.equal(result.effectiveUsable, "UNKNOWN");
});
