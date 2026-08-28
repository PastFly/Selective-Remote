# Closed staging readiness

This milestone prepares a non-destructive inventory before choosing how Cloud
will coexist with services already running on an Ubuntu host. It does not
authorize deployment, firewall changes, service restarts, container removal or
host reset.

## Read-only audit

Copy only the script to the target host or run it from an audited checkout:

```bash
bash cloud/scripts/audit-host-readonly.sh cloud.example.invalid
```

The optional hostname is used only for DNS resolution. The script reports:

- operating system, kernel and capacity;
- TCP/UDP listeners, with a focused 80/443 summary;
- running Docker containers and published ports;
- Docker network names and drivers;
- selected reverse-proxy, container and tunnel service unit names;
- IPv4/IPv6 resolution for the supplied hostname.

It intentionally does not use `sudo`, print process environments, read `.env`
or service configuration files, inspect container environment variables, or
change any host state.

## Handling the report

Review the output before sharing it. Container names, images, public addresses
and service names can be operationally sensitive. Store the sanitized result
in the private continuity repository, never in a public issue or pull request.

## Decision gate

After reviewing the inventory, choose one deployment model:

1. a dedicated staging server or IP;
2. a reviewed shared reverse proxy on TCP 443;
3. a temporary non-production port restricted by firewall and authentication.

Do not start the bundled Caddy service while another listener owns TCP 443.
Back up and verify recovery of existing services before any later approved
reconfiguration.
