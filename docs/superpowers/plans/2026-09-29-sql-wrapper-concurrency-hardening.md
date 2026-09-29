# Dormant resource SQL concurrency hardening

## Scope and invariants

Harden the existing, internal V2 preparation tables and store methods. Keep all Vaults V1 by default, with no production mutation route, device trust activation, CEK delivery, grants, groups, or ACL enforcement. Migration 017 is additive; never edit applied migrations 013–016.

* An active child always has an active parent folder in the same Vault, and moves cannot form a cycle. Identity UUIDs remain globally unique, including tombstones.
* A manifest pointer references a PUBLISHED ciphertext version with at least one active wrapper. The pointer, wrappers and ciphertext commit atomically in the internal store.
* A published version cannot lose its last active wrapper, even through direct SQL or concurrent operations.
* A stale resource/manifest version fails rather than publishing. A concurrent device admission or revocation cannot silently pass a stale wrapper set as complete.
* Direct SQL may fail with a deadlock/serialization error when it takes row locks in reverse order; it must not commit an invalid state. Internal store takes Vault before resource before pointer before wrappers, and handles retries only when safe.

## Execution

1. Add PostgreSQL 16 integration tests for direct SQL races, stale pointer/registry, last wrapper, tombstone reuse, device admission and interruption. Ensure CI executes them. Add small store behavior tests for statement ordering and retry/idempotency contract. Observe failing tests first.
2. Add migration 017 guards and constraints using Vault row serialization for all resource mutation paths. Revalidate after lock acquisition under READ COMMITTED. Guard direct DELETE paths and ensure cascade behavior is explicit. Require PUBLISHED ciphertext at pointer advancement.
3. Update internal store transaction order and version preconditions. Add bounded deadlock handling or fail-closed policy with documented retry contract; keep commits atomic.
4. Run local Cloud tests, Swift tests, Release build, Pages tests; rely on PostgreSQL 16 CI for integration due no local PostgreSQL service. Fix failures and check scope stays dormant.
5. Commit/push branch, open PR, run formal exact-head Codex Security diff scan, CI and Test DMG. Record verified evidence in Continuity and return exact head for Owner gate. Do not merge public main.
