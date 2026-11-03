# Browser Mixed-Version Storage Cutover Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans and preserve the existing Draft PR and user data. This is release-blocker work, not authorization to deploy.

**Goal:** Prevent an older open browser tab from overwriting a newer tab's encrypted Personal or Team snapshot, while retaining all old copies for a verified recovery.

**Architecture:** Keep device and trust material in its existing store, but use separately named records for new snapshot generations. In one IndexedDB transaction, compare both the expected new snapshot and the captured older record state before committing. A changed or ambiguous old record stops synchronization; neither side is silently deleted. Legacy Personal ownership cannot be established by a shared password, a server copy, or an old remembered key, so unknown ownership remains quarantined pending independent evidence and a supported recovery flow. Server-side compatibility enforcement must be evaluated separately because storage separation alone cannot stop an old tab from sending authenticated V1 writes.

**Tech Stack:** Browser IndexedDB, WebCrypto, JavaScript, Node test runner, fake-indexeddb, PostgreSQL 16.

**Spec:** Existing approved [V2 migration/publication design](../specs/2026-09-30-vault-v2-migration-publication-design.md), the prior V1 compatibility requirement, and the preserved owner requirement not to mutate ordinary Vaults without a safe migration.

## Boundaries

- Do not migrate, delete or overwrite existing user snapshots merely because their account password or remote ciphertext matches.
- A regression test against a legacy client is local evidence; it is not a real two-user staging E2E.
- Keep old and new ciphertext if a legacy write appears after cutover; fail closed rather than auto-selecting a winner.
- A safe owner-verified recovery for pre-existing unbound Personal snapshots, old-client server fencing, interrupted native Team commits and real Mac/browser/V2 acceptance remain separate release gates.

## Task 1: Personal snapshot isolation

**Files:** `cloud/public/vault-local.js`, `cloud/public/app.js`, `cloud/tests/public-vault-local.test.mjs`, related browser regression tests.

- [ ] Reproduce an actual old-repository `put` after a new same-account edit on a shared synthetic IndexedDB, and confirm it overwrites the new snapshot before changing the implementation.
- [ ] Choose a new versioned account snapshot namespace; retain old account-scoped and unscoped ciphertext. In a single IndexedDB transaction, block ambiguous old state and check for an old write alongside each new write.
- [ ] Test old/new writers in both orders, identical passwords, a contaminated remote, a failed write, account switches, retained ciphertext and delayed acknowledgement. Keep unsupported legacy recovery explicitly blocked.
- [ ] Run focused browser regression tests and independent review; record limitations and only then commit the task.

## Task 2: Team snapshot isolation

**Files:** `cloud/public/team-vault-sync.js`, `cloud/tests/public-team-vault-sync.test.mjs`, associated UI regressions.

- [ ] Reproduce a legacy writer racing the current device-scoped Team snapshot, including unsynced changes.
- [ ] Write new per-device snapshots to a separate namespace. Atomically compare old unscoped and old per-device records, retain both, and use a tombstone to prevent resurrection on remove.
- [ ] Test old/new writes in either order, interrupted migration, a foreign device, tombstones, same-device concurrent edits, remote conflicts and both retained copies.
- [ ] Run Team tests and independent review, record limitations, then commit.

## Task 3: Browser capability fence

**Files:** `cloud/src/server.mjs`, `cloud/src/postgres-store.mjs`, browser client request adapters and PostgreSQL HTTP tests.

- [ ] Trace authenticated session device platform and all browser bearer/cookie paths; add a test showing an old web client can write after the new deployment.
- [ ] Require the new storage capability for authenticated web sessions on both bearer and cookie paths; derive the device type from server state, never the request's claimed user agent. Preserve supported native V1 behavior and initial sign-in.
- [ ] Test missing, wrong and current capability for both browser authentication mechanisms, plus Mac V1, logout, sign-in, reload, session switching and failed authentication. Do not apply to production.

## Task 4: Acceptance

- [ ] Repeat independent security review, targeted browser and PostgreSQL tests, full Cloud and Swift suites, Release build, exact-head CI/Test DMG, and real isolated staging acceptance.
- [ ] Record every failure and distinguish stale-head results. Finish only when independently verified recovery exists for existing Personal snapshots and the requested actual E2E has passed, or preserve the exact remaining blocker.

## Review focus

- Old IDB writes between reads and commit; failure or interruption during migration; old code rewriting legacy state after a new snapshot exists.
- A→B account switches with the same password; unverified or contaminated source snapshots; missing or malformed markers.
- Device keys and trust roots remain unchanged and are never copied into logs or user-visible diagnostics.
- Old web bearer versus native bearer compatibility; browser reload and cookie identity after a session switch.
- Revocation, server-revision conflicts, partial acknowledgement, unsynced data and downgrade behavior remain fail-closed and recoverable.
