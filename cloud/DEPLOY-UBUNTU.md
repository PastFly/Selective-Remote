# Deployment on Ubuntu 24.04

The production endpoint is `https://cloud.pastfly.ru`. Its public `A` record
must resolve to the Ubuntu host before Caddy starts certificate issuance.

## 1. Read-only preflight

From a clean checkout of PR 28, run:

```bash
sudo bash cloud/scripts/preflight-ubuntu.sh
```

Review the output before changing packages or firewall rules. In particular,
ports 80 and 443 must be available for Caddy. The SSH port must remain allowed
before any firewall change.

## 2. Required inbound ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| 49222 | TCP | Existing SSH administration |
| 80 | TCP | ACME HTTP challenge and HTTPS redirect |
| 443 | TCP | HTTPS API and portal |
| 443 | UDP | Optional HTTP/3 |

PostgreSQL port 5432 and application port 8080 must not be published on the
host or opened in the firewall.

## 3. Runtime configuration

Copy `.env.example` to `.env`, restrict it to the administrator and replace all
placeholders. Generate independent secrets; do not reuse the SSH key, account
password or database password.

```bash
cd cloud
cp .env.example .env
chmod 600 .env
openssl rand -base64 48
openssl rand -base64 48
openssl rand -base64 48
```

The first random value can be used for `POSTGRES_PASSWORD`, and the second for
`SESSION_TOKEN_PEPPER`. Use the third, independent value for
`EMAIL_VERIFICATION_TOKEN_PEPPER`. Set `ACME_EMAIL` to the certificate contact
address. Configure `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD` and
`SMTP_FROM` using a dedicated mail account. Use `SMTP_SECURE=true` for implicit
TLS, or `false` only when the provider supports STARTTLS; the application
requires encryption and validates the server certificate in both modes.

Keep `ALLOW_REGISTRATION=false` until email verification, password reset,
request rate limiting and abuse protection are implemented and the complete
flow is manually approved.

## 4. Start and verify

```bash
docker compose config
docker compose build --pull
docker compose up -d
docker compose ps
docker compose logs --tail=120 caddy cloud postgres
curl --fail --silent --show-error https://cloud.pastfly.ru/healthz
curl --fail --silent --show-error https://cloud.pastfly.ru/v1/meta
```

Caddy is pinned to the Let’s Encrypt production ACME endpoint. It obtains the
certificate, redirects HTTP to HTTPS and renews automatically. The persistent
`caddy-data` volume contains ACME account and certificate state and must not be
deleted during routine updates.

## 5. Routine updates

Deploy only reviewed commits from the Cloud feature branch until v0.32 is
approved for `main`:

```bash
git fetch origin
git switch feature/selective-remote-cloud-v0.32.0
git pull --ff-only
docker compose -f cloud/compose.yaml build --pull
docker compose -f cloud/compose.yaml up -d
```

No fixed monthly certificate-renewal cron is needed. Caddy schedules renewal
from certificate lifetime and ACME Renewal Information, then reloads the new
certificate without stopping the service.
