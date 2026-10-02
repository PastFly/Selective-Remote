# Whole-generation publication (PR B)

This implements the Owner-approved full-scope publication/materialization spec, sections 4–5. It prepares a new complete immutable generation for **every ACTIVE Vault in the Team**, then commits policy, all pointers, audit, effective-delta outbox and receipt together. Preparing/uploading never changes current pointers. It does not migrate a legacy Vault, deploy Cloud, activate production V2, or enable production CEK delivery. PR C remains the runtime/controller and actual staging acceptance gate.

## Activation boundary

`WHOLE_PUBLICATION_ENABLED` defaults to false. Enablement requires an already enabled publication reader, `PUBLICATION_ENVIRONMENT=staging`, an explicit allowlist containing **all** participating ACTIVE Vaults, and a distinct `WHOLE_PUBLICATION_PREVIEW_SECRET` of at least 32 bytes. Existing PREPARING and ordinary recipient routes retain their own gates. No environment/runtime file is changed by this implementation.

All routes require a real authenticated account/device/session plus `X-Vault-Schema-Version: 2`, `X-Vault-Capability: resource_acl_v2`, and `X-Publication-Version: 1`. Bodies cannot select another actor. Mutations require existing Team Owner/Admin authority, current admitted root custody, and authenticated predecessor custody. Admin target ceilings come from the existing Team policy. Policy permission and possession of an actual decryption key remain distinct.

## Operation and consent

The request binds Team/operation IDs, the complete Vault/resource graph, exact policy, explicit content-part intentions and predecessor custodian devices, plus at most one Team group mutation. Plaintext never enters the request, preview, audit, outbox or registry. Clients canonicalize list order locally before hashing; a server response cannot broaden their intended request.

Signed preview binds the authenticated session/device/key, canonical request, complete current and successor read-sets, predecessors, recipients, custody and resource/part/wrapper totals. Pages contain at most 100 rows and bind the same token and complete row hash/count. Rotation or process restart invalidates outstanding tokens; clients must explicitly re-preview. There is no unsigned/fallback commit. The token lifetime is at most five minutes.

Start durably freezes the operation, fixed effective timestamp and deterministic generation IDs. Exact persisted bytes are replayable; changed request/bytes conflict. A fresh token can consent to the **same** immutable operation after expiry or authenticated session renewal, only if the frozen request/read-set/successor still match. A stale operation must be explicitly discarded; it cannot silently become a new intent. Discard is idempotent and retains immutable artifacts, permanent reservations and tombstones. A committed operation cannot be discarded. If START has not yet arrived, confirmed discard records a scoped immutable cancellation; a physical shared unique operation key rejects any delayed START even under an older repeatable-read snapshot. Additive schema22 introduces this arbitration without rewriting schema21 checksums.

## Custody, repair and preparation

The custodian authenticates the complete predecessor header/manifest, own signed inventory/proofs and raw policy commitment before materializing every required part, including Credential SECRET and the administrative sidecar. Repair intersects old and current entitlement and returns only the same surviving device's wrapper. Missing keys, newly admitted devices without old custody, expired consent or changed read-sets fail closed. Ordinary reads continue to require the complete coherent current snapshot; they never fall back to repair or historical objects.

The administrative sidecar envelope hash and custody wrapper Merkle root are signed into the manifest. Older synthetic preparations without this commitment cannot use filtered sidecar repair and require a fresh authenticated preparation. No real V2 Vault existed at this change's activation boundary. A predecessor publisher's historical certificate may be authenticated only under the independently pinned identical root, without lowering or advancing a directory pin and without authorizing it as a current recipient. New wrappers always require fresh current device-directory verification.

Clients decrypt and freshly encrypt **all** resource parts and sidecars under new CEKs/nonces with the new generation context. They persist protected immutable upload bytes before uploading. The checkpoint protection key is independent of predecessor/legacy Vault keys. Browser protection uses a nonextractable local WebCrypto key; Mac uses the secure device store. Loss of protection keys requires a new attempt. Endpoint/account/device/session/generation changes stop the flow. Metadata edits preserve Credential SECRET unless that exact SECRET edit was explicitly declared.

READY requires complete resource, wrapper, recipient inventory, sidecar and signed manifest coverage with exact successor sequence/predecessor. Immutable 512 KiB projection frames are individually bounded, digest-bound and ordered at assembly; a partial upload cannot be READY. Old ACTIVE bytes remain private and retained.

## Atomic commit and recovery

Commit locks Team and sorted Vault rows, then the direct-SQL-conflicting tables. It validates live session and signed consent after waits, installs the exact projected group/policy versions and checks the actual successor snapshot before swapping all pointers. Audit, outbox and one durable scoped receipt commit in the same transaction. Deadlock/serialization retry is bounded to the same operation; it never re-previews automatically. The inherited global table locks serialize unrelated Teams as well, an explicit operating-envelope limitation.

A lost response is resolved by the immutable account/device/Team-scoped receipt and exact committed manifest/header read-back. Identical replay returns the original receipt even after consent expiry; changed replay conflicts. Receipt recovery can survive loss of mutation role, but ordinary read-back still requires current recipient entitlement. Read-back/refresh failure keeps the receipt and write fence; it cannot undo success. Only definitive authenticated precommit conflict, followed by scoped null-receipt checks and confirmed discard, may clear an uncommitted local fence. Network/cancellation/5xx uncertainty never does.

Owned COMMITTED recovery context contains only scoped receipt Vault tuples and the authenticated session plus the original operation key version. Its `recoveryOnly` marker conveys no mutation authority; resources, policy, groups and membership lists are empty. This allows receipt recovery after mutation-role or custody loss without exposing current policy. READY context retains the full current authorization gate. Missing-operation context or a null receipt alone never establishes safe cancellation.

Notifications describe only committed effective permission deltas. Removing an equivalent alternative path generates audit without a false revocation notification. The dormant `WholePublicationOutbox` adapter leases bounded committed rows and repeats the same event key on lost acknowledgement. A future sink must durably deduplicate that key before acknowledging. No automatic scheduler, public notification delivery or email is enabled by PR B.

## Independent limits and proof

One operation permits at most 10 ACTIVE Vaults, 1000 live resources including Folders, 10,000 ordinary plus sidecar wrappers, and 20,000,000 estimated policy-evaluation cells. Every bound is fail closed; there is no silent batching. The actual JSON request limit is 1 MiB, each decoded projection frame at most 512 KiB, encoded checkpoint/projection at most 64 MiB and aggregate prepared ciphertext/frames at most 128 MiB. Payload size, policy fanout and consent expiry remain independent constraints even below count limits.

Full actual 100/1000 resource measurements, 10/11 Vault and 10,000/10,001 wrapper boundaries are recorded in [local scale evidence](../security/whole-publication-scale-2026-10-02.md). The measured per-part snapshot/projection/evaluator cost is nonlinear. Local small-fixture/Node measurements do not establish production capacity, native/Browser runtime acceptance, real staging acceptance or release readiness. Final exact-head tests, formal Security, CI/Test DMG and fresh Owner merge gate are recorded in Continuity.
