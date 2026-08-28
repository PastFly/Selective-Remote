#!/usr/bin/env bash
set -uo pipefail

audit_hostname="${1:-}"

if [[ $# -gt 1 || "${audit_hostname}" == "--help" || "${audit_hostname}" == "-h" ]]; then
    cat <<'USAGE'
Usage: audit-host-readonly.sh [public-hostname]

Prints a read-only Ubuntu host inventory for Selective Remote Cloud staging.
The script does not use sudo, read environment files, or change services,
containers, firewall rules, listeners, files, or network configuration.
USAGE
    [[ $# -le 1 ]] || exit 64
    exit 0
fi

if [[ -n "${audit_hostname}" ]]; then
    if [[ "${audit_hostname}" == -* || ${#audit_hostname} -gt 253 || ! "${audit_hostname}" =~ ^[A-Za-z0-9.-]+$ ]]; then
        echo "Invalid public hostname" >&2
        exit 64
    fi
fi

section() {
    echo
    echo "## $1"
}

command_state() {
    local name="$1"
    if command -v "${name}" >/dev/null 2>&1; then
        echo "${name}: available"
    else
        echo "${name}: unavailable"
    fi
}

echo "Selective Remote Cloud read-only host audit"
echo "Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

section "Operating system"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "OS: ${PRETTY_NAME:-unknown}"
else
    echo "OS: unknown"
fi
echo "Kernel: $(uname -srmo)"
echo "Architecture: $(uname -m)"

section "Capacity"
df -hP / 2>/dev/null || true
if command -v free >/dev/null 2>&1; then
    free -h 2>/dev/null || true
fi

section "Audit tools"
for tool in ss docker systemctl getent; do
    command_state "${tool}"
done

section "Listening sockets"
if command -v ss >/dev/null 2>&1; then
    ss -H -lntup 2>/dev/null || true
else
    echo "Socket inventory unavailable: install iproute2 to provide ss."
fi

tcp_80="unknown"
tcp_443="unknown"
udp_443="unknown"
if command -v ss >/dev/null 2>&1; then
    tcp_80="available"
    tcp_443="available"
    udp_443="available"
    ss -H -lnt '( sport = :80 )' 2>/dev/null | grep -q . && tcp_80="occupied"
    ss -H -lnt '( sport = :443 )' 2>/dev/null | grep -q . && tcp_443="occupied"
    ss -H -lnu '( sport = :443 )' 2>/dev/null | grep -q . && udp_443="occupied"
fi

section "Ingress summary"
echo "TCP 80: ${tcp_80}"
echo "TCP 443: ${tcp_443}"
echo "UDP 443: ${udp_443}"

section "Docker inventory"
if command -v docker >/dev/null 2>&1; then
    docker --version 2>/dev/null || true
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    echo
    docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}' 2>/dev/null || true
else
    echo "Docker is unavailable."
fi

section "Relevant running services"
if command -v systemctl >/dev/null 2>&1; then
    systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep -Ei '^(caddy|nginx|apache2?|docker|containerd|xray|amnezia|wg-quick|wireguard).*\.service$' \
        || true
else
    echo "systemd inventory unavailable."
fi

if [[ -n "${audit_hostname}" ]]; then
    section "Public hostname resolution"
    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "${audit_hostname}" 2>/dev/null || echo "No IPv4 result."
        getent ahostsv6 "${audit_hostname}" 2>/dev/null || echo "No IPv6 result."
    else
        echo "DNS inventory unavailable."
    fi
fi

section "Result"
if [[ "${tcp_443}" == "occupied" ]]; then
    echo "BLOCKER: TCP 443 is occupied. Do not start the bundled standalone Caddy service."
else
    echo "No TCP 443 listener was detected by this audit. Recheck immediately before deployment."
fi
echo "This report is inventory only; no host state was changed."
