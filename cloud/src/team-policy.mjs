export const teamRoles = Object.freeze(["owner", "admin", "editor", "viewer"]);
export const invitationalTeamRoles = Object.freeze(["admin", "editor", "viewer"]);

const permissions = Object.freeze({
  read: new Set(teamRoles),
  list_members: new Set(teamRoles),
  create_vault: new Set(["owner", "admin"]),
  write_vault: new Set(["owner", "admin", "editor"]),
  manage_vault_keys: new Set(["owner", "admin"]),
  invite_member: new Set(["owner", "admin"]),
  invite_admin: new Set(["owner"]),
  manage_member: new Set(["owner", "admin"]),
});

export function validateTeamName(value, errorCode = "invalid_team") {
  const name = String(value ?? "").trim();
  if (!name || name.length > 120 || /[\u0000-\u001f\u007f]/.test(name)) throw new Error(errorCode);
  return name;
}

export function validateTeamRole(value, { invitation = false } = {}) {
  const role = String(value ?? "").toLowerCase();
  const allowed = invitation ? invitationalTeamRoles : teamRoles;
  if (!allowed.includes(role)) throw new Error("invalid_team_role");
  return role;
}

export function validateIdempotencyKey(value) {
  const key = String(value ?? "");
  if (key.length < 16 || key.length > 128 || !/^[A-Za-z0-9._:-]+$/.test(key)) {
    throw new Error("invalid_idempotency_key");
  }
  return key;
}

export function requireTeamPermission(role, permission) {
  if (!permissions[permission]?.has(role)) throw new Error("team_access_denied");
}

export function requireInvitationPermission(actorRole, invitedRole) {
  validateTeamRole(actorRole);
  const role = validateTeamRole(invitedRole, { invitation: true });
  requireTeamPermission(actorRole, role === "admin" ? "invite_admin" : "invite_member");
  return role;
}

export function requireMembershipChange(actor, target, nextRole = null) {
  validateTeamRole(actor?.role);
  validateTeamRole(target?.role);
  if (!actor?.id || !target?.id || actor.id === target.id) throw new Error("team_access_denied");
  requireTeamPermission(actor.role, "manage_member");

  if (actor.role === "admin") {
    if (!["editor", "viewer"].includes(target.role)) throw new Error("team_access_denied");
    if (nextRole !== null && !["editor", "viewer"].includes(validateTeamRole(nextRole))) {
      throw new Error("team_access_denied");
    }
  }
  if (nextRole !== null) validateTeamRole(nextRole);
}
