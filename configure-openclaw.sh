#!/usr/bin/env bash
# configure-openclaw.sh — Runs INSIDE the sandbox to configure openclaw.
#                         Copied into the sandbox image at /usr/local/bin/configure-openclaw by the Dockerfile.
#
# Preferred usage: from the host via run-setup.sh (handles SSH config + IP resolution):
#   source .env && bash run-setup.sh
#
# Manual interactive usage (from inside sandbox via `openshell sandbox connect <name>`):
#   export TELEGRAM_BOT_TOKEN="..." ALLOWED_CHAT_IDS="..." OLLAMA_MODEL="..." TELEGRAM_IP="..."
#   bash /usr/local/bin/configure-openclaw
#
# What it does:
#   1. Configures openclaw: Telegram channel, Ollama provider, SearXNG plugin, gateway mode
#   2. Fixes Telegram DNS: writes a static /etc/hosts entry so OpenShell's
#      mechanistic_mapper can resolve api.telegram.org (the sandbox nameserver
#      has no DNS on port 53, which blocks connections without this fix)
#   3. Starts the openclaw gateway as a background process
#
# Environment variables (required):
#   TELEGRAM_BOT_TOKEN  — from your .env file
#   ALLOWED_CHAT_IDS    — your Telegram user ID
#   OLLAMA_MODEL        — Ollama model to use (default: qwen3.5:9b)
#   OLLAMA_CONTEXT_LENGTH — context window size in tokens (default: 131072 / 128k)
#                           sets both openclaw's contextWindow (conversation budget) and
#                           num_ctx passed to Ollama (GPU memory allocation). Must match
#                           what Ollama is configured to support.
#   TELEGRAM_IP         — IP for api.telegram.org, resolved on the host before running
#                         (sandbox nameserver has no external DNS; run-setup.sh handles this)

set -euo pipefail

OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-131072}"

# ---------------------------------------------------------------------------
# [1/3] Configure openclaw
# ---------------------------------------------------------------------------
echo "==> [1/3] Configuring openclaw..."

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "  ERROR: TELEGRAM_BOT_TOKEN is not set" >&2
  exit 1
fi
if [[ -z "${ALLOWED_CHAT_IDS:-}" ]]; then
  echo "  ERROR: ALLOWED_CHAT_IDS is not set" >&2
  exit 1
fi

openclaw config set gateway.mode local
openclaw config set channels.telegram.enabled true
IFS=',' read -ra _CHAT_ID_ARRAY <<< "$ALLOWED_CHAT_IDS"
for _i in "${!_CHAT_ID_ARRAY[@]}"; do
  openclaw config set "channels.telegram.allowFrom.$_i" "${_CHAT_ID_ARRAY[$_i]// /}"
done
openclaw config set channels.telegram.dmPolicy allowlist
openclaw config set channels.telegram.botToken "$TELEGRAM_BOT_TOKEN"
# Write Ollama provider config and SearXNG plugin in a single Python pass.
# openclaw config set validates the full schema after each write, so we cannot
# set models.providers.ollama.baseUrl alone — the models[] array is required too.
# Writing the full provider object at once via Python avoids this.
python3 -c "
import json

with open('/sandbox/.openclaw/openclaw.json') as f:
    config = json.load(f)

config.setdefault('models', {}).setdefault('providers', {})['ollama'] = {
    'baseUrl': 'http://host.openshell.internal:11434',
    'api': 'ollama',
    'request': {'allowPrivateNetwork': True},
    'models': [{'id': '$OLLAMA_MODEL', 'name': '$OLLAMA_MODEL', 'api': 'ollama', 'contextWindow': $OLLAMA_CONTEXT_LENGTH}]
}
config.setdefault('agents', {}).setdefault('defaults', {}).setdefault('model', {})['primary'] = 'ollama/$OLLAMA_MODEL'
config.setdefault('plugins', {}).setdefault('entries', {})['searxng'] = {
    'enabled': True,
    'config': {'webSearch': {'baseUrl': 'http://host.openshell.internal:8888'}}
}

with open('/sandbox/.openclaw/openclaw.json', 'w') as f:
    json.dump(config, f, indent=2)
print('  Config updated.')
"
openclaw config validate

echo "  openclaw configured."

# ---------------------------------------------------------------------------
# [2/3] Fix Telegram DNS
# ---------------------------------------------------------------------------
# The sandbox nameserver has no DNS on port 53.
# OpenShell's mechanistic_mapper resolves hostnames to verify they're not
# internal IPs. DNS failure = connection blocked.
#
# Fix: add a static /etc/hosts entry. /etc/hosts must be in read_write in
# the sandbox policy for this to work.
#
# The sandbox nameserver cannot resolve external hostnames, so we accept the
# IP as TELEGRAM_IP env var (resolved on the host before running this script).
# Fallback: try dig/getent/python3 in case a future image has working DNS.
echo "==> [2/3] Fixing Telegram DNS..."
TGIP="${TELEGRAM_IP:-}"
if [[ -z "$TGIP" ]]; then
  TGIP=$(dig +short api.telegram.org A 2>/dev/null | grep -E '^[0-9]+\.' | head -1)
fi
if [[ -z "$TGIP" ]]; then
  TGIP=$(getent hosts api.telegram.org 2>/dev/null | awk '{print $1}' | head -1)
fi
if [[ -z "$TGIP" ]]; then
  TGIP=$(python3 -c "import socket; print(socket.gethostbyname('api.telegram.org'))" 2>/dev/null || true)
fi
if [[ -z "$TGIP" ]]; then
  echo "  ERROR: Could not resolve api.telegram.org — is DNS working?" >&2
  echo "  Resolve on the host and pass as TELEGRAM_IP env var:" >&2
  echo "    TELEGRAM_IP=\$(dig +short api.telegram.org A | grep -m1 '^[0-9]')" >&2
  exit 1
fi
# Remove any existing entry then add fresh
grep -v 'api.telegram.org' /etc/hosts > /tmp/hosts.new
cat /tmp/hosts.new > /etc/hosts
echo "$TGIP api.telegram.org" >> /etc/hosts
echo "  Added: $TGIP api.telegram.org"

# ---------------------------------------------------------------------------
# [3/3] Start gateway
# ---------------------------------------------------------------------------
echo "==> [3/3] Starting openclaw gateway..."
pkill -f "openclaw gateway run" 2>/dev/null || true
rm -f /tmp/gateway.log
setsid openclaw gateway run > /tmp/gateway.log 2>&1 < /dev/null &
echo "  Gateway PID: $!"
echo "  Log: /tmp/gateway.log"
echo ""
echo "Done. Watch for Telegram polling with: openshell logs --tail"
echo "Or inside the sandbox: tail -f /tmp/gateway.log"
