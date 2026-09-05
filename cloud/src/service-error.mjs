const operationStatuses = Object.freeze({
  registration_disabled: 403,
  invalid_credentials: 401,
  email_not_verified: 403,
  smtp_not_configured: 503,
  rate_limited: 429,
  invalid_verification_token: 400,
  invalid_password_reset_token: 400,
  invalid_email: 400,
  invalid_password: 400,
  invalid_device: 400,
  invalid_content_type: 415,
  invalid_json: 400,
  request_too_large: 413,
  invalid_vault_envelope: 400,
  invalid_wrapped_key: 400,
  invalid_base_revision: 400,
  invalid_envelope_version: 400,
  vault_too_large: 413,
  vault_missing: 404,
  invalid_team: 400,
  invalid_team_role: 400,
  invalid_shared_vault: 400,
  invalid_idempotency_key: 400,
  invalid_team_invitation: 400,
  team_not_found: 404,
  team_access_denied: 403,
  team_member_exists: 409,
  team_last_owner: 409,
  shared_vault_exists: 409,
});

export function publicOperationError(error) {
  const code = error?.message;
  const status = operationStatuses[code];
  return status ? { status, code } : null;
}
