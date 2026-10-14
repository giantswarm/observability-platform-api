#!/usr/bin/env bash
#
# Gets a Dex ID token through the OAuth2 device-code flow and prints it to stdout.
# Prompts go to stderr.
#
# Usage: BASE_URL=https://observability.<codename>.<base-domain> dex-token.sh
#
# Environment:
#   BASE_URL       API base URL, used to derive DEX_URL (required unless DEX_URL is set)
#   DEX_URL        Dex issuer URL (default: BASE_URL with observability. replaced by dex.)
#   DEX_CLIENT_ID  Public Dex client (default: zQiFLUnrTFQwrybYzeY53hWWfhOKWRAU)

set -euo pipefail

if [ -z "${DEX_URL:-}" ]; then
  : "${BASE_URL:?BASE_URL or DEX_URL is required}"
  DEX_URL="${BASE_URL/\/\/observability./\/\/dex.}"
fi
DEX_URL="${DEX_URL%/}"
DEX_CLIENT_ID="${DEX_CLIENT_ID:-zQiFLUnrTFQwrybYzeY53hWWfhOKWRAU}"

device="$(curl -sSf "$DEX_URL/device/code" \
  -d client_id="$DEX_CLIENT_ID" -d scope="openid email groups profile")"
device_code="$(echo "$device" | jq -r .device_code)"
interval="$(echo "$device" | jq -r '.interval // 5')"
deadline=$(( $(date +%s) + $(echo "$device" | jq -r '.expires_in // 300') ))

echo "Log in at: $(echo "$device" | jq -r .verification_uri_complete)" >&2

while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep "$interval"
  response="$(curl -sS -m 10 "$DEX_URL/token" -d client_id="$DEX_CLIENT_ID" \
    -d grant_type=urn:ietf:params:oauth:grant-type:device_code \
    -d device_code="$device_code" || true)"
  if echo "$response" | jq -e .id_token >/dev/null 2>&1; then
    echo "$response" | jq -r .id_token
    exit 0
  fi
  error="$(echo "$response" | jq -r '.error // empty' 2>/dev/null || true)"
  case "$error" in
    authorization_pending|slow_down|"") ;;
    *) echo "Dex error: $response" >&2; exit 1 ;;
  esac
done

echo "Device code expired" >&2
exit 1
