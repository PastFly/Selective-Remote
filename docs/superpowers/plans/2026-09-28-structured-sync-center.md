# Structured Sync Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Present truthful Personal and Team sync state on macOS and Cloud, route recovery through existing actions, and extend the existing Diagnostics Center without changing sync engines.

**Architecture:** Each client keeps a typed, ephemeral presentation projection over existing sync outcomes. The macOS projection observes Personal and Team events and powers a compact Sync Center and a privacy-safe Diagnostics pane. Cloud replaces message-text parsing of its existing badge with typed result updates and a small disclosure. Unknown and historical states remain visibly distinct from confirmed current state.

**Tech Stack:** Swift 6 / SwiftUI / Swift Testing; browser JavaScript / Node tests; existing Selective Remote Cloud API and sync actors.

**Spec:** `design/post-032-sync-diagnostics/README.md` in the shared workspace, refined by the Owner's post-0.32 Sync Center request.

## Global Constraints

- Base the branch on frozen public `main` `063e109694d4307343dab8ee7271b114e20a5ffd`; do not use PR #206 as a base or alter it.
- Keep public main, 0.32 release state, feed, Pages and production Cloud unchanged.
- No new sync engine, server protocol, Vault format, cryptographic path, notification persistence or second Diagnostics Center.
- Present only proven fields; unknown pending count and cross-device state must remain unknown.
- Recovery actions call existing Personal/Team sync, Device, Team and conflict flows.
- UI and report never expose Vault plaintext, keys, credentials, raw sync errors or sensitive identifiers.

## Review Focus

1. A persisted Personal revision must not imply that the current account is synchronized.
2. A successful scope must not hide a failed Team scope; signed-out zero Team reports must not become success.
3. Localized message strings must not determine Cloud status.
4. A retry must affect only its scope and must not run on every render.
5. Diagnostics export must use an explicit allowlist and existing redaction.

## Task 1 — Exact inventory and typed semantics

- [x] Verify live frozen main, PR #206 separation and Continuity baseline.
- [x] Inventory Mac Personal/Team, browser Personal/Team, Devices and Diagnostics source events.
- [x] Record authoritative, derived, ephemeral and unavailable fields in the PR documentation.
- [x] Add reducer tests for status priority, unknown/stale state, offline, pending count and scope isolation.
- [x] Implement the smallest typed macOS projection and pass focused tests.

## Task 2 — macOS Sync Center

- [x] Add tests for Personal/Team event adaptation and scoped retry routing.
- [x] Observe existing sync call boundaries without adding polling or decrypting for UI.
- [x] Add compact indicator and Sync Center in existing navigation; keep sparse, adaptive cards and RU/EN copy.
- [ ] Verify narrow and normal widths, Graphite/Light, keyboard, VoiceOver labels and reduced motion.

## Task 3 — Existing Diagnostics Center

- [x] Add a test proving sync report export uses allowlisted state; the existing redaction test covers synthetic secrets.
- [x] Add a Cloud & Sync pane to `DiagnosticsCenterView`, reading the same presentation snapshots.
- [x] Extend report builder only with allowlisted categories, dates and revisions; keep `DiagnosticRedactor` as final authority.
- [x] Route Diagnostics actions to existing Cloud/Sync/Device/Team flows, and keep Refresh read-only.

## Task 4 — Cloud typed status and compact surface

- [x] Add browser tests for typed Personal/Team outcomes, aggregate priority, offline and RU/EN switching.
- [x] Replace localized-text regex/MutationObserver inference with in-memory typed state updated at existing sync result/error boundaries.
- [x] Add compact disclosure for observed scopes with existing retry/conflict routes and unknown handling.
- [ ] Check mobile/desktop, Light/Graphite, focus/Escape and no horizontal overflow.

## Task 5 — Verification and handoff

- [ ] Run targeted Swift and Cloud tests, full Swift suite, Cloud suite and Release build; audit first-party warnings.
- [ ] Perform scoped security/privacy/performance review, including wrong-scope retry and stale state.
- [ ] Run rendered Mac and Cloud matrix where permitted; label any unverified state honestly.
- [ ] Commit and push isolated branch, create PR without merge, verify exact-head CI and Test DMG.
- [ ] Update Continuity with exact refs, checks and limitations; leave Owner manual acceptance as the next gate.
