#!/usr/bin/env bash
set -euo pipefail

# Safe, synthetic browser preflight. Never targets production or stores credentials.
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
mkdir -p qa-artifacts/browser

command -v playwright-cli
playwright-cli --help > qa-artifacts/browser/cli-help.txt
grep -q 'open' qa-artifacts/browser/cli-help.txt

python3 -m http.server 8765 --bind 127.0.0.1 --directory cloud/public \
  > qa-artifacts/browser/http-server.log 2>&1 &
server_pid=$!
trap 'playwright-cli close >/dev/null 2>&1 || true; kill "$server_pid" >/dev/null 2>&1 || true' EXIT

ready=no
for i in {1..25}; do
  if curl --fail --silent --show-error http://127.0.0.1:8765/ >/dev/null 2>&1; then
    ready=yes
    break
  fi
  sleep 1
done
test "$ready" = yes

export PLAYWRIGHT_CLI_SESSION=sr-cloud-offline-smoke
playwright-cli open http://127.0.0.1:8765/ --browser=chrome \
  > qa-artifacts/browser/open.log
playwright-cli snapshot --filename="$ROOT/qa-artifacts/browser/cloud-accessibility.yaml" \
  > qa-artifacts/browser/snapshot.log
playwright-cli screenshot --filename="$ROOT/qa-artifacts/browser/cloud-landing.png" \
  > qa-artifacts/browser/screenshot.log

test -s qa-artifacts/browser/cloud-accessibility.yaml
test -s qa-artifacts/browser/cloud-landing.png
grep -q 'Selective Remote Cloud' qa-artifacts/browser/cloud-accessibility.yaml

echo "PLAYWRIGHT_CLI_PREFLIGHT=PASS (browser/UI snapshot only, not registration or Cloud E2E)"
