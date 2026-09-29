# Secure Device Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit, cryptographically verified account-device bootstrap and approval without activating Vault v2 or changing legacy Team Vault behavior.

**Architecture:** Reuse the PR #214 local ECDSA account root and existing ECDH device key. The server relays account-scoped pending requests and one-time proof challenges, stores signed records and terminal decisions under account locks, while the trusted root custodian verifies ECDH possession and signs admission. Both clients pin trust out of band and verify signatures before future wrapper eligibility.

**Tech Stack:** Swift/CryptoKit/Keychain, browser WebCrypto/IndexedDB, Node 22, PostgreSQL 16, Swift Testing and Node test runner.

**Spec:** `docs/superpowers/specs/2026-09-29-secure-device-bootstrap-design.md`

## Global Constraints

- Keep `TARGET_RELEASE=0.32.0`, PR #210 Draft, Vault v2/CEK delivery/grants/groups/ACL inactive, and no production Cloud deployment or release action.
- Never accept a root fingerprint supplied only by the server. Require local first-device creation or authenticated out-of-band pairing.
- Do not use legacy `key_approved_at` as a signed-certificate or proof-of-possession substitute.
- Keep certificate v1's fixed P-256 algorithm and account scope; Team membership and epoch remain separate eligibility gates.
- Use bounded, canonical, domain-separated transcripts and fail closed on unknown fields/versions.
- Device private keys never leave Keychain/IndexedDB; server DB stores public records, nonce state and non-secret audit metadata only.

## Review Focus

- Concurrent first-root publication with different roots: exactly one wins; losing client retains local pin and fails closed.
- Delayed proof after rejection/revocation/expiry: cannot approve, issue a certificate or advance directory state.
- Browser storage clearing after registration: no silent root adoption or wrapper eligibility.
- Team device with valid account cert but revoked membership or stale epoch: wrapper eligibility denied.
- Server returns the right device ID with an attacker key: direct fingerprint comparison and signed-certificate verification deny before wrapper creation.

---

### Task 1: Trust protocol and proof primitives

**Files:** Modify `cloud/public/device-trust-v1.js`, `Sources/SelectiveRemote/CloudDeviceTrustV1.swift`; add focused browser/Swift tests and shared fixture.

**Interfaces:** Canonical challenge transcript, ECDH-HMAC proof creation/verification, strict certificate field and directory checks, pure wrapper eligibility decision consuming membership/admission/capability inputs.

- [ ] Add failing browser and Swift tests for valid proof, replay transcript mutation, wrong device/key, expiry, certificate field tampering, stale directory and Team eligibility denial.
- [ ] Run focused tests and confirm expected failures.
- [ ] Implement canonical proof and eligibility primitives using the existing P-256 ECDH device key and root-signed certificate format.
- [ ] Run focused tests, record cross-runtime fixture and commit.

### Task 2: Additive device-approval storage and races

**Files:** Add `cloud/migrations/016_secure_device_approval.sql`; add `cloud/src/device-approval-store.mjs` or narrow `PostgresStore` methods; add PostgreSQL tests; update CI migration job.

**Interfaces:** Root publish/read; pending create/list; challenge start/answer/consume; atomic approve/reject/revoke/rekey; signed-record publication; account audit read/write. All mutations scope by session account and lock the root/account row.

- [ ] Write failing PostgreSQL tests for duplicate root, pending, serial and challenge; approve/reject, revoke/approve and rekey/approve races; stale directory version; cross-account ID hiding.
- [ ] Run the PostgreSQL job to prove failures.
- [ ] Add constraints, partial uniqueness, challenge expiry/consumption and transaction locking; preserve signed history and no private keys.
- [ ] Run PostgreSQL tests and commit.

### Task 3: Authenticated service and API

**Files:** Modify `cloud/src/service.mjs`, `cloud/src/server.mjs`, `cloud/src/service-error.mjs`; add API/service tests.

**Interfaces:** `/v1/device-trust` endpoints for root, requests, challenges, decisions and signed records. Validate exact bodies, rate limits, CSRF, idempotency and account scope; return generic foreign-ID errors.

- [ ] Add failing request/authorization tests, including IDOR, stale-session, duplicate idempotency and body bounds.
- [ ] Run focused tests; implement routes/service validation on store methods.
- [ ] Run focused tests and commit.

### Task 4: Browser bootstrap, pairing and approval UI

**Files:** Modify `cloud/public/vault-sync.js`, `cloud/public/app.js`, `cloud/public/i18n.js`; add browser logic and rendered UI tests.

**Interfaces:** Explicit first-root creation/pin/publish; new-device fingerprint and OOB root-pin entry; pending request; custodian review/compare/PoP/approve/reject; revocation and explicit rekey states.

- [ ] Add failing browser tests for no auto-bootstrap, root persistence, storage loss, substitution before/after approval, duplicate/rejected/expired request and RU/EN actionable errors.
- [ ] Implement one clear UI flow using existing device panel and confirmation patterns.
- [ ] Run logic/rendered tests across RU/EN, Light/Graphite and narrow/desktop; commit.

### Task 5: Mac bootstrap, pairing and approval UI

**Files:** Modify `Sources/SelectiveRemote/CloudAPIClient.swift`, `CloudDeviceTrustStore.swift`, `CloudTeamManagementView.swift` and narrow supporting views; add Swift tests.

**Interfaces:** Keychain-backed explicit first-device bootstrap; out-of-band root pinning; pending request and fingerprint view; custodian proof verification/signing; revoke/rekey state.

- [ ] Add failing Swift tests for root restart/conflict, missing pin fail-closed, proof and certificate interoperability, and client request parsing.
- [ ] Implement Mac flow with RU/EN copy, safe focus/error states and no implicit trust on login.
- [ ] Run focused Swift and rendered UI tests; commit.

### Task 6: Notification and audit integration

**Files:** Modify browser/Mac notification projections and source polling, server audit storage/query; add tests.

**Interfaces:** One actionable `device.pending` item per request, resolved by source change; account audit with six allowed event names and no secrets.

- [ ] Add failing dedupe/resolution and audit-redaction tests.
- [ ] Implement source reconciliation and deep link to review UI on both clients.
- [ ] Run focused tests and commit.

### Task 7: Boundary review and full verification

**Files:** Update architecture docs, tests and CI only for evidenced gaps.

- [ ] Verify legacy v1 behavior, no production V2/CEK/grants/groups/ACL activation, no registry/wrapper mutation API and no feed/release changes.
- [ ] Run targeted browser/Mac/PostgreSQL matrix, full Swift and Cloud suites, Release build and `git diff --check`.
- [ ] Run formal Codex Security exact-head diff scan; fix every reportable code issue and repeat affected/full checks and scan.
- [ ] Push branch, open Ready PR, wait exact-head CI and Test DMG; do not merge.

### Task 8: Continuity and Owner gate

**Files:** Update `STATE.yaml`, `ROADMAP.md`, `PROJECT_CONTEXT.md`, `VERIFIED_HISTORY.md`, `HANDOFF_PROMPT.md` and other affected Continuity files.

- [ ] Record exact branch/head/tree, tested scope, unresolved browser/root/rollback boundaries, independent SQL/wrapper gate and all checks.
- [ ] Commit/push/fetch/read back Continuity and verify live main/PR #210 remain unchanged.
- [ ] Present exact-head PR and evidence for fresh Owner merge decision.
