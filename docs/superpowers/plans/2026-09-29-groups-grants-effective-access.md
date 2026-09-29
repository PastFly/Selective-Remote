# Groups, Grants and Effective Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add dormant V2_PREPARING Team groups, Vault grants, Effective Access, and snapshot-bound preview/commit APIs without changing V1 Vault behavior.

**Architecture:** Migration 018 stores Team groups and scoped grants with direct SQL constraints. A single policy module validates masks and computes paths; a PostgreSQL store uses existing Team/device authorization, Vault serialization, transactions, and audit. Thin service/server routes expose bounded operations only for V2_PREPARING Vaults.

**Tech Stack:** PostgreSQL 16, Node.js 22 ES modules, `pg`, Node test runner; SwiftPM regression and Release build.

**Spec:** `docs/superpowers/specs/2026-09-29-groups-grants-effective-access-design.md`

## Global Constraints

- V2_ACTIVATED=NO; REAL_VAULT_MIGRATION=NO; PRODUCTION_CEK_DELIVERY=NO.
- ACCESS_MANAGER_UI_ACTIVE=NO; PRODUCTION_CLOUD_DEPLOYED=NO; PR210_STATE=DRAFT_UNMERGED.
- TAG_CREATED=NO; RELEASE_PUBLISHED=NO; no public feed, signing, or notarization change.
- Only V2_PREPARING Vaults accept new policy mutations; existing V1 behavior remains unchanged.
- Reuse existing Team role policy; no nested groups or second role hierarchy.
- Batches: at most 50 resources, 20 explicit principals, 1,000 expanded pairs; pagination 50.
- Fresh Owner gate required before public main mutation.

## Review Focus

- A direct SQL writer races a grant commit: one serializes or fails with retry, never bypasses scope/mask/version rules (Task 1/4).
- An Admin targets an Owner/Admin through a group edge: existing Team ceiling denies mutation (Task 2/3).
- A member is revoked and re-added during preview: old membership/epoch cannot authorize commit (Task 5).
- Multiple inheritance paths survive one revoke: evaluator keeps rights and emits no false revoked notification (Task 4/6).
- Session secret rotates between preview and commit: typed conflict; no unsigned fallback (Task 5).

---

### Task 1: Migration 018 and direct SQL invariants

**Files:** Create `cloud/migrations/018_groups_grants_effective_access.sql`; Test `cloud/tests/groups-grants-postgres.test.mjs`.

**Interfaces:** Produces `team_policy_revisions`, `team_access_groups`, `team_access_group_members`, `vault_access_grants`, registry `policy_kind`, Vault `access_policy_version`; later store tasks consume them. Group has Team FK only. Grant has scoped Team/Vault/target/principal references, permission mask and tombstone.

- [ ] Write failing PostgreSQL tests for fresh migration, V1 default preservation, Team-only group lifetime, immutable registry type, duplicate active grant, invalid Credential.Edit-only mask, cross-Team rows, stale epoch, tombstone reuse and concurrent SQL writes.
- [ ] Run: `cd cloud && TEST_DATABASE_URL="$TEST_DATABASE_URL" node --test tests/groups-grants-postgres.test.mjs`. Expected: migration/table assertions fail before 018.
- [ ] Implement migration 018: additive columns/tables, partial unique indexes, scoped FKs, format/mask/version guards, appropriate Vault/Team locks, and bounded query indexes. Keep existing Vault format transitions untouched.
- [ ] Run the same tests. Expected: PASS, including concurrent direct SQL matrix.
- [ ] Commit migration and tests.

### Task 2: Permission contract and existing Team ceiling

**Files:** Create `cloud/src/access-policy.mjs`; Modify `cloud/src/team-policy.mjs`; Test `cloud/tests/access-policy.test.mjs`, `cloud/tests/team-policy.test.mjs`.

**Interfaces:** Produces `validateGrant(kind, mask)`, `inheritedViewBit(kind)`, `requireAccessMutation(actorRole, targetRole)`, and `evaluateAccessPaths({kind, paths, cryptoStatus, clientVerified})`. Task 4 consumes these exact exports.

- [ ] Write failing tests for all kind masks, Credential.Edit⇒Reveal, five inheritance mappings through arbitrary Folder depth, invalid persisted grants, YES/NO/UNKNOWN usability, Owner/Admin/Editor/Viewer matrix.
- [ ] Run: `cd cloud && node --test tests/access-policy.test.mjs tests/team-policy.test.mjs`. Expected: new imports or assertions fail.
- [ ] Implement pure policy functions, reusing `requireTeamPermission` and `requireMembershipChange` target ceilings; grant bits never confer Team administration.
- [ ] Run same tests. Expected: PASS.
- [ ] Commit policy and tests.

### Task 3: Team groups and grants transactional store

**Files:** Create `cloud/src/access-store.mjs`; Modify `cloud/src/postgres-store.mjs` only to delegate; Test `cloud/tests/groups-grants-postgres.test.mjs`.

**Interfaces:** Produces store methods `listAccessGroups`, `createAccessGroup`, `renameAccessGroup`, `deleteAccessGroup`, `addAccessGroupMember`, `removeAccessGroupMember`, `listAccessGrants`, `applyAccessGrant`, `revokeAccessGrant`. All inputs carry actor user/device, Team, Vault context, idempotency key and expected versions; all writes return typed result.

- [ ] Add failing PG tests for active device/membership/role and V2 gate, Team group reuse after Vault rollback, current-epoch edges, CRUD/version/CAS, typed `group_grants_must_be_revoked_first` above 1,000 with safe count and bounded revoke batches.
- [ ] Run: `cd cloud && TEST_DATABASE_URL="$TEST_DATABASE_URL" node --test tests/groups-grants-postgres.test.mjs`. Expected: new methods absent.
- [ ] Implement transaction methods with Vault→Team lock ordering, `40P01/40001` whole-transaction retry, Team Audit and durable idempotency receipts; reject all stale/cross-scope inputs.
- [ ] Run same tests. Expected: PASS.
- [ ] Commit store and tests.

### Task 4: Effective Access and folder ancestry

**Files:** Create `cloud/src/effective-access.mjs`; Modify `cloud/src/access-store.mjs`; Test `cloud/tests/effective-access.test.mjs`, `cloud/tests/groups-grants-postgres.test.mjs`.

**Interfaces:** Produces `getEffectiveAccess`, `listWhoHasAccess`, `listResourcesByPrincipal`, each with bounded cursor, path IDs, typed blocked reasons, crypto status and effectiveUsable. Task 5 calls the same evaluator inside snapshot transactions.

- [ ] Add failing tests for direct/group/ancestor paths, multi-level Folder propagation, alternate path after revoke, stale epoch, tombstoned/cyclic ancestry, wrapper unavailable/unverified, non-enumeration, pagination and snapshot consistency.
- [ ] Run targeted tests. Expected: missing evaluator/store method failures.
- [ ] Implement recursive same-Vault ancestor query and one evaluator over a consistent PG snapshot; fail closed for corrupt scope/ancestry/grant masks.
- [ ] Run targeted tests. Expected: PASS.
- [ ] Commit evaluator and tests.

### Task 5: Preview, bounded bulk commit and move gate

**Files:** Create `cloud/src/access-preview.mjs`; Modify `cloud/src/access-store.mjs`, `cloud/src/service.mjs`; Test `cloud/tests/access-preview.test.mjs`, `cloud/tests/groups-grants-postgres.test.mjs`.

**Interfaces:** Produces `previewAccessChange` and `commitAccessChange`; token is signed, expiring, actor/device/epoch/request/read-set bound. `crypto_publication_required` rejects published-resource moves.

- [ ] Add failing tests for exact before/after per user/resource and alternate paths, batch caps, replay/idempotency, stale versions/epochs, token tampering/expiry/secret rotation/restart, unsigned commit rejection, bulk atomic rollback, unpublished move and published move rejection.
- [ ] Run targeted tests. Expected: missing preview/commit operations.
- [ ] Implement canonical request hashing and domain-separated HMAC using server session secret; verify under locks and re-evaluate the same read set before one atomic commit. Include explicit transaction audit and no preview notification.
- [ ] Run targeted tests. Expected: PASS.
- [ ] Commit preview and tests.

### Task 6: HTTP API and notification semantics

**Files:** Modify `cloud/src/server.mjs`, `cloud/src/service.mjs`, `cloud/src/service-error.mjs`; Test `cloud/tests/access-api.test.mjs`, `cloud/tests/team-api-surface.test.mjs`.

**Interfaces:** Exposes authenticated `/v1/teams/:teamID/access-groups` and `/v1/teams/:teamID/vaults/:vaultID/access-*` routes via the Task 3–5 store. No V1 content route changes.

- [ ] Add failing API tests for Owner/Admin/Editor/Viewer, V1 fail-closed, Team/Vault injection, pagination, typed errors, preview-only silence, committed effective delta notification candidate, and alternate-path revoke silence.
- [ ] Run targeted tests. Expected: route 404 or missing service methods.
- [ ] Wire thin routes with body limits, UUID checks, device/session authorization and minimal redacted responses; derive notification candidate from committed effective permission delta only.
- [ ] Run targeted tests. Expected: PASS.
- [ ] Commit API and tests.

### Task 7: Migration matrix, scale, full regressions and review

**Files:** Modify `.github/workflows/ci.yml` if PG16 matrix lacks migration 018 coverage; Create `cloud/tests/access-scale.test.mjs` or a bounded EXPLAIN evidence script; Update architecture docs only for verified results.

**Interfaces:** Consumes all prior tasks; produces immutable test/EXPLAIN evidence and exact-head security/CI/DMG gate. No production deploy.

- [ ] Verify fresh PG16 migrations 1–18, direct SQL concurrency, representative EXPLAIN (ANALYZE, BUFFERS) for effective user/resource, who-has-access, resources-by-principal and group list at roughly 100 members/1,000 resources. Record plans and timings.
- [ ] Run full Cloud tests, full Swift regression and Release build. Expected: all PASS; diagnose any failure before continuation.
- [ ] Run formal Codex Security diff scan on final exact head; fix reportable findings with test-first changes and rescan. Expected: zero unresolved reportable findings.
- [ ] Push non-main branch and create/update Draft PR; await CI and Test DMG for exact head. Expected: SUCCESS.
- [ ] Update Continuity with verified SHA/tree, tests, scan, CI/DMG and release boundaries; request fresh Owner gate before merge.
