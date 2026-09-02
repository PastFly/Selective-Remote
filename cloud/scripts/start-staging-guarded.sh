#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cloud_dir="$(cd -- "${script_dir}/.." && pwd -P)"
readonly node_validator_image="node@sha256:1b2479dd35a99687d6638f5976fd235e26c5b37e8122f786fcd5fe231d63de5b"

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
compose_files=()
container_compose_files=()
compose_mounts=()
compose_index=0
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
    compose_files+=( "${resolved_file}" )
    container_file="/compose-input-${compose_index}.yaml"
    container_compose_files+=( "${container_file}" )
    compose_mounts+=(
        --mount "type=bind,src=${resolved_file},dst=${container_file},readonly"
    )
    ((compose_index += 1))
done

validator_container=(
    docker run --rm --pull=never --network none --read-only
    --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges
    --memory 128m --memory-swap 128m --cpus 0.5 --pids-limit 64
)

"${validator_container[@]}" \
    "${compose_mounts[@]}" \
    --mount "type=bind,src=${script_dir}/validate-postgres-bind-source.mjs,dst=/validator.mjs,readonly" \
    "${node_validator_image}" node /validator.mjs "${container_compose_files[@]}"
"${script_dir}/validate-postgres-storage.sh" --check
"${compose[@]}" config --quiet
"${compose[@]}" config --format json |
    "${validator_container[@]}" -i \
        --env "POSTGRES_DATA_HOST_PATH=${POSTGRES_DATA_HOST_PATH}" \
        --mount "type=bind,src=${script_dir}/validate-postgres-bind-model.mjs,dst=/validator.mjs,readonly" \
        "${node_validator_image}" node /validator.mjs
exec "${compose[@]}" up -d
