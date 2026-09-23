#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
probe_id="$(uuidgen)"
filter='sshPasswordKeychainProcessBoundary'

run_stage() {
    SR_TEST_SSH_RELAUNCH_STAGE="$1" \
    SR_TEST_SSH_RELAUNCH_ID="$probe_id" \
        swift test --filter "$filter"
}

cleanup() {
    run_stage cleanup >/dev/null || true
}

cd "$repo_root"
trap cleanup EXIT
run_stage save
run_stage read
printf '%s\n' 'SSH_KEYCHAIN_PROCESS_REUSE=PASS'
