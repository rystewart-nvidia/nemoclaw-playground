#!/usr/bin/env bash
# Start the openclaw gateway inside the sandbox.
# Usage: ./scripts/start-gateway.sh [sandbox-name]
#
# Run this after telegram-setup.sh. The gateway runs persistently inside the sandbox
# and handles all channel connections (Telegram, Discord, etc.).
#
# To verify after starting:
#   openshell logs --tail   # watch for getUpdates polls to api.telegram.org

set -euo pipefail

SANDBOX="${1:-my-assistant}"

PROXY_CMD=$(openshell sandbox ssh-config "$SANDBOX" | grep ProxyCommand | sed 's/.*ProxyCommand //')
if [[ -z "$PROXY_CMD" ]]; then
  echo "Error: could not get ProxyCommand for sandbox '$SANDBOX'" >&2
  exit 1
fi

echo "==> Starting openclaw gateway in sandbox '$SANDBOX'..."
ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o "ProxyCommand=$PROXY_CMD" \
  -l sandbox localhost \
  'nohup openclaw gateway run > /tmp/gateway.log 2>&1 & echo "Gateway PID: $!"'

echo ""
echo "==> Checking channel status..."
sleep 2
ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o "ProxyCommand=$PROXY_CMD" \
  -l sandbox localhost \
  'openclaw channels status'

echo ""
echo "To watch Telegram polling: openshell logs --tail"
