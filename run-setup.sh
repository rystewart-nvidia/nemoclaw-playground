#!/usr/bin/env bash
# run-setup.sh — Host-side script to configure and start the openclaw sandbox.
#
# Run this from the repo root after creating the sandbox:
#   bash run-setup.sh
# (sources .env automatically — no need to source it first)
#
# What it does:
#   1. Generates an SSH config for the sandbox (openshell sandbox ssh-config)
#   2. Uploads the current configure-openclaw.sh from the repo into the sandbox (always latest)
#   3. SSHes into the sandbox and runs the uploaded script with all required env vars
#
# Note: configure-openclaw.sh is also baked into the sandbox image at
# /usr/local/bin/configure-openclaw by the Dockerfile, but run-setup.sh uploads the repo
# version each time so you can iterate on it without rebuilding the image.
#
# Requires: .env with TELEGRAM_BOT_TOKEN, ALLOWED_CHAT_IDS set; SANDBOX_NAME, OLLAMA_MODEL optional
# Requires: openshell installed and sandbox already created (see README step 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source .env from repo root if it exists and values aren't already in the environment.
# set -a exports every variable that is assigned, so they're available to child processes.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

SANDBOX_NAME="${SANDBOX_NAME:-my-assistant}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3.5:9b}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-131072}"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "ERROR: TELEGRAM_BOT_TOKEN is not set. Fill it in .env or export it before running." >&2
  exit 1
fi
if [[ -z "${ALLOWED_CHAT_IDS:-}" ]]; then
  echo "ERROR: ALLOWED_CHAT_IDS is not set. Fill it in .env or export it before running." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Generate SSH config (always regenerate in case sandbox was recreated)
# ---------------------------------------------------------------------------
echo "==> Generating SSH config for sandbox '$SANDBOX_NAME'..."
SSH_CONF="/tmp/os-ssh-${SANDBOX_NAME}.conf"
openshell sandbox ssh-config "$SANDBOX_NAME" > "$SSH_CONF"
echo "    Config written to $SSH_CONF"

# ---------------------------------------------------------------------------
# Upload latest configure-openclaw.sh and run inside the sandbox
# ---------------------------------------------------------------------------
echo "==> Uploading configure-openclaw.sh to sandbox '$SANDBOX_NAME'..."
scp -F "$SSH_CONF" "$SCRIPT_DIR/configure-openclaw.sh" "openshell-$SANDBOX_NAME:/tmp/configure-openclaw.sh"

echo "==> Running configure-openclaw.sh inside sandbox '$SANDBOX_NAME'..."
ssh -F "$SSH_CONF" "openshell-$SANDBOX_NAME" \
  "TELEGRAM_BOT_TOKEN='$TELEGRAM_BOT_TOKEN' \
   ALLOWED_CHAT_IDS='$ALLOWED_CHAT_IDS' \
   OLLAMA_MODEL='$OLLAMA_MODEL' \
   OLLAMA_CONTEXT_LENGTH='$OLLAMA_CONTEXT_LENGTH' \
   bash /tmp/configure-openclaw.sh"

echo ""
echo "Setup complete. To watch Telegram polling: openshell logs --tail"
