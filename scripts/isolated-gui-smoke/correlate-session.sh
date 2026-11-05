#!/bin/bash
set -euo pipefail
fixture="$(dirname "$0")"
port="$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $2}')"
if [[ -z "${SSH_ORIGINAL_COMMAND:-}" ]]; then
  kind=interactive
else
  hash="$(printf '%s' "$SSH_ORIGINAL_COMMAND" | shasum -a 256 | awk '{print $1}')"
  if [[ "$hash" = b857fa20c9a8fb92b87f14f2322c41b7e2c76ef0b0ca19adfae0e134494fa690 ]]; then kind=diagnostic; else kind=other; fi
fi
printf '%s %s %s %s\n' "$$" "$PPID" "$port" "$kind" >> "$fixture/correlation.log"
if [[ "$kind" = interactive ]]; then exec /bin/bash -l; fi
exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
