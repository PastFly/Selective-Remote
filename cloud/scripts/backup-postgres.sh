#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cloud_dir="$(cd -- "${script_dir}/.." && pwd -P)"

usage() {
    cat <<'USAGE'
Usage: backup-postgres.sh /absolute/private/backup-directory

Creates a PostgreSQL custom-format backup, validates it with pg_restore, and
writes a sibling SHA-256 checksum. The destination must already exist outside
the repository. Existing backups are never overwritten.
USAGE
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
    usage
    exit 0
fi

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 64
fi

backup_dir="$1"
if [[ "${backup_dir}" != /* ]]; then
    echo "Backup directory must be an absolute path." >&2
    exit 64
fi
if [[ ! -d "${backup_dir}" || -L "${backup_dir}" ]]; then
    echo "Backup destination must be an existing non-symlink directory." >&2
    exit 64
fi
backup_dir_mode="$(stat -c '%a' -- "${backup_dir}")"
if (( (8#${backup_dir_mode} & 077) != 0 )); then
    echo "Backup directory must not grant group or other permissions." >&2
    exit 77
fi
if [[ "$(stat -c '%u' -- "${backup_dir}")" != "$(id -u)" ]]; then
    echo "Backup directory must be owned by the current user." >&2
    exit 77
fi
if [[ "${backup_dir}" == "${cloud_dir}" || "${backup_dir}" == "${cloud_dir}/"* ]]; then
    echo "Backup destination must be outside the repository." >&2
    exit 64
fi
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose is required." >&2
    exit 69
fi

compose=(docker compose --project-directory "${cloud_dir}" -f "${cloud_dir}/compose.yaml")
if ! "${compose[@]}" exec -T postgres pg_isready >/dev/null 2>&1; then
    echo "The Compose PostgreSQL service is not ready." >&2
    exit 69
fi

umask 077
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="selective-remote-cloud-${timestamp}.dump"
backup_path="${backup_dir}/${backup_name}"
checksum_path="${backup_path}.sha256"

if [[ -e "${backup_path}" || -e "${checksum_path}" ]]; then
    echo "Refusing to overwrite an existing backup." >&2
    exit 73
fi

temporary_backup="$(mktemp "${backup_dir}/.selective-remote-cloud.XXXXXX")"
temporary_checksum="$(mktemp "${backup_dir}/.selective-remote-cloud-sha256.XXXXXX")"
cleanup() {
    rm -f -- "${temporary_backup}" "${temporary_checksum}"
}
trap cleanup EXIT INT TERM

"${compose[@]}" exec -T postgres sh -ceu \
    'exec pg_dump --format=custom --compress=9 --no-owner --no-privileges --username="$POSTGRES_USER" --dbname="$POSTGRES_DB"' \
    > "${temporary_backup}"

if [[ ! -s "${temporary_backup}" ]]; then
    echo "PostgreSQL returned an empty backup." >&2
    exit 74
fi

"${compose[@]}" exec -T postgres pg_restore --list < "${temporary_backup}" >/dev/null
chmod 600 "${temporary_backup}"
mv -- "${temporary_backup}" "${backup_path}"

(
    cd -- "${backup_dir}"
    sha256sum -- "${backup_name}" > "${temporary_checksum}"
)
chmod 600 "${temporary_checksum}"
mv -- "${temporary_checksum}" "${checksum_path}"

trap - EXIT INT TERM
echo "Backup created: ${backup_path}"
echo "Checksum created: ${checksum_path}"
