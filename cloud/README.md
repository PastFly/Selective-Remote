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
configured.

## Production host

The supplied Caddy configuration expects `cloud.pastfly.ru` to resolve to the
Ubuntu host. Only Caddy publishes host ports; PostgreSQL is private to the
Compose network.
