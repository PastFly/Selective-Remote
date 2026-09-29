# Principal policy and device usability correction plan

**Base:** public `main` `6e8994f82fb96ed34fb510ae27d8ddb97595cc92`. **Spec:** `42f0ca3` (`SPEC_GATE=APPROVED`). **Scope:** a bounded follow-up to merged PR #217; no format activation, migration, CEK delivery, UI or production deployment.

## Contract

- `policyEffective` contains device-independent user rights, mask and all paths. Who-has, resources-by-principal and preview return policy only.
- `deviceUsability` exists only for an explicit `subjectDeviceID` on an individual Effective Access request. It binds the exact subject user, current admission/epoch and current wrapper for that device. `effectiveUsable` appears only inside it.
- `ManageAccess` is a dormant descriptive grant bit. Existing Team Owner/Admin policy alone authorizes mutations; grant presence never elevates Editor/Viewer or bypasses Admin target ceilings. It is not a device decryption action.

## Test-first steps

1. Update pure policy/evaluator tests to require separate `policyEffective` and optional `deviceUsability` envelopes; reject unqualified usability in aggregate views. Keep existing path-union and credential mask tests.
2. Add PostgreSQL 16 integration with one subject and an admitted device plus a second, unadmitted device. Publish a wrapper for every currently admitted Team device, as the existing SQL coverage invariant requires; assert `UNKNOWN` for the subject's wrapped device and `NO` for the unadmitted one, while `policyEffective` is identical. A missing or foreign device must also fail closed. Add Owner/Admin/Editor/Viewer mutation-ceiling assertions for `ManageAccess`.
3. Modify the store to evaluate policy before any wrapper read, query wrappers only for explicit exact device and keep preview/notification deltas policy-only. Modify service/HTTP query plumbing for optional `subjectDeviceID` and validate UUIDs.
4. Run targeted Cloud tests, PostgreSQL 16 migration/concurrency and scale CI, full Cloud and Swift regression, Release build, Test DMG and formal exact-head Codex Security diff scan. Record the exact PR head, tests and limitations in Continuity. Keep the PR Draft until a fresh Owner main-merge gate.
