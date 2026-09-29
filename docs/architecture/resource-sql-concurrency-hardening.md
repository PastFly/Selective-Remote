# Dormant resource SQL concurrency contract

This foundation applies only to internal preparation in `V2_PREPARING`. Existing Vaults remain `V1_ACTIVE`; there is no production registry, wrapper, manifest, rotation, CEK, grant, group, or ACL mutation route.

## Transaction and lock model

PostgreSQL uses its default `READ COMMITTED` isolation. Every internal resource mutation starts a transaction, locks the `shared_vaults` row, checks the actor and locks its membership, and then locks the relevant resource and manifest pointer before changing version rows. Version expectations are checked after those locks. The SQL guards lock the same Vault row before checking parent, wrapper and pointer invariants. This serializes direct SQL on one Vault without a table-wide lock.

Direct SQL `UPDATE` or `DELETE` can acquire its target row before the trigger locks the Vault, opposite to the internal order. PostgreSQL may abort one side with `40P01` or `40001`; the committed state remains valid. Internal mutations retry at most twice after rolling back the entire transaction, then surface the SQL error. Each attempt rereads actor status and expected versions. Direct SQL callers must retry the entire operation with fresh preconditions. The optional durable idempotency key gives the same stored result for an exact replay and rejects a changed request under the same key; a future production API must require a key.

## Database enforced

* Resource UUIDs have a global primary key. Tombstones remain rows; direct hard deletion is forbidden while the Vault exists. Composite foreign keys keep parent folders and crypto records in the same Team/Vault.
* Parent creation, move and tombstone checks run after the Vault lock, so concurrently moving folders cannot commit a cycle or leave a live child under a tombstoned parent. Any registry update for a published resource is denied because it advances the registry version and would stale the bound ciphertext; a future atomic replacement design is required.
* A current manifest pointer has one row per resource part, advances key and manifest versions by one, and targets a `PUBLISHED` ciphertext whose registry version matches the active identity. It requires at least one active wrapper for an eligible admitted recipient and complete wrapper coverage for every currently admitted, non-revoked recipient. Direct pointer deletion is denied in V2 preparation; a reverted V1 Vault may retire a dormant pointer.
* Active wrappers for a current published version cannot be deleted. Obsoleting a wrapper for a currently admitted device is denied; the last published wrapper is protected even for a revoked recipient. Direct admission of a new device after any pointer exists in a V2-preparing Vault is denied. Admission and active device/membership identity changes are forbidden; the existing account-deletion cascade may anonymize an already revoked membership's user ID. Device key/algorithm changes are denied while an admitted active wrapper exists; revoked device or membership epochs cannot be reactivated. The existing device rekey transaction retires admissions before replacing the key. Future recipient changes need atomic wrapper provisioning and rotation.
* The store publishes ciphertext, wrappers, pointer and old-version obsolescence in one transaction. A rollback exposes none of the changes.

## Application enforced and future gate

The internal store validates envelope format and scope, actor permission, current admission, expected registry/manifest/key versions and request idempotency. The database does not verify ciphertext cryptographic authenticity or a future grants/policy version because no production CEK delivery or grants policy exists. Any production mutation route must require durable idempotency, design an atomic admission and wrapper provisioning flow, and retain the existing V2 activation, device trust and manual acceptance gates.

## Performance scope

Primary and composite keys cover scoped identity, pointer and version lookups. Migration 017 adds a partial active-wrapper index for coverage and last-wrapper checks. Publication checks recipients in one Team and version rows in one resource part. Mutations serialize per Vault; this trades concurrent writes within one Vault for direct-SQL safety. PostgreSQL 16 CI runs the integration matrix on small fixtures; a production-sized `EXPLAIN (ANALYZE, BUFFERS)` review remains necessary before exposing a mutation API.
