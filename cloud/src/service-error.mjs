const operationStatuses = Object.freeze({
  registration_disabled: 403,
  email_exists: 409,
  invalid_credentials: 401,
  email_not_verified: 403,
  email_delivery_failed: 502,
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
});

export function publicOperationError(error) {
  const code = error?.message;
  const status = operationStatuses[code];
  return status ? { status, code } : null;
}
