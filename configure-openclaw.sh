#!/usr/bin/env bash
# configure-openclaw.sh — Runs INSIDE the sandbox to configure openclaw.
#                         Copied into the sandbox image at /usr/local/bin/configure-openclaw by the Dockerfile.
#
# Preferred usage: from the host via run-setup.sh (handles SSH config generation and gateway start):
#   source .env && bash run-setup.sh
#
# Manual interactive usage (from inside sandbox via `openshell sandbox connect <name>`):
#   export TELEGRAM_BOT_TOKEN="..." ALLOWED_CHAT_IDS="..." OLLAMA_MODEL="..."
#   bash /usr/local/bin/configure-openclaw
#
# What it does:
#   Writes openclaw.json in a single Python pass: gateway mode, Telegram channel, Ollama provider, SearXNG plugin
#   (Gateway start is handled separately by run-setup.sh after workspace restore)
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
# Configure openclaw
# ---------------------------------------------------------------------------
echo "==> Configuring openclaw..."

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
# Append a path reminder to AGENTS.md so the model doesn't prefix write paths
# with the full workspace directory (which creates a double-nested structure).
WORKSPACE_DIR="/sandbox/.openclaw/workspace"
AGENTS_MD="$WORKSPACE_DIR/AGENTS.md"
PATH_GUIDANCE="
## File Paths
When writing workspace files, use either:
- **Just the filename:** \`USER.md\`, \`IDENTITY.md\`
- **Full absolute path:** \`/sandbox/.openclaw/workspace/USER.md\`

Do NOT use a bare relative path like \`sandbox/.openclaw/workspace/USER.md\` (no leading slash) — that resolves relative to the workspace root and creates a double-nested directory."

if [[ -f "$AGENTS_MD" ]] && ! grep -qF "$PATH_GUIDANCE" "$AGENTS_MD"; then
  printf '%s\n' "$PATH_GUIDANCE" >> "$AGENTS_MD"
  echo "  AGENTS.md updated with path guidance."
fi

echo "  openclaw configured."
