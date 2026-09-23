#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "$temporary_dir"' EXIT

if ! python3 -c 'import paramiko' >/dev/null 2>&1; then
    python3 -m pip install --disable-pip-version-check \
        --target "$temporary_dir/python" \
        -r "$repo_root/Tests/SSHPasswordE2E/requirements.txt" >/dev/null
    export PYTHONPATH="$temporary_dir/python${PYTHONPATH:+:$PYTHONPATH}"
fi

swiftc -parse-as-library -D SSH_ASKPASS_TESTING \
    "$repo_root/Native/SSHKeychainAskPass.swift" \
    -framework AppKit -framework Security \
    -o "$temporary_dir/SSHKeychainAskPass"

python3 "$repo_root/Tests/SSHPasswordE2E/run.py" \
    "$repo_root" "$temporary_dir/SSHKeychainAskPass"
