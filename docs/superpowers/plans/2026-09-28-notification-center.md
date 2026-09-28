# Notification Center v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task by task. Steps use checkbox syntax for tracking.

**Goal:** Add a source-backed, privacy-safe attention inbox for 0.33 on Mac and Cloud.

**Architecture:** Each platform projects existing typed source state into local scoped records. Only allowlisted identity, type and lifecycle timestamps persist locally; source systems still decide resolution and perform actions. The UI observes the projection and routes to existing flows.

**Tech Stack:** Swift 6/SwiftUI/Testing; browser JavaScript/Node test; existing Cloud CSS and i18n.

**Spec:** `docs/notification-center-033.md`.

## Global Constraints

- Base `4febe0054947b395d028d94a6f9b1ef7aae7188f`; preserve frozen 0.32 `063e109694d4307343dab8ee7271b114e20a5ffd`.
- Feature branch and PR only; no public main, release/feed/tag, production Cloud deployment, signing or notarization.
- No new server table/API, Vault plaintext, arbitrary error text, credential or key in notification records.
- Read is independent of resolution; only authoritative source state resolves an issue.
- Existing Activity, Diagnostics, Sync Center, Devices, invitations, conflicts and Known Hosts own actions.

## Review Focus

- Switching accounts or Team access cannot expose another recipient's items.
- A Retry/start/locked/temporary offline state cannot remove an active sync error.
- A stale invitation/device snapshot cannot resolve an item after a fetch error.
- An action click cannot approve a device, accept an invitation or trust an SSH key implicitly.
- Repeated observations cannot grow storage, while a recurrence becomes visible and unread.

---

### Task 1: Pure projection and retention

**Files:** Create `Sources/SelectiveRemote/NotificationProjection.swift`, `Tests/SelectiveRemoteTests/NotificationProjectionTests.swift`, `cloud/public/notification-projection.js`, `cloud/tests/notification-projection.test.mjs`.

**Interfaces:** Observations carry typed kind, source family, recipient/scope, opaque source ID, and time. Stores expose active items, attentionCount, unreadCount, observe/reconcile and markRead. No arbitrary display payload.

- [ ] Write tests for device, invitation, sync, conflict, fail-closed, host key, dedupe, read/resolved, recurrence, retention, recipient isolation and secret-like input rejection.
- [ ] Run targeted tests and confirm expected red failures.
- [ ] Implement minimal typed stores with local persistence adapters; resolve only on successful complete snapshots or typed confirmed success.
- [ ] Run targeted tests to green and commit.

### Task 2: Source adapters and routes

**Files:** Modify `SyncPresentation.swift`, `CloudTeamInvitationPrompt.swift`, `AppModel.swift`, `ContentView.swift`, `cloud/public/app.js`; add focused tests beside Task 1 tests.

**Interfaces:** Sync adapters consume typed snapshots/observations; account adapters consume existing fetched device and pending invitation lists; host key adapter consumes the existing guided recovery candidate and explicit success event. Routes only navigate/retry through existing controls.

- [ ] Add failing source and route tests for each event family and source-driven resolution.
- [ ] Run targeted tests to confirm red.
- [ ] Wire source change points, account isolation and existing actions without new polling/decrypt/render writes.
- [ ] Run targeted tests to green and commit.

### Task 3: Mac presentation

**Files:** Create `Sources/SelectiveRemote/NotificationCenterView.swift`; modify `ContentView.swift`; add focused Swift tests.

- [ ] Add failing UI contract tests for attention badge, filters, read state and RU/EN semantic labels.
- [ ] Confirm red, implement compact bell/popover and routes, then targeted green.
- [ ] Render empty/single/mixed/read/resolved states in RU/EN × Light/Graphite × normal/narrow; check keyboard and VoiceOver basics; commit.

### Task 4: Cloud presentation

**Files:** Modify `cloud/public/index.html`, `cloud/public/styles.css`, `cloud/public/i18n.js`, `cloud/public/app.js`; add Cloud tests.

- [ ] Add failing DOM/route/ARIA tests for panel, filters, attention badge and localization.
- [ ] Confirm red, implement responsive header panel with text-only source-derived labels and action routes, then targeted green.
- [ ] Render empty/single/mixed/read/resolved states in RU/EN × Light/Graphite × desktop/mobile; check Tab/Shift-Tab/Enter/Space/Escape and ARIA; commit.

### Task 5: Final evidence and handoff

**Files:** Relevant Continuity `STATE.yaml`, `ROADMAP.md`, `VERIFIED_HISTORY.md`; final PR body.

- [ ] Run full Swift/Cloud/Release, warning and performance review, and exact-head Codex Security diff scan; correct actionable findings with new-head checks.
- [ ] Push branch, open feature PR, wait exact-head CI and Test DMG, and verify PR metadata/checks.
- [ ] Update, commit, push/fetch and blob-verify Continuity; report exact head and Owner manual checklist without merging.
