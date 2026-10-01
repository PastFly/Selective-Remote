# 0.32 Release Convergence Implementation Plan

> **For agentic workers:** Use Superpowers systematic debugging and verification before completion for each bounded defect. Independent product surfaces may be audited in parallel; integrate and verify one final candidate.

**Goal:** Prepare the first public Cloud/Teams 0.32 candidate for Owner acceptance by the evening of 2 October 2026, Europe/Moscow.

**Architecture:** Retain the approved client encryption, Team authority, signed preview/commit and migration boundaries. Freeze public main after approved PR #220; new source changes address confirmed release defects and remain on a non-main branch until a fresh exact-head Owner gate.

**Tech stack:** macOS SwiftUI/SwiftPM; browser JavaScript/CSS; Node 22; PostgreSQL 16; existing CI and Test DMG workflows.

**Spec:** Owner's Release Convergence decision of 1 October 2026; existing approved Access/Sharing and migration/publication specs remain governing security contracts.

## Global constraints

- NO NEW LARGE FEATURES. Changes require confirmed defect, security issue, release blocker, harmful first-run usability, localization or accessibility evidence.
- Current public download is v0.31.0; 0.32 and Cloud/Teams remain upcoming until publication.
- Production Cloud deployment requires staging, migration, security, backup, rollback and fresh Owner approval.
- New fix PRs require fresh exact-head Owner merge authorization.
- No public feed advance until the downloaded official signed/notarized asset is verified.
- Synthetic/local visual evidence is distinct from authenticated HTTPS staging and human VoiceOver.

## Review focus

- Older backend without trust routes: explain unsupported version; never fabricate device approval success.
- Missing crypto material: user-level policy never implies a usable device key.
- Expired/racing preview: require complete new signed preview and exactly one committed receipt.
- Resolved notifications and unknown sync: display source state with useful explanation/action.
- Locale/theme/narrow changes: keep primary controls visible, named and keyboard reachable.

## Tasks

- [x] Verify #220 exact head, formal scan, checks and review threads; Ready and guarded squash merge; verify tree. Retire #210 using existing reconciled reference material.
- [x] Complete post-merge CI/Pages and record freeze, retired prototype and release strategy in Continuity.
- [x] Audit Mac Access presentation in `CloudAccessLocalization.swift`, `CloudResourceAccessView.swift`, `AccessRegistrationPrerequisite.swift`, `RegisteredResourcePicker.swift`; fix confirmed human-copy and effective-device-row defects with focused regression/render evidence.
- [x] Audit browser Access in `access-copy.js`, `access-manager.js`, `access-manager.css`; replace protocol enums/masks with localized labels, preserving incomplete-preview and published-generation guards. Verify RU/EN, Light/Graphite, keyboard and responsive rendering.
- [x] Diagnose older-backend trust failures in `vault-sync.js`, `device-trust-ui.js`, `app.js`, `CloudDeviceTrustView.swift`; write a failing 404 boundary regression, provide typed unsupported state and safe localized next action; label fields/statuses accessibly.
- [x] Audit Sync/Notifications; reproduce and correct only material status/copy defects. Record retained bounds and pending manual speech acceptance.
- [ ] Run targeted failure injection, full Cloud/Swift/Release, PostgreSQL 16 migration/concurrency/scale, exact-head and v0.31 aggregate formal Security, CI and Test DMG. Open a bounded fix PR with a fresh Owner gate.
- [ ] Prepare isolated staging upgrade: source/schema inventory, protected backup, full-chain dry run, rollback/controller fence, health/schema/asset checks. Owner confirmed cloud.pastfly.ru is test staging; production does not exist. Preserve the deployment compatibility fence before a runtime mutation.
- [ ] Run authenticated staging E2E using exact-run disposable test resources; password entry stays with Owner. Test a synthetic allowlisted Vault migration, old client, second device, reload/restart/revoke/rotation. Record each unavailable production path as a blocker.
- [ ] Prepare truthful upcoming website/README copy, new privacy-safe screenshots and long/short RU/EN release notes, What's New and GitHub release body. Preserve v0.31 download.
- [ ] Check Developer ID availability; prepare ad-hoc acceptance RC if unavailable. Perform official v0.31 preservation/upgrade acceptance in an isolated profile. Official signing/notarization/publication remain gated.
- [ ] Maintain one release dashboard and authoritative roadmap: done, final hardening, external blocker, after 0.32. Report exact candidate, evidence and unresolved release gates.

Full source regression runs after all concurrent edits stabilize. Only affected tests repeat during individual defect cycles.


## Confirmed convergence defects and verification

- Mac device permission rows omitted when crypto metadata was absent: actual SwiftUI red/green regression.
- Cloud final preview-page keyboard focus could fall onto Confirm: real browser red/green, one commit receipt, cancel/escape focus restoration.
- Internal states/masks and mixed language in Access: localized presentation, policy/device usability remains separate.
- Old Device Trust collection404 presented raw/general errors: typed unsupported capability on Mac/browser, session preserved; named input/status copy.
- Resolved notification text still required action; unknown Sync lacked an explanation: truthful source-resolution and confirmation copy.
- Mobile Device Trust default-sized controls: existing panel controls now44px with visible keyboard focus.
- Account password change left the encrypted Personal Vault under the old passphrase: reproduced in a fresh synthetic browser. Temporarily deny all password changes until atomic rewrap, with409 and explicit unchanged-password/session copy. No new rewrap architecture.
- Native96 fixture reused a coordinator invalidated when each window disappeared: fresh state per window and positive OCR body assertions, red24→green96. First capture batch is invalid evidence.
- Review corrected settings read-only semantics and retained pending device approval across ordinary transient/no-answer errors.

Local checks: Cloud565 PASS/22 PG-specific skips/one existing atomic-rewrap TODO; separately PostgreSQL16 matrix84/84 without skips and schema12→19 preservation/restore; final Swift705 PASS; final Release PASS. Browser Access144 states plus focused48 states; Device Trust/Notifications48 renders. Native repaired96 states. These are local synthetic checks, not authenticated staging or human VoiceOver.

Release gates remain: fresh bounded-PR Owner merge approval, staging upgrade/controller fence and real E2E, Owner-confirmed FULL scope: missing resource mapping/publication/materialization block RC until completed, real official0.31 upgrade in an isolated macOS account, human speech acceptance and Developer ID. Current official0.31 download checksum verified; its app is ad-hoc, no publisher Team ID. Never treat the historical asset as Developer ID proof.
