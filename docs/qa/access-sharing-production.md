# Access and Sharing local acceptance evidence

This page describes **LOCAL_VISUAL_PREVIEW** evidence only. The browser uses a fresh anonymous headless Edge profile, a localhost origin, synthetic scoped API responses and the actual `initializeTeamWorkspace` Access destination and `AccessManager`. The Mac captures use the actual `SelectiveRemoteCloudResourceAccessView` in an `NSHostingView` and a WindowServer-backed `NSWindow`, with a memory token store and synthetic `dataLoader`. No image or test proves authenticated staging, V2 decryption, migration, CEK delivery or production activation.

## Reproduce

From the source repository on macOS:

```sh
PLAYWRIGHT_MODULE=/Users/kadaevleonid/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright/index.mjs \
CHROMIUM_PATH='/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge' \
ACCESS_QA_MATRIX=1 ACCESS_QA_OUTPUT=/private/tmp/access-task5-cloud-final \
node cloud/tests/browser/access-manager-smoke.mjs

SR_CAPTURE_ACCESS_MATRIX=/private/tmp/access-task5-native-final \
swift test --filter 'actualAccessSheetWindowServerMatrix|firstGrantDoesNotShowRevokeGuidance|deviceCodesHaveLocalizedSafeCopy'

node --test cloud/tests/access-manager.test.mjs cloud/tests/access-client.test.mjs
```

The optional browser wrapper is `cloud/tests/fixtures/access-manager.html`; it embeds the production index and only permits localhost. The script's synthetic adapter has no real credentials or production fixture flag. The [tracked portable manifest](access-sharing-production-manifest.json) records scenario dimensions, expected image names, bounds and log paths. The browser also writes a detailed `manifest.json` beside PNGs; each row has scenario, locale, theme, viewport and overflow result. Capture directories are temporary evidence, not tracked source. Native PNG names encode scenario, language, appearance and window width.

## Matrix and checks

Cloud captures 12 states (empty, loading, V1, PREPARING, READY, ACTIVE, direct, group, multiple paths, no key, UNKNOWN, error) in RU/EN × Light/Graphite × desktop/tablet/mobile: 144 PNGs. The script asserts the effective device status and path counts before capture. Mac captures the same 12 states in RU/EN × Light/Graphite × 480/820 point windows: 96 PNGs. Its fixture uses the real typed client/context, registry, Who and explicit member-device effective endpoints; the capture test asserts expected path and device states. Rendering uses WindowServer pixels, not cached PDF text.

The 240-image matrix was captured before the review fix to the native fallback title and expired-preview footer. Focused native window/OCR and launchable-app checks verify those corrections; the older matrix files must not be presented as post-fix pixels.

The browser scale pass checks 5/100/1000 members and 50/500/5000 resources. It records elapsed local synthetic request time and request count separately from server performance; each directory remains bounded to a 50-row page. The real Team route smoke verifies `initializeTeamWorkspace().setView("access")` mounts the same Access Manager root. Component smoke additionally checks the authenticated browser adapter, first grant/preview/commit, off-page exact metadata, group rename identity, all policy paths, explicit device UNKNOWN, opaque label canary and READY/ACTIVE write gates.

The focused web preview tests reject incomplete terminal details, duplicate pair/grant rows and changed count tuples before confirmation. The corresponding native tests cover terminal totals, alternate paths and commit receipt retention when refresh fails. Neither UI may retry a validated commit after a refresh 503.

For focused malformed-preview window evidence, run `SR_CAPTURE_ACCESS_MATRIX=/private/tmp/access-task5-invalid-native swift test --filter 'incompleteDuplicateAndChangedCountsCannotCommit'`. Without the variable, the same test checks the portable typed coordinator contract and does not request WindowServer pixels. With the variable, it writes PNG and Vision OCR text for pending and terminal invalid previews; assertions require the rendered “Next impact page” or “Preview change” control, no “Confirm” control, and no commit request. This opt-in check requires a macOS login session with WindowServer. Swift Testing's standalone host exposes no accessibility labels for these SwiftUI controls, so OCR is visual evidence, not VoiceOver evidence.

### Pending native keyboard and VoiceOver acceptance

In a macOS login session, build the isolated QA app with `bash Tests/AccessAcceptanceHarness/build-local-app.sh`, then open `/private/tmp/AccessAcceptance-valid.app` or `/private/tmp/AccessAcceptance-invalid.app`. These disposable apps link the real `SelectiveRemoteCloudResourceAccessView` into a test-only `.sheet` with an in-memory typed API adapter. They are separate from the production app product. The valid fixture starts with a terminal preview and can return one synthetic commit receipt; the invalid fixture starts with a two-page preview whose terminal counts change. Record the source SHA, OS version, language, appearance, screenshot, and a screen recording of each interaction:

1. Use Tab and Shift-Tab to traverse Close, the three access tabs, Search recipients, recipient checkboxes, permission controls, Preview change, and Refresh. Verify visible focus and the spoken name, role, and state of each control with VoiceOver.
2. With the search field focused, Enter performs search without applying a change. With a valid terminal preview and focus on Confirm, Space or Enter opens the “Apply the previewed change?” dialog. Escape cancels it and causes zero `/access-commit` requests. After the 60-second preview lifetime, the footer offers Preview again; a fresh preview must preserve the exact pending operation, including a bound resource move.
3. Reopen confirmation and use Space or Enter on Apply once. Check one commit request and the server receipt before the committed message. Escape on the sheet closes it without a commit.
4. Repeat with incomplete terminal, duplicate rows, and changed-count preview replies. Confirm must be unavailable after the invalid page; Tab, Enter, and Space must not reach a commit action.

Programmatic Return events sent to a standalone `NSWindow` inside Swift Testing did not dispatch the SwiftUI alert, and that test host's AppKit accessibility tree returned zero labels; neither behavior is treated as product acceptance. The launchable app exposes the real sheet's accessibility controls through macOS. The app prints the synthetic commit request count when its window closes. Human VoiceOver speech still needs human acceptance; accessibility tree labels alone do not establish it.

Local CUA acceptance on 2026-09-30 used the launchable actual-sheet app. AX exposed named tabs, Search recipients, View/Edit/Manage access checkboxes and buttons; Search had initial focus. Tab reached Edit, Space changed its value, Return produced a valid preview, Return opened the real confirmation alert, Escape cancelled it, and Tab plus Return on Apply produced the committed message. Escape removed the sheet. The valid fixture's JSONL had 12 requests and exactly one `/access-commit`. For the malformed fixture, Preview change produced Pairs: 2 and Next impact page; loading the terminal page with changed counts cleared preview/confirmation and displayed the fresh-preview error. A subsequent Space on Edit and Return still produced no confirmation. Its JSONL had eight requests, three preview requests, and zero commits. These are local synthetic API results; VoiceOver speech and authenticated staging remain separate acceptance gates.

The final-source expiry check used the same actual sheet: Preview change produced Confirm, the footer changed automatically to Preview again after more than 60 seconds, and clicking it restored fresh Confirm without losing the selected recipient or pending request. Its JSONL had seven requests, two preview calls and zero commits. This run checked renewal, while the earlier valid run checked the single committed receipt.

## Production gates still open

- V1 legacy Host, Credential, Snippet, Folder and Forwarding models have no persisted authoritative V2 registry identity. Their contextual actions explain the mapping prerequisite. The native per-Vault picker uses exact registered IDs and is available only in PREPARING because current list/exact metadata APIs reject READY/ACTIVE.
- Personal copies create fresh V1 encrypted identities and leave the original intact; resource ACL continuation needs mapping and publication. Both ancestry drag paths stop before persistence when mapping or publication is missing.
- READY/ACTIVE policy writes require a reviewed encrypted generation publication path and remain blocked. ACTIVE fixture rendering does not establish real key delivery or usable cryptography.
- Production activation, migration, CEK delivery, Cloud deployment, public main change, release/feed update and official signing/notarization are outside this local evidence. Authenticated HTTPS staging and manual accessibility/VoiceOver acceptance require a separate authorized environment and Owner credentials.

## Draft PR #210 remainder

The [approved Access composition spec](../superpowers/specs/2026-09-30-access-sharing-production-design.md) and [V2 publication design](../superpowers/specs/2026-09-30-vault-v2-migration-publication-design.md) are the governing contracts. [Draft PR #210](https://github.com/PastFly/Selective-Remote/pull/210) remains a non-authoritative reference. The [source-linked remainder audit](../architecture/access-sharing-pr210-reference-audit.md) extracts its useful crypto, migration, registry and rollout topics for bounded follow-up. Recommend closure only after those inputs are accepted; do not merge its synthetic UI or close the PR automatically.
