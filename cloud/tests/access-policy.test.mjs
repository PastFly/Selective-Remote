import assert from "node:assert/strict";
import test from "node:test";
import {
  validateGrant, inheritedViewBit, evaluateAccessPaths, permissionBits,
  requiredCryptoParts, usabilityByPermission,
} from "../src/access-policy.mjs";
import { requireAccessMutation } from "../src/team-policy.mjs";

test("each policy kind accepts only its exact permission mask", () => {
  const valid = {
    HOST: 1 | 4 | 8, CREDENTIAL: 1 | 2 | 4 | 8,
    SNIPPET: 1 | 4 | 8, FORWARDING: 1 | 8,
    FOLDER: 1 | 32, VAULT: 1 | 4 | 8 | 16,
  };
  for (const [kind, mask] of Object.entries(valid)) {
    assert.equal(validateGrant(kind, mask), mask);
    assert.throws(() => validateGrant(kind, mask | 64), /invalid_grant_permission/);
  }
  assert.throws(() => validateGrant("CREDENTIAL", permissionBits.Edit), /credential_edit_requires_reveal/);
  assert.throws(() => validateGrant("CREDENTIAL", 1 | 4), /credential_edit_requires_reveal/);
  assert.equal(validateGrant("CREDENTIAL", 2 | 4), 6);
  assert.throws(() => validateGrant("UNKNOWN", 1), /invalid_policy_kind/);
});

test("Vault and each Folder level map View to the descendant View or ViewMetadata", () => {
  for (const kind of ["HOST", "CREDENTIAL", "SNIPPET", "FORWARDING", "FOLDER"]) {
    assert.equal(inheritedViewBit(kind), permissionBits.View);
    const result = evaluateAccessPaths({ kind, paths: [
      { id: "vault", sourceType: "INHERITED_CONTAINER", mask: permissionBits.View },
      { id: "folder-1", sourceType: "INHERITED_CONTAINER", mask: permissionBits.View },
      { id: "folder-2", sourceType: "INHERITED_CONTAINER", mask: permissionBits.View },
    ], cryptoStatus: "NO", requiresCrypto: false });
    assert.equal(result.policyMask, permissionBits.View);
    assert.equal(result.paths.length, 3);
    assert.equal(result.paths.every((path) => path.permission ===
      (kind === "CREDENTIAL" ? "ViewMetadata" : "View")), true);
  }
});

test("malformed persisted Credential grant fails evaluation closed", () => {
  assert.throws(() => evaluateAccessPaths({ kind: "CREDENTIAL", paths: [
    { id: "malformed", sourceType: "DIRECT", mask: permissionBits.Edit },
  ], cryptoStatus: "WRAP_PRESENT_UNVERIFIED", requiresCrypto: true }),
  /invalid_persisted_grant/);
});

test("policy and crypto usability stay distinct", () => {
  const input = { kind: "HOST", paths: [
    { id: "direct", sourceType: "DIRECT", mask: permissionBits.View },
  ], requiresCrypto: true };
  assert.equal(evaluateAccessPaths({ ...input, cryptoStatus: "NO" }).effectiveUsable, "NO");
  assert.equal(evaluateAccessPaths({ ...input, cryptoStatus: "WRAP_PRESENT_UNVERIFIED" }).effectiveUsable, "UNKNOWN");
  assert.equal(evaluateAccessPaths({ ...input, cryptoStatus: "WRAP_PRESENT_UNVERIFIED", clientVerified: true }).effectiveUsable, "UNKNOWN");
  assert.equal(evaluateAccessPaths({ ...input, cryptoStatus: "NO", requiresCrypto: false }).effectiveUsable, "YES");
  assert.equal(evaluateAccessPaths({ ...input, paths: [], cryptoStatus: "WRAP_PRESENT_UNVERIFIED" }).effectiveUsable, "NO");
});

test("existing Team role ceiling governs policy mutations", () => {
  for (const target of ["owner", "admin", "editor", "viewer"]) {
    assert.doesNotThrow(() => requireAccessMutation("owner", target));
    if (["owner", "admin"].includes(target)) {
      assert.throws(() => requireAccessMutation("admin", target), /team_access_denied/);
    } else {
      assert.doesNotThrow(() => requireAccessMutation("admin", target));
    }
    for (const actor of ["editor", "viewer"]) {
      assert.throws(() => requireAccessMutation(actor, target), /team_access_denied/);
    }
  }
});


test("a direct grant reports each permission path without labeling Edit as View", () => {
  const result = evaluateAccessPaths({ kind: "HOST", paths: [
    { id: "host-editor", sourceType: "DIRECT", mask: permissionBits.View | permissionBits.Edit },
  ], cryptoStatus: "NO", requiresCrypto: false });
  assert.deepEqual(result.paths[0].permissions, ["View", "Edit"]);
  assert.equal(result.paths[0].permission, undefined);
});


test("crypto work is derived per permission rather than from policy presence", () => {
  assert.deepEqual(requiredCryptoParts("HOST", permissionBits.ManageAccess), []);
  assert.deepEqual(requiredCryptoParts("HOST", permissionBits.View | permissionBits.Edit), ["GENERAL"]);
  assert.deepEqual(requiredCryptoParts("CREDENTIAL", permissionBits.View), ["METADATA"]);
  assert.deepEqual(requiredCryptoParts("CREDENTIAL", permissionBits.Reveal), ["SECRET"]);
  assert.deepEqual(requiredCryptoParts("CREDENTIAL", permissionBits.View | permissionBits.Reveal),
    ["METADATA", "SECRET"]);
});


test("mixed policy rights retain per-permission crypto usability", () => {
  assert.deepEqual(usabilityByPermission({ ManageAccess: "NOT_REQUIRED",
    View: "NO", Reveal: "WRAP_PRESENT_UNVERIFIED" }), {
    ManageAccess: "YES", View: "NO", Reveal: "UNKNOWN",
  });
});
