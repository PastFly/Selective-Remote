import assert from "node:assert/strict";
import test from "node:test";
import {
  requireInvitationPermission,
  requireMembershipChange,
  requireTeamPermission,
  validateIdempotencyKey,
  validateTeamName,
  validateTeamRole,
} from "../src/team-policy.mjs";

test("four fixed Team roles enforce the 0.32 permission boundary", () => {
  for (const role of ["owner", "admin", "editor", "viewer"]) {
    assert.equal(validateTeamRole(role), role);
    assert.doesNotThrow(() => requireTeamPermission(role, "read"));
  }
  assert.doesNotThrow(() => requireTeamPermission("admin", "create_vault"));
  assert.throws(() => requireTeamPermission("editor", "create_vault"), /team_access_denied/);
  assert.throws(() => requireTeamPermission("viewer", "create_vault"), /team_access_denied/);
  assert.throws(() => validateTeamRole("custom"), /invalid_team_role/);
});

test("only an Owner can invite an Admin and invitations cannot assign Owner", () => {
  assert.equal(requireInvitationPermission("owner", "admin"), "admin");
  assert.equal(requireInvitationPermission("admin", "editor"), "editor");
  assert.throws(() => requireInvitationPermission("admin", "admin"), /team_access_denied/);
  assert.throws(() => requireInvitationPermission("owner", "owner"), /invalid_team_role/);
});

test("membership changes reject self-mutation and Admin escalation", () => {
  const owner = { id: "owner-membership", role: "owner" };
  const admin = { id: "admin-membership", role: "admin" };
  const editor = { id: "editor-membership", role: "editor" };

  assert.doesNotThrow(() => requireMembershipChange(owner, admin, "viewer"));
  assert.doesNotThrow(() => requireMembershipChange(admin, editor, "viewer"));
  assert.throws(() => requireMembershipChange(admin, editor, "admin"), /team_access_denied/);
  assert.throws(() => requireMembershipChange(admin, owner, "viewer"), /team_access_denied/);
  assert.throws(() => requireMembershipChange(owner, owner, "admin"), /team_access_denied/);
});

test("Team names and idempotency keys are bounded before storage", () => {
  assert.equal(validateTeamName("  Operations  "), "Operations");
  assert.equal(validateIdempotencyKey("request:0123456789"), "request:0123456789");
  assert.throws(() => validateTeamName(""), /invalid_team/);
  assert.throws(() => validateTeamName("bad\nname"), /invalid_team/);
  assert.throws(() => validateIdempotencyKey("short"), /invalid_idempotency_key/);
  assert.throws(() => validateIdempotencyKey("x".repeat(16) + " "), /invalid_idempotency_key/);
});
