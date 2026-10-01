# Resource materialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver exact legacy resource identity and authenticated immutable-publication reads into real Mac/browser scoped models, while keeping activation and published mutation disabled.

**Architecture:** A shared signed reader projection authenticates a minimal header, each part descriptor, a recipient-only wrapper proof and complete recipient inventory. PostgreSQL retains permanent scoped identities and immutable generation associations. Both clients verify pinned publisher trust and generation high-water before decrypting, stage a complete view, recheck the pointer and persist securely before display.

**Tech Stack:** Node.js/WebCrypto, PostgreSQL 16, Swift/CryptoKit, existing Cloud HTTP service, Keychain and browser device-local protected storage.

**Spec:** `docs/superpowers/specs/2026-10-01-full-scope-publication-materialization-design.md` (Owner approved).

## Global Constraints

- Baseline `6de88d78b5de934aba95383cf853f0771bf6e15d`; branch `codex/vault-resource-materialization`; worktree `.worktrees/access-sharing-production`.
- PR A only: no ACTIVE mutations, activation route, real migration, Cloud deploy, feed/tag/release/signing/notarization. Existing V1 behavior stays intact.
- Preserve the single evaluator, existing Team role ceiling and complete ACTIVE snapshot guard. Membership/device/root/epoch changes deny new delivery.
- No TOFU, unsigned projection, legacy-wrapper fallback, unprotected CEK/plaintext cache, actor IDs from request bodies, or Owner/Admin decrypt override.
- Limits: 1000 resources, 10,000 wrappers, 100 signed descriptors/page, 1 MiB encoded part/descriptor, 64 MiB checkpoint, 128 MiB aggregate. Typed fail-closed errors. Credential parts stay together within the descriptor budget; the existing resource-ID cursor is retained.
- PR B retains successor generation writes/repair; PR C retains controller deployment and actual synthetic staging E2E. Fixture success cannot close RC.
- Each task follows RED → minimal implementation → GREEN, then related regression and a scoped commit. Final full gates precede fresh exact-head Owner merge approval.

## Shared wire interfaces

All signed/hash inputs use UTF-8 `selective-remote/publication/v1\0` + purpose + `\0` + existing canonical JSON. Hex digests are lowercase SHA-256. Root signatures are P-256 ECDSA raw 64-byte base64url. UUID strings are canonical lowercase.

- `header.payload`: `version:1, teamID, vaultID, generationID, sequence, previousHash, descriptorCommitment, publisherAccountID, publisherDeviceID, publisherKeyVersion`. `previousHash` is null for sequence 1. Header hash commits the complete signed header. To avoid circular commitments, descriptorCommitment hashes the sorted descriptor cores before adding headerHash/signatures; the core contains every other descriptor field.
- `descriptor.payload`: `headerHash, resourceID, kind, part, parentFolderID, context, ciphertextHash, wrapperRoot`. Descriptor identity is resourceID/part; signed digest commits the complete descriptor.
- Wrapper leaf commits the complete validated wrapper plus recipient account, membership epoch, device ID and device key version. Canonical sorting key is membershipID/deviceID; duplicate keys and empty sets reject. Parent SHA-256 uses distinct purpose `wrapper-parent` and exact ordered left/right digests; odd last node duplicates itself. Proof binds index and total leaves, bounded by 14 levels.
- `inventory.payload`: `headerHash, accountID, deviceID, membershipID, membershipEpoch, count, digest`; digest covers the complete sorted resourceID/part/signed-descriptor-digest array. Count is parts, not pages. Each reader receives only its own signed inventory.
- `projection`: signed header, signed descriptors, signed recipient inventories, wrapper leaf/proof data. Validate against immutable administrative manifest/resources/objects before READY. Older generations without projection are unavailable through reader API.
- Transport prefix `/v1/teams/:teamID/vaults/:vaultID/publication`: `header`, `publisher`, `directory`, `resources/:resourceID/parts/:part`. Every non-header read pins generationID/headerHash. Signed cursor binds actor/session/device/scope/generation/filter/expiry.
- Decrypted parts contain exact `teamID,vaultID,resourceID,kind,part` linkage plus the original record or whitelisted Credential metadata; no SECRET in METADATA. An encrypted custodian sidecar contains mapping/fingerprint/tombstones/clocks only, and explicit custodian wrappers.

## Task 1: Signed reader projection and shared vectors

**Files:** create `cloud/public/vault-publication-v1.js`, `cloud/tests/vault-publication-v1.test.mjs`, shared `Tests/SelectiveRemoteTests/Fixtures/vault-publication-v1.json`; create `Sources/SelectiveRemote/CloudVaultPublicationV1.swift` and corresponding Swift tests.

**Interfaces — produces:** canonical publication bytes/hash/signature validation, Merkle root/proof, strict header/descriptor/inventory validation and projection preparation/verification. Consumers Tasks 2–5 use these exact wire interfaces.

- [ ] Write literal byte/hash vectors and tamper/scope/proof/completeness/rollback tests first.
- [ ] Run Node/Swift targeted tests; observe missing behavior failures.
- [ ] Implement strict bounded protocol using existing trust/resource crypto primitives; no new evaluator.
- [ ] Run both targeted suites; reject extra fields, invalid versions, duplicate wrappers, wrong proof orientation/index/count, altered descriptor/context/header and incomplete inventories.
- [ ] Commit protocol and vectors.

## Task 2: Exact persistent legacy mapping and reader-ready preparation

**Files:** modify `cloud/public/vault-v2-migration.js`; create `cloud/public/legacy-resource-mapping.js`; create `Sources/SelectiveRemote/CloudLegacyResourceMapping.swift`; add matching Node/Swift tests and representative supported export fixtures.

**Interfaces — consumes:** Task 1 projection. **Produces:** persisted scope/source-key mapping, resource-linked GENERAL/METADATA/SECRET payloads, metadata-only encrypted custodian sidecar and signed projection carried with preparation.

- [ ] Test canonical UUID preservation, duplicate/collision/tombstone rejection, exact Unicode/case path preservation, nested parents, stable resume and clocks/times/unknown fields preservation; unsupported secrets block the whole attempt.
- [ ] Observe RED, then replace ordinal-only mapping with stable source identities and explicit folder map; persist before encryption and fault-test restart.
- [ ] Preserve Credential original fields in SECRET with safe metadata whitelist; add exact linkage to each part. Select explicit verified custodian wrappers for sidecar; do not copy live payload into it.
- [ ] Attach projection using original custodian root and exact recipient targets; restart must replay persisted immutable bytes.
- [ ] Run converter/crypto/trust/mapping suites and commit.

## Task 3: Permanent identities, immutable projection storage and authenticated reads

**Files:** create `cloud/migrations/020_vault_publication_readers.sql`, `cloud/src/vault-publication-store.mjs`; modify `vault-migration-store.mjs`, `migration-policy.mjs`, `postgres-store.mjs`, `config.mjs`, `service.mjs`, `server.mjs`; add PostgreSQL and HTTP publication tests using existing synthetic fixtures.

**Interfaces — consumes:** Tasks 1–2 projection and scoped resource IDs. **Produces:** stage-gated read transport with signed completeness, publisher bundle and recipient-only part responses.

- [ ] Test fresh/12→20 migration, registry/generation insertion orders, cross-scope collisions, discard/reuse and direct SQL tombstone races; observe RED.
- [ ] Reconcile old reservations into permanent identities with scoped generation associations; discarded identities remain retained, mutable attributes never alter identity scope, live tombstones cannot resurrect.
- [ ] Store/freeze projection in PREPARING, cross-validate before READY; existing unprojected foundation remains inaccessible. Keep ACTIVE pointer freeze unchanged.
- [ ] Implement repeatable-read requests with fresh membership/admission/root/certificate and ACTIVE snapshot/evaluator checks. Bound publisher bundle to current generation and member Team. Filter wrapper and inventory to exact subject.
- [ ] Implement directory page ≤100 signed descriptors, exact off-page lookup, signed cursors, generation_changed denial, non-enumerating outsiders and no shared cache.
- [ ] Run migration/direct-SQL concurrency/scale/EXPLAIN and HTTP permission matrix; commit.

## Task 4: Browser verified materialization and publisher identity UI

**Files:** create `cloud/public/vault-publication-client.js`; modify actual browser Cloud/Vault rendering and Access resource resolution in `cloud/public/app.js`; add browser/Node integration tests.

**Interfaces — consumes:** Task 3 transport, Task 1 verifier, Task 2 linked payloads. **Produces:** coherent scoped models, exact contextual resource references and separately gated secret retrieval.

- [ ] Test real crypto two-account/device fixtures, missing publisher pin, same-sequence hash fork, incomplete or over-100-descriptor pagination, pointer switch, logout/account/endpoint switch, storage failure and authoritative revocation; observe RED.
- [ ] Reuse verified own-account pin; require explicit independent fingerprint confirmation for another publisher, scoped endpoint/Team/account pin, never silent replacement.
- [ ] Verify header/trust/high-water, descriptors/Merkle/ciphertext, decrypt exact key/AAD/linkage, collect full signed inventory, recheck pointer and protected persistence before atomic display.
- [ ] Route actual published Vault rendering through scoped models; context-menu Share/Who-has consumes verified resource IDs. Credential metadata cannot fetch SECRET, editing/move/grants remains publication-required/read-only.
- [ ] Preserve coherent encrypted offline cache with stale label; identity checks at persistence/display and authoritative loss clear managed views/secrets.
- [ ] Run browser/full related Cloud suites; commit.

## Task 5: Mac verified materialization, durable cache and actual scoped models

**Files:** create `CloudVaultPublicationAPI.swift`, `CloudVaultPublicationCoordinator.swift`, `CloudVaultPublicationStore.swift`; modify `CloudTeamVaultAutoSync.swift`, `CloudTeamHosts.swift`, `CloudTeamCredentials.swift`, `CloudTeamSnippets.swift`, `CloudAccessCoordinator.swift`, `CloudResourceAccessView.swift` as needed; add Swift pipeline/identity/cache tests.

**Interfaces — consumes:** same transport/protocol/linked payloads as browser. **Produces:** durable endpoint/account/device/Team/Vault-scoped publication view and exact references integrated into existing Host/Credential/Snippet/Forwarding/Folder models.

- [ ] Test actual CryptoKit shared vectors/unwrap/decrypt, partial reads, rollback/fork, missing cross-account pin, account/logout/pointer changes and durability failure; observe RED.
- [ ] Implement captured identity pipeline, secure Keychain protection/high-water, publisher independent fingerprint sheet and existing own-account trust reuse.
- [ ] Verify/stage/recheck/persist atomically, then feed real stores with verified scope/reference; maintain secret separation and read-only publication state.
- [ ] Close secret displays/actions on authoritative loss; transient failures preserve stale coherent encrypted cache. YES follows local exact-part decrypt only.
- [ ] Run targeted and full Swift regression plus Release; commit.

## Task 6: Complete PR A verification and fresh Owner gate

**Files:** add failure/concurrency/scale evidence and operator docs as needed; update Continuity in its separate repository.

**Interfaces — consumes:** all completed tasks. **Produces:** reviewable Draft PR with immutable tested head/tree, exact-head formal security report, CI/Test DMG and Continuity.

- [ ] Run full PostgreSQL 16 migration/concurrency/scale/EXPLAIN, Cloud and Swift tests, Release; record commands/counts/logs and all failures resolved.
- [ ] Independent whole-branch code review; TDD fixes for actionable findings, then relevant/full regressions. Run formal immutable-head Codex Security scan and resolve every reportable finding before gate.
- [ ] Push non-main branch, create Draft PR, attach it to this chat; await CI and Test DMG on exact head. No public main mutation.
- [ ] Reconcile/push/verify Continuity SHA/blobs with head/tree and limits. Explicitly retain all runtime/release boundaries and PR B/C remaining gates.
- [ ] Present exact-head Owner merge gate only after all required evidence succeeds.

## Review Focus

1. **Authorization:** actual authenticated read and exact subject filtering; no role-derived secret entitlement.
2. **Authenticity:** cross-account pin, root/certificate/high-water, signed projection, recipient Merkle proof and inventory completeness.
3. **Identity:** byte-preserving legacy conversion, stable IDs, tombstone permanence, direct SQL races and immutable associations.
4. **Client coherence:** final pointer/session checks, durable high-water before display, secret separation, revocation cleanup and stale cache.
5. **Scope:** no activation/ACTIVE mutation/deploy or release side effect; full PR A integration rather than fixture-only protocol.
