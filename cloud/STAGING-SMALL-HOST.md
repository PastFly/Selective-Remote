# Optional small-host closed staging

This profile is an experimental, opt-in budget for one operator using tiny
synthetic records. It is not production sizing, protection against a hostile
public workload, or permission to deploy. Leave the default profile unchanged.

On the current dedicated staging host, apply files in this exact order from
the `cloud` directory. The PostgreSQL bind profile must appear once and last:
Earlier three-file examples are not valid for this host and must not be reused.

```bash
node_validator_image='node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b'
docker compose -f compose.yaml -f compose.443-only.yaml -f compose.small-host.yaml \
  -f compose.postgres-bind.yaml config --quiet
docker compose -f compose.yaml -f compose.443-only.yaml -f compose.small-host.yaml \
  -f compose.postgres-bind.yaml config --format json \
  | docker run --rm -i --pull=never --network none --read-only \
      --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges \
      --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64 \
      --mount "type=bind,src=$(pwd -P)/scripts/validate-small-host-model.mjs,dst=/validator.mjs,readonly" \
      "$node_validator_image" node /validator.mjs
```

Use the pinned Node 22 container for the checker; host Node.js is not required.
Pre-pull and verify the exact image because this command fails closed with
`--pull=never`. A generated Compose model may contain secrets; pipe it directly
to the checker, do not paste it into chat/CI and do not commit it. Use a fresh
private temporary directory and dummy-only `.env` when testing configuration
before deployment. The checker prints only fixed status/budget metadata. Keep
shell strict mode inside a child Bash, not the interactive SSH login shell.
These commands do not start services; Docker starts only the disposable
validator container. The resource checker does not replace the independent
exact-source, mount and rendered-bind checks in
`scripts/start-staging-guarded.sh`; pass the same four files to that wrapper
only after all deployment gates are approved.

## Reviewed starting budgets, not measured service capacity

| Service | Memory cap | Memory + swap cap | CPU cap | PID cap |
| --- | ---: | ---: | ---: | ---: |
| PostgreSQL | 160 MiB | 192 MiB | 0.25 | 128 |
| Cloud | 320 MiB | 384 MiB | 0.40 | 128 |
| Caddy | 96 MiB | 128 MiB | 0.10 | 128 |

Total caps are 576 MiB RAM, 128 MiB additional swap and 0.75 CPU. This does not
reserve capacity for the host or neighboring workloads: review their peaks,
not just idle usage. Docker/kernel swap-limit support must be verified before
launch. Do not disable OOM handling or remove limits to force startup.

Each service rotates JSON logs at 10 MiB with 3 files (about 90 MiB across the
stack, plus filesystem/rotation overhead). Database storage and WAL remain
unbounded by this profile: `max_wal_size` is a soft checkpoint target, not a
disk quota. Retained images, build cache, database growth and private backups
also consume disk. Do not run a broad Docker prune on a shared host.

The profile uses `on-failure:3` to bound immediate crash-restart loops; it is
not unattended availability management, and services do not automatically
return just because the Docker daemon restarts. Inspect a failure before a
manual restart. Never restart or reconfigure unrelated services.

## Password hashing and memory

The current scrypt parameters are N=131072, r=8, p=1: approximately 128 MiB
native working memory per active calculation. The 256 MiB `maxmem` option is
an upper bound, not the Node heap size. Do not reduce scrypt's cost parameters.

`UV_THREADPOOL_SIZE=1` is set before Node starts and serializes libuv work,
including scrypt. This also delays filesystem and DNS work; it does not bound
the HTTP request queue. `NODE_OPTIONS=--max-old-space-size=96` limits V8 old
space, not total RSS, native crypto allocations or Buffers. The container cap
is the separate total-memory boundary. Registration is forced off even if
`.env` requests otherwise.

A bounded probe exercises four submitted hashes and verifications without
weakening their parameters and prints peak RSS only:

```bash
UV_THREADPOOL_SIZE=1 NODE_OPTIONS=--max-old-space-size=96 node scripts/probe-staging-kdf.mjs
```

This is a baseline crypto probe, not an HTTP/SQL/cgroup load test. Run it first
in the reviewed Node 22 image with the same memory/swap/CPU limits and no
published ports. Confirm actual container limits and test service readiness,
database initialization, migrations, single-user login and small CRUD before
accepting these budgets. Large Vaults/concurrent uploads are outside this
experimental profile and can still exhaust memory. Use a larger isolated host
for broader tests or public traffic.

## Launch gates and monitoring

- Recheck available RAM/swap/disk and TCP/UDP 443 immediately before launch.
- Build/pull one component at a time; runtime limits do not limit Docker builds.
- Generate independent runtime secrets directly into an owner-only `.env`,
  never through terminal output, chat, command arguments or git. Keep secrets
  out of container inspection output. Do not use the validation placeholders.
- SMTP may remain entirely unset only while registration is disabled; email
  verification and password reset delivery are not accepted without real SMTP.
- Apply the same four ordered profiles and project name to every later
  operation. Prefer the default project identity derived from `cloud` so the
  existing backup/restore scripts locate the same PostgreSQL service. They
  currently select the base file only; a custom project name needs a separate
  reviewed backup/restore integration before use.
- Check Docker stats, host MemAvailable, swap pressure, filesystem space,
  service health, OOMKilled and restart counters. Never print container Env.
- Pause testing and stop only the Cloud stack if memory availability drops
  below 128 MiB, root free space below 1 GiB, swap activity persists, any OOM
  occurs, or a neighboring service degrades. These are conservative initial
  operator thresholds, not guarantees. Preserve all database/certificate volumes.
- Recheck image security/updates before Internet exposure; version pinning and
  successful config validation are not a vulnerability assessment.
- No real data until a disposable restore drill and encrypted off-host backup
  policy are verified. No general-purpose public registration in this profile.

References: [Compose service limits](https://docs.docker.com/reference/compose-file/services/),
[Node scrypt](https://nodejs.org/docs/latest-v22.x/api/crypto.html#cryptoscryptpassword-salt-keylen-options-callback),
[Node thread pool](https://nodejs.org/docs/latest-v22.x/api/cli.html#uv_threadpool_sizesize),
[PostgreSQL memory settings](https://www.postgresql.org/docs/16/runtime-config-resource.html).
