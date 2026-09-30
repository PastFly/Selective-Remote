# Staging Vault v1→v2 migration publication

This foundation is **OFF by default**. It has no production HTTP migration route, automatic migration, V2 enablement, sharing UI or CEK delivery. Existing production Vaults stay legacy/v1. Use only disposable, allowlisted synthetic staging Vaults. Target release remains 0.32.0.

## Operator/client sequence

1. Operator config explicitly selects staging environment, synthetic enablement, Vault UUID allowlist, test database URL and an absolute external fence path. Production/default config fails before connecting or reading stdin.
2. `preview` captures source revision and a canonical public-policy/device snapshot. Client `previewLegacyMigration` inventories the decrypted schema-1 document locally. Unsupported records (`sshKey` included), duplicate/colliding IDs, invalid folders, embedded secrets or opaque encoded profiles block conversion. Credential unknown fields remain secret.
3. Client `prepareMigrationInventory` persists an AES-GCM checkpoint under its locally held legacy key **before** submitting opaque graph descriptors to `start`. Scope binds Team/Vault/attempt/source revision/encrypted-source hash/snapshot hash/policy version. Valid unique UUIDs are reused; missing IDs and folder IDs remain stable on resume. Server sees no names, paths, plaintext document fingerprint or CEKs.
4. `start` stores the desired policy, immutable read snapshot and reserved resource IDs. Default direct grants preserve legacy read/reveal access for all current members; Owner/Admin authority and Admin target ceiling use existing Team policy. Group policy uses only existing Team groups. Every entitled principal needs eligible admitted devices.
5. Client prepares independent GENERAL or Credential METADATA/SECRET CEKs, verifies root pins and signed recipient directory high-water, wraps to every exact eligible device, locally opens its own wrapper/part, and root-signs the manifest. If the preparing custodian lacks a needed part permission/self-wrapper, preparation blocks. This bounded engine does not implement third-party delegated encryption.
6. `upload` is exact-object idempotent; changed replay fails. The encrypted checkpoint may be uploaded with the first object; later uploads can omit it when the durable client checkpoint already contains the complete batch. Server progress follows persisted part rows. `validate` verifies exact graph, all hashes/contexts/recipient sets and custodian signature; READY freezes objects. Validation failure records a safe failure audit; exact-snapshot `start` resumes failed preparation. Source/policy/device changes require discard and a new attempt.
7. `activate` rechecks snapshot under fixed-order table locks; PostgreSQL deadlock/serialization victims retry the whole rolled-back transaction at most three times. Only immutable part commitments are read during activation, not ciphertext bodies. Before COMMIT the operator durably appends an exact manifest intent to the independent fence. Atomic COMMIT changes attempt state and Vault publication pointer/format/policy version, retires v1 row/revision/wrapper/invitation data and writes audit. Lost response is resolved by exact attempt/manifest replay.
8. `check-compatibility` verifies schema floor 19 and every fenced active manifest. A pending fence with no matching active DB state fails closed until exact activation retry/recovery. `discard` removes only pre-activation staging; reusable Team groups and v1 remain intact. After activation recovery is fix-forward only.

The staging CLI consumes opaque JSON on stdin, not a plaintext source file. Input fields are operation/input/object/checkpoint/manifest/manifestHash. Use `MIGRATION_ENVIRONMENT=staging`, `MIGRATION_SYNTHETIC_ENABLED=YES`, `MIGRATION_SYNTHETIC_VAULT_IDS`, `MIGRATION_STAGING_DATABASE_URL`, `MIGRATION_FENCE_PATH`. `input` binds actorUserID/actorDeviceID/teamID/vaultID/attemptID plus schemaVersion 2 and capability `resource_acl_v2`; it is a trusted local operator identity, not an unauthenticated public session API. Root signature and server membership/admission checks are still mandatory. No arbitrary request boolean enables production.

## Read and compatibility boundary

`active_vault_migration_parts` joins only the exact active attempt pointer. Internal staging read requires current active membership, explicit admission, current signed device trust and an exact part grant; it returns only that device's wrapper. Changed memberships/groups/edges or wrapper recipient readiness fail closed until a future fix-forward publication supports them. There is no production reader or writer for this generation in this PR. Principal policy does not prove device crypto usability.

Current legacy read/write/key-device/wrapper calls return `vault_upgrade_required` for authorized migrated-Vault requests; outsiders retain non-enumeration. Version strings (0.31/old 0.32) never enable access. Old server SQL omitting format predicates sees NULL whole-Vault ciphertext and no old wrappers/revisions. DB guards forbid pointer/format downgrade or reintroducing v1 payloads.

A complete old DB restore erases DB-local guards; only the external fence detects it. The fence must be outside the DB backup/restore boundary, with durable file+directory fsync, no symlink file, exclusive append lock and corruption rejection. A crashed append lock requires explicit operator recovery; do not remove it or reset a fence automatically. The real deployment controller must check code/schema floor and fenced DB publication state **before** serving traffic. The CLI check alone cannot stop someone bypassing it, a malicious server or restoration of both DB and fence.

## Remaining production gates

- Real root recovery and independently pinned first-device/recovery trust.
- Deployment-controller compatibility fence integration, persistence, restore and ambiguous-COMMIT recovery acceptance.
- Exact converter acceptance with real export fixtures, unsupported sshKey conversion, and any opaque profile/embedded-secret blockers.
- Stable lifecycle linkage to production registry/policy/crypto APIs and future mutation/fix-forward publication; existing dormant legacy generation APIs cannot mutate this new generation.
- Active-member/device change handling, third-party custodian preparation and revocation/key rotation after activation.
- Mac/Cloud production UI integration, manual device pairing/Known Hosts acceptance and staging end-to-end acceptance.

Tombstones, source vector clocks and original document are preserved inside the encrypted client checkpoint; production adapters must define their active sync/materialization semantics and legacy-key recovery before real cutover. No server plaintext validation claim is made: opaque conversion correctness relies on the tested client converter and authorized root-signing custodian.

## Measured synthetic proof

PostgreSQL 16.15; three existing Team groups, three admitted signed devices:

| Resources | Wrappers | Prepare | Upload + validation | Activation | Activation queries | Ciphertext/wrappers bytes | Commitment EXPLAIN |
|---:|---:|---:|---:|---:|---:|---:|---|
| 100 | 300 | 681 ms | 1080 ms | 15.2 ms | 33 | 289401 | Index Scan, 0.041 ms |
| 1000 | 3000 | 56494 ms | 7010 ms | 23.2 ms | 33 | 2894001 | Index Scan, 0.344 ms |

Client checkpoint resealing dominates the 1000-resource preparation time and is quadratic in total prepared checkpoint bytes; optimize its storage format before larger production batches while preserving fresh-CEK/crash invariants. Activation query count is fixed and does not fetch ciphertext JSON; graph/recipient/snapshot validation still scales with resource, grant and device counts. Numbers describe this local synthetic run, not a production latency guarantee.

Audit records only committed started/prepared/failed/activated/discarded transitions, opaque IDs/counts/hashes and safe blockers. Preview has no audit/notification side effect. CI repeats fresh migrations, concurrency/failure matrix and both scale sizes on PostgreSQL 16.
