# Guided Known Hosts Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user independently verify and safely replace one changed known-host key, then retry the original SSH intent.

**Architecture:** Extend the existing known-hosts service with route-bound candidate selection and a guarded file transaction. Publish one recovery sheet through the existing AppModel/ContentView; wire existing Terminal, SFTP and Forwarding failure paths to the same coordinator without changing credential routing. Ambiguous cases stay manual.

**Tech Stack:** Swift 6, SwiftUI, macOS 14+, OpenSSH, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-28-known-hosts-recovery-design.md`

## Global Constraints

- Source baseline is `063e109694d4307343dab8ee7271b114e20a5ffd`; public `main` and 0.32 release files are immutable in this task.
- No automatic host-key trust, no prompt-text role inference, no passwords or private keys in logs or tests.
- Sync/Diagnostics and Notification Center are design-only and excluded from this PR.
- Every new behavior gets a failing test before production code.

## Review Focus

1. An external editor changes the source file after the user sees the key: reject without replacement.
2. A second scan returns a different key of the same algorithm: reject without replacement.
3. Hashed and duplicate endpoint entries: accept only one OpenSSH-proven line; otherwise manual path.
4. A managed Jump Host mismatch must never be labelled destination solely from process output.
5. A failed write or backup must leave the original file valid and prevent retry.

---

### Task 1: Candidate and endpoint matching

**Files:** `Sources/SelectiveRemote/SSHKnownHostsService.swift`, `Tests/SelectiveRemoteTests/SSHKnownHostsRecoveryTests.swift`

**Interfaces:** `SSHKnownHostRecoveryCandidate` captures role, profile ID, endpoint, source snapshot, old/new exact key and fingerprints. `SSHKnownHostsService.recoveryCandidate(...)` returns a candidate only for one unambiguous entry.

- [ ] Add tests for hostname, IPv4, IPv6, custom port, algorithm, duplicate, marker and hashed lookup.
- [ ] Run focused tests and observe expected failures.
- [ ] Implement minimal matching and scan-backed candidate construction.
- [ ] Run focused tests to green; commit.

### Task 2: Guarded replacement transaction

**Files:** `Sources/SelectiveRemote/SSHKnownHostsService.swift`, `Tests/SelectiveRemoteTests/SSHKnownHostsRecoveryTests.swift`

**Interfaces:** `replaceConfirmed(candidate:from:rescan:) async throws -> URL` returns a versioned backup URL only after verified replacement.

- [ ] Add tests for rescan change, source change, exact-line-only replacement, backup exclusivity/mode, failed write, symlink refusal and preserved original.
- [ ] Run focused tests and observe expected failures.
- [ ] Implement source revalidation, versioned backup, sibling temp, fsync, atomic rename, result verification and app-owned lock.
- [ ] Run focused tests to green; commit.

### Task 3: Route-aware connection coordinator

**Files:** `Sources/SelectiveRemote/AppModel.swift`, `Sources/SelectiveRemote/SSHService.swift`, `Sources/SelectiveRemote/SmartReconnect.swift`, `Tests/SelectiveRemoteTests/SSHServiceTests.swift`

**Interfaces:** An AppModel recovery intent records original retry action and trusted `SSHConnectionSettings`; it exposes one candidate or a manual reason.

- [ ] Add tests proving direct vs managed-Jump role, no prompt-text role selection, no automatic retry and fail-closed ambiguous routing.
- [ ] Run focused tests and observe expected failures.
- [ ] Wire terminal, SFTP and forwarding failure signatures to route-bound inspection; preserve AskPass identities and existing reconnect guard.
- [ ] Run focused tests to green; commit.

### Task 4: Native RU/EN recovery sheet

**Files:** `Sources/SelectiveRemote/ContentView.swift`, new focused SwiftUI view if needed, `Tests/SelectiveRemoteTests/LocalizationAndAuxiliaryWindowsTests.swift`

**Interfaces:** The sheet receives immutable candidate details, Cancel, Copy, Confirm and guarded result/retry actions.

- [ ] Add testable view-state/locale contracts for safe default, distinct role, copy and no mutation on Cancel.
- [ ] Run focused tests and observe expected failures.
- [ ] Implement the sheet and AppModel presentation route.
- [ ] Run focused tests to green; commit.

### Task 5: Integrated verification

**Files:** tests and source touched above only.

- [ ] Run synthetic OpenSSH direct/Jump scenarios and negative mutation cases.
- [ ] Run full Swift test suite and Release build.
- [ ] Audit first-party warnings and exact diff; run scoped Codex Security review.
- [ ] Run CI and Test DMG on exact pushed branch head; keep public main and 0.32 baseline unchanged.
- [ ] Report Owner manual RU/EN, Graphite/Light, keyboard, VoiceOver, direct/Jump and retry checklist without claiming unperformed acceptance.
