# Vault v1→v2 Migration Publication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove resumable client-only migration and atomic staging-only publication with unchanged v1 authority before activation.
**Architecture:** Immutable attempt-scoped resource/part/policy generation plus one active Vault pointer. Reuse crypto v2, signed device trust and Effective Access evaluator; retire legacy payloads atomically and require an independent deployment fence.
**Tech Stack:** Node/WebCrypto, existing pg client, PostgreSQL 16, Swift regression.
**Spec:** `docs/superpowers/specs/2026-09-30-vault-v2-migration-publication-design.md`

## Global Constraints

- Baseline `60a9e80c294e139ffefab8332362be7bfff22800`; TARGET_RELEASE=0.32.0.
- PRODUCTION_V2_ACTIVATED=NO; PRODUCTION_MIGRATION_RUN=NO; PRODUCTION_CLOUD_DEPLOYED=NO.
- ACCESS_MANAGER_UI_ACTIVE=NO; PR210_STATE=DRAFT_UNMERGED; TAG_CREATED=NO; RELEASE_PUBLISHED=NO; PUBLIC_FEED_CHANGED=NO.
- Client-only plaintext/CEKs; no request boolean enables production; no Use without Reveal.
- Exact-head formal scan, CI/Test DMG and fresh Owner approval precede public-main merge.

## Review Focus

- Resume after a crash between ID persistence and the first ciphertext must preserve all IDs and use fresh CEKs.
- A label/unknown Credential field must never leak into metadata; Host embedded secrets must block conversion.
- Legacy code omitting format predicates must see no original ciphertext/wrappers after activation.
- Device/group/certificate changes while ready must conflict even when normal APIs are bypassed with direct SQL.
- A restored old DB must fail the independent operator fence check; a pending fence must survive ambiguous COMMIT.

### Task 1: Local inventory, identity checkpoint and crypto preparation

**Files:** Create `cloud/public/vault-v2-migration.js`; test `cloud/tests/vault-v2-migration-client.test.mjs`.
**Interfaces:** Produces `previewLegacyMigration({document, existingIDs})`, `prepareLegacyMigration({document, scope, snapshot, policy, recipientTargets, pinnedTrust, root, checkpointKey, checkpoint, persistCheckpoint, faultAt})`, `openMigrationCheckpoint({checkpoint,key,scope})`, and canonical manifest signing. Scope binds teamID/vaultID/attemptID/sourceRevision/sourceHash/snapshotHash/policyVersion. Output has opaque resource descriptors, immutable `{resourceID,part,envelope,wrappers,sha256}` objects, encrypted checkpoint and signed manifest. No server module receives plaintext.

- [ ] Write tests for each type, invalid/missing/duplicate IDs, folder ancestry, unsupported sshKey, tombstones, embedded Host secrets, strict Credential metadata/secret round-trip, foreign trust pins, all injection stages and restart with persisted checkpoint.
- [ ] Run `node --test cloud/tests/vault-v2-migration-client.test.mjs`; expect missing-module RED.
- [ ] Implement exact conversion, persisted ID map before crypto, one fresh CEK per part, verified device wraps, local round-trip, checkpoint and root signature. Bound resources at 1000 and recipient devices at 100; no silent field drop.
- [ ] Run same test; expect all PASS; commit.

### Task 2: Snapshot/policy validation and staging schema

**Files:** Create `cloud/src/migration-policy.mjs`, `cloud/migrations/019_vault_v2_migration_publication.sql`; tests `cloud/tests/vault-v2-migration-policy.test.mjs`, `cloud/tests/vault-v2-migration-postgres.test.mjs`; update migration-version assertions affected by 019.
**Interfaces:** Consumes Task1 descriptors/manifest; produces `canonicalMigrationJSON(value)`, `migrationHash(value)`, `validateMigrationResources(resources)`, `migrationRecipients({resources,policy,snapshot})`, `verifyMigrationManifest({manifest,expected,rootPublicKey})`. Registry descriptors `{id,kind,parentFolderID,sourceOrdinal}`; exact permissions use existing evaluator. Schema stores attempt/source/snapshot/policy/manifest/checkpoint, resource graph and part hashes/JSON envelopes; active views join exact pointer and V2_ACTIVE.

- [ ] Write policy RED tests: cross-scope/membership epoch, Credential Edit without Reveal, every inheritance path, no eligible device, exact recipient matrix, signature/hash tamper, Admin target ceiling and invalid/repeated resource ordinals.
- [ ] Write PostgreSQL RED tests: missing 019, v1 payload stays intact, immutable READY data, scoped FKs/global IDs, atomic pointer visibility, irreversibility/retired legacy payload and old raw SQL read/write rejection.
- [ ] Run policy tests and PG16 test (local isolated server when available, otherwise exact branch CI); observe RED.
- [ ] Implement pure validation and additive schema with safe legacy payload constraint for V2_ACTIVE, immutable generation/format guards and no live row activation.
- [ ] Run policy and PG16 tests; expect PASS; commit.

### Task 3: Authorized resumable store and atomic cutover

**Files:** Create `cloud/src/vault-migration-store.mjs`; tests `cloud/tests/vault-v2-migration-store.test.mjs`, extend PG16 matrix; integrate internal store in `cloud/src/postgres-store.mjs`; adjust `cloud/src/service.mjs` only for safe authorized legacy upgrade-required response.
**Interfaces:** `VaultMigrationStore(pool,{environment,enabled,allowedVaultIDs,fence,faultAt})` exposes `preview(input)`, `start(input)`, `putPart(input,object,checkpoint)`, `validate(input,manifest)`, `activate(input,manifestHash)`, `discard(input)`, `readPart(input)`. Input actorUserID/actorDeviceID/teamID/vaultID/attemptID is session-derived by operator. Every method fails before data reads unless enabled staging + allowlisted Vault. `readPart` additionally requires schema2/resource_acl_v2 and exact current subject actor permissions.

- [ ] Write RED tests for default OFF/production refusal, role/epoch/admission/cert gating, exact replay/changed replay, source/policy/group/device/rotation staleness, missing/extra wrappers, interrupted upload, validation and each activation query fault, double/concurrent activation and partial visibility.
- [ ] Observe targeted RED. Implement complete ordered snapshots, cryptographic device validation, bounded staged writes, signed immutable READY candidate, table-lock protected snapshot recheck, atomic pointer/payload retirement/audit and exact read-back for ambiguous COMMIT. Keep v1 writes authoritative before activation.
- [ ] Add safe authorized upgrade-required behavior with outsider non-enumeration; client version strings alone never grant v2 access.
- [ ] Run store/PG16 matrix PASS; commit.

### Task 4: Independent compatibility fence and staging operator

**Files:** Create `cloud/src/migration-fence.mjs`, `cloud/scripts/vault-v2-migration-staging.mjs`, `docs/architecture/vault-v2-migration-publication.md`; tests `cloud/tests/vault-v2-migration-operator.test.mjs`.
**Interfaces:** Fence `intent({teamID,vaultID,attemptID,manifestHash,schemaFloor:19})` persists outside DB restore; `verify({schemaVersion,publications})` rejects old code/schema/restored DB or unknown pending outcome. Operator exposes preview/start/upload/validate/discard/activate/check-compatibility via explicit staging configuration and opaque encrypted input. No plaintext file input is accepted by the server operator.

- [ ] Write RED tests for absent/default production gate, malformed/symlink/corrupt fence, concurrent append, restored DB, missing active manifest, pending activation, unsupported client schema/capability and no secret logging.
- [ ] Implement fail-closed append/fsync and compatibility checks; document floor integration as a remaining production deployment gate and full-stack rollback boundary.
- [ ] Run operator tests PASS; commit.

### Task 5: Full failure/concurrency/scale and review gates

**Files:** Extend targeted/PG16 tests; create reproducible scale benchmark `cloud/scripts/benchmark-vault-v2-migration.mjs`; update `.github/workflows/ci.yml` PG16 test list; exact validation report in PR/Continuity.
**Interfaces:** Benchmark reports only counts, durations, wrapper/staging byte totals and activation query count, never records/keys.

- [ ] Complete all Owner matrix cases, run 100/1000-resource preparation and multi-device/group PG16 activation; record actual duration/transaction cost.
- [ ] Run targeted tests, all Cloud tests, full Swift regression and Release build, reading concise logs; fix concrete failures with RED→GREEN.
- [ ] Perform one fresh whole-branch code review, address material findings with regression tests. Run exact-head formal Codex Security scan; fix reportable findings and rescan.
- [ ] Push non-main branch, create/attach Draft PR; await exact-head CI and Test DMG. Reconcile #210 description if needed. Batch/push/verify Continuity.
- [ ] Report every requested field and remaining production fence/root-recovery boundaries; request fresh Owner gate for exact head; do not merge.
