#!/usr/bin/env bash
set -euo pipefail

echo "Selective Remote Cloud deployment preflight"
echo

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    echo "OS: ${PRETTY_NAME:-unknown}"
else
    echo "OS: unknown"
fi

echo "Kernel: $(uname -srmo)"
echo "Architecture: $(uname -m)"
echo "Disk:"
df -h / | tail -n 1
echo "Memory:"
free -h | sed -n '1,2p'

if command -v docker >/dev/null 2>&1; then
    echo "Docker: $(docker --version)"
    if docker compose version >/dev/null 2>&1; then
        echo "Compose: $(docker compose version)"
    else
        echo "Compose: not installed"
    fi
else
    echo "Docker: not installed"
fi

echo "Listening TCP ports:"
ss -lntp 2>/dev/null | sed -n '1,80p' || true

if ss -H -lnt '( sport = :443 )' 2>/dev/null | grep -q .; then
    echo "BLOCKER: TCP port 443 is already listening; do not start the supplied Caddy service."
    ss -lntp '( sport = :443 )' 2>/dev/null || true
else
    echo "TCP port 443: available for the standalone Caddy design"
fi

if command -v ufw >/dev/null 2>&1; then
    echo "UFW:"
    ufw status verbose || true
else
    echo "UFW: not installed"
fi

echo "DNS from the server:"
getent ahostsv4 cloud.pastfly.ru || true

echo
echo "Preflight is read-only; no packages, firewall rules or services were changed."
