# Resource reader verification and local scale evidence

PR A provides authenticated immutable-generation reads. Runtime reader enablement
remains default OFF and staging-allowlisted. This document does not authorize
activation, real migration, deployment or a release.

## Reproducible isolated workload

`cloud/scripts/benchmark-publication-read.mjs` accepts only an explicit
`TEST_DATABASE_URL` with a loopback host and database name matching
`pr_a_publication_benchmark_*test`, without URL query or fragment. It requires
PostgreSQL 16. Create a fresh disposable synthetic database first; never use a
staging or production database. The script applies migrations, creates synthetic
accounts/devices/Vaults and uses the internal fixture operator to prepare and
activate only those isolated fixture generations.

From `cloud/`, run with the isolated URL set:

```sh
node scripts/benchmark-publication-read.mjs 100 1000
```

The workload follows the actual authenticated loopback HTTP API and PostgreSQL
reader, then the browser client’s signed header/descriptor/inventory/Merkle
verification, WebCrypto unwrap/decryption, payload linkage and full model
materialization. Each fixture has nine admitted devices, Host resources, no
groups and one reading subject. The custodial sidecar adds one wrapper. Assertions
require every expected model, exactly one part read per Host, no-store HTTP
responses and the exact durable high-water value.

The fixture’s independently generated HTTPS trust identity is redirected to
loopback HTTP only by this harness. The client cache is an explicitly labelled
memory surrogate. It does **not** measure TLS, browser IndexedDB durability,
native rendering, Credential SECRET delivery, staging throughput or production
capacity. Separate browser tests exercise actual Chromium/WebCrypto/IndexedDB.
Client process RSS includes fixture preparation; server RSS is a separate Node
process sampled once a second. Neither is a container limit measurement.

## Observed local results — 2026-10-01

Local Node 26.7.0 and PostgreSQL 16.15, actual HTTP/PG/WebCrypto path, nine devices.
These measurements do not substitute for the deployment's Node runtime:

| Resources | Wrappers | Complete materialization | Requests | HTTP p95 / p99 | Server peak RSS | Projection bytes |
| --- | --- | --- | --- | --- | --- | --- |
| 100 | 901 | 2.508 s | 104 | 28.76 / 34.97 ms | 226.25 MB | 1,129,744 |
| 1000 | 9001 | 169.824 s | 1013 | 175.14 / 178.35 ms | 419.04 MB | 11,252,953 |

Preparation took 7.531 s and 129.373 s respectively and is excluded from
materialization. HTTP response totals were 376,133 and 3,725,108 bytes. Client peak
RSS including fixture preparation was 227.48 MB and 407.18 MB. All models passed
actual cryptographic verification/decryption and linkage assertions.

A repeat after the cached reader-key binding change passed the same 1000-resource
workload: preparation 130.800 s, materialization 175.303 s, 1013 requests,
HTTP p95/p99 176.28/178.62 ms and server peak RSS 408.83 MB. Client peak RSS,
including preparation, was 709.77 MB. Response and projection byte totals matched
the first run. These local measurements show variation; they do not establish an
acceptable runtime or memory envelope. The immutable measured source snapshot was
`be4238a19ee67d6700fb167142dd10093c201bce`; subsequent lifecycle/UI fixes require
their own targeted regressions and final complete suite.

The current PostgreSQL reader reloads the full immutable projection and computes
recipient policy for each request. Multiplying projection JSON bytes by request
count estimates 117.49 MB and 11.40 GB of repeated projection transfer from the DB;
this is an estimate, not a captured database-wire byte count, and excludes other
snapshot/query work. A single indexed part lookup EXPLAIN cannot represent this
complete workload. The separate backend boundary fixture exercises 1000 resources
and exactly 10,000 wrappers; it is not interchangeable with this full-read workload.

## Required operational acceptance

Before ordinary staging/production reader activation, measure the actual Mac and
browser paths on the intended runtime, including repeat synchronization, secrets,
multi-user concurrency, latency, RSS/cgroup pressure and repeated DB work. Choose
an explicit acceptable operating envelope; reduce repeated immutable-projection
work if that envelope fails. Retain fresh authorization, exact-generation pinning,
complete signed inventory and device-scoped entitlement on every delivery. Do not
trade these checks for an unverified process-local cache or a role-based shortcut.

Full regression runs must retain the observed default-parallel fixture deadlock
disclosure. Direct SQL grant fixture writes can exhaust bounded retries against
the preexisting global operator table-lock order. Run the complete PG suite with
independent files sequenced as CI does, while retaining explicit within-test
concurrency matrices. Serial success does not claim that arbitrary parallel
fixture SQL never encounters PostgreSQL 40P01.
