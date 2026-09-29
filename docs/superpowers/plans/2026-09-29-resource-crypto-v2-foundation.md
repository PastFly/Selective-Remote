# Resource crypto v2 foundation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add dormant per-resource CEK, ciphertext, wrapper, and atomic publication primitives without enabling Vault v2 or sharing.

**Architecture:** A separate browser/macOS format uses random 256-bit CEKs, AES-256-GCM payloads, and P-256 ECDH/HKDF/AES-GCM device wrappers. Canonical binary AAD binds immutable scope and independent version counters. PostgreSQL stores versioned ciphertext and wrapper sets behind an internal transaction; no route invokes it.

**Tech Stack:** Swift 6/CryptoKit, browser WebCrypto, Node tests, PostgreSQL 16.

**Spec:** Owner attachment `344da038-6a40-434c-9235-4d3c9d54a3cc`.

## Global Constraints

- Existing Vaults remain `V1_ACTIVE`; no V2 activation, migration, ACL, groups, grants, or production UI.
- Keep PR #210 Draft and public main unchanged.
- No production registry mutation API. Concurrent direct-SQL hardening is required before one exists.
- Production wrapper use remains blocked until device-key authenticity and current-epoch admission are enforced.

## Review Focus

- A wrapper moved between Team/Vault/resource/part/device/epoch/key version must fail to decrypt.
- Stale ciphertext or wrapper versions must not become the published manifest pointer.
- Partial ciphertext or wrapper insertion must roll back on failure.
- Malformed base64, algorithms, versions, nonce and tag sizes must fail closed.
- Existing V1 sync/invitation/device admission must be unchanged.

### Task 1: Browser format and crypto

**Files:** `cloud/public/resource-crypto-v2.js`, `cloud/tests/resource-crypto-v2.test.mjs`.

- [x] Write negative and roundtrip tests; observe missing-module failure.
- [x] Implement random CEK, canonical AAD, strict envelope parser, ciphertext and wrapper primitives.
- [x] Run targeted tests and correct test expectations.

### Task 2: macOS format and interoperability

**Files:** `Sources/SelectiveRemote/CloudResourceCryptoV2.swift`, `Tests/SelectiveRemoteTests/CloudResourceCryptoV2Tests.swift`, cross-platform fixture.

- [x] Write failing Swift tests for CEK, AAD, envelope, wrapper, mutations, and browser fixture.
- [x] Implement matching CryptoKit primitives and strict decoding.
- [x] Run targeted Swift tests.

### Task 3: Dormant storage and atomic publication

**Files:** `cloud/migrations/014_resource_crypto_v2.sql`, `cloud/src/postgres-store.mjs`, Cloud migration/store/integration tests.

- [x] Write failing SQL/store tests for V1 rejection, version compare, rollback, missing wrapper and concurrent publication.
- [x] Add additive scoped tables, constraints and transaction primitive with no route.
- [ ] Run targeted Cloud and PostgreSQL tests.

### Task 4: Review and Owner gate

**Files:** `docs/architecture/resource-crypto-v2-foundation.md`, Continuity repository.

- [ ] Document trust model, nonce limits, version compatibility, rotation and performance.
- [ ] Run full Swift/Cloud/Release and exact-head formal security review; fix reportable findings.
- [ ] Push branch, await CI/Test DMG, update Continuity, and present exact-head Owner gate.
