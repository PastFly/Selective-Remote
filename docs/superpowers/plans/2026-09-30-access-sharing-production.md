# Access & Sharing Production Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate real authenticated Access & Sharing product surfaces in Mac and Cloud with truthful lifecycle and publication gates.

**Architecture:** Reuse existing session transports and policy engine. Add bounded read directories and transaction-bound group previews, then shared native/web access surfaces. Preserve the immutable active-generation publication gate; fixtures exercise future ACTIVE presentation without claiming real activation.

**Tech Stack:** SwiftUI/Swift Testing, browser ES modules/native DOM, Node test runner, PostgreSQL 16.

**Spec:** `docs/superpowers/specs/2026-09-30-access-sharing-production-design.md`

## Global Constraints

- TARGET_RELEASE=0.32.0
- PRODUCTION_V2_ACTIVATED=NO; PRODUCTION_MIGRATION_RUN=NO; PRODUCTION_CEK_DELIVERY=NO; PRODUCTION_CLOUD_DEPLOYED=NO
- TAG_CREATED=NO; RELEASE_PUBLISHED=NO; PUBLIC_FEED_CHANGED=NO; no official signing/notarization.
- Public main requires fresh exact-head Owner approval. PR #210 is Draft reference, never merge wholesale or close automatically in this task.
- Every access mutation uses server preview → explicit confirmation → signed commit; server session, existing Owner/Admin policy and same-Team/Vault identity are authoritative.
- Preserve PREPARING-only policy mutation and active-generation publication boundary. READY/ACTIVE writes fail closed with useful publication gate; never infer crypto success from policy.
- Pages max50; grant/move request max50 changes,20 explicit principals,1000 expanded pairs. No silent partial commit.
- Permission masks HOST13,CREDENTIAL15,SNIPPET13,FORWARDING9,FOLDER33. Credential Edit requires Reveal. No Use/Connect/Run security bits.
- Every effective path survives; policyEffective is user-scoped, deviceUsability explicitly device-scoped. Unverified wrapper → UNKNOWN.
- RU/EN, Light/Graphite, accessibility and rendered actual-component matrix required; local fixtures are not authenticated staging acceptance.
- Plaintext labels only from authorized scoped local decryption; fallback opaque ID/kind. No secrets/keys/tokens in logs, audit or notification persistence.

## Review Focus

- A filtered page may be empty with nextCursor: browsing must continue without eager whole-directory loading.
- A slow old Team/Vault response must never populate a newly selected context or keep a usable preview.
- An equivalent alternate path suppresses false revocation and notification even when a direct grant was removed.
- A client possessing a V1 snapshot must not use it as a V2 plaintext label directory.
- Copying the same Personal resource twice creates distinct Team identities and keeps original credential references correct.

### Task 1: Product-safe Access API directories and signed group workflow

**Files:**
- Create: `cloud/src/access-surface-store.mjs` (bounded directory/context reads and group preview binding helpers), `cloud/tests/access-surface.test.mjs`, `cloud/tests/access-surface-postgres.test.mjs`.
- Modify: `cloud/src/access-store.mjs`, `cloud/src/access-preview.mjs`, `cloud/src/service.mjs`, `cloud/src/server.mjs`, `cloud/src/postgres-store.mjs`, affected Access tests.
- Reference: `/private/tmp/access-api-inventory.md`.

**Interfaces:**
- Produce authenticated GET `/v1/teams/:teamID/access-vaults?limit&cursor` → `{rows:[{id,teamID,name,formatState}],nextCursor}`; preserve legacy Vault list.
- Produce GET `/v1/teams/:teamID/vaults/:vaultID/access-context` → existing exact foundation capabilities plus `policyMutationAvailable`, `blockers` string array; no migration or CEK data.
- Produce GET `/v1/teams/:teamID/vaults/:vaultID/access-resources?limit&cursor&kind` → `{rows:[{id,teamID,vaultID,policyKind,parentFolderID,resourceVersion}],nextCursor}` for eligible PREPARING context only.
- Produce bounded GET `/v1/teams/:teamID/vaults/:vaultID/access-resources/:resourceID` → one metadata row with the same fields and authorization, for grant targets outside the current directory page. Missing/tombstoned/cross-scope IDs fail closed; no eager inventory scan or inferred kind.
- Extend GET access-groups with bounded literal search; produce GET `/v1/teams/:teamID/access-groups/:groupID/members?limit&cursor` → `{rows:[{id,groupID,userID,membershipID,membershipEpoch,version}],nextCursor}`.
- Produce GET `/v1/teams/:teamID/vaults/:vaultID/access-devices?subjectUserID&limit&cursor` → `{rows:[{id,name,platform,admitted}],nextCursor}` for exact active same-Team subject in eligible PREPARING context. No keys/wrappers and no foreign-user enumeration. Explicit device picker must not use the actor's device for another user or require UUID entry.
- Produce POST `/v1/teams/:teamID/vaults/:vaultID/access-group-preview` with `{request:{type,groupID?,edgeID?,expectedVersion?,name?,targetMembershipID?},cursor?}`. Types `GROUP_CREATE/GROUP_RENAME/GROUP_DELETE/GROUP_MEMBER_ADD/GROUP_MEMBER_REMOVE`.
- Produce POST matching `access-group-commit` with `{request,token}` and idempotency header. Preview response `{token,snapshotID,details,counts,nextCursor}`; snapshotID is the hash of signed binding before expiry, stable across unchanged pages; detail identifies affected user/resource/Vault and before/after effective policy. Add the same snapshotID to existing grant preview responses. Group result includes actual mutation result and committed `notificationCandidates`. No unsigned original HTTP group mutation bypass.
- Preserve existing exact grant APIs. Correct revoke-only bulk Audit to `bulk_revoke.applied`.
- Group preview additionally returns `affectedGrants:[{grantID,vaultID,targetKind,targetID,permissionMask,version}]` and `counts.affectedGrants`, including when no members currently receive those grants. Both details and affectedGrants page at50 using the same offset; nextCursor continues until both collections end. No fake user row for empty membership; no plaintext target labels.

- [ ] **Step 1: Write failing tests** for scoped directories, literal search and paged empty results; role/device denial; no key/ciphertext response; all group operations require signed preview; stale actor/role/member/group/revision/token invalidates atomically; delete fanout1001 typed safe count and zero writes; equivalent paths yield no candidate; PREPARING real API and READY/ACTIVE fail-closed publication gate.
- [ ] **Step 2: Run** `node --test cloud/tests/access-surface.test.mjs` and relevant PostgreSQL test against isolated PG16. Expected failures identify absent contracts.
- [ ] **Step 3: Implement** minimal adapters using existing admitted-device/scope checks, bounded SQL and signed request/snapshot token conventions. Group commit rechecks signed snapshot within existing transaction/locks before mutation; do not validate then call an unrelated transaction. Keep group Team lifecycle independent. For effects reuse evaluator and exact memberships; bounded overflow rejects, never incomplete preview. Add only safe typed public errors and counts. No active-generation mutation, migrations or crypto publication.
- [ ] **Step 4: Run** focused Access tests and PG16 stale/concurrency/rollback cases; record commands/output. Existing direct-store group primitives may remain internal, but public route/service paths cannot bypass preview. Add EXPLAIN/scale evidence for new indexed directories at 1000 members/5000 opaque resources with no unbounded data response.
- [ ] **Step 5: Commit** API and tests. Write precise wire contract and response examples to task report for downstream adapters, including every chosen field shape; no token values.

### Task 2: Cloud Access Manager and authenticated browser adapter

**Files:**
- Create: `cloud/public/access-client.js`, `cloud/public/access-model.js`, `cloud/public/access-manager.js`, `cloud/public/access-copy.js`, `cloud/public/access-manager.css`; `cloud/tests/access-client.test.mjs`, `cloud/tests/access-model.test.mjs`, `cloud/tests/access-manager.test.mjs`.
- Modify: `cloud/public/vault-sync.js`, `cloud/public/app.js`, `cloud/public/index.html`, `cloud/public/i18n.js` only integration hooks.
- Reference: `/private/tmp/access-cloud-inventory.md` and Task1 report.

**Interfaces:**
- Consume Task1 exact routes plus existing authenticated `createAuthenticatedVaultClient`, paged members, grants, who-has, effective-access, preview/commit.
- Produce `createAccessClient({request,currentUserID,currentDeviceID})` typed methods and `createAccessManager({root,client,context,resolveLabel,onCommitted})` with `setContext(context)`, `refresh()`, `destroy()`; context includes Team/Vault/role/device but never grants authority. `resolveLabel(ref)` returns only a locally authorized label or null.
- Produce resource permission/preset helpers and localized consequence/error/state copy usable by fixtures. Mutation result callback only after committed server success.

- [ ] **Step 1: Write failing tests** for exact wire requests/token binding, 401 invalidation, stale-context suppression, changed draft invalidates preview, empty page with nextCursor, Credential masks, all paths, opaque labels, UNKNOWN semantics, explicit-device requests, limits/no partial commit and useful typed errors.
- [ ] **Step 2: Run** the new focused tests to establish RED.
- [ ] **Step 3: Implement** actual Team-management Access destination, Members/Groups/Resources, independent search/paging, recipient chips, presets/custom checks, group CRUD/member operations and impact preview; grants change/revoke and bulk max50 with explicit scope, preview paging and confirm. Make no direct write without preview. V1/readiness and immutable READY/ACTIVE gate are clear, no activation control. Only authorized local labels; no plaintext V1→V2 shortcut. Use textContent/semantic DOM, focus/Escape/keyboard, live errors, mobile CSS with theme tokens, explicit RU/EN copy and locale-change rerender.
- [ ] **Step 4: Run** focused tests and real product component DOM tests. Integration exercises real adapter with synthetic scoped server responses rather than standalone prototype state. Check response-generation guards and commit idempotency.
- [ ] **Step 5: Commit** Cloud surface and contract tests; report fixture hooks required by Task5.

### Task 3: Native typed Access client, Share and Effective Access sheet

**Files:**
- Create: `Sources/SelectiveRemote/CloudAccessModels.swift`, `CloudAccessAPI.swift`, `CloudAccessCoordinator.swift`, `CloudResourceAccessView.swift`, `CloudAccessLocalization.swift`; `Tests/SelectiveRemoteTests/CloudAccessTests.swift` (adapt actual test directory convention).
- Modify: `Sources/SelectiveRemote/CloudAPIClient.swift` only common authenticated transport visibility/helpers as needed; `CloudTeamManagementView.swift` for an Access entry within existing management.
- Reference: `/private/tmp/access-mac-inventory.md` and Task1 report.

**Interfaces:**
- Consume Task1 wire contract and existing authorized session transport. Produce `SelectiveRemoteCloudAccessReference` with TeamID/VaultID/resourceID/kind and optional already authorized displayName; distinct state DTOs; validate response scope.
- Produce native `SelectiveRemoteCloudResourceAccessView(reference:client:session:onCommitted:)`, coordinator load/preview/commit and paged picker, plus reusable read-only state/error components. Callback carries committed server candidates, not client computed rights.

- [ ] **Step 1: Write failing tests** for transport paths/encoding, UUID scopes, malformed masks and DTOs, picker pagination1000, principal/device separation, every path, equivalent revoke copy, restart/stale preview and no commit without fresh token, invalidation on context/selection changes.
- [ ] **Step 2: Run** focused Swift tests to establish RED.
- [ ] **Step 3: Implement** strict Sendable/Codable value models and existing bearer/401 transport reuse. Build compact native sheet: resource header, Share/Who has access/Effective views, search recipient tabs/chips/page navigation, resource presets/custom toggles with Reveal invariant, explicit-device query, preview consequences and confirmation. Gate lifecycle and unresolved mapping truthfully; no plaintext secrets. Use native focus/keyboard default/cancel buttons/VoiceOver labels and existing RU/EN/theme conventions; bounded normal/narrow sheet.
- [ ] **Step 4: Run** focused Swift tests and compile. Provide real-view fixture initializer using injected transport/model only for local visual tests, never a production synthetic data mode.
- [ ] **Step 5: Commit** native reusable surface; report exact entry-point initializer/coordinator signature for Task4.

### Task 4: Resource entry points, safe Personal copy, DnD and existing notification/audit integration

**Files:**
- Modify: `Sources/SelectiveRemote/CloudTeamHosts.swift`, `CloudTeamCredentials.swift`, `CloudTeamSnippets.swift`, `ForwardingManager.swift`, `ContentView.swift`, `CloudProfileShareView.swift`, `VaultResourceIdentity.swift` only mapping helpers if needed.
- Modify: `NotificationProjection.swift`, `MacNotificationCenter.swift`, `NotificationCenterView.swift`; `cloud/public/notification-projection.js`, `notification-center.js`, `app.js` Audit integration.
- Create focused copy/move helpers when needed and covering Swift/Cloud tests; preserve single responsibility.

**Interfaces:**
- Consume Task3 sheet/reference and Task2 committed callback; resolve exact stored resourceID/Folder mapping, never scoped display ID/path hash or ruleID.
- Produce shared `AccessMoveDecision` gate used by both sidebar/main persistence paths; ordinary V1/reorder proceeds, registered V2 ancestry mutation returns preview-required and server commit/publish gate.
- Extend notification kinds for current-account committed effective gains/losses, opaque stable IDs and deduplication. No preview/local draft events.

- [ ] **Step 1: Write failing tests** for Host/Credential/Snippet/Forwarding/Folder entry routing with exact identity, missing mapping prerequisite, Personal-copy twice fresh identities and credential reference rewrites, original intact, failed access-changing move zero persistence in both paths, V1 reorder preservation, foreign-account/zero-delta candidate suppression and safe Audit labels.
- [ ] **Step 2: Run** affected focused tests to establish RED.
- [ ] **Step 3: Implement** Share/Who has access contextual and suitable detail actions without sidebar clutter. Forwarding/Folder without registry mapping explains prerequisite; mapped fixtures exercise real sheet. Personal copy has explicit copy wording/Team/Vault/Folder destination, fresh IDs, retained original and optional access continuation. Do not bypass encrypted uploader/CAS/key-role restrictions. Gate both DnD paths before persistence; published resource useful crypto gate. Add candidate filtering only after successful committed response, no false revoke for equivalent path. Localize group/grant/bulk/move Audit without secret/unauthorized name metadata.
- [ ] **Step 4: Run** covering regression tests; check no existing DnD or shared-secret behavior regresses.
- [ ] **Step 5: Commit** integration and update #210 parity table in spec with unique remaining docs; recommend closure, do not close automatically.

### Task 5: Real-component fixture/render matrix and acceptance evidence

**Files:**
- Create: `cloud/tests/fixtures/access-manager.html`, `access-manager-fixture.js`, focused browser smoke/matrix tests following existing browser tooling; native fixture/export harness using existing runtime conventions; `docs/qa/access-sharing-production.md`.
- Modify only changed Access files for concrete failures found, plus covering tests.
- Modify `.github/workflows/ci.yml` to include `tests/access-surface-postgres.test.mjs` in the existing PostgreSQL16 job's explicit test list, so new authorization/concurrency regressions run with a real database in CI.

**Interfaces:**
- Consume actual Task2/3/4 product modules/views and injected clients; synthetic test state only, no production fixture switch or invented backend success.
- Produce portable scenario/evidence manifest, scale timings/request bounds, screenshots outside tracked source when large, and functional/local visual status distinctly from staging acceptance.

- [ ] **Step 1: Add failing acceptance scenarios** for actual Cloud/native surfaces, including navigation through the real Team workspace Access destination rather than only constructing its component: empty/loading/error, V1/preparing/ready/active fixture, direct/group/multiple paths, no key/UNKNOWN; keyboard focus/close/confirm, RU/EN Light/Graphite normal/narrow and desktop/tablet/mobile; denied-label canary and stale context. Include 5/100/1000 members and50/500/5000 resources with bounded visible rows/API requests.
- [ ] **Step 2: Run** new smoke/scenarios to capture concrete RED gaps.
- [ ] **Step 3: Implement** narrowly required fixture hooks and fix real rendered failures; fixtures explicit `LOCAL_VISUAL_PREVIEW`, `TEST_SESSION_MODE=FRESH_ANONYMOUS`, local origin. No credentials, real deployment or synthetic staging acceptance claim. ACTIVE mutation fixtures may exercise UI adapter with a test response, but real published-generation writes remain blocked.
- [ ] **Step 4: Run** full rendered matrix, focused behavior/security tests and record evidence. Controller then runs full Cloud/Swift, Release, PG16 matrix/scale, final independent review, exact-head formal security scan, CI/Test DMG and Continuity; fixes require covering tests and review.
- [ ] **Step 5: Commit** fixtures, QA evidence and final #210 remainder audit. Report explicit production publication/mapping/deployment/manual acceptance gates. Prepare fresh Owner gate only after all authorized candidate checks are complete; never merge automatically.
