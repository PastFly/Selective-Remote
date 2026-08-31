#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: validate-postgres-storage.sh --check|--prepare

Required environment (non-secret):
  POSTGRES_DATA_MOUNT_ROOT       dedicated mounted filesystem root
  POSTGRES_DATA_HOST_PATH        direct child used as PostgreSQL data directory
  POSTGRES_DATA_EXPECTED_SOURCE  expected block/LVM device path
  POSTGRES_DATA_EXPECTED_FSTYPE  expected filesystem type, for example ext4
  POSTGRES_DATA_UID              numeric postgres UID from the reviewed image
  POSTGRES_DATA_GID              numeric postgres GID from the reviewed image

--check validates an already prepared path without changing it.
--prepare creates only the missing direct-child data directory after every
mount/device/filesystem check passes. It refuses existing wrong ownership and
never changes the mount root recursively.
USAGE
}

stat_device() {
    if stat -c '%d' -- "$1" >/dev/null 2>&1; then
        stat -c '%d' -- "$1"
    else
        stat -f '%d' -- "$1"
    fi
}

stat_uid() {
    if stat -c '%u' -- "$1" >/dev/null 2>&1; then
        stat -c '%u' -- "$1"
    else
        stat -f '%u' -- "$1"
    fi
}

stat_gid() {
    if stat -c '%g' -- "$1" >/dev/null 2>&1; then
        stat -c '%g' -- "$1"
    else
        stat -f '%g' -- "$1"
    fi
}

stat_mode() {
    if stat -c '%a' -- "$1" >/dev/null 2>&1; then
        stat -c '%a' -- "$1"
    else
        stat -f '%Lp' -- "$1"
    fi
}

if [[ $# -eq 1 && ( "$1" == "--help" || "$1" == "-h" ) ]]; then
    usage
    exit 0
fi
if [[ $# -ne 1 || ( "$1" != "--check" && "$1" != "--prepare" ) ]]; then
    usage >&2
    exit 64
fi
mode="$1"

required=(
    POSTGRES_DATA_MOUNT_ROOT
    POSTGRES_DATA_HOST_PATH
    POSTGRES_DATA_EXPECTED_SOURCE
    POSTGRES_DATA_EXPECTED_FSTYPE
    POSTGRES_DATA_UID
    POSTGRES_DATA_GID
)
for name in "${required[@]}"; do
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required setting: ${name}" >&2
        exit 64
    fi
done

mount_root="${POSTGRES_DATA_MOUNT_ROOT%/}"
data_path="${POSTGRES_DATA_HOST_PATH%/}"
expected_source="${POSTGRES_DATA_EXPECTED_SOURCE}"
expected_fstype="${POSTGRES_DATA_EXPECTED_FSTYPE}"
expected_uid="${POSTGRES_DATA_UID}"
expected_gid="${POSTGRES_DATA_GID}"

if [[ "${mount_root}" != /* || "${data_path}" != /* || "${expected_source}" != /* ]]; then
    echo "Mount root, data path and expected source must be absolute." >&2
    exit 64
fi
if [[ "${mount_root}" == "/" || "${data_path}" == "/" ]]; then
    echo "Root filesystem paths are not valid PostgreSQL storage targets." >&2
    exit 64
fi
if [[ "$(dirname -- "${data_path}")" != "${mount_root}" ]]; then
    echo "PostgreSQL data path must be a direct child of the mount root." >&2
    exit 64
fi
if [[ ! "${expected_uid}" =~ ^[0-9]+$ || ! "${expected_gid}" =~ ^[0-9]+$ ]]; then
    echo "PostgreSQL UID and GID must be numeric." >&2
    exit 64
fi
if [[ ! -d "${mount_root}" || -L "${mount_root}" ]]; then
    echo "Mount root must be an existing non-symlink directory." >&2
    exit 72
fi
if [[ "$(readlink -f -- "${mount_root}")" != "${mount_root}" ]]; then
    echo "Mount root must not traverse symlinks." >&2
    exit 72
fi
if ! mountpoint -q -- "${mount_root}"; then
    echo "Dedicated PostgreSQL filesystem is not mounted." >&2
    exit 72
fi

actual_target="$(findmnt -nr -M "${mount_root}" -o TARGET)"
actual_source="$(findmnt -nr -M "${mount_root}" -o SOURCE)"
actual_fstype="$(findmnt -nr -M "${mount_root}" -o FSTYPE)"
actual_options="$(findmnt -nr -M "${mount_root}" -o OPTIONS)"
if [[ "${actual_target}" != "${mount_root}" ]]; then
    echo "Mount lookup did not resolve to the exact mount root." >&2
    exit 72
fi
if [[ "${actual_fstype}" != "${expected_fstype}" ]]; then
    echo "PostgreSQL filesystem type does not match the reviewed value." >&2
    exit 72
fi
case ",${actual_options}," in
    *,rw,*) ;;
    *) echo "PostgreSQL filesystem is not writable." >&2; exit 72 ;;
esac

resolved_actual_source="$(readlink -f -- "${actual_source}")"
resolved_expected_source="$(readlink -f -- "${expected_source}")"
if [[ -z "${resolved_actual_source}" || "${resolved_actual_source}" != "${resolved_expected_source}" ]]; then
    echo "Mounted PostgreSQL device does not match the reviewed source." >&2
    exit 72
fi

if [[ -L "${data_path}" ]]; then
    echo "PostgreSQL data path must not be a symlink." >&2
    exit 72
fi
if [[ ! -e "${data_path}" ]]; then
    if [[ "${mode}" != "--prepare" ]]; then
        echo "PostgreSQL data path is missing; run explicit preparation first." >&2
        exit 72
    fi
    if [[ "${EUID}" -ne 0 ]]; then
        echo "Preparation must run as root." >&2
        exit 77
    fi
    install -d -m 0700 -o "${expected_uid}" -g "${expected_gid}" -- "${data_path}"
fi
if [[ ! -d "${data_path}" || -L "${data_path}" ]]; then
    echo "PostgreSQL data path must be a non-symlink directory." >&2
    exit 72
fi
if [[ "$(readlink -f -- "${data_path}")" != "${data_path}" ]]; then
    echo "PostgreSQL data path must not traverse symlinks." >&2
    exit 72
fi
if [[ "$(findmnt -nr -T "${data_path}" -o TARGET)" != "${mount_root}" ]]; then
    echo "PostgreSQL data path is not on the reviewed mount." >&2
    exit 72
fi
if [[ "$(stat_device "${data_path}")" != "$(stat_device "${mount_root}")" ]]; then
    echo "PostgreSQL data path is on a different filesystem." >&2
    exit 72
fi
if [[ "$(stat_uid "${data_path}")" != "${expected_uid}" || \
      "$(stat_gid "${data_path}")" != "${expected_gid}" ]]; then
    echo "PostgreSQL data path ownership does not match the reviewed image." >&2
    exit 77
fi
if [[ "$(stat_mode "${data_path}")" != "700" ]]; then
    echo "PostgreSQL data path mode must be 0700." >&2
    exit 77
fi

echo "POSTGRES_STORAGE_OK: reviewed mount and data path are ready"
