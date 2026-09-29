# Access & Sharing: v1 to ACL-capable v2 migration design

Status: design only, 2026-09-29. No database migration, crypto format, production endpoint or existing Vault is changed. This is a proposed protocol to be reviewed before implementation.

## Compatibility boundary

Current v1 Team Vault distributes one key for a whole encrypted Vault document. A 0.32 client that has this key cannot be made to forget existing records. A restricted v2 Vault must therefore have a distinct server-side format/capability gate, independently encrypted per-resource envelopes and v2-only wrappers. It must never place restricted v2 resources in the v1 ciphertext, reuse its key, or expose them through its whole-Vault endpoint. Legacy v1 Vaults may remain accessible under their existing coarse membership policy; they must be labeled **not granular**.

`MINIMUM_CLIENT_VERSION_FOR_ACL` is a **capability**, `resource_acl_v2`, carried in an authenticated client/device admission record. Target release may be 0.33 or later after implementation; version string alone is insufficient. A 0.32 client cannot negotiate this capability and fails closed for restricted v2 catalog/envelopes/wraps/writes. Downgrade attempts cannot make a v2 Vault serve v1 ciphertext or wrappers. A user with an old offline copy of v1 plaintext retains that historical copy; the product must not promise retroactive secrecy.

## Proposed state machine

```text
V1_ACTIVE
  -> V2_PREPARING       (Owner/Admin starts; v1 source stays authoritative)
  -> V2_STAGED          (ACL-aware eligible client enumerates, maps IDs,
                        encrypts independent envelopes, builds wraps and manifest)
  -> V2_VALIDATING      (server checks manifest/identity/count/version; eligible
                        clients verify decrypt and policy/wrap coverage)
  -> V2_COMMITTING      (freeze v1 writes; compare source revision + membership
                        epoch + policy; atomic pointer/capability cutover)
  -> V2_ACTIVE          (only v2 API; v1 source archived and access blocked)

Any pre-commit state -> V1_ACTIVE after abort and staged-object cleanup.
V2_COMMITTING interruption -> recover transaction state, never expose mixed modes.
V2_ACTIVE -> V1 rollback is forbidden for restricted content; restore only
             to a new v2 generation from a validated v2 snapshot.
```

V1 source revision, Team membership epochs, eligible devices, record count, resource ID/type map, Folder ancestry, per-resource ciphertext hash, key generation, policy version and stage lease are fixed in the migration manifest. Client content is authenticated with `(teamID, vaultID, resourceType, resourceID, parentFolderID, contentVersion, keyVersion)` as associated data. The server registers immutable type/scope bindings and rejects ID collision/reuse. A client-side encrypted legacy ID map preserves continuity for recovery, while copied/imported cross-boundary records get new IDs/CEKs and no implicit direct grants. Folder path strings become UUID-backed parent edges; ambiguous or conflicting paths require user resolution before commit.

## Cases and required behavior

| Case | Required response |
| --- | --- |
| Full success | Validate every resource/wrap and expected source revision, cut over once, block legacy v1 API for that Vault, audit migration generation and verify sample decrypt on admitted v2 clients. |
| Interrupted upload/stage | Resume idempotently using stage ID and ciphertext hashes before lease expiry; otherwise clean staged objects. V1 remains authoritative and no v2 policy is visible. |
| Partial mapping, missing key, Folder ambiguity, broken wrapper | Do not cut over. Report exact recoverable blocker to authorized Owner/Admin, without secret contents; retain v1 service until a valid full stage exists. |
| Cutover transaction interruption | Read durable committed state; serve either v1 or v2 generation, never an unversioned mixture. Retry compare-and-swap with same idempotency key. |
| Rollback after v2 active | Never return restricted v2 resources to 0.32/v1 whole-Vault API. Restore into a new v2 generation with policy/key revalidation. |
| Member revoked during migration | Invalidate manifest and staged wraps tied to old epoch; restart at a new membership snapshot. Revoked member receives no newly staged wrappers; old v1 plaintext already held remains unrecoverable. |
| New member added during migration | Invalidate or explicitly rebase staged recipient set and wraps before commit. No automatic whole-Vault plaintext access. |
| Old client online at cutover | Stop v1 sync for this Vault, return capability-required status with no restricted ciphertext/wraps. Other legacy Vaults continue under their coarse policy. |
| Old offline client returns | Reject v1 upload/download for cut-over Vault and show upgrade requirement; never merge its stale whole-Vault write into v2. Local old copies cannot be remotely erased with a security guarantee. |
| Conflicts/imports | Resolve against a stable source revision before cutover; after cutover, import to new v2 identity/envelope under a previewed destination policy. Do not import grants or wrapper bytes. |

During staging, ordinary v1 writers may continue, but every source revision change invalidates validation and requires delta re-encryption. The final write freeze is short and explicit. If the source is too large to freeze safely, implement a journaled dual-write **only for ACL-aware migration clients** with proveable consistency before cutover; never accept legacy v1 writes into v2. There is no live dual-format sharing after cutover.

## Resource/key migration and revocation

For each record, the trusted eligible client decrypts v1, assigns/validates stable ID and Folder UUID, creates a fresh independent CEK and authenticated envelope, then generates wraps for explicitly authorized principals/devices or flat-group keys. It zeroes transient buffers where practical, but makes no claim that OS memory or old clients can be purged. A v2 Vault is a catalog container; it has no content key granting all resources. New grants require policy and usable wraps to become effective together.

On revoke, the server denies future reads/wraps immediately and advances policy/epoch as applicable. The affected resource enters `ROTATION_PENDING`; an eligible custodian decrypts the latest ciphertext, creates a new CEK/ciphertext/version and wraps only current recipients. Protected writes and new grant fulfillment fail closed while inconsistent. A previously authorized user may have retained old ciphertext, CEK, plaintext or session; rotation protects **future versions**, not copies already made. Removing a flat-group member rotates every CEK that member could have learned through that group, even if a new group key is issued. A bounded, audited queue and recovery custodian are required before enabling broad groups.

The migration and rekey design requires threat tests for stale epochs, replayed grants, partial ciphertext/wrap publication, old-client downgrade, ID collision, cross-Team/Vault scope and offline resumes before production rollout. See [threat model](access-sharing-threat-model.md).
