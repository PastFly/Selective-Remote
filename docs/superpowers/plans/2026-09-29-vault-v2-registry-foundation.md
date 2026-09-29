# Vault v2 Resource Registry Foundation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox syntax.

**Goal:** Add dormant resource identity, format and old-route guard primitives while preserving every existing Vault as v1.

**Architecture:** Additive PostgreSQL migration records format and opaque resource bindings, with no public ACL or v2 payload endpoint. Existing v1 store paths require `V1_ACTIVE`; client-side identity models prepare stable Folder IDs for a later encrypted v2 migration without writing names or changing live v1 documents.

**Tech Stack:** PostgreSQL, Node.js, Swift 6/SwiftPM.

**Spec:** Owner request attached in this task; architecture reference is Draft PR #210, especially `docs/architecture/access-sharing-{resource-registry,v2-old-client-gate,v2-migration-state-machine}.md`.

## Global Constraints

- Start from public main `c554e26c3a36a95d439f35258137ec6625755fb5`.
- All existing Vaults stay `V1_ACTIVE`; no automatic format transition or real payload migration.
- No grants, groups, ACL enforcement, CEKs, v2 wrappers, Access Manager backend or Credential.Use.
- Public main and Draft PR #210 remain untouched.

## Review Focus

- A same-named Folder in Host and Snippet namespaces must not merge.
- A tombstoned resource ID cannot be recreated, even after another Vault is involved.
- A resource parent must be a Folder in the same Team/Vault and cannot form a cycle.
- Old list/get/put/key-device/wrapper paths must fail closed for hypothetical `V2_ACTIVE`.
- An old-client query must not leak names or ciphertext from a v2 Vault.

---

### Task 1: Additive schema and registry store

**Files:** `cloud/migrations/013_resource_registry_foundation.sql`, `cloud/src/postgres-store.mjs`, `cloud/tests/migrations.test.mjs`, `cloud/tests/team-postgres-integration.test.mjs`.

**Interfaces:** `registerResourceIdentity({teamID,vaultID,resourceID,policyClass,parentFolderID})`, `getResourceIdentity({teamID,vaultID,resourceID})`, `tombstoneResourceIdentity(...)`. Only internal store methods; no public route.

- [ ] Write failing migration/store tests for default v1, uniqueness, scope, parent Folder, tombstones and no plaintext fields.
- [ ] Run them and observe expected RED.
- [ ] Add migration and minimal store methods with tenant/Vault predicates.
- [ ] Run targeted tests GREEN; inspect query plan/indexes.
- [ ] Commit.

### Task 2: Capability and old-route guard

**Files:** `cloud/src/postgres-store.mjs`, `cloud/src/vault-format.mjs`, `cloud/tests/team-postgres-store.test.mjs`, `cloud/tests/team-postgres-integration.test.mjs`.

**Interfaces:** `V1_ACTIVE`, reserved `resource_registry_v2`/`resource_acl_v2`, and format checks in every legacy Vault route. No API to activate v2.

- [ ] Write failing tests for hypothetical v2 list/get/put/wrapper/key-device denial, including v1 unchanged.
- [ ] Run RED.
- [ ] Implement format predicates and session-bound capability classification, keeping both capabilities inactive for existing Vaults.
- [ ] Run targeted tests GREEN.
- [ ] Commit.

### Task 3: Mac and browser identity models

**Files:** `Sources/SelectiveRemote/VaultResourceIdentity.swift`, `Tests/SelectiveRemoteTests/VaultResourceIdentityTests.swift`, `cloud/public/resource-identity.js`, `cloud/tests/public-resource-identity.test.mjs`.

**Interfaces:** random UUID creation, immutable ID on rename/move, new ID on copy/import/duplicate; persisted-in-v2-preparation Folder mapping for Host and Snippet namespaces. Do not modify v1 Vault document format or current UI.

- [ ] Write failing tests for matching Mac/browser ID shape, nested/duplicate-named Folders, move/rename/copy/import and namespace separation.
- [ ] Run RED.
- [ ] Implement minimal pure models.
- [ ] Run targeted tests GREEN.
- [ ] Commit.

### Task 4: Full verification and PR

- [ ] Run complete Cloud and Swift suites, Release build, migration checks and diff check.
- [ ] Review exact diff for no active ACL/crypto/UI changes, then run formal exact-head security scan.
- [ ] Push branch, create PR and await exact-head CI/Test DMG.
- [ ] Update Continuity with evidence and return Owner gate, without merging.
