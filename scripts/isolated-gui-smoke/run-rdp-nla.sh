#!/bin/bash
set -euo pipefail

test "${GITHUB_ACTIONS:-}" = true
test "${RUNNER_ENVIRONMENT:-}" = github-hosted
test "${USER:-}" = runner
fixture="$RUNNER_TEMP/nla-fixture"
mount="$RUNNER_TEMP/nla-mount"
mkdir -m 700 "$fixture" "$mount"
app_pid=''
server_pid=''
cleanup() {
  local result=$?
  if [[ "$result" -ne 0 ]]; then screencapture -x "$RUNNER_TEMP/evidence/failure-screen.png" || true; fi
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; fi
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  hdiutil detach "$mount" >> "$RUNNER_TEMP/evidence/mount.log" 2>&1 || true
}
trap cleanup EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -keyout "$fixture/key.pem" -out "$fixture/cert.pem" > /dev/null 2>&1
chmod 600 "$fixture/key.pem"
images=("$RUNNER_TEMP"/candidate/*.dmg)
test "${#images[@]}" -eq 1
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "${images[0]}" > "$RUNNER_TEMP/evidence/mount.log"
app="$mount/Selective Remote.app"
codesign --verify --deep --strict "$app"
executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
binary="$app/Contents/MacOS/$executable"
test "$bundle" = local.selectiveremote || { printf 'unexpected bundle id\n' >&2; exit 1; }
shasum -a 256 "$binary" > "$RUNNER_TEMP/evidence/executable-sha256.txt"
cp scripts/isolated-gui-smoke/probe.swift "$RUNNER_TEMP/main.swift"
swiftc "$RUNNER_TEMP/main.swift" scripts/isolated-gui-smoke/KeyboardMap.swift -o "$RUNNER_TEMP/gui-app-probe"
swiftc scripts/isolated-gui-smoke/verify-rdp-pattern.swift -o "$RUNNER_TEMP/verify-rdp-pattern"
server="$RUNNER_TEMP/ironrdp/target/debug/examples/server"
policy='(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:3389"))'
server_policy='(version 1)(allow default)(deny network-inbound)(deny network-outbound)(allow network-inbound (local ip "localhost:3389"))'
for scenario in invalid valid; do
  # Disposable hosted runner, this domain is freshly created by this probe only.
  if defaults read "$bundle" >/dev/null 2>&1; then
    if [[ "$scenario" = invalid ]]; then printf 'synthetic defaults domain not empty\n' >&2; exit 1; fi
    defaults delete "$bundle"
  fi
  expected_secret='TEST-ONLY-CODEX-RDP-SECRET'
  if [[ "$scenario" = invalid ]]; then expected_secret='TEST-ONLY-CODEX-INCORRECT-SECRET'; fi
  IRONRDP_LOG=info sandbox-exec -p "$server_policy" "$server" --bind-addr 127.0.0.1:3389 --cert "$fixture/cert.pem" --key "$fixture/key.pem" \
    --sec hybrid --user test --pass "$expected_secret" > "$fixture/$scenario-server.log" 2>&1 &
  server_pid=$!
  for _ in {1..45}; do
    kill -0 "$server_pid" || { printf 'synthetic server exited\n' >&2; exit 1; }
    if lsof -nP -a -p "$server_pid" -iTCP:3389 -sTCP:LISTEN | grep -q '127.0.0.1:3389'; then break; fi
    sleep 1
  done
  lsof -nP -a -p "$server_pid" -iTCP:3389 -sTCP:LISTEN | grep -q '127.0.0.1:3389'
  sandbox-exec -p "$policy" "$binary" > "$fixture/$scenario-app.log" 2>&1 &
  app_pid=$!
  sleep 12
  kill -0 "$app_pid"
  SR_BUILD_KIND=network SR_EXPECTED_EXECUTABLE="$binary" SR_EXPECTED_HASH="$(shasum -a 256 "$binary" | cut -d ' ' -f 1)" \
    python3 scripts/isolated-gui-smoke/run-bounded.py 90 "$RUNNER_TEMP/gui-app-probe" "$app_pid" --double-click-rdp > "$RUNNER_TEMP/evidence/$scenario-ui.log"
  if [[ "$scenario" = invalid ]]; then
    for _ in {1..30}; do
      if grep -Eiq 'invalid credentials|logon.failure|logon.denied|wrong.password|credentials.rejected' "$fixture/$scenario-server.log"; then break; fi
      sleep 1
    done
    if ! grep -Eiq 'invalid credentials|logon.failure|logon.denied|wrong.password|credentials.rejected' "$fixture/$scenario-server.log"; then
      sed -E 's/TEST-ONLY-CODEX-[A-Z-]+/[SYNTHETIC-REDACTED]/g' "$fixture/$scenario-server.log" > "$RUNNER_TEMP/evidence/invalid-server-diagnostic.log"
      printf 'no server evidence of rejected credentials\n' >&2
      exit 1
    fi
    if grep -q SYNTHETIC_RDP_PATTERN_UPDATE "$fixture/$scenario-server.log"; then printf 'invalid credentials reached display\n' >&2; exit 1; fi
    printf 'SYNTHETIC_RDP_NLA_WRONG_PASSWORD_REJECTED=YES\n' | tee "$RUNNER_TEMP/evidence/invalid-result.txt"
  else
    for _ in {1..45}; do
      if grep -q SYNTHETIC_RDP_PATTERN_UPDATE "$fixture/$scenario-server.log"; then break; fi
      sleep 1
    done
    grep -q SYNTHETIC_RDP_PATTERN_UPDATE "$fixture/$scenario-server.log"
    connected=''
    for _ in {1..20}; do
      for child in $(pgrep -P "$app_pid" || true); do
        command=$(ps -p "$child" -o comm=)
        if [[ "$command" == *SelectiveRemoteSession ]] && lsof -nP -a -p "$child" -iTCP -sTCP:ESTABLISHED | grep -q '127.0.0.1:3389'; then connected="$child"; fi
      done
      [[ -z "$connected" ]] || break
      sleep 1
    done
    test -n "$connected"
    lsof -nP -a -p "$connected" -iTCP -sTCP:ESTABLISHED > "$RUNNER_TEMP/evidence/valid-client-socket.txt"
    for _ in {1..15}; do
      screencapture -x "$RUNNER_TEMP/evidence/rdp-screen.png"
      if "$RUNNER_TEMP/verify-rdp-pattern" "$RUNNER_TEMP/evidence/rdp-screen.png" > "$RUNNER_TEMP/evidence/rdp-rendered.txt"; then break; fi
      sleep 2
    done
    grep -Fx 'SYNTHETIC_RDP_PATTERN_RENDERED=YES' "$RUNNER_TEMP/evidence/rdp-rendered.txt"
    printf 'SYNTHETIC_RDP_NLA_AUTHENTICATED_DISPLAY=YES\n' | tee "$RUNNER_TEMP/evidence/valid-result.txt"
  fi
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" || true
  app_pid=''
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" || true
  server_pid=''
done
