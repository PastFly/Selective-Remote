# Optional 443-only staging ingress

Use this opt-in Compose override only when an existing, reviewed host service
must continue to own TCP 80 and TCP 443 is available. The default deployment
profile is unchanged.

## Requirements

- Docker Compose 2.24.4 or newer for the `!override` merge tag;
- TCP 443 available immediately before launch;
- public DNS for `CLOUD_PUBLIC_HOST` resolving to the host;
- an ACME contact address in `ACME_EMAIL`;
- enough memory and disk for PostgreSQL, Node.js, container images and private
  backup/restore work;
- public registration disabled until SMTP and the complete flow are reviewed.

Hosts with only 1 GiB RAM and no swap have little failure margin. Prefer at
least 2 GiB RAM. A smaller closed-staging host requires a separately reviewed
swap and resource-monitoring plan before deployment.

## Verify the merged model

Keep secrets in the private `.env` file and set these two non-secret values:

```dotenv
CLOUD_PUBLIC_HOST=staging.example.invalid
CLOUD_PUBLIC_ORIGIN=https://staging.example.invalid
```

Validate the exact merged model before starting it:

```bash
docker compose version
docker compose -f compose.yaml -f compose.443-only.yaml config --quiet
docker compose -f compose.yaml -f compose.443-only.yaml config
```

The rendered `caddy` service must publish only TCP/UDP 443 and must mount
`Caddyfile.443-only` at `/etc/caddy/Caddyfile`. PostgreSQL and the Cloud API
must remain unpublished.

## Launch boundary

Run the read-only host audit again immediately before launch. Do not stop an
unknown TCP 443 owner. When the port is available, start the closed staging
stack with the same ordered file pair:

```bash
docker compose -f compose.yaml -f compose.443-only.yaml build --pull
docker compose -f compose.yaml -f compose.443-only.yaml up -d
docker compose -f compose.yaml -f compose.443-only.yaml ps
```

This mode disables HTTP redirects and the ACME HTTP challenge. Caddy obtains
and renews the certificate through TLS-ALPN on TCP 443. Clients and health
checks must use an explicit `https://` URL.
