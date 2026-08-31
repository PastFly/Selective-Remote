#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cloud_dir="$(cd -- "${script_dir}/.." && pwd -P)"

usage() {
    cat <<'USAGE'
Usage: start-staging-guarded.sh COMPOSE_FILE [COMPOSE_FILE ...]

Runs the PostgreSQL storage preflight, validates the merged Compose model and
then starts the supplied ordered Compose files. All POSTGRES_DATA_* settings
required by validate-postgres-storage.sh must already be exported.

Example:
  scripts/start-staging-guarded.sh \
    compose.yaml compose.443-only.yaml compose.postgres-bind.yaml
USAGE
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
    usage
    exit 0
fi
if [[ $# -lt 1 ]]; then
    usage >&2
    exit 64
fi

compose=(docker compose --project-directory "${cloud_dir}")
for compose_file in "$@"; do
    if [[ "${compose_file}" == /* ]]; then
        resolved_file="${compose_file}"
    else
        resolved_file="${cloud_dir}/${compose_file}"
    fi
    if [[ ! -f "${resolved_file}" || -L "${resolved_file}" ]]; then
        echo "Compose file must be an existing non-symlink file: ${compose_file}" >&2
        exit 64
    fi
    compose+=( -f "${resolved_file}" )
done

"${script_dir}/validate-postgres-storage.sh" --check
"${compose[@]}" config --quiet
"${compose[@]}" config --format json | node "${script_dir}/validate-postgres-bind-model.mjs"
exec "${compose[@]}" up -d
