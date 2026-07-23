#!/usr/bin/env bash
# ponytail: loop-only pure mode avoids plugin/MCP startup on 1GB VPS; set OPENCODE_BIN to opt out.
set -euo pipefail

OPENCODE_REAL_BIN="$HOME/.opencode/bin/opencode"
ENV_FILE="$HOME/.env"

[ -x "$OPENCODE_REAL_BIN" ] || {
  echo "opencode-headless: missing executable: $OPENCODE_REAL_BIN" >&2
  exit 1
}
[ -r "$ENV_FILE" ] || {
  echo "opencode-headless: missing environment file: $ENV_FILE" >&2
  exit 1
}

set -a
. "$ENV_FILE"
set +a

[ -n "${VPS_GATEWAY_API_KEY:-}" ] || {
  echo "opencode-headless: VPS_GATEWAY_API_KEY is not set" >&2
  exit 1
}

if [ "${1:-}" = "--self-check" ]; then
  echo "opencode-headless: OK"
  exit 0
fi

exec "$OPENCODE_REAL_BIN" --pure "$@"
