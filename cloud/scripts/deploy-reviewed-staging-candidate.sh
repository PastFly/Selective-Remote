#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin
if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then
  echo 'Usage: deploy-reviewed-staging-candidate.sh prepare|backup|install [--dry-run] ABS_PLAN_JSON ABS_NODE_ARCHIVE'
  echo 'First provisioning only. Prepare does not alter live source, environment or traffic.'
  exit 0
fi
[[ ${EUID} -eq 0 ]] || { echo staging_install_owner >&2; exit 77; }
[[ $# -ge 3 && $# -le 4 ]] || { echo staging_install_arguments >&2; exit 64; }
phase=$1; shift
case "$phase" in prepare|backup|install) ;; *) echo staging_install_arguments >&2; exit 64;; esac
dry=()
if [[ ${1:-} == --dry-run ]]; then dry=(--dry-run); shift; fi
[[ $# -eq 2 && $1 == /* && $2 == /* ]] || { echo staging_install_arguments >&2; exit 64; }
plan=$1; archive=$2
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for file in "$plan" "$archive" "$script_dir/staging-reviewed-installer.mjs"; do
  [[ -f "$file" && ! -L "$file" && $(stat -c %u -- "$file") == 0 ]] || { echo staging_install_permissions >&2; exit 77; }
  [[ $(realpath -e -- "$file") == "$file" ]] || { echo staging_install_permissions >&2; exit 77; }
  parent=$(dirname -- "$file")
  while true; do
    [[ $(stat -c %u -- "$parent") == 0 ]] || { echo staging_install_permissions >&2; exit 77; }
    parent_mode=$(stat -c %a -- "$parent"); (( (8#$parent_mode & 0022) == 0 )) || { echo staging_install_permissions >&2; exit 77; }
    [[ $parent == / ]] && break
    parent=$(dirname -- "$parent")
  done
  mode=$(stat -c %a -- "$file"); (( (8#$mode & 0022) == 0 )) || { echo staging_install_permissions >&2; exit 77; }
done
[[ $(sha256sum -- "$archive" | cut -d' ' -f1) == c1bfeecf1d7404fa74728f9db72e697decbd8119ccc6f5a294d795756dfcfca7 ]] || { echo staging_install_runtime_digest >&2; exit 77; }
# Only a verified runtime is unpacked into disposable bootstrap scratch. No
# deployment/controller/state path is touched before the Node preflight passes.
umask 077
bootstrap=$(mktemp -d /tmp/pr-c-installer-runtime.XXXXXX)
trap 'rm -rf -- "$bootstrap"' EXIT
tar -xJf "$archive" -C "$bootstrap" node-v22.18.0-linux-x64/bin/node
"$bootstrap/node-v22.18.0-linux-x64/bin/node" "$script_dir/staging-reviewed-installer.mjs" "$phase" "${dry[@]}" "$plan" "$archive"
