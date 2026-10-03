# Whole publication local scale proof

This evidence concerns PR B's bounded whole-generation publication. It is an isolated local fixture measurement, not production capacity, Chromium or native acceptance, staging deployment, controller-fence acceptance, or release approval.

The earlier local 100/1000-resource and count-boundary processes loaded the migration-021 precursor before the additive migration-022 pre-START cancellation work. Migration 021's checksum and the measured non-cancellation resource/wrapper crypto paths remained unchanged. The migration-022 cancellation lookups are not included in those query counts. A separate complete 100-resource smoke applied migration 022 incrementally and loaded the current store; its evidence is identified below. Candidate CI separately runs the 100/1000-resource profiles after applying migration 022. Cancellation correctness and lost-START races require their dedicated integration tests, not extrapolation from this scale evidence.

A fresh all-seven-profile schema-22 rerun is recorded in the final section below; it supersedes the precursor migration limitation for those rerun measurements while preserving the original evidence.

## Reproduce

Create a new disposable PostgreSQL 16 database on loopback with a name ending `_test`. The harness applies migrations through the ordinary migration runner. It never drops, truncates, resets, restores, or rewrites migration checksums.

```sh
WHOLE_PUBLICATION_BENCHMARK=1 \
TEST_DATABASE_URL=postgresql://migration_test@127.0.0.1:55439/pr_b_whole_publication_benchmark_final_test \
WHOLE_PUBLICATION_BENCHMARK_SCENARIOS=resources100,resources1000,resources1001,vaults10,vaults11,wrappers10000,wrappers10001 \
WHOLE_PUBLICATION_BENCHMARK_OUTPUT=pr-b-whole-benchmark-reproduction.json \
node cloud/scripts/whole-publication-benchmark.mjs \
  > /tmp/pr-b-whole-benchmark-reproduction.log 2>&1

node --test cloud/tests/whole-publication-benchmark-guard.test.mjs
```

The executable requires the exact separate opt-in value `1` and `TEST_DATABASE_URL`. It rejects ordinary database names, external hosts, ambiguous URL query options, fragments, unsupported protocols, and fallback `DATABASE_URL` before importing storage or opening a connection. Accepted hosts are `127.0.0.1`, `localhost`, and `::1`; database names are restricted to lowercase letters, digits and underscores ending `_test`. Output defaults to the platform temporary directory; only that directory, `/tmp` and the macOS `/private/tmp` alias are accepted, with a strict `pr-b-whole-benchmark-*.json` basename. Five target guard tests and two portable output guard tests were observed RED before their implementations and GREEN afterwards: seven tests pass.

## Method

The resource fixtures contain one real generated Folder plus 99 or 999 live Hosts with small synthetic payloads. The ten-Vault fixture measures a complete operation across ten real ACTIVE Vaults with one Host each. Real PostgreSQL migrations, signed device certificates/directories, P-256 key wrapping, AES-GCM encryption, signatures, Merkle proofs, operation/receipt persistence and atomic pointer changes are exercised. Trust roots and pins originate in the isolated fixture; first-contact identity verification UI is not measured.

The harness uses the actual browser publication modules with Node WebCrypto. It reads and decrypts every predecessor part and administrative sidecar, prepares the complete fresh generation and encrypted checkpoint, and independently compares every predecessor/successor CEK and nonce. It collects every signed preview page, uploads every part and actual 512 KiB projection chunks, validates READY, commits, reads the account/device scoped receipt and every committed manifest, then verifies the recipient header/inventory/descriptors/proofs and decrypts every committed part and sidecar. The local checkpoint repository is the existing fixture's in-memory persistence seam; this does not measure IndexedDB durability.

At exactly 10,000 wrappers, the fixture has 999 live resources, ten genuinely certified/admitted devices and ten predecessor custodians: `999 × 10 + 10 = 10,000`. Every additional device's resource and sidecar wrappers are proof-checked and decrypted from committed PostgreSQL storage with its real private key. This bulk cryptographic check is distinct from the actor's ordinary recipient transport read. The 10,001-wrapper rejection starts with 999 resources and actor-only custody, then proposes one additional Host: `1000 × 10 + 1 = 10,001`.

The 1001-resource and eleven-Vault scenarios start from real published local generations and assert typed `publication_limit` together with unchanged pointer/policy, operation, generation, receipt, outbox and audit state. They do not silently batch the operation. Default five-minute preview expiry remains enabled. If preparation/upload consumes the original token's lifetime, the harness explicitly obtains a fresh preview immediately before commit for the same immutable operation and requires byte-equivalent binding, request and generations. This renewal is measured separately and cannot broaden consent.

Each stage records elapsed time, client-observed PostgreSQL query count and accumulated query time, heap and RSS before/after, and heap/RSS peaks sampled every 25 ms. Internal SQL statements executed by PostgreSQL triggers are included in outer query duration but are not separately counted. Process maximum RSS is also retained. Sampling can miss brief allocation peaks. Sizes are actual encoded JSON bytes: prepared part ciphertext plus sidecars, signed projections, encrypted checkpoint and largest encoded upload body. Initial migration is reported separately from successor publication; a complete generation's cost must not be described as a fixed cost per edited resource.

## Evidence and observed failures

The runtime is Node 26.7.0 and PostgreSQL 16.15 (Homebrew, arm64) on the developer Mac. The database is dedicated to these local fixtures; timing is not an isolated hardware capacity test. Raw logs and JSON are retained under `/private/tmp/pr-b-whole-benchmark-*`.

`/private/tmp/pr-b-whole-benchmark-evidence.json` provides a compact index of the eight completed profiles, their source-artifact SHA-256 hashes, migration provenance, stage measurements and boundary results. Earlier source artifacts containing a later harness failure are explicitly marked; only their independently completed profiles are selected.

The first real 1000-resource run reproduced a V8 regular-expression stack overflow in server checkpoint validation after part upload. The backend subsequently replaced the unbounded positive quantifier with a length-first check and a negated-character scan; its dedicated large-checkpoint/budget tests are separate evidence. The first ten-Vault seed exposed duplicate fixture names at the third Vault. The fixture was corrected to use distinct names. Final numerical results are recorded after rerunning these real scenarios.

The completed 100/1000 runs are retained in `/private/tmp/pr-b-whole-benchmark-final-resources.log` and `.json`. Both reached READY and atomic COMMIT under the original five-minute preview, recovered the exact receipt/manifests and decrypted every committed resource plus sidecar. The independent fresh-key checks covered 101 and 1001 CEKs/nonces respectively.

| Live resources | Initial publication | Client preparation | Upload + READY | Atomic commit | Recipient verify/decrypt | Successor client SQL queries | Sampled peak RSS / heap |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100 (99 Hosts + 1 Folder) | 1.282 s / 3220 queries | 0.204 s | 2.552 s | 0.147 s | 0.651 s | 7662 | 238.52 / 68.91 MiB |
| 1000 (999 Hosts + 1 Folder) | 46.310 s / 30220 queries | 2.021 s | 189.357 s | 1.315 s | 70.306 s | 72695 | 545.70 / 247.48 MiB |

Client preparation includes predecessor decryption, fresh generation encryption and durable checkpoint encryption through the fixture persistence seam. The extra independent key/nonce comparison took 0.031 s and 0.292 s. Signed paged preview took 0.062 s / 129 queries and 1.946 s / 417 queries. Receipt/manifest recovery took 0.017 s / 37 queries and 0.110 s / 37 queries. The complete successor cycle, including independent key checking and full recipient verification/decryption, took approximately 3.67 s and 265.35 s. The initial migration and EXPLAIN collection are excluded from those successor totals.

| Resources | Prepared ciphertext + sidecar | Signed projection | Encrypted checkpoint | Projection chunks | Largest encoded upload body |
| --- | ---: | ---: | ---: | ---: | ---: |
| 100 | 201226 B | 168210 B | 632861 B | 2 | 699170 B |
| 1000 | 2001224 B | 1672111 B | 6178066 B | 16 | 699172 B |

The 1000-resource operation made 1018 upload/start/validate store calls and ten recipient descriptor pages. The measured cost is strongly nonlinear: complete snapshots/projections and recipient policy are repeatedly loaded and processed per part. These data do not support a fixed-time claim for one logical edit.

The actual ten-Vault operation completed with ten Hosts and ten sidecars. Initial publication took 0.469 s / 2428 client queries; signed preview 0.108 s / 745; complete client preparation 0.065 s; independent twenty-key/nonce checking 0.007 s; upload/READY 1.804 s / 10759; atomic commit 0.517 s / 3037; all ten receipt manifests 0.101 s / 316; recipient verify/decrypt 0.106 s / 830. Each of the ten current pointers moved to sequence 2 in the committed operation. This proves the ten-Vault count boundary with small inventories, not the complete ten-Vault × 1000-resource × 10000-wrapper cross-product.

The 1001-resource request failed with `publication_limit` and safe counts `{vaults:1, resources:1001}` in 0.035 s / 31 client queries. Eleven real ACTIVE Vaults failed with the same typed error and `{vaults:11}` in 0.0015 s / six queries. The compared pointer/policy, operation/generation, receipt, outbox and audit state remained identical in both cases. These completed results are in `/private/tmp/pr-b-whole-benchmark-final-bounds.log` and `.json`.

The real 10001-wrapper request failed with `publication_limit` and safe counts `{vaults:1, resources:1000, parts:1001, wrappers:10001}` in 0.187 s / 33 client queries. The same state comparison was unchanged. Its predecessor contained 999 real resources and ten certified/admitted devices; initial publication took 145.367 s / 30219 client queries. The extra proposed Host includes an explicit USER resource grant for the existing membership, ensuring an actual ten-device fanout. The completed rejection is retained in `/private/tmp/pr-b-whole-benchmark-final-wrappers.log` and `.json`; the following first 10000-fixture setup failure is also retained rather than counted as a pass.

Harness integration fixes were verified against actual runs: request ordering was canonicalized before signed consent verification; the overflow Host received an explicit fanout grant; custodian targets now contain public certificate/key fields without accidentally serializing the fixture's private CryptoKey object. The corrected exact-10000 run is retained separately in `/private/tmp/pr-b-whole-benchmark-final-10000.log` and `.json`.

### Exactly 10,000 wrappers

The corrected process exited successfully with `committed_and_decrypted`. Its 999 live resources comprise 998 Hosts and one Folder. All 1000 actor resource/sidecar wrappers and all 9000 wrappers for the other nine certified devices were decrypted from the committed generation. Independent fresh-key checking covered 1000 CEKs and nonces. The actor used ten ordinary recipient descriptor pages; other-device verification bulk-loaded committed objects and projections in two SQL queries, so that additional stage is a cryptographic fanout check, not ten-device transport throughput.

| Stage | Elapsed time | Client SQL queries |
| --- | ---: | ---: |
| Initial predecessor publication | 144.749 s | 30219 |
| Signed paged preview | 5.988 s | 385 |
| Complete client preparation | 14.245 s | 0 |
| Independent fresh CEK/nonce comparison | 0.298 s | 0 |
| Upload + READY | 614.042 s | 46549 |
| Same-operation preview renewal | 0.590 s | 32 |
| Atomic commit | 6.673 s | 103 |
| Receipt/manifest recovery | 0.309 s | 37 |
| Actor recipient verify/decrypt | 118.912 s | 28270 |
| Other nine devices verify/decrypt | 4.923 s | 2 |

The complete successor cycle took 765.981 s (12.77 minutes) and 75378 client SQL queries, excluding the initial publication and EXPLAIN collection. Upload/READY alone accumulated 162.227 s of query duration. The original five-minute token expired during preparation/upload. The fresh preview retained the exact operation binding, request and generations before atomic commit; expiry was not increased.

Prepared ciphertext plus sidecar occupied 8245215 B, signed projections 12452997 B, and encrypted checkpoint 28942042 B. The operation made 1081 upload/start/validate store calls, including 80 projection chunks; the largest encoded upload body was 699172 B. Actor recipient transport returned 3167266 encoded bytes. Sampled peak heap was 934.41 MiB and sampled peak RSS 1355.42 MiB. Process maximum RSS was 1609.28 MiB, confirming that the sampling missed a higher transient memory peak. Passing this local count boundary with small payloads is a correctness result with substantial observed time and memory cost, not a production capacity claim.

### Migration-022 smoke

After the precursor runs, the ordinary migration runner applied the additive migration 022 to the same isolated database without a reset. Its recorded checksum is `4872c50d4b6b20a83588416e096d0ca05344222809385d4aa1d637c6b139ea72`; migration 021 remained `13b20843ee667f02dfacc634625f7cdd808b77cfac198476cf97ea4cfb9ba10a`. A fresh process using the current store completed the 100-resource profile, including all 101 fresh CEKs/nonces, READY, atomic commit, receipt/manifest recovery and decryption of 100 resources plus sidecar. Upload/READY took 2.330 s / 4644 queries, commit 0.140 s / 105 queries and recipient verification/decryption 0.927 s / 2855 queries. This smoke validates current harness integration, not the larger profiles on migration 022.

Its raw log is `/private/tmp/pr-b-whole-benchmark-final-schema22.log`. Supplying the bare portable output name placed its JSON in the actual platform temporary directory: `/var/folders/yy/bdp7xgbs797g_vzgdlhs3c_m0000gn/T/pr-b-whole-benchmark-final-schema22.json`.

## Query plans and scope limits

`EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` is retained for actual active projection lookup, exact part identity lookup, identity reservation lookup, operation primary-key lookup, projection-chunk ordering, and representative operation-scope and pending-outbox queries. The recipient resource cursor operates over the signed projection in application memory after the active projection lookup; there is no SQL keyset-pagination capacity claim.

At 1000 resources, the exact part query used `vault_migration_parts_pkey` (one row, three shared buffer hits, 0.007 ms). The active projection lookup used nested loops over small sequential scans (one result, 24 shared hits, 0.251 ms). The complete identity reservation query returned 1000 rows by a sequential scan (12 shared hits, 0.126 ms). Operation primary-key/scope queries took 0.009 ms on tiny tables; pending outbox returned zero rows in 0.005 ms; projection chunk ordering returned 16 rows in 0.009 ms. These warm local plans must be read alongside the substantially larger full-stage costs above.

The fixtures use small plaintext payloads and few accounts. No-op successor operations create audit and receipt records without effective permission changes, so their outbox is empty. An empty-outbox plan establishes neither populated-outbox performance nor worker delivery throughput. PostgreSQL can appropriately choose sequential scans for tiny operation/outbox/chunk tables; the harness does not force index use. EXPLAIN timing alone excludes transport encoding and the cost of repeatedly loading and processing complete JSON projections/snapshots; the full-stage measurements include that work.

The 64 MiB checkpoint, 128 MiB prepared aggregate and 1 MiB request limits remain independent encoded-byte gates. Passing resource or wrapper count boundaries with these small fixture payloads does not mean every payload/fanout shape at those counts fits the byte budgets or preview expiry. Full Cloud/Swift/regression, browser runtime, immutable candidate review, Security, CI and Test DMG evidence remains owned by the main PR B verification cycle.

## Fresh schema-22 verification — 2026-10-02 UTC

The resumed PR #223 verification ran all seven profiles in one successful process against a newly created loopback PostgreSQL 16.15 database, `pr223_scale_20261003_test`, with migrations 1–22 applied through the normal runner before any profile. Node was 26.7.0. No reset, production connection, checksum rewrite, activation or migration of an existing Vault occurred. Raw report: `/tmp/pr-b-whole-benchmark-pr223-final.json`; log: `/tmp/pr223-scale-final.log`. Report SHA-256: `32486f4822c2656f55bb0e68d0b3f21ea79e98683f911f2f4630a860e022850d`.

The process began at 2026-10-02T21:36:04.603Z with the frozen whole-publication crypto/flow/backend code. Subsequent Browser changes were confined to the IndexedDB repository, which this benchmark does not instantiate (its checkpoint seam is in-memory); subsequent Swift toolchain fixes are also outside the harness. Real IndexedDB durability and trust-race proofs are separate Browser tests and are not claimed by these scale measurements. Concurrent local build/test activity makes these observations unsuitable as isolated hardware or production capacity estimates.

| Profile | Complete successor cycle | Upload + READY | Atomic commit | Successor client SQL queries | Profile sampled peak RSS, including seed |
| --- | ---: | ---: | ---: | ---: | ---: |
| resources100 | 3.430 s | 2.091 s | 0.127 s | 7773 | 236.72 MiB |
| resources1000 | 265.392 s | 188.332 s | 1.327 s | 73729 | 609.27 MiB |
| resources1001 | typed limit; state unchanged | 31.301 ms rejection | — | 32 rejection queries | — |
| vaults10 | 3.042 s | 2.083 s | 0.565 s | 15742 | 515.77 MiB |
| vaults11 | typed limit; state unchanged | 1.748 ms rejection | — | 7 rejection queries | — |
| wrappers10000 | 780.715 s | 627.117 s | 6.634 s | 76475 | 1290.62 MiB |
| wrappers10001 | typed limit; state unchanged | 201.346 ms rejection | — | 34 rejection queries | — |

All four accepted profiles freshly encrypted every resource part and administrative sidecar, checked every predecessor/successor CEK and nonce for freshness, atomically committed the complete Vault set, recovered exact receipts/manifests, and verified/decrypted all committed parts. The 10,000-wrapper profile decrypted all 1,000 actor wrappers plus 9,000 wrappers for nine other certified devices. The 1001-resource, 11-Vault and 10001-wrapper profiles each returned `publication_limit` and preserved all compared pointer/policy/operation/generation/receipt/outbox/audit state. Every profile retained its actual query plans in the JSON report.

The 10,000-wrapper run used 8,245,215 B of prepared ciphertext/sidecar, 12,452,997 B of projection and 28,942,040 B of encrypted checkpoint. Its 1,081 upload/start/validate calls included 80 projection chunks, largest body 699,172 B. The original five-minute preview expired during preparation/upload; an explicit fresh preview preserved the exact immutable binding before commit. Process maximum RSS across the entire seven-profile run was 1405.23 MiB; this aggregate maximum cannot be attributed to one stage. The large-profile latency and memory cost remain an operating-envelope gate before runtime enablement. Passing these count boundaries does not prove the maximum Vault × resource × device cross-product, large plaintext payloads, populated outbox throughput, real browser/native capacity or PR C staging/controller acceptance.
