#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cloud_dir="$(cd -- "${script_dir}/.." && pwd -P)"

usage() {
    cat <<'USAGE'
Usage: restore-postgres.sh --confirm-restore /absolute/path/backup.dump

Restores a validated custom-format backup into the Compose PostgreSQL service.
The Cloud service must already be stopped. This operation replaces database
objects and is intentionally blocked without the exact confirmation flag.
USAGE
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
    usage
    exit 0
fi

if [[ $# -ne 2 || "$1" != "--confirm-restore" ]]; then
    usage >&2
    exit 64
fi

backup_path="$2"
if [[ "${backup_path}" != /* || ! -f "${backup_path}" || -L "${backup_path}" ]]; then
    echo "Backup must be an absolute path to a regular non-symlink file." >&2
    exit 64
fi
checksum_path="${backup_path}.sha256"
if [[ ! -f "${checksum_path}" || -L "${checksum_path}" ]]; then
    echo "A regular sibling .sha256 file is required." >&2
    exit 65
fi
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose is required." >&2
    exit 69
fi

backup_dir="$(cd -- "$(dirname -- "${backup_path}")" && pwd -P)"
backup_name="$(basename -- "${backup_path}")"
if [[ ! "${backup_name}" =~ ^selective-remote-cloud-[0-9]{8}T[0-9]{6}Z\.dump$ ]]; then
    echo "Backup filename does not match the generated backup format." >&2
    exit 65
fi
read -r recorded_hash recorded_name < <(awk 'NR == 1 { print $1, $2 }' "${checksum_path}")
if [[ ! "${recorded_hash}" =~ ^[0-9a-f]{64}$ || "${recorded_name}" != "${backup_name}" ]]; then
    echo "Checksum file does not describe the selected backup." >&2
    exit 65
fi
(
    cd -- "${backup_dir}"
    sha256sum --check --status -- "${backup_name}.sha256"
) || {
    echo "Backup checksum verification failed." >&2
    exit 65
}

compose=(docker compose --project-directory "${cloud_dir}" -f "${cloud_dir}/compose.yaml")
running_services="$("${compose[@]}" ps --status running --services 2>/dev/null || true)"
if grep -Fxq "cloud" <<< "${running_services}"; then
    echo "Stop the Cloud service before restoring the database." >&2
    exit 75
fi
if ! grep -Fxq "postgres" <<< "${running_services}"; then
    echo "The PostgreSQL service must be running for restore." >&2
    exit 69
fi

"${compose[@]}" exec -T postgres pg_restore --list < "${backup_path}" >/dev/null

echo "Checksum and archive format verified; restoring database objects."
"${compose[@]}" exec -T postgres sh -ceu \
    'exec pg_restore --clean --if-exists --no-owner --no-privileges --exit-on-error --single-transaction --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' \
    < "${backup_path}"

echo "Restore completed. Start Cloud, verify migrations, health and application data."
