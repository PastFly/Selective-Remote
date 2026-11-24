#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf '%s\n' 'Usage: bash verify-named-ingress.sh [expected IPv4]' >&2
}

if (( $# > 1 )); then
  usage
  exit 2
fi
expected_address=${1:-185.9.25.50}
python3 - "$expected_address" <<'PY'
import ipaddress
import sys

try:
    ipaddress.IPv4Address(sys.argv[1])
except ipaddress.AddressValueError:
    raise SystemExit("Expected a valid IPv4 address.")
PY

origin='https://pr255-staging.pastfly.ru:8443'
index_sha='d631c7093dc8413eeb4eccfd0d9c258c9f433c6d1714553660e165f4ced1db57'
temp_directory=$(mktemp -d)
trap 'rm -rf -- "$temp_directory"' EXIT

fetch() {
  local mode=$1 path=$2 name=$3 expected_version=$4
  local result
  if ! result=$(env -u CURL_CA_BUNDLE -u SSL_CERT_FILE -u SSL_CERT_DIR \
    curl --disable --silent --show-error --fail --noproxy '*' --ipv4 \
      --proto '=https' --tlsv1.2 --connect-timeout 5 --max-time 12 \
      "$mode" --dump-header "$temp_directory/$name.headers" \
      --output "$temp_directory/$name.body" \
      --write-out '%{http_code} %{http_version} %{remote_ip}' "$origin$path"); then
    printf 'HTTPS request failed for %s (%s).\n' "$path" "$mode" >&2
    return 1
  fi
  if [[ "$result" != "200 $expected_version $expected_address" ]]; then
    printf 'Unexpected status, HTTP version or remote IP for %s (%s).\n' "$path" "$mode" >&2
    return 1
  fi
}

fetch --http1.1 /readyz ready_h1 '1.1'
fetch --http2 /readyz ready_h2 '2'
fetch --http2 /v1/meta meta '2'
fetch --http2 / index '2'

python3 - "$temp_directory" "$index_sha" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def require(ok, message):
    if not ok:
        raise SystemExit(message)

def body(label):
    return json.loads((root / (label + ".body")).read_bytes())

for label in ("ready_h1", "ready_h2"):
    require(body(label).get("status") == "ready", f"{label} did not report ready.")

meta = body("meta")
require(meta.get("registrationEnabled") is False, "Registration is not closed.")
require(meta.get("apiVersion") == 1 and meta.get("vaultSchemaVersion") == 1,
        "Unexpected API or Vault schema version.")
raw_headers = (root / "meta.headers").read_text(encoding="iso-8859-1")
headers = {}
for line in raw_headers.splitlines():
    if ":" in line:
        key, value = line.split(":", 1)
        headers.setdefault(key.strip().lower(), []).append(value.strip())
require(headers.get("x-selective-v1-write-fence") == ["1"], "V1 writer fence is absent.")
require(headers.get("x-selective-v1-write-status") == ["vault_write_temporarily_unavailable"],
        "V1 writer does not report the expected closed state.")
require("x-selective-personal-vault-write-status" not in headers, "Personal test pilot is active.")
actual_sha = hashlib.sha256((root / "index.body").read_bytes()).hexdigest()
require(actual_sha == sys.argv[2], "Frontend index does not match PR #255.")
print("PASS: system-trusted HTTPS, HTTP/1.1, HTTP/2, ready, closed write gates, exact PR #255 index.")
PY
