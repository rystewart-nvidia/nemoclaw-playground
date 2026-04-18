#!/usr/bin/env bash
# configure-openclaw.sh — Runs INSIDE the sandbox to configure openclaw.
#                         Copied into the sandbox image at /usr/local/bin/configure-openclaw by the Dockerfile.
#
# Preferred usage: from the host via run-setup.sh (handles SSH config generation):
#   source .env && bash run-setup.sh
#
# Manual interactive usage (from inside sandbox via `openshell sandbox connect <name>`):
#   export TELEGRAM_BOT_TOKEN="..." ALLOWED_CHAT_IDS="..." OLLAMA_MODEL="..."
#   bash /usr/local/bin/configure-openclaw
#
# What it does:
#   1. Writes openclaw.json in a single Python pass: gateway mode, Telegram channel, Ollama provider, SearXNG plugin
#   2. Starts the openclaw gateway as a background process
#
# Environment variables (required):
#   TELEGRAM_BOT_TOKEN  — from your .env file
#   ALLOWED_CHAT_IDS    — your Telegram user ID
#   OLLAMA_MODEL        — Ollama model to use (default: qwen3.5:9b)
#   OLLAMA_CONTEXT_LENGTH — context window size in tokens (default: 131072 / 128k)
#                           sets both openclaw's contextWindow (conversation budget) and
#                           num_ctx passed to Ollama (GPU memory allocation). Must match
#                           what Ollama is configured to support.

set -euo pipefail

OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-131072}"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN is not set" >&2
  exit 1
fi
if [[ -z "${ALLOWED_CHAT_IDS:-}" ]]; then
  echo "ERROR: ALLOWED_CHAT_IDS is not set" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# [1/2] Configure openclaw
# ---------------------------------------------------------------------------
echo "==> [1/2] Configuring openclaw..."

python3 << 'PYEOF'
import json, os

config_path = '/sandbox/.openclaw/openclaw.json'
try:
    with open(config_path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}

# Run the gateway in local mode (no cloud relay)
config.setdefault('gateway', {})['mode'] = 'local'

# Telegram channel: enable, set bot token, restrict to allowlisted chat IDs
config.setdefault('channels', {})['telegram'] = {
    'enabled': True,
    'botToken': os.environ['TELEGRAM_BOT_TOKEN'],
    'allowFrom': [id.strip() for id in os.environ['ALLOWED_CHAT_IDS'].split(',')],
    'dmPolicy': 'allowlist',
}

# Ollama provider: point at the host Ollama instance via the openshell internal hostname
ollama_model = os.environ['OLLAMA_MODEL']
ollama_ctx = int(os.environ['OLLAMA_CONTEXT_LENGTH'])
config.setdefault('models', {}).setdefault('providers', {})['ollama'] = {
    'baseUrl': 'http://host.openshell.internal:11434',
    'api': 'ollama',
    'models': [{'id': ollama_model, 'name': ollama_model, 'api': 'ollama', 'contextWindow': ollama_ctx}]
}
# Set the Ollama model as the default for all agents
config.setdefault('agents', {}).setdefault('defaults', {}).setdefault('model', {})['primary'] = f'ollama/{ollama_model}'

# SearXNG plugin: point at the host SearXNG instance for web search
config.setdefault('plugins', {}).setdefault('entries', {})['searxng'] = {
    'enabled': True,
    'config': {'webSearch': {'baseUrl': 'http://host.openshell.internal:8888'}}
}

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
print('  Config updated.')
PYEOF

openclaw config validate
echo "  openclaw configured."

# ---------------------------------------------------------------------------
# [2/2] Start gateway
# ---------------------------------------------------------------------------
echo "==> [2/2] Starting openclaw gateway..."
pkill -f "openclaw gateway run" 2>/dev/null || true
rm -f /tmp/gateway.log
setsid openclaw gateway run > /tmp/gateway.log 2>&1 < /dev/null &
echo "  Gateway PID: $!"
echo "  Log: /tmp/gateway.log"
echo ""
echo "Done. Watch for Telegram polling with: openshell logs --tail"
echo "Or inside the sandbox: tail -f /tmp/gateway.log"
