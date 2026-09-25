#!/bin/bash
set -euo pipefail

dmg="${1:?published DMG path is required}"
team_id="${SELECTIVEREMOTE_EXPECTED_TEAM_ID:?expected Team ID is required}"
identity="${SELECTIVEREMOTE_CODESIGN_IDENTITY:?Developer ID Application identity is required}"

if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ \
    || "$identity" != "Developer ID Application: "*"($team_id)" ]]; then
    echo "Published DMG verification requires the exact Developer ID identity and Team ID." >&2
    exit 1
fi

hdiutil verify "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg"

mount_root="$(mktemp -d "${TMPDIR:-/tmp}/sr-release-mounted.XXXXXX")"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        hdiutil detach "$mount_root" -force >/dev/null 2>&1 || true
    fi
    rmdir "$mount_root" >/dev/null 2>&1 || true
}
trap cleanup EXIT

hdiutil attach -readonly -nobrowse -mountpoint "$mount_root" "$dmg" >/dev/null
mounted=true
app="$mount_root/Selective Remote.app"
test -d "$app"

publisher_requirement="=anchor apple generic and identifier \"local.selectiveremote\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$team_id\""
codesign --verify --deep --strict -R "$publisher_requirement" "$app"
signature_info="$(codesign -d --verbose=4 "$app" 2>&1)"
printf '%s\n' "$signature_info" | grep -Fx "Authority=$identity" >/dev/null
printf '%s\n' "$signature_info" | grep -Fx "TeamIdentifier=$team_id" >/dev/null
spctl --assess --type execute --verbose=4 "$app"
