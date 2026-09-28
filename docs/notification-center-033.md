# Notification Center v1 (0.33) — source-backed design

Baseline: public `main` `4febe0054947b395d028d94a6f9b1ef7aae7188f`.
The frozen 0.32 release commit `063e109694d4307343dab8ee7271b114e20a5ffd` is not changed.

## Purpose and boundaries

The center answers “What needs my attention?” It is a projection of current
problems and pending decisions, not a historical feed. Activity, Diagnostics,
Sync Center, Team Audit, conflict resolution and device approval remain the
authoritative flows. Opening a notification navigates to one of those flows;
it never performs the privileged action itself.

## Source and classification

| Candidate | Scope | Class | Source | Resolution |
| --- | --- | --- | --- | --- |
| Device key awaiting approval | Cloud account; Mac portal shortcut | persistent, actionable, security, device | account devices with registered key and no approval/revocation | fresh account-device list no longer has it pending |
| Team invitation for current account | Cloud account; Mac invitation flow | persistent, actionable, team | pending invitations endpoint | fresh pending list no longer includes it |
| Personal/Team sync error | per session and scope | persistent, actionable, sync | structured Sync snapshot/observation | confirmed healthy result for that scope |
| Sync conflict | per session and scope | persistent, actionable, sync | typed conflict result | confirmed resolution in the source |
| Team materialization, missing wrapper, rotation | account/team scope when proven | persistent, actionable, security and sync | typed fail-closed Team state | source reports successful materialization |
| Host identity mismatch | Mac local only | persistent, actionable, security | guided Known Hosts candidate from failed connection | successful explicit guided recovery, not opening/reading card |
| Team role/member change | neither | informational | Team Audit | stays in Team Audit; no actionable v1 event |
| Ordinary offline/syncing/success/connection | neither | transient or informational | existing status/Activity | never added to inbox |

The persistent candidates are all actionable. Device approval and host identity
are `SECURITY`; invitations are `TEAM`; sync error and conflict are `SYNC`;
fail-closed and wrapper/admission issues are both `SECURITY` and `SYNC`, scoped
to a Team Vault when the source has an exact Vault ID. A transient state is
never retained. Team membership and role changes remain informational in Team
Audit because v1 has no new decision for the recipient.

Cloud Team sync is only for the **selected** Team Vault. A selected-scope
success must not resolve another Team scope. Mac Team sync aggregate cannot
claim a per-Vault resolution; it resolves only its own aggregate issue after
the typed engine reports a complete successful cycle.

## Model, privacy and persistence

An item persists `id`, `recipient`, `group`, `kind`, `scopeID`, `sourceID`,
`createdAt`, `lastObservedAt`, `readAt` and `resolvedAt`. Severity, source kind,
deduplication key and action route are derived from the typed kind, group and
opaque source IDs. `safeMetadata`, primary/secondary action strings and display
names are deliberately not stored. This keeps the payload allowlist limited to
enums, UUIDs and timestamps. Display labels are fixed localized copy; source
identity is used only for routing to an existing flow. No arbitrary metadata,
Vault plaintext, credential, key, token, raw error or fingerprint is allowed
in the projection. No new server table/API or cross-device read sync.

Local durable read state and unresolved safe projections are scoped to the
current account/device. Reconciliation happens on authoritative source
changes, never on rendering. An unavailable source leaves an active item
active. A complete successful source snapshot may resolve items absent from
that source. Reading sets `readAt` and does not set `resolvedAt`; routing and
retry also do not resolve. Reappearance after resolution reactivates the same
dedupe identity and becomes unread. The main badge counts active actionable
items; unread is a separate count inside the panel.

Resolved items are kept at most 30 days and 100 items per recipient. Active
items are never removed by age. Transient statuses are not persisted. Source
lists have existing server bounds; the local projection rejects malformed
identities and accepts at most 1,000 observations per source snapshot and 5,000
stored items. The cap prevents local storage abuse without expiring an existing
active security item.

Mac keeps host identity issues in installation-local UserDefaults and account
issues in per-endpoint, per-account UserDefaults envelopes. The normalized Cloud
endpoint is hashed into the storage key, preventing UUID reuse across endpoints
from loading another endpoint's history. Cloud keeps the account projection
in per-account `localStorage`. Switching account hides the old account's issues;
read state remains local to this device/browser, with no claim of cross-device
sync. Cloud has no Host Key event because it does not initiate SSH connections.

## UI and routes

Mac uses a compact bell/popover in existing chrome. Cloud uses a compact
header indicator and responsive panel. Both offer All, Needs Action, Sync and
Security filters, RU/EN copy, an empty state, visible unread state, and
accessible keyboard navigation. Actions call existing routes: Devices, Team
invitations/management, Sync Center/retry, conflict resolver, Diagnostics or
Guided Known Hosts Recovery. Mac-only host identity is never sent to Cloud.

## Verification

Test the pure projection with device/invitation/sync/conflict/fail-closed/host
signals, dedupe, counters, read versus resolved, recurrence, retention,
privacy and recipient isolation. Then exercise real Mac/Cloud integration,
render RU/EN × Light/Graphite × normal/narrow or desktop/mobile across empty,
single and mixed states, run full Swift/Cloud/Release checks, and formally scan
the exact PR head before Owner review. Rendered previews are not authenticated
staging acceptance or Owner manual acceptance.

Representative synthetic captures and reproduction instructions are in
`docs/evidence/notification-center-033/`.

## Payload threat model and performance

The attacker-controlled inputs are Cloud response fields, Team/Vault record
content, errors, host names/fingerprints and browser events/storage. The
projection receives only typed status and UUID source references. It rejects
other recipient IDs and malformed group/kind combinations before persistence.
Cloud renders fixed copy with `textContent`, never `innerHTML` or source labels.
Opening an item sets read state and navigates; it does not approve a device,
accept an invitation, select a conflict winner or trust a host key. A stale
source reference falls back to its existing parent flow. A failed source fetch
never resolves active items.

The new data is confined to local preferences/storage. Diagnostics export and
Cloud API payloads are unchanged; the projection is not copied into logs or
crash-report custom fields. Local storage still reveals the existence and type
of an issue to anyone already able to read that OS/browser profile, so names,
fingerprints and decrypted details are excluded. Bounded snapshots and storage
size limit event spam. Polling reuses existing invitation/device refreshes;
rendering performs no network request, decryption or persistence write.
Persistence is immediate for a new item, read transition or resolution and
throttled for timestamp-only observations in the browser.
The Mac invitation poll discards late results after endpoint/session changes.
Cloud sync events carry their originating recipient, and complete device and
invitation responses carry request-order sequence numbers so older responses
cannot clear newer attention cues.

## Owner manual acceptance before 0.33 release

On a test Mac and browser, verify RU/EN, Light/Graphite, normal/narrow or
desktop/mobile, empty and every event type, mixed/read/resolved states, Tab,
Shift-Tab, Enter, Space and Escape, and VoiceOver labels. Check that device,
invitation, conflict, Team and Known Hosts actions open their existing flows;
reading and retrying must not clear the attention badge. In a safe Known Hosts
test, the SSH connection must stay stopped until explicit guided recovery.
