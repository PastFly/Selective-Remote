# PR C Staging Fence and Real Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Owner already approved the architecture and ordered implementation now; root executes and reviews this plan without another architecture-confirmation round.

**Goal:** Make independent rollback evidence govern actual staging startup/publication, then prove the approved synthetic migration and cross-device workflows without touching ordinary Vaults.

**Architecture:** First repair the existing fence's reader floor and query ordering without changing its outcome semantics. Then add an append-only outcome journal shared by initial migration and whole-generation publication, connect it to the actual start/deploy boundary, and perform the explicitly authorized real test-staging acceptance. Feature/source tests never substitute for runtime, manual, or release evidence.

**Tech Stack:** Existing Node.js ESM (`node>=22`), PostgreSQL16/`pg`, fs durability primitives, Bash/Compose controller, Browser WebCrypto/IndexedDB, macOS Swift6/CryptoKit; no new dependency or paid tool.

**Spec:** `docs/superpowers/specs/2026-10-01-full-scope-publication-materialization-design.md`, approved blob `a8859022545c420c80ef75091b3ec3ff054e19af`, especially §§6 and Required proof/release acceptance. Companion governing specs: `docs/superpowers/specs/2026-09-30-vault-v2-migration-publication-design.md` and `docs/superpowers/specs/2026-09-30-access-sharing-production-design.md`.

**Baseline:** public main `7e60aad624f7bc5a436887c2634af17c4390fb92`, tree `4276cbdbe60db2fd0d4a1a013720ce2109f2d690` (PR223's approved tree). Root creates the PR C non-main branch only after post-merge CI/Continuity verification. This plan is not implementation or PR C completion.

## Global Constraints

- “Implement on non-main branches.” Every public-main change needs fresh exact-head Owner approval; prior PR223 approval is consumed.
- Runtime activation is explicit, operator-enabled and allowlisted for disposable `TEST-ONLY-CODEX-<run-id>` Vaults; defaults stay off. Ordinary Vaults never migrate automatically.
- `cloud.pastfly.ru` is test staging; production does not exist. No production deploy/CEK, automatic migration, tag/release/feed, official signing or notarization follows from this plan.
- “Fence intent is durable before COMMIT; ambiguous COMMIT retains it.” “Timeout, missing response or a restored older DB is not proof of abort.”
- “After activation/published change, fix-forward only.” No live DB restore for source rollback, automatic fence reset/deletion, damaged-fence suppression, or weakened trust/role/old-client guards.
- Preserve exact complete-ACTIVE-set atomicity and existing typed bounds:10Vaults/1000resources/10000wrappers; do not introduce partial/silent publication.
- Fence lives independently of DB backups/restores. Whole DB+fence erasure/bypass, arbitrary malicious-server rollback, first-contact suppression and root recovery remain outside this protection.
- Start with Task1 only; do not implement outcome states there. Tasks2–8 constitute remaining PR C scope, not already completed work.
- Local tests use disposable PG databases and synthetic keys. Do not log credentials, plaintext, private keys, production environment values or real account PII.
- Source work and PR C test-staging deployment/test-only migration are explicitly authorized by the current Owner instruction. Task6 prepares/reviews the exact candidate/controller/backup, then proceeds under that standing authorization; ask only for genuinely missing external permission/credentials or an action beyond test-only scope. Task1 performs no runtime mutation; subsequent tasks retain the full approved PR C scope.

## Review Focus

1. Pre019/restored schema: typed floor denial before querying nonexistent migration tables, even with an otherwise plausible publication list — Task1.
2. Crash/torn append/replayed resolve after one Vault in a multi-Vault operation: no partial confirmed minimum, no clearing an unresolved intent — Task2.
3. COMMIT succeeded but its reply/confirmation write disappeared: recover from exact receipt/read-back, never infer abort from timeout or absence — Task3.
4. Old image or alternate start command against a restored DB: controller rejects before guarded traffic; readiness alone is insufficient — Tasks4–5.
5. Same endpoint, changed account/device or restart during acceptance: preserve newer protected history, deny revoked/old-client access and leave every ordinary Vault V1 — Task7.

## File/Interface Boundaries

- `cloud/src/migration-fence.mjs`: existing durable file and compatibility facade; retain no-follow, exclusive lock, full writes and repeated file+directory fsync.
- New `cloud/src/migration-compatibility.mjs`: schema-first DB read orchestration with injectable query; no environment/connection creation.
- New `cloud/src/migration-fence-journal.mjs`: strict versioned records and pure reducer; file I/O stays in MigrationFence.
- New `cloud/src/publication-fence-coordinator.mjs`: exact intent/transaction-outcome/read-back bridge, shared by the two stores.
- New `cloud/src/deployment-compatibility.mjs` and `cloud/scripts/check-deployment-compatibility.mjs`: independently invoked candidate/code/schema/publication gate; no implicit migration or fence creation.
- Existing `cloud/scripts/start-staging-guarded.sh`, `cloud/Dockerfile`, `cloud/src/server.mjs`, `cloud/src/config.mjs` and Compose: actual controller, startup and traffic integration.
- New `cloud/scripts/staging-publication-acceptance.mjs` plus Browser/native acceptance fixtures: bounded synthetic workflow and redacted evidence; no public migration HTTP API.
- New source record `docs/security/pr-c-staging-acceptance.md`; Continuity `ops/DEPLOYMENT.md`, `ops/MIGRATION-RECOVERY.md`, `ops/SCALING.md` change only when their actual portable facts change. Do not repurpose the historical pinned V4 deployment script.

### Task 1: Reader floor20 and schema-first compatibility (first independently finished unit)

**Files:** modify `.github/workflows/ci.yml` (explicit PG test list), `cloud/src/migration-fence.mjs`, `cloud/scripts/vault-v2-migration-staging.mjs`, `cloud/tests/vault-v2-migration-operator.test.mjs`; create `cloud/src/migration-compatibility.mjs`, `cloud/tests/migration-compatibility.test.mjs`, `cloud/tests/migration-compatibility-postgres.test.mjs`.
**Interfaces:** `MigrationFence.verifySchemaFloor(schemaVersion: number): Promise<true>` reads/validates retained records and rejects invalid/below-floor schema, enforcing a minimum schema19 even for an empty journal, without requiring publication tables. Existing `verify({schemaVersion,publications})` remains the full pointer/hash check. `verifyMigrationCompatibility({query,fence}): Promise<{compatible:true}>`, where `query(text,values?) -> Promise<{rows}>`, reads `schema_migrations`, calls `verifySchemaFloor`, then fetches current publications and rereads the complete fence through `verify` so a newly appended requirement cannot be skipped. CLI supplies `(text,values)=>pool.query(text,values)`.
- [x] Write `reader fence accepts floor20 and retains floor19`: real temporary file accepts19/20;20-record rejects schema19; exact20 publication passes; reject18/21/22, strings, null, NaN, unsafe/noninteger floors as unsupported record floors in this bounded task.
- [x] Write `schema floor denial never queries publication tables`: query spy returns schema12/18/19 with a20fence, and schema12/18 with an empty real fence; assert typed `deployment_schema_floor` and exactly one schema query, zero `vault_migration_attempts` queries (Focus1).
- [x] Write `compatible schema checks floor before publication query`: event list equals schema→floor→publications→full verify; matching19/19 and20/20 pass, mismatched pointer/hash still denies. Malformed/null/noninteger max(version) must not become a usable schema through Number coercion.
- [x] Run `node --test cloud/tests/vault-v2-migration-operator.test.mjs cloud/tests/migration-compatibility.test.mjs`; record meaningful RED (floor20 rejected/current helper absent), not a test syntax/fixture failure.
- [x] Implement only supported record floors19/20 and reusable floor validation; extract the existing CLI query into the helper. Preserve `migration_staging_only` guard, absent/corrupt/symlink rejection and all fsync replay semantics. No PENDING/CONFIRMED/ABORT change.
- [x] Add PG16 schema12/18/19/20 fixtures using temporary migration directories containing the unchanged prefix from `loadMigrations`; apply with existing `applyMigrations`. Advance only a separate fresh disposable database through12→18→19→20 using the normal migration runner; never downgrade shared state. Exercise the real guarded CLI at each stage as well as the injected helper. Assert pre019 produces typed floor error, not42P01;19 legacy and20 reader paths succeed with matching synthetic rows.
- [x] Run the two unit files plus `TEST_DATABASE_URL=<disposable local DB> node --test --test-concurrency=1 cloud/tests/migration-compatibility-postgres.test.mjs`; require no unexpected skips/failures. Run existing migration operator/store/PG regressions relevant to activation.
- [x] Review diff and commit this unit on the new PR C branch: `fix: verify reader migration schema floor before publication queries`. Mark Task1 only complete; no journal/controller/staging completion claim.

### Task 2: Versioned append-only outcome journal and atomic multi-Vault reduction

**Files:** create `cloud/src/migration-fence-journal.mjs`, `cloud/tests/migration-fence-journal.test.mjs`; modify `cloud/src/migration-fence.mjs`, `cloud/tests/vault-v2-migration-operator.test.mjs`.
**Interfaces:** `validateFenceEvent(event)`, `reduceFenceEvents(events) -> {schemaFloor,committed,pending}`. Version2 `PENDING_INTENT` record binds unique `intentID`, `operationID`, `kind:'MIGRATION'|'PUBLICATION'`, sorted complete `vaults:[{teamID,vaultID,generationID,sequence,headerHash,manifestHash}]`, and `schemaFloor`; terminal records reference exact `intentID`+canonical intent digest and carry `CONFIRMED_COMMIT` or `PROVEN_ABORT`. `MigrationFence.append(event)` performs durable append; `snapshot()` returns validated reduced state. Journal schema supports actual emitted19legacy/20reader/22whole-publication floors; unknown versions/outcomes fail closed.
- [ ] Write `pending multiVault intent blocks all guarded traffic until one exact outcome`: one append covers the whole sorted set; no per-Vault prefix confirmation (Focus2). `confirmed commit advances all minima`, `proven abort preserves prior minima`, `later pending does not erase prior committed history` must assert exact maps.
- [ ] Write `outcome replay is idempotent and contradictory replay conflicts`; reject duplicate Vaults, altered membership/order-normalized digest, rollback/same-sequence fork, invalid IDs/hashes/floors, orphan resolution and commit-after-abort.
- [ ] Write real-file tests `torn tail and short writes fail closed`, `replay repeats both fsync barriers`, `interrupted lock never resets itself`, `journal capacity exhaustion never truncates prior events`. Preserve the existing4MiB limit unless measured scope requires a reviewed bounded change.
- [ ] Define legacy compatibility explicitly: strict old records remain conservative unresolved requirements until exact original activation read-back appends a v2 resolution binding their complete old tuple; never silently relabel old intent bytes as confirmed/aborted or erase them. Legacy19 records remain exact attemptID/manifestHash requirements: do not invent a reader headerHash/sequence when no signed reader projection exists. Test byte-preserving upgrade and failed upgrade replay.
- [ ] Run `node --test cloud/tests/migration-fence-journal.test.mjs cloud/tests/vault-v2-migration-operator.test.mjs` RED, implement pure reducer then durable append adapter, rerun GREEN.
- [ ] Review state transitions/disk-failure matrix and commit `feat: retain append-only publication fence outcomes`; no controller or runtime claim yet.

### Task 3: Wire initial migration and whole publication to exact transaction outcomes

**Files:** create `cloud/src/publication-fence-coordinator.mjs`, `cloud/tests/publication-fence-coordinator.test.mjs`, `cloud/tests/publication-fence-postgres.test.mjs`; modify `cloud/src/vault-migration-store.mjs`, `cloud/src/whole-publication-store.mjs`, `cloud/scripts/vault-v2-migration-staging.mjs`, migration/whole-publication fixture configuration.
**Interfaces:** `PublicationFenceCoordinator({fence})`; `beforeCommit(intent) -> Promise<void>`, `confirmCommit({intentID,receipt,readback})`, `reconcile({intentID,readCommittedOutcome})`; internal `proveAbort({intentID,proof})` accepts only an opaque provenance-bound AbortProof minted by the trusted transaction adapter while tracking whether COMMIT was dispatched. AbortProof is not an operator JSON or public caller boolean. Read-back returns exact immutable signed manifest/header plus stored receipt; missing/timeout is unresolved, never abort proof. A positive abort in this scope requires acknowledged rollback before any COMMIT was attempted; no after-restart pointer-absence shortcut. Successful ROLLBACK after an unknown COMMIT, arbitrary operator JSON, timeout, receipt absence or older restored DB never suffices. Process-loss ambiguity remains `PENDING_INTENT` without exact committed receipt/manifest; do not claim pg_xact_status alone is restore-proof.
- [ ] Write `lost COMMIT reply retains pending then resolves exact receipt`, `failed confirm fsync retains pending and retries`, `rollback acknowledged before COMMIT appends abort`, `COMMIT dispatched then connection failure can never prove abort`, `operator JSON cannot mint abort proof`, and `post-restart absent receipt remains pending despite rollback acknowledgement` (Focus3).
- [ ] Write actualPG tests for migration and two-Vault publication: inject faults before intent, after intent, each policy/pointer/outbox/receipt stage, before/after COMMIT and terminal append; assert old-or-new atomic DB set and complete fence minima. Preserve bounded SQL40P01/40001 retry, use a distinct intent per actual transaction attempt and exact same authorized operation.
- [ ] Run coordinator tests RED. Bind migration activation and whole-publication commit immediately before durable cutover/COMMIT, retaining complete generation/manifest data; require durable intent before COMMIT. Full fence failure aborts DB mutation.
- [ ] Add an operator-only `reconcile-fence` command to existing staging CLI; read exact receipt and immutable manifest/header without mutating policy or inventing consent. Positive terminal outcomes append; unresolved stays blocking. No new public endpoint.
- [ ] Run unit+serialPG tests GREEN; replace activation fixture no-op fences in the end-to-end proof with actual temp-file fences. Keep deliberately isolated unit seams labelled.
- [ ] Review ambiguous-outcome source/control/sink trace and commit `feat: reconcile durable fence with publication transaction outcomes`.

### Task 4: Independent old-code/schema gate and actual startup wiring

**Files:** create `cloud/src/deployment-compatibility.mjs`, `cloud/scripts/check-deployment-compatibility.mjs`, `cloud/deployment-compatibility.json`, `cloud/tests/deployment-compatibility.test.mjs`; modify `cloud/src/migration-compatibility.mjs`, `cloud/src/config.mjs`, `cloud/src/server.mjs`, `cloud/scripts/start-staging-guarded.sh`, `cloud/Dockerfile`, `cloud/compose.yaml` and applicable storage overlay.
**Interfaces:** `verifyDeploymentCompatibility({query,fence,candidate}) -> Promise<{compatible:true}>`; candidate is a controller-pinned reviewed source/image identity plus static capabilities `{fenceVersion:2,maxSchemaVersion:22,readerProjectionVersion:1,wholePublicationVersion:1}` extracted from the selected image, not a free caller version claim. Reuse Task1 query ordering and Task2 snapshot; pending/unsupported capability/schema/missing Vault/lower generation/hash mismatch deny.
- [ ] Write `old image missing fence capability cannot open traffic`, `schema floor rejects before migrations or publication queries`, `missing/corrupt fence never initializes silently`, `new pending intent closes guarded traffic` (Focus4).
- [ ] Run tests RED; implement independent gate before selecting/starting an image and before current Docker entrypoint migrations, and repeat before `server.listen`. Explicit first provisioning creates an empty fence only through reviewed operator action, never on absence during startup.
- [ ] Require configured independent host fence path and strict journal support whenever migration/read/publication is enabled; shipped feature defaults remain off. The check executable can run without binding HTTP; rejected startups do not report ready or pump outbox.
- [ ] During service operation, block new guarded requests/readiness while any intent is unresolved; in-flight already-authorized reads retain the existing spec semantics. Reconcile through local operator channel, reopen only after verified terminal state; no fail-open polling window.
- [ ] Run startup process tests with injected DB/controller adapters and assert zero listen/up/migrate side effects after denial. Verify Compose mounts preserve independent fence across DB restore and pin source/image metadata.
- [ ] Review alternate start paths and commit `feat: enforce publication compatibility before guarded traffic`.

### Task 5: Controller/restore negative acceptance before any staging change

**Files:** create `cloud/tests/staging-controller-fence.test.mjs`, `cloud/scripts/verify-staging-controller.mjs`; update `docs/architecture/vault-v2-migration-publication.md` and new `docs/security/pr-c-staging-acceptance.md` with local evidence only.
**Interfaces:** `verifyControllerFixture({candidate,query,fence,runCommand,report})` exercises the actual start script/check executable, substituting command transport only; reports redacted stage/outcome and observed traffic exposure.
- [ ] Write `restored DB12 cannot reach post019 query or compose up`, `restored lower generation cannot serve`, `missing fenced Vault and same-sequence fork deny`, `old code with a modern schema denies`, `pending multiVault intent refuses startup`.
- [ ] Run tests RED; add only necessary controller adapters/guard fixes. Preserve source/image pinning, Compose storage validation and backup independence; never bypass the real checked script with a test-only controller.
- [ ] Run actual local disposable PG restore tests: capture newer external fence, restore an older DB into a different database, prove rejection before traffic and preserve external bytes. Restore both DB+fence remains explicitly outside the proof.
- [ ] Run `node --test --test-concurrency=1 cloud/tests/staging-controller-fence.test.mjs` with disposable PG; require all negative cases rejected at their expected boundary and no ordinary Vault mutation.
- [ ] Review evidence and commit `test: prove controller rejects incompatible database restores`.

### Task 6: Prepare and perform the authorized candidate test-staging rollout

**Files:** create `cloud/scripts/deploy-reviewed-staging-candidate.sh`, `cloud/scripts/staging-publication-acceptance.mjs`; update `docs/security/pr-c-staging-acceptance.md`; later update Continuity ops documents for actual changes. Do not edit/reuse the historically authorized pinned V4 script as new authority.
**Interfaces:** deployment consumes immutable reviewed `{sourceSHA,tree,imageDigest,controllerDigest}`, ordered Compose files, protected backup references and independent fence path; acceptance runner consumes dedicated synthetic account/device handles through protected input, never prints secret values.
- [ ] Add dry-run controller tests that reject changed candidate/image/script digest, unexpected runtime/schema, missing backup verification, wrong environment and non-allowlisted Vaults. Run RED→minimal implementation→GREEN before the authorized runtime operation.
- [ ] Inventory current source/image/schema/HTTPS and ordinary Vault format/pointer state read-only; record existing backup/fence retention and recovery references without credentials. Prepare and review the exact deployment/health/abort procedure and concrete evidence before execution under the current staging authorization.
- [ ] Record the current explicit Owner authorization for PR C test-staging deploy/test-only migration, verify the concrete reviewed candidate/controller/backup and proceed within it. Ask only if external permission/credentials are genuinely unavailable or the next action exceeds test-only scope; do not create another Owner/design-confirmation gate. Fresh approval remains required for any later public-main mutation.
- [ ] Create protected DB backup, verify checksum/archive and isolated restore; retain fence separately. Run guarded candidate deploy/schema upgrade/health/ready/HTTPS checks; assert every ordinary Vault remains V1/schema1/no pointer.
- [ ] Before test activation, prove candidate code/schema/controller/fence compatibility. Keep allowlist limited to disposable `TEST-ONLY-CODEX-<run-id>` Vaults; do not enable ordinary migration or production delivery.
- [ ] Record exact runtime/source/image/schema/backup/controller results, update affected ops/Continuity and commit/fetch verification. Any post-activation failure is fix-forward; no live restore/reset shortcut.

### Task 7: Real migration, Browser/Mac/second-device and negative acceptance

**Files:** extend `cloud/scripts/staging-publication-acceptance.mjs`; create `cloud/tests/browser/staging-publication-acceptance.mjs`, `Tests/SelectiveRemoteTests/StagingPublicationAcceptanceTests.swift`; reuse existing `cloud/public/vault-v2-migration.js`, `cloud/tests/whole-publication-browser-postgres.test.mjs`, native `CloudVaultPublicationAPI`, `CloudWholePublicationCoordinator` and actual app flows; fix demonstrated source defects narrowly.
**Interfaces:** run manifest records synthetic IDs, pinned candidate/device public identities, stage/result and protected evidence references. Browser uses actual WebCrypto/IndexedDB and real HTTPS; native uses isolated synthetic profile and actual API/coordinator, not mock decrypted usability labels.
- [ ] Build fixture-level RED checks for expected denial, stable identities, protected history across restart/account/device change and ordinary-Vault invariants before running the real matrix (Focus5). No public migration HTTP route; operator uploads opaque encrypted/signed client preparation.
- [ ] On approved staging, execute fresh user→Team/invite→secure second-device approval; migrate populated and empty syntheticV1 using exact source export/mapping/checkpoint and the actual fence. Verify Folder/Host/Credential/Snippet/Forwarding content and SECRET boundaries on Mac/Browser/second device.
- [ ] Exercise grant/group/revoke/move/content edit→complete publication, equivalent-path no-false-revocation notification, all-ACTIVE atomic successor, stale/racing previews, lost response, client refresh failure, reload/restart and receipt-only recovery.
- [ ] Prove old0.31/old0.32/no-capability read/write/wrapper denial, revoked-device denial/rotation, changed trust/device epoch rejection and no wrapper invention. Preserve rollback/fork/high-water and marker-erasure limitations in report.
- [ ] Repeat isolated backup/older restore/controller denial using the observed runtime's artifacts; never restore the live DB. Reassert all ordinary pre-existing Vaults remain V1/schema1/no pointer after every mutation phase.
- [ ] Record real versus fixture/manual evidence separately; mark unavailable physical-device/human workflows pending rather than synthesizing PASS. Review and commit source/test fixes plus sanitized evidence in bounded units.

### Task 8: Full regression, immutable review, Security, CI/TestDMG and Owner gate

**Files:** update PR C implementation ledger and `docs/security/pr-c-staging-acceptance.md`; changed source tests/docs only; Continuity STATE/HANDOFF/PROJECT_CONTEXT/README/ROADMAP/VERIFIED_HISTORY/LESSONS/checkpoint and affected ops evidence per UPDATE_PROTOCOL.
- [ ] Run final targeted fence/controller/PG/Browser/native matrices, PG16 fresh and12→latest migrations, direct-SQL concurrency/fault injection and isolated restore negatives with no unintended skips.
- [ ] Run full Cloud serialPG suite, full Swift regression and Release on supported Swift6 CI toolchain, actual Browser durable/restart tests, Pages/packaging guards; report existing rewrap TODO and inherited Nodemailer advisory accurately.
- [ ] Re-run required100/1000resource and10Vault/10000wrapper scale/fanout boundaries with complete prepare/encrypt/upload/commit/read-back/decrypt, client+server RSS/bytes/query plans; distinguish memory seams from native/IndexedDB/real HTTPS cost.
- [ ] Complete fresh independent whole-branch review; resolve findings with meaningful RED→GREEN and freeze exact head/tree. Obtain sealed formal Codex Security diff scan with canonical coverage/deferred accounting; prior PR223 scan is not PR C evidence.
- [ ] Push permitted feature branch/Draft PR, require exact-head CI and TestDMG; download/check digests, read-only mount and deep-strict signature. No ad-hoc artifact is official signing/notarization or actual upgrade acceptance.
- [ ] Publish/fetch/verify complete Continuity with exact source/PR/checks/runtime evidence, failures and remaining gates. Present exact head for fresh Owner Ready/merge approval; no public-main action beforehand.
- [ ] PR C can be marked implemented_verified only for flows actually demonstrated. Full0.32 RC still needs aggregatev0.31→RC Security, human Known Hosts/device-pairing/VoiceOver/transport, clean-install/official0.31 upgrade preservation and distribution prerequisites; no release/feed/tag authority is inferred.

## Execution/Self-review Handoff

- Task1 is the immediate small deliverable; Tasks2–8 remain unchecked and must not be summarized as complete when Task1 passes.
- Spec§6 maps to Tasks1–5; explicit staging scope/ordinary-Vault invariant and §117 map to Tasks6–7; every-PR proofs and retained RC boundaries map to Task8.
- Five Review Focus cases are pinned to named test steps above; journal, coordinator and verifier interface names agree across tasks.
- User/Continuity authority overrides the skill's generic plan-review pause: root self-reviews this plan and proceeds with the already-authorized Task1 after post-merge CI/Continuity, without another architecture confirmation.

## Task 1 verified implementation evidence

Meaningful pre-fix regressions reproduced floor20 rejection, empty-fence old-schema acceptance, and real guarded CLI schema12 returning a generic operator failure. The corrected unit passes25targeted tests, including unchanged migration prefixes12→18→19→20 on a separate PostgreSQL16 database and both helper/CLI. Full serial Cloud suite with actual Edge/IndexedDB:829total,828PASS,0FAIL,0SKIP,1existing password-rewrapTODO. Initial sandbox-only Edge launch failed; the complete permitted-browser rerun passed. Independent Task1 review found no actionable issues. Existing file/directory fsync replay tests pass. `.github/workflows/ci.yml` now includes the new PG integration test. This is Task1 evidence only; Tasks2–8, real staging execution and final exact-head PR C gates remain pending.
