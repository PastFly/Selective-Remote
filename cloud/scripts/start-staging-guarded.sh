#!/usr/bin/env bash
set -euo pipefail
if [[ $# -eq 1 && ( "$1" == --help || "$1" == -h ) ]]; then
  cat <<'USAGE'
Usage: start-staging-guarded.sh [--maintenance-upgrade]

Starts only the image and ordered Compose files pinned in the separately
installed root-owned /opt/selective-remote-controller/settings.json.
Explicit initial maintenance closes traffic before upgrading a pristine V1 DB.
USAGE
  exit 0
fi
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --maintenance-upgrade ) ]] || { echo invalid_deployment_arguments >&2; exit 64; }
# Ordered Compose inputs and all pins live in the separately retained root-owned
# settings. Arbitrary checkout arguments must not select an alternate start path.
exec /opt/selective-remote-controller/scripts/staging-controller.sh "$@"
