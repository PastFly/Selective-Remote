# Sync presentation inventory (frozen 0.32 source)

Source authority: public `main` `063e109694d4307343dab8ee7271b114e20a5ffd`. This inventory supports the isolated post-0.32 Sync Center branch. `AUTHORITATIVE` means an existing sync result or stored engine fact; it does not imply all devices are current.

| Surface | Existing fact | Class | Presentation limit / hook |
| --- | --- | --- | --- |
| Mac Personal | Last successful timestamp and applied revision in `SelectiveRemotePersonalVaultSyncStatus` | AUTHORITATIVE history | Global UserDefaults keys are not account scoped. Show only when tied to the current in-process account; never promote cached history to current. `CloudPersonalVaultAutoSync.swift:5-16`. |
| Mac Personal | Enabled, configured, last error, download-active flag | AUTHORITATIVE for each local flag | Download-active does not cover outbound work; generic error may contain raw localized text. Categorize, never export raw text. `CloudSettingsView.swift:13-23,206-295`; `SelectiveRemoteApp.swift:497-539`. |
| Mac Personal | Full end-to-end current state; exact pending count, next retry, byte progress | UNAVAILABLE | A successful server check or historical revision does not establish complete current materialization. `CloudPersonalVaultAutoSync.swift:281-305,317-344,370-406`. |
| Mac Team | Report counts for scanned, synchronized, uploaded, conflicts, pending wrappers, rotation and failures | AUTHORITATIVE at cycle boundary | Current callers discard the report; signed-out zero report means unknown. `CloudTeamVaultAutoSync.swift:11-22,79-113,202-241`; `SelectiveRemoteApp.swift:209-212,446-454`. |
| Mac Team | Aggregate lifecycle/issue derived from report | DERIVED, EPHEMERAL | A complete cycle with every scanned Vault accounted and no issue confirms only that observed cycle. Individual Vault revisions remain unavailable; avoid raw `lastFailure`. |
| Mac Team | Per-Vault last success/revision across relaunch and exact pending count | UNAVAILABLE | Needs separately reviewed per-Vault observation; do not fabricate from aggregate report. |
| Browser Personal | `synchronizeVault` typed status and revision/remoteRevision | AUTHORITATIVE for observed page-session attempt | Result statuses include empty, upload, download, up-to-date, remote-changed and conflict. `cloud/public/vault-sync.js:1343-1393`; `app.js:3896-3911,4372-4408`. |
| Browser Personal | Last displayed revision/time | EPHEMERAL | DOM state is local to current page, not cross-device history. `cloud/public/app.js:128-164`. |
| Browser Team | Selected Vault typed sync/wrapper result | AUTHORITATIVE for selected observed Vault | Other Team Vaults remain unknown. `cloud/public/team-vault-sync.js:725-843`; `app.js:2745-2805`. |
| Browser aggregate | Header badge previously inferred from localized message regex and defaulted to synchronized | DERIVED but unreliable | Replace `app.js:4842-4867` with typed projection; unknown at startup. |
| Browser connectivity | `navigator.onLine` | EPHEMERAL hint | Offline is a hint; online is not proof of Cloud reachability. |
| Devices | Existing Cloud key approval and Team admission/wrapper controls | AUTHORITATIVE within those flows | Review routes only; Sync Center neither approves a device nor bypasses fingerprint/role checks. `cloud/public/app.js:2198-2228`; `index.html:875-889`. |
| Diagnostics | Existing report builder, redactor, copy/export and pane picker | AUTHORITATIVE technical report surface | Add one Cloud & Sync pane with allowlisted categories; do not copy raw sync errors, Team names or IDs. `DiagnosticsCenter.swift:30-162,445-677,1019-1037`. |

Status lifecycle, aggregate priority and recovery action availability are **DERIVED** presentation facts. In-progress state, browser results and local connectivity are **EPHEMERAL** and reset on reload/account switch. Unobserved scopes remain **UNAVAILABLE/UNKNOWN**, never silently “Synced.”

## Bounded recovery and privacy contract

- Mac presentation events carry only a category or aggregate counts. The active Team cycle token and session generation reject late results. Personal outbound errors are categorized at the existing scheduling boundary and accepted only for the generation that scheduled them.
- Team `hiddenFailClosed` is shown only for the existing missing-wrapper or rotation signals. Generic failures are errors without a claim that Vault data is corrupt.
- Browser DOM observation events contain allowlisted scope, status, revision and error category. Conflict records, names, IDs and raw errors never enter the event detail.
- Diagnostics Copy/Export adds only lifecycle, issue category, local confirmation time, applied revision and fail-closed category, then runs the existing `DiagnosticRedactor`. Team names, hostnames, account IDs and raw sync errors remain excluded.
- Retry dispatches to the existing Personal or Team action for its own scope. Device and Team actions open existing management routes; no approval or role check is performed in presentation code.
- Notification Center may later consume `scope`, `category`, `severity`, `action route`, `deduplication key` and safe metadata. This branch stores no notification event or inbox and emits no Activity entry for routine sync attempts.

## Scoped security and performance review

Reviewed the branch diff for secret and diagnostic leakage, cross-Team mixing, wrong-scope retry, stale success, unsafe error text, fail-open materialization, identifier exposure, and action-route privilege bypass. The review corrected a fabricated Personal pending marker, a browser aggregate that could hide a scope error while offline, old-session Mac results reaching a new session, and an over-specific crypto failure category. The resulting state remains in memory, uses existing sync events, and adds no polling, decryption, storage writes, server API, approval path, or Activity event. The browser status covers only Personal and the selected observed Team Vault; its success copy explicitly says “observed.” Manual authenticated and mobile acceptance remains a separate gate.
