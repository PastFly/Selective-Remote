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

The browser scale pass checks 5/100/1000 members and 50/500/5000 resources. It records elapsed local synthetic request time and request count separately from server performance; each directory remains bounded to a 50-row page. The real Team route smoke verifies `initializeTeamWorkspace().setView("access")` mounts the same Access Manager root. Component smoke additionally checks the authenticated browser adapter, first grant/preview/commit, off-page exact metadata, group rename identity, all policy paths, explicit device UNKNOWN, opaque label canary and READY/ACTIVE write gates.

The focused web preview tests reject incomplete terminal details, duplicate pair/grant rows and changed count tuples before confirmation. The corresponding native tests cover terminal totals, alternate paths and commit receipt retention when refresh fails. Neither UI may retry a validated commit after a refresh 503.

## Production gates still open

- V1 legacy Host, Credential, Snippet, Folder and Forwarding models have no persisted authoritative V2 registry identity. Their contextual actions explain the mapping prerequisite. The native per-Vault picker uses exact registered IDs and is available only in PREPARING because current list/exact metadata APIs reject READY/ACTIVE.
- Personal copies create fresh V1 encrypted identities and leave the original intact; resource ACL continuation needs mapping and publication. Both ancestry drag paths stop before persistence when mapping or publication is missing.
- READY/ACTIVE policy writes require a reviewed encrypted generation publication path and remain blocked. ACTIVE fixture rendering does not establish real key delivery or usable cryptography.
- Production activation, migration, CEK delivery, Cloud deployment, public main change, release/feed update and official signing/notarization are outside this local evidence. Authenticated HTTPS staging and manual accessibility/VoiceOver acceptance require a separate authorized environment and Owner credentials.

## Draft PR #210 remainder

The [approved Access composition spec](../superpowers/specs/2026-09-30-access-sharing-production-design.md) and [V2 publication design](../superpowers/specs/2026-09-30-vault-v2-migration-publication-design.md) are the governing contracts. [Draft PR #210](https://github.com/PastFly/Selective-Remote/pull/210) remains a non-authoritative reference. The [source-linked remainder audit](../architecture/access-sharing-pr210-reference-audit.md) extracts its useful crypto, migration, registry and rollout topics for bounded follow-up. Recommend closure only after those inputs are accepted; do not merge its synthetic UI or close the PR automatically.
