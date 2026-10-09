#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin
if [[ $# -eq 1 && ( $1 == --help || $1 == -h ) ]]; then
  echo 'Usage: staging-migration-operator.sh [--activation-fault before_commit|after_commit] < protected-scoped-request.json'
  echo 'Uses only the installed controller identity and root-provisioned operator scope.'
  exit 0
fi
[[ ${EUID} -eq 0 && ( $# -eq 0 || ( $# -eq 2 && $1 == --activation-fault && ( $2 == before_commit || $2 == after_commit ) ) ) ]] || { echo staging_operator_arguments >&2; exit 77; }
readonly root=/opt/selective-remote-controller
cd "$root"
for file in settings.json runtime-node.sha256 bundle.sha256 scripts/staging-migration-operator-helper.mjs; do
  [[ -f "$file" && ! -L "$file" && $(stat -c %u -- "$file") == 0 ]] || { echo staging_operator_permissions >&2; exit 77; }
  mode=$(stat -c %a -- "$file"); (( (8#$mode & 0022) == 0 )) || { echo staging_operator_permissions >&2; exit 77; }
done
sha256sum --strict --status -c runtime-node.sha256 || { echo staging_operator_runtime_digest >&2; exit 77; }
sha256sum --strict --status -c bundle.sha256 || { echo staging_operator_controller_digest >&2; exit 77; }
exec env -i PATH=/usr/bin:/bin "$root/runtime/node-v22.18.0-linux-x64/bin/node" "$root/scripts/staging-migration-operator-helper.mjs" "$@"
