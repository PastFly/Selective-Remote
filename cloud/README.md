# Selective Remote Cloud

Self-hosted Cloud foundation for Selective Remote v0.32. The API stores only
opaque encrypted Vault revisions; plaintext remote-access data remains on user
devices.

## Local verification

```bash
npm ci
npm test
cp .env.example .env
# Replace every placeholder secret before starting the stack.
docker compose up --build
```

Registration is intentionally disabled in the example configuration. It must
stay disabled on a public host until email verification and SMTP delivery are
configured, password reset and request throttling are implemented, and the
complete flow passes manual security review. Enabling it fails closed unless
the verification-token pepper and all SMTP settings are present. SMTP uses
implicit TLS when `SMTP_SECURE=true`; otherwise the client requires STARTTLS
and rejects invalid certificates.

Registration creates an unverified account and sends a one-time link; it does
not return a bearer session. Password login and session lookup remain blocked
until the token is consumed. SMTP connectivity is verified before the service
starts whenever registration is enabled. A resend/recovery flow for delivery
failures is not implemented yet, so registration must remain disabled.

The Cloud container applies numbered SQL migrations before starting the API.
Applied filenames and SHA-256 checksums are recorded in `schema_migrations`.
Never edit an applied migration; add the next numbered file instead.

## Production host

The supplied Caddy configuration expects `cloud.pastfly.ru` to resolve to the
Ubuntu host. Only Caddy publishes host ports; PostgreSQL is private to the
Compose network.

See [`DEPLOY-UBUNTU.md`](DEPLOY-UBUNTU.md) for the read-only preflight, required
ports, secret generation, first launch and verification steps. Caddy uses the
Let’s Encrypt production ACME endpoint and renews certificates automatically.
