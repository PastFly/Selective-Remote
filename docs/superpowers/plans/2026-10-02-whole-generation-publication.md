# Whole-generation publication implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare and atomically publish complete successor generations for every ACTIVE Vault in a Team, with exact signed consent, surviving-custodian repair reads and durable retry receipts.

**Architecture:** Keep PR A's ordinary recipient transport and complete Team snapshot guard. Add a distinct stage-gated publication coordinator whose read-only preview binds the predecessor read-set and deterministic successor; immutable preparation and one transaction install the successor policies, pointers, audit, outbox and receipt together. Both clients use verified local custody and fresh per-part cryptography, never the retired legacy Vault key.

**Tech stack:** Existing Node/WebCrypto, PostgreSQL 16, Swift/CryptoKit/Keychain and browser IndexedDB/nonextractable wrapping-key infrastructure; no new dependency or paid service.

**Spec:** `docs/superpowers/specs/2026-10-01-full-scope-publication-materialization-design.md`, approved blob `a8859022545c420c80ef75091b3ec3ff054e19af`.

**Baseline:** public main `7ff61198b5d7a836000f0af101f996250db8c76a`, tree `d0a905c6c68bbd676bd06591ff873cb9ffed3092`, approved PR A #222 squash merge. Reuse its proven unchanged baseline; do not repeat its entire test gate before writing PR B tests.

## Global constraints

- `V2_ACTIVATED=NO`; `REAL_VAULT_MIGRATION=NO`; `PRODUCTION_CEK_DELIVERY=NO`; `PRODUCTION_CLOUD_DEPLOYED=NO` for real runtime; disposable isolated fixtures may exercise ACTIVE transitions.
- No public-main mutation without fresh exact-head Owner approval. No feed/tag/release/official signing/notarization; public download remains 0.31.
- All ACTIVE Vaults in a Team participate, including logically unchanged Vaults. V1 content remains V1. Existing PREPARING APIs do not gain authority over ACTIVE Vaults.
- At most 10 ACTIVE Vaults, 1000 live resources including Folders, 10,000 complete wrappers, 64 MiB encrypted checkpoint and 128 MiB aggregate prepared ciphertext/sidecar. At most 100 descriptors/page and 1 MiB encoded part/descriptor upload. Check actual encoded bytes, boundary and boundary+1. No silent batching.
- Fresh CEKs/nonces for every part in each generation. Permanent Team/Vault identities and tombstones; exact kind/path preservation; `Credential.Edit` without `Reveal` invalid. Only View inherits through live Folder levels.
- One existing Team Owner/Admin hierarchy. ManageAccess/role never manufactures plaintext keys or sidecar custody. Principal policy and device crypto usability remain separate.
- READY/ACTIVE bytes, graph, policy, scope, recipient inventories and commitments are immutable. Restart/secret rotation invalidates previews; never unsigned/fallback commit or automatic expanded re-preview.
- Lock Team, sorted Vaults, operation/attempts, reservations, then policy/group/member/device/trust tables; retain direct-SQL-conflicting locks and bounded identical-operation deadlock/serialization retry.
- Precondition read-set and authenticated successor snapshot are different values. Recompute both under locks; unexpected post-write rows/epochs abort every policy/pointer/audit/outbox/receipt effect.
- Ordinary reads retain the complete snapshot guard and never serve an older generation after cutover. Repair requires fresh post-revocation preview and intersection of predecessor/current entitlements for the same surviving admitted device.
- Only committed effective-policy deltas notify; equivalent permissions via another path produce audit without false revocation. Crypto repair is separate.
- External append-only controller deployment fencing and real HTTPS/second-device/E2E remain PR C; PR B may not claim runtime/release acceptance or enable its own runtime gates.

## Review focus

- A consent token remains in flight while a session/key/Team epoch changes: fail closed at commit and every repair request.
- A removed edge preserves equivalent policy through another group: audit the path change, do not notify access revoked.
- A lost ciphertext cache exists on a surviving custodian but a newer device lacks predecessor wrappers: repair only the original device's still-entitled parts/sidecar; never synthesize custody.
- A same operation ID is retried after COMMIT response loss or altered bytes: return the exact original scoped receipt or typed replay conflict, never a second mutation.
- Trigger-generated successor rows or direct-SQL changes diverge from the previewed successor, including tombstones: abort all Vaults; never install a generation signed against pre-change policy.

## Shared interfaces

`request` is version 1, exact Team/operation UUIDs, a complete sorted `vaults` list of `{vaultID, resources, policy, contentChanges, custodianDeviceIDs}`, and optional one Team-scoped `groupMutation`. `contentChanges` identifies `{resourceID, part}` only: no plaintext or plaintext fingerprint is sent to the server. Custodians are explicit admitted predecessor custody selections, not implicit Owner/Admin devices; count their sidecar wrappers in the complete budget. A full new generation encrypts every part regardless of that intention list. The store verifies the request against permanent identities and authenticated predecessors; clients cannot invent the participating list.

`current` lists `{vaultID, generationID, sequence, headerHash, resources, policy}` for every ACTIVE Vault. `snapshots` contains the exact current and projected successor snapshots per Vault, with the same membership/device/trust/policy records used by PR A. Fixed operation timestamps and deterministic group/revision changes make the projected state checkable without writes during preview. Any discrepancy with real trigger results conflicts at commit; do not omit a security-bearing snapshot field to make it match.

`WholePublicationPlan` carries canonical request/read-set/successor hashes, predecessor tuple per Vault, desired policy hashes, effective principal deltas, exact per-device recipients, part/wrapper totals, blockers and operation binding. Custodian-local key availability is a separate verified client input, not a server assertion that role or wrapper presence proves decryption.

### Task 1: Pure whole-Team constraints and exact consent tokens

**Files:** Create `cloud/src/whole-publication-policy.mjs`, `cloud/tests/whole-publication-policy.test.mjs`.

**Interfaces:** Produce `validateWholePublicationRequest(request, current)`, `deriveWholePublicationPlan({request,current,snapshots,actorRole})`, `WholePublicationPreviewTokens({secret,clock,ttlMS}).issue(binding)` and `.open(token,binding)`; subsequent tasks provide authenticated snapshots and immutable requests, not user-selected authority.

- [x] Write tests for complete ACTIVE set, foreign/duplicate IDs, invalid Credential masks, broken Folder graph, exact content-part intents, 10/11 Vaults, 1000/1001 resources and 10000/10001 wrappers.
- [x] Run `node --test cloud/tests/whole-publication-policy.test.mjs`; expect RED for missing implementation.
- [x] Validate exact request shape and scope; use existing `validateMigrationResources`, `migrationRecipients` and Team role ceiling; sort canonical consent deterministically without normalizing identity bytes. Typed limits return safe counts without payloads.
- [x] Test token binding to session/account/device/key epoch, operation/request/read-set/predecessors/successor/counts/expiry; tamper, expiry, rotation, restart, unsigned token and changed selection all fail. Sign domain-separated canonical bytes with existing Node HMAC, minimum 32-byte server secret, 5-minute maximum lifetime.
- [x] Run the task tests and relevant `vault-v2-migration-policy` / `team-policy` tests; expect zero failures. Commit `feat: bind whole-Team publication intent and limits`.

### Task 2: Immutable operation/generation, policy-version, receipt and outbox storage

**Files:** Create `cloud/migrations/021_whole_generation_publication.sql`, `cloud/tests/whole-publication-schema-postgres.test.mjs`; modify applicable latest-version assertions in `cloud/tests/migrations.test.mjs` and `vault-publication-store.test.mjs` without weakening old invariants.

**Interfaces:** Produce scoped immutable operation/generation links, generation-linked policy versions, append-only committed receipt and effective-delta outbox rows. Reuse permanent identity reservations and generation associations from schema 20.

- [x] Write PG tests for fresh/12→latest migration, no changes to any real/default V1 row, operation/account/device/Team scope, competing publishers, READY freeze, retained prior ACTIVE bytes, immutable receipts and direct-SQL cross-scope/partial-commit rejection.
- [x] Observe RED, then add scoped FKs, uniqueness and trigger constraints. Allow successor associations without deleting or reusing a tombstone and without mutating predecessor attempts. Bind every generation to one exact operation and predecessor.
- [x] Test existing independent writers and both identity insertion orders; run with disposable `TEST_DATABASE_URL` on PG16, zero skips. Commit `feat: retain immutable publication operations and receipts`.

### Task 3: Authenticated read-only preview and predecessor repair

**Files:** Create `cloud/src/whole-publication-store.mjs`, `cloud/src/whole-publication-snapshot.mjs`, `cloud/tests/whole-publication-preview-postgres.test.mjs`, `cloud/tests/whole-publication-repair-postgres.test.mjs`.

**Interfaces:** `WholePublicationStore(pool,config).preview(input,request)`, `.repairDirectory(input,token,page)`, `.repairPart(input,token,{vaultID,resourceID,part})`. Snapshot module produces exact ordered current/successor read-sets; Task 1 signs them. Input actor/session/device comes from authenticated service, not body fields.

- [ ] RED: preview is read-only, exhaustible 100-descriptor pages match signed totals, all ACTIVE Vaults are required, live READY attempt returns `publication_ready_attempt_exists`, Owner/Admin ceiling and actor admission/root apply.
- [ ] Implement current loading and deterministic successor projection with existing evaluator; validate group lifecycle independently of Vaults. Group delete >1000 grants returns `group_grants_must_be_revoked_first` with safe remaining count and bounded prior revoke workflow.
- [ ] RED→GREEN repair after actual membership/trust revoke: intersect predecessor and current entitlement; same surviving device wrapper only; SECRET/sidecar custody enforced; new device, expired/stale token or second revoke denies. Ordinary reader remains unchanged and returns repair-required on stale full snapshot.
- [ ] Test role matrix Owner/Admin/Editor/Viewer, every scope/session/key mix and SQL phantom changes. Commit `feat: preview coherent successor publication and scoped repair`.

### Task 4: Complete immutable preparation/start/upload/READY

**Files:** Extend `whole-publication-store.mjs`; create `cloud/tests/whole-publication-preparation-postgres.test.mjs`; modify `cloud/public/vault-publication-v1.js` and shared vector tests to accept only explicitly expected successor sequence/predecessor, keeping migration default sequence1/previousHash null.

**Interfaces:** `.start(input,token,request)`, `.putPart(input,operationID,vaultID,object)`, `.putProjection(input,operationID,vaultID,projection,sidecar,checkpoint)`, `.validate(input,operationID,manifests)` return immutable generation IDs/scope and READY commitments. Shared projection validator receives explicit expected sequence/previousHash; no unconstrained sequence acceptance.

- [ ] RED: reused cross-generation bytes/context, missing/extra/wrong-epoch wrapper, incomplete parts/sidecar/recipient inventory, identity resurrection, >1MiB request or aggregate limits, changed replay and incomplete multi-Vault preparation cannot reach READY.
- [ ] Implement complete generation associations and exact commitments using existing cipher/manifest/projection validators; clients fresh-encrypt every part. Recheck live verified recipient/custody sets and durable checkpoint encoded budget. No current pointer changes during preparation.
- [ ] Test restart and identical immutable uploads, two competing preparations and SQL writes against READY. Commit `feat: freeze complete successor publication generations`.

### Task 5: Atomic all-Vault commit, effective outbox/audit and receipt replay

**Files:** Extend store/snapshot modules; create `cloud/tests/whole-publication-commit-postgres.test.mjs`, `cloud/tests/whole-publication-concurrency-postgres.test.mjs`.

**Interfaces:** `.commit(input,operationID,token,request)`, `.receipt(input,operationID)` produce account/device/Team-scoped immutable `{operationID,requestHash,vaults:[{vaultID,generationID,sequence,headerHash}],committedAt}`. A replay with a different body fails, even after success.

- [ ] RED: two-Vault old-or-new visibility, all persistence-boundary failures roll back policy/pointers/audit/outbox/receipt, changed full read-set denies, signed old snapshot never ACTIVE after mutation, session expiry rechecked after lock wait.
- [ ] Acquire deterministic locks including direct-SQL-conflicting tables; validate precondition/preview expiry/READY, install exact projected Team/group/policy versions, recompute successor and require exact hash before all pointer swaps. Keep old objects private. Bound deadlock/serialization retries to the same operation, never auto-re-preview.
- [ ] RED→GREEN lost response returns original receipt; cross-account/device/Team read denied; equivalent remaining access suppresses false notification; real effective changes create committed outbox with idempotent delivery. Refresh failure cannot roll back a committed result.
- [ ] Run direct SQL group/member/device/grant/tombstone/pointer races and fault injection; commit `feat: atomically commit whole-Team publication with receipts`.

### Task 6: Browser and Mac verified custody, fresh encryption and durable resume

**Files:** Create `cloud/public/whole-publication-client.js`, `cloud/tests/whole-publication-client.test.mjs`, `Sources/SelectiveRemote/CloudWholePublicationCoordinator.swift`, `Tests/SelectiveRemoteTests/CloudWholePublicationCoordinatorTests.swift`; extend existing publication APIs/models/store and Access Manager entrypoints narrowly.

**Interfaces:** Client coordinator prepares frozen complete plans only after full preview/custody verification, uploads persisted exact bytes, commits with a fresh matching token and validates/read-backs the scoped receipt. Existing reader supplies verified linked plaintext/sidecar; keys remain local.

- [ ] RED for missing plaintext/sidecar key despite Admin role, metadata-only Credential, checkpoint persist failure, logout/endpoint/account/device changes, stale generation during await, fresh nonce/CEK every part, round-trip mismatch and changed resume input.
- [ ] Implement fresh operation checkpoint key in Mac's secure device envelope/browser nonextractable local protection; bind account/endpoint/Team/operation/generations. Persist bytes before upload, reuse only persisted immutable bytes, require fresh keys/attempt after checkpoint loss. Never borrow predecessor CEK or legacy whole-Vault key for checkpoint encryption.
- [ ] Recheck request/session/generation ownership at persistence/display/commit; verify complete preview and receipts. Lost success keeps receipt and disables writes until exact read-back. Add real browser IDB/WebCrypto restart/race tests and Swift secure-store failure tests.
- [ ] Run targeted browser/Swift tests, commit `feat: prepare and resume verified whole publication on clients`.

### Task 7: Distinct authenticated stage-gated transport and active editing entrypoints

**Files:** Modify `cloud/src/service.mjs`, `server.mjs`, `postgres-store.mjs`, `config.mjs`, authenticated Access Manager/browser entrypoints and native typed API; create `cloud/tests/whole-publication-http.test.mjs` and appropriate native API tests.

**Interfaces:** `/v1/teams/:teamID/publication/{preview,start,upload,validate,commit,receipt,repair}` uses only the new coordinator. Config is disabled by default, explicit staging/allowlist/capability required. Existing PREPARING/recipient routes retain their contracts.

- [ ] RED: unauthenticated, forged actor body, production/default config, V1, old client, off-allowlist and oversized requests fail closed. Contextual edit/move/share uses exact materialized resource identity and publication flow, never V1/registry fallback.
- [ ] Implement typed safe errors and causal session ownership, custodian blocker and read-only retry state. Use real component/HTTP tests; no new UI architecture or feature breadth.
- [ ] Run transport/API/entrypoint tests; commit `feat: expose bounded authenticated successor publication workflow`.

### Task 8: Full candidate proof and fresh Owner gate

**Files:** Add actual 100/1000 resources, up to10 Vaults/10000 wrappers benchmark/matrix harness in `cloud/scripts/`; update bounded operation cost/security docs and Continuity.

- [ ] Run PG16 fresh/12→latest and direct-SQL matrix; real multi-Vault atomic/failure/retry tests; EXPLAIN and boundary/boundary+1 tests. Measure full client encrypt/decrypt, bytes, memory and query cost honestly; no production-capacity claim from mocks.
- [ ] Run full serial Cloud tests with within-test concurrency, actual Chromium, full Swift regression and Release. Preserve preexisting TODO/default-parallel fixture caveat; do not count skipped PG tests as proof.
- [ ] Produce immutable whole-branch review packet from baseline7ff6119 and obtain one fresh most-capable review; bounded RED→GREEN fixes and full verification as required by executing-plans.
- [ ] Push non-main candidate, create/attach Draft PR, run formal exact-head Codex Security scan, CI and Test DMG. Verify artifact hashes/read-only bundle; no official signing/notarization.
- [ ] Publish Continuity exact head/tree and all evidence; stop at fresh exact-head Owner merge gate. PR C runtime/controller/staging acceptance remains pending; no real activation/deploy/RC-ready claim.
