# Vault v1 → v2 migration state machine and recovery

Status: design only, 2026-09-29. No migration code, schema or production data has changed. This narrows the earlier [migration proposal](access-sharing-migration.md) into one atomic cutover protocol. A Team can retain separate v1 and v2 Vaults; one Vault is never mixed. Old-client routing is defined in [the capability gate](access-sharing-v2-old-client-gate.md).

## Durable states

```text
V1_ACTIVE
  └─ start by Owner/Admin with source revision and Team-epoch snapshot
     → V2_PREPARING
       ├─ register staged resource/Folder IDs; encrypt payloads with fresh CEKs;
       │  stage current-recipient wraps and encrypted legacy map; validate manifest
       │  → V2_READY
       ├─ recoverable error → FAILED (v1 remains authoritative)
       └─ cancel/expired lease → ROLLBACK_PENDING → V1_ACTIVE

V2_READY
  ├─ changed source revision, membership, device directory, policy or manifest
  │  → V2_PREPARING (invalidate/rebuild affected stage)
  ├─ validation failure → FAILED (v1 remains authoritative)
  └─ compare-and-swap under Vault row lock, freeze v1 writes, audit and atomically
     switch `format=v2` + published manifest + capability gate → V2_ACTIVE

FAILED → V2_PREPARING after authorized repair, or ROLLBACK_PENDING.
V2_ACTIVE → only newer V2 generation; NEVER → V1_ACTIVE.
```

`ROLLBACK_PENDING` exists **only before activation** to clean hidden staged rows/objects and release the short write freeze if held. `FAILED` is a durable diagnostic state, never a partially visible ACL. The v1 ciphertext/revision remains authoritative until the single activation transaction commits. After activation, the old v1 object is inaccessible to API clients and retained only under controlled backup policy; it must not be re-served by app rollback or an old endpoint.

## Stage and validation manifest

An admitted unlocked custodian snapshots exact v1 Vault revision, active Team member epochs, admitted device-key identities and old record/tombstone set. It maps every live Host/Credential/Snippet/Forwarding record and every Folder path to one v2 ID under [registry rules](access-sharing-resource-registry.md), resolving collisions and ambiguous paths before `V2_READY`. Each Host/Snippet/Forwarding/Folder payload receives a fresh CEK and authenticated ciphertext; each Credential is split into independently keyed `metadata` and `secret` parts, so ViewMetadata never supplies the secret CEK. The client stages wraps **per part** for all recipients authorized by the initial explicit v2 grants. No v1 whole-Vault key or wrapper is reused. The encrypted legacy ID/path map is for migration/recovery, never an ACL alias.

The manifest records source revision/hash/counts, staging generation/lease, ID/type/parent map hash, ciphertext hashes, resource key epochs, wrap recipient/device-key identities, grant/policy snapshot and client validation results. Server validates complete coverage, uniqueness, same-Team/Vault ancestry, no active/tombstone collision, allowed version fields and structurally complete current wraps. At least one authorized custodian and one independently admitted validation device should decrypt representative payloads and check type/parent/hash; **server cannot prove decryption**. The precise validation sampling versus full proof is an unresolved security decision. Missing or malformed wraps block usable access and cutover when required for initial recipients.

## Crash, concurrency and failure cases

| Point of failure | Durable result and recovery |
| --- | --- |
| Before stage upload | `V1_ACTIVE` or `V2_PREPARING`, v1 serves normally; restart by stage ID. |
| Partial resource/Folder upload | Hidden staged objects have hashes and idempotency keys; resume missing objects or expire lease and clean. No v2 reader can list them. |
| App crash during local decrypt/re-encrypt | New custodian resumes with encrypted manifest and staged hashes; if old v1 revision changed, rebuild affected stage. Plaintext is not stored in server stage. |
| Group/member/device change or revoke during stage | Invalidate affected wrap set and snapshot; revoked epoch receives no v2 wraps. A prior v1 offline copy cannot be retracted. |
| New member during stage | Do not automatically broaden access; re-preview initial grants, stage new wraps if authorized, revalidate. |
| Old client writes while preparing | v1 revision increments; `V2_READY` CAS becomes stale, so cutover waits for restaging. |
| Old client writes at cutover | Vault row lock orders operations: old write wins first and invalidates CAS, or cutover wins first and old write is rejected by format gate. |
| Process dies during activation | Database commit is all-or-nothing. Recovery reads durable format/published-manifest pointer; no intermediate v2 visibility. |
| Validation fails or custodian unavailable | `FAILED`, continue v1 coarse service with clear diagnostic; no partial ACL. |
| Failure after `V2_ACTIVE` | Fail closed for affected v2 operation; restore from validated v2 backup/new generation. Never roll restricted content back to v1. |

The cutover transaction atomically checks source v1 revision, Team epoch/device/policy snapshot, stage lease and manifest hash; it changes format, current manifest pointer, API gate and audit in the same database commit. Staged blob storage may not be transactional, so publication is by an atomic **database pointer to already durable, hash-verified blobs**. Garbage collection occurs after success/abort with retention and recovery limits. Pre-activation cleanup may delete only objects belonging to the specific stage generation.

Migration cannot remove secrets already acquired under v1 whole-Vault access. It gives granular guarantees only for new v2 resource versions and future server delivery, subject to the [key lifecycle](access-sharing-v2-key-lifecycle.md) and a completed old-client gate. A rollout must test each crash point, stale write, backup/restore and API rollback before production activation.
