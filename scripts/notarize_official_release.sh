#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo "Usage: notarize_official_release.sh <dmg>" >&2
    exit 64
fi

readonly dmg="$1"
readonly notary_profile="${SELECTIVEREMOTE_NOTARY_PROFILE:-}"

if [[ -z "$notary_profile" ]]; then
    echo "Official release requires a notarization Keychain profile." >&2
    exit 65
fi

xcrun notarytool submit "$dmg" \
    --keychain-profile "$notary_profile" \
    --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"

echo "Official notarization, stapling, and Gatekeeper validation passed."
