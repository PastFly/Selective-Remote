# Deployment on Ubuntu 24.04

The production endpoint is `https://cloud.pastfly.ru`. Its public `A` record
must resolve to the Ubuntu host before Caddy starts certificate issuance.

> **Known host blocker:** TCP port 443 is currently owned by
> `xray-linux-amd6`. Do not start the supplied Caddy Compose service, stop Xray,
> or change either listener until an explicit 443 coexistence architecture is
> reviewed and approved. The current Compose port mapping cannot coexist with
> that listener.

## 1. Read-only preflight

From a clean reviewed checkout, run the generic audit without `sudo`:

```bash
bash cloud/scripts/audit-host-readonly.sh cloud.pastfly.ru
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

On the current host, TCP 443 is not available. This table describes the
standalone Caddy design only; it is not authorization to replace or reconfigure
the existing Xray listener.

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
openssl rand -base64 48
openssl rand -base64 48
openssl rand -hex 32
```

The first random value can be used for `POSTGRES_PASSWORD`, and the second for
`SESSION_TOKEN_PEPPER`. Use the third, independent value for
`EMAIL_VERIFICATION_TOKEN_PEPPER`, the fourth for
`PASSWORD_RESET_TOKEN_PEPPER`, the fifth for `ABUSE_TOKEN_PEPPER`, and the
64-character hexadecimal value for `PROXY_SHARED_SECRET`. Set `ACME_EMAIL` to
the certificate contact address. Configure `SMTP_HOST`, `SMTP_PORT`,
`SMTP_USER`, `SMTP_PASSWORD` and `SMTP_FROM` using a dedicated mail account. Use
`SMTP_SECURE=true` for implicit TLS, or `false` only when the provider supports
STARTTLS; the application requires encryption and validates the server
certificate in both modes.

Email verification, password reset, request rate limiting and abuse protection
are implemented, but registration remains disabled until SMTP is configured
and the complete browser/macOS flow is manually approved.

## 4. Database backup and restore drill

Create a private directory outside the checkout, then run a custom-format
backup. The script uses the PostgreSQL container environment without printing
database credentials, validates the archive and writes a SHA-256 checksum.

```bash
sudo install -d -m 700 /var/backups/selective-remote-cloud
bash cloud/scripts/backup-postgres.sh /var/backups/selective-remote-cloud
```

Keep at least one encrypted off-host copy under a separately controlled backup
policy. A backup is not accepted until a restore drill succeeds on disposable
staging infrastructure.

Restore is destructive and fails unless the checksum is valid, PostgreSQL is
running, Cloud is stopped and the exact confirmation flag is supplied:

```bash
docker compose -f cloud/compose.yaml stop cloud
bash cloud/scripts/restore-postgres.sh --confirm-restore \
  /var/backups/selective-remote-cloud/selective-remote-cloud-YYYYMMDDTHHMMSSZ.dump
docker compose -f cloud/compose.yaml up -d cloud
curl --fail --silent --show-error https://cloud.pastfly.ru/healthz
```

Do not perform the first restore drill against the only production database.
Record only sanitized success metadata in the private continuity repository;
never commit a dump, checksum containing a private path, or credentials.

## 5. Start and verify

This section is blocked on the current host until the 443 coexistence design is
approved. Do not run the commands below while Xray owns TCP 443.

```bash
docker compose config --quiet
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

## 6. Routine updates

Deploy only an exact reviewed commit. For work already approved and merged,
use `main` with fast-forward-only updates:

```bash
git fetch origin
git switch main
git pull --ff-only
docker compose -f cloud/compose.yaml build --pull
docker compose -f cloud/compose.yaml up -d
```

No fixed monthly certificate-renewal cron is needed. Caddy schedules renewal
from certificate lifetime and ACME Renewal Information, then reloads the new
certificate without stopping the service.
