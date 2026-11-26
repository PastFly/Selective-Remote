#!/usr/bin/env bash
set -euo pipefail
if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  echo 'Usage: staging-controller.sh [--maintenance-upgrade | --verify-installation | --upgrade-team-authorization | --verify-production-pair | --production-personal-pilot open PILOT OWNER VAULT MINUTES | --production-personal-pilot close PILOT]'
  echo 'Requires the separately provisioned root-owned controller and protected settings.'
  exit 0
fi
# Installed independently by the reviewed operator. Never execute the candidate's
# launcher/checker, and never initialize missing retained history here.
readonly root=/opt/selective-remote-controller
readonly runtime=runtime/node-v22.18.0-linux-x64/bin/node
[[ ${EUID} -eq 0 ]] || { echo deployment_controller_owner >&2; exit 77; }
[[ $# -eq 0 || ( $# -eq 1 && ( "$1" == --maintenance-upgrade || "$1" == --verify-installation || "$1" == --upgrade-team-authorization || "$1" == --verify-production-pair ) ) || ( $# -eq 3 && "$1" == --production-personal-pilot && "$2" == close ) || ( $# -eq 6 && "$1" == --production-personal-pilot && "$2" == open ) ]] || { echo invalid_deployment_arguments >&2; exit 64; }
cd "$root"
for path in /opt "$root" "$root/scripts" "$root/runtime" "$root/runtime/node-v22.18.0-linux-x64" "$root/runtime/node-v22.18.0-linux-x64/bin" "$root/$runtime" "$root/scripts/staging-controller.sh" "$root/scripts/verify-staging-controller.mjs" "$root/runtime-node.sha256" "$root/bundle.sha256" "$root/settings.json"; do
  [[ -e "$path" && ! -L "$path" && $(stat -c %u -- "$path") == 0 ]] || { echo deployment_controller_owner >&2; exit 77; }
  mode=$(stat -c %a -- "$path")
  (( (8#$mode & 0022) == 0 )) || { echo deployment_controller_permissions >&2; exit 77; }
done
sha256sum --strict --status -c runtime-node.sha256 || { echo deployment_runtime_digest >&2; exit 77; }
sha256sum --strict --status -c bundle.sha256 || { echo deployment_controller_digest >&2; exit 77; }
exec env -i PATH=/usr/bin:/bin "$root/$runtime" "$root/scripts/verify-staging-controller.mjs" "$@"
