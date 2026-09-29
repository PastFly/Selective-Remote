# Trusted device-key foundation implementation plan

## Scope and file map

Implement the reviewed [design](../specs/2026-09-29-trusted-device-key-foundation-design.md) as dormant 0.32 foundation from public main `f945bbeeb8a795c0dfe88b8731bf07e5ddf32377`. The PR must not enable production CEK delivery or Vault v2. Tests precede each product change.

- `cloud/public/device-trust-v1.js`: canonical record encoding, P-256 signing/verification, local trust pin/high-water model, and safe wrapper gate.
- `Sources/SelectiveRemote/CloudDeviceTrustV1.swift`: matching CryptoKit format, validation and wrapper gate.
- `Tests/SelectiveRemoteTests/CloudDeviceTrustV1Tests.swift`, `cloud/tests/device-trust-v1.test.mjs`, `Tests/SelectiveRemoteTests/Fixtures/device-trust-browser.json`: cross-language, mutation and rollback tests.
- `cloud/migrations/015_device_trust_v1.sql`, `cloud/tests/device-trust-postgres.test.mjs`: additive dormant public-record storage and database constraints, with no HTTP route or production writer.
- `docs/architecture/device-trust-v1-boundary.md`: account/device audit, root bootstrap and trust limitations.

## Task 1 — Canonical certificate and signed checkpoint

1. Write browser and Swift tests for one canonical certificate payload and checkpoint payload. Assert exact bytes, sorted directory entries and strict parsing; run targeted tests and observe expected failure because the APIs do not exist.
2. Implement bounded length-prefixed encoding with domain/version separation and normalized UUIDs. Encode X9.63 P-256 public keys and raw 64-byte signatures using WebCrypto ECDSA SHA-256 and CryptoKit P256.Signing.
3. Test browser-created certificate/checkpoint verified on Mac, plus changed account/device/key/version/signature rejection. Confirm both targeted suites green.

## Task 2 — Root bootstrap, device approval, replacement and revocation

1. Write failing tests for local root generation and first-device self certificate, a second device approved by root custodian, duplicate same-device replacement refusal, explicit higher-version replacement, and revocation removing the active entry.
2. Implement pure trust records and root pin. The root private key stays only on the originating client; browser uses non-extractable CryptoKey in IndexedDB and Mac uses the existing protected local envelope. Bind pins to endpoint and account; expose explicit reset rather than server-assisted silent recovery.
3. Re-run targeted tests. Never infer account trust from server-supplied root alone.

## Task 3 — Verified wrapper gate and local high-water

1. Write a failing simulated server-substitution test: server returns an attacker key for legitimate device ID; `wrapForVerifiedDevice` throws before invoking the v2 wrapper. Add wrong account, revoked entry, old checkpoint, stale certificate and unpaired root tests.
2. Implement verification of pinned root, certificate and directory signatures, active entry digest, expected identity and nondecreasing local directory version. Advance high-water only after all checks pass; rejected records must not change local trust state.
3. Delegate to existing `wrapResourceCEK`/`SelectiveRemoteResourceCryptoV2.wrap` only with the verified key. Test no wrapper for attacker substitution and a working wrapper for the approved device.

## Task 4 — Additive dormant storage

1. Write a PostgreSQL 16 integration test that applies migration 015 and rejects duplicate root, duplicate certificate key version, duplicate checkpoint version and oversized signed records; verify no Vault row or format state is changed. Observe test failure before migration.
2. Add tables with owner-account foreign keys, scoped uniqueness and immutable signed record columns. Do not add public API or production mutation method. Record direct-SQL concurrency as the separate required gate.
3. Run PostgreSQL integration and Cloud suite; fix only failures in this scope.

## Task 5 — Review, package and handoff

1. Document first-device root, browser code-delivery limit, lost custodian reset, offline freshness and separate Team/policy trust boundary.
2. Run targeted suites, full Swift and Cloud suites, Release build and migration integration. Verify no V1 path or public route changed.
3. Commit/push branch, create PR, run formal Codex Security exact-head diff scan focused on substitution, replay/rollback, certificate confusion, key logging and SQL integrity. Fix reportable findings and repeat exact-head tests/scan.
4. Wait exact-head CI and Test DMG. Update Continuity with source SHA, evidence and gates. Present exact head for a fresh Owner merge decision; do not merge.

## Review focus

- Browser ECDSA signature representation differs from CryptoKit DER: use and test fixed `r || s` bytes.
- The server can replay a signed old checkpoint: test local high-water and state mutation only after verification.
- A fresh client cannot trust a server-delivered root: test missing out-of-band pin failure.
- Same device ID with a new ECDH key must require explicit signed replacement: test silent substitution failure.
- A trusted certificate does not imply Team membership: require independently supplied expected account/Team scope before wrapping; keep production Team delivery disabled.
