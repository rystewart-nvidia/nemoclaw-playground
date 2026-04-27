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
#   4. Optionally restores workspace from a backup
#   5. Starts the openclaw gateway (after restore, so it reads the correct workspace files)
#
# Options:
#   --from-backup [timestamp]  Restore workspace after setup without prompting.
#                              Uses most recent backup if no timestamp given.
#   --no-restore               Skip backup restore prompt entirely.
#   --regenerate-ssh           Auto-confirm SSH config regeneration if it already exists.
#
# Note: configure-openclaw.sh is also baked into the sandbox image at
# /usr/local/bin/configure-openclaw by the Dockerfile, but run-setup.sh uploads the repo
# version each time so you can iterate on it without rebuilding the image.
#
# Requires: .env with TELEGRAM_BOT_TOKEN, ALLOWED_CHAT_IDS set; SANDBOX_NAME, OLLAMA_MODEL optional
# Requires: openshell installed and sandbox already created (see README step 5)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------
start_gateway() {
  echo "==> Restarting openclaw gateway..."
  ssh -F "$SSH_CONF" "openshell-$SANDBOX_NAME" bash << 'ENDSSH'
    openclaw gateway stop >/dev/null 2>&1 || true
    kill -9 $(pgrep -f "openclaw gateway" 2>/dev/null) 2>/dev/null || true
    sleep 1
    rm -f /tmp/gateway.log
    setsid openclaw gateway run > /tmp/gateway.log 2>&1 < /dev/null &
    echo "  Gateway enabled (PID: $!)"
    echo "  Log: /tmp/gateway.log"
ENDSSH
  echo ""
  echo "Done. Watch for Telegram polling with: openshell logs --tail"
  echo "Or inside the sandbox: tail -f /tmp/gateway.log"
}

# Source .env from repo root if it exists and values aren't already in the environment.
# set -a exports every variable that is assigned, so they're available to child processes.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

# ---------------------------------------------------------------------------
# Parse command-line arguments
# ---------------------------------------------------------------------------
RESTORE_MODE=""        # "auto" | "skip" | "" (prompt)
RESTORE_TIMESTAMP=""
FORCE_SSH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-backup)
      RESTORE_MODE="auto"
      if [[ "${2:-}" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
        RESTORE_TIMESTAMP="$2"
        shift
      fi
      shift
      ;;
    --no-restore)
      RESTORE_MODE="skip"
      shift
      ;;
    --regenerate-ssh)
      FORCE_SSH=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: bash run-setup.sh [--from-backup [timestamp]] [--no-restore] [--regenerate-ssh]" >&2
      exit 1
      ;;
  esac
done

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
if [[ -f "$SSH_CONF" ]]; then
  if [[ "$FORCE_SSH" == true ]]; then
    rm -f "$SSH_CONF"
  else
    read -r -p "    SSH config already exists at $SSH_CONF. Delete and regenerate? [y/N] " reply || true
    if [[ "$reply" =~ ^[Yy]$ ]]; then
      rm -f "$SSH_CONF"
    else
      echo "    Exiting. Remove $SSH_CONF manually or re-run and confirm deletion."
      exit 0
    fi
  fi
fi
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

# ---------------------------------------------------------------------------
# Stop any running gateway before restore so it can't race to recreate files
# ---------------------------------------------------------------------------
ssh -F "$SSH_CONF" "openshell-$SANDBOX_NAME" bash << 'ENDSSH' 2>/dev/null || true
  openclaw gateway stop 2>/dev/null || true
  kill -9 $(pgrep -f "openclaw gateway" 2>/dev/null) 2>/dev/null || true
ENDSSH

# ---------------------------------------------------------------------------
# Restore workspace backup (optional)
# ---------------------------------------------------------------------------
if [[ "$RESTORE_MODE" != "skip" ]]; then
  _backup_root="${BACKUP_BASE:-$HOME/.openclaw/backups}/$SANDBOX_NAME"
  if [[ "$RESTORE_MODE" == "auto" ]] && { [[ ! -d "$_backup_root" ]] || [[ -z "$(ls -A "$_backup_root" 2>/dev/null)" ]]; }; then
    echo "Error: --from-backup specified but no backups found in '$_backup_root'." >&2
    exit 1
  fi

  if [[ -d "$_backup_root" ]] && [[ -n "$(ls -A "$_backup_root" 2>/dev/null)" ]]; then
    echo ""
    _latest=$(ls -1t "$_backup_root" | head -1)
    _target="${RESTORE_TIMESTAMP:-$_latest}"

    if [[ "$RESTORE_MODE" == "auto" ]]; then
      echo "==> Restoring workspace from backup: $_target"
      bash "$SCRIPT_DIR/scripts/backup-workspace.sh" restore "$_target" --yes
    else
      echo "==> Workspace backup found for '$SANDBOX_NAME'."
      echo "    Most recent: $_latest"
      read -r -p "    Restore workspace to '$SANDBOX_NAME'? [y/N] " _restore_reply || true
      if [[ "$_restore_reply" =~ ^[Yy]$ ]]; then
        bash "$SCRIPT_DIR/scripts/backup-workspace.sh" restore "$_latest" --yes
      else
        echo "    Skipping restore."
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Start gateway — after restore so workspace files are in place at startup
# ---------------------------------------------------------------------------
start_gateway

echo ""
echo "Setup complete."