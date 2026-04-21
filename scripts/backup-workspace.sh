#!/usr/bin/env bash
# backup-workspace.sh — Backup and restore the openclaw agent workspace.
#
# Usage:
#   bash scripts/backup-workspace.sh backup [sandbox-name]
#   bash scripts/backup-workspace.sh restore [timestamp] [sandbox-name] [--yes]
#   bash scripts/backup-workspace.sh list [sandbox-name]
#
# sandbox-name defaults to $SANDBOX_NAME from .env, then 'my-assistant'.
# BACKUP_BASE can be set in .env to override the backup storage location
# (default: ~/.openclaw/backups).
#
# What gets backed up: the agent workspace directory, which holds personality
# and memory files (SOUL.md, USER.md, IDENTITY.md, AGENTS.md, MEMORY.md, memory/).
# These are lost on sandbox rebuild — back up before destroying or recreating.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}  +${NC} $*"; }
warn()  { echo -e "${YELLOW}  -${NC} $* (skipped)" >&2; }
fail()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source .env from repo root so SANDBOX_NAME, BACKUP_BASE, etc. are available.
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/../.env"
  set +a
fi

WORKSPACE_REMOTE="/sandbox/.openclaw/workspace"
BACKUP_BASE="${BACKUP_BASE:-$HOME/.openclaw/backups}"
WORKSPACE_FILES=(SOUL.md USER.md IDENTITY.md AGENTS.md MEMORY.md)
WORKSPACE_DIRS=(memory)

do_backup() {
  local sandbox="$1"
  local backup_root="$BACKUP_BASE/$sandbox"
  local timestamp dest
  timestamp=$(date +%Y%m%d-%H%M%S)
  dest="$backup_root/$timestamp"

  mkdir -p "$dest"
  chmod 0700 "$backup_root"

  echo "==> Backing up workspace from sandbox '$sandbox'..."
  echo "    Destination: $dest"
  echo ""

  local count=0
  for file in "${WORKSPACE_FILES[@]}"; do
    if openshell sandbox download "$sandbox" "$WORKSPACE_REMOTE/$file" "$dest/" 2>/dev/null; then
      info "$file"
      (( count++ )) || true
    else
      warn "$file not found in workspace"
    fi
  done

  for dir in "${WORKSPACE_DIRS[@]}"; do
    if openshell sandbox download "$sandbox" "$WORKSPACE_REMOTE/$dir" "$dest/" 2>/dev/null; then
      info "$dir/"
      (( count++ )) || true
    else
      warn "$dir/ not found in workspace"
    fi
  done

  echo ""
  if [[ $count -eq 0 ]]; then
    rmdir "$dest" 2>/dev/null || true
    fail "Nothing was backed up. Is the workspace initialized? (sandbox: $sandbox)"
  fi

  echo "Backup complete: $dest"
}

do_restore() {
  local backup_dir="$1"
  local sandbox="$2"
  local yes="${3:-false}"

  [[ -d "$backup_dir" ]] || fail "Backup directory not found: $backup_dir"

  echo ""
  echo "  Backup : $backup_dir"
  echo "  Target : sandbox '$sandbox'"
  echo ""
  if [[ "$yes" != true ]]; then
    read -r -p "  Restore workspace to '$sandbox'? [y/N] " reply || true
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
  fi

  echo ""
  echo "==> Restoring workspace to sandbox '$sandbox'..."

  # Clear existing workspace so openshell sandbox upload can overwrite.
  local ssh_conf
  ssh_conf=$(mktemp)
  openshell sandbox ssh-config "$sandbox" > "$ssh_conf"
  ssh -F "$ssh_conf" "openshell-$sandbox" \
    'rm -rf /sandbox/.openclaw/workspace && mkdir -p /sandbox/.openclaw/workspace' 2>/dev/null || true
  rm -f "$ssh_conf"

  local count=0
  for file in "${WORKSPACE_FILES[@]}"; do
    if [[ -f "$backup_dir/$file" ]]; then
      openshell sandbox upload "$sandbox" "$backup_dir/$file" "$WORKSPACE_REMOTE/"
      info "$file"
      (( count++ )) || true
    fi
  done

  for dir in "${WORKSPACE_DIRS[@]}"; do
    if [[ -d "$backup_dir/$dir" ]]; then
      openshell sandbox upload "$sandbox" "$backup_dir/$dir" "$WORKSPACE_REMOTE/"
      info "$dir/"
      (( count++ )) || true
    fi
  done

  echo ""
  echo "Restore complete ($count items)."
}

list_backups() {
  local sandbox="$1"
  local backup_root="$BACKUP_BASE/$sandbox"

  if [[ ! -d "$backup_root" ]] || [[ -z "$(ls -A "$backup_root" 2>/dev/null)" ]]; then
    echo "No backups found for sandbox '$sandbox' in $backup_root"
    return 1
  fi

  echo "Backups for '$sandbox' ($backup_root):"
  local i=1
  while IFS= read -r ts; do
    echo "  [$i] $ts"
    (( i++ )) || true
  done < <(ls -1t "$backup_root")
}

# ---------------------------------------------------------------------------
# Argument parsing and dispatch
# ---------------------------------------------------------------------------
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
  backup)
    SANDBOX="${1:-${SANDBOX_NAME:-my-assistant}}"
    do_backup "$SANDBOX"
    ;;

  restore)
    # restore [timestamp] [sandbox-name] [--yes]
    # --yes may appear anywhere after the subcommand to skip confirmation.
    TIMESTAMP=""
    SANDBOX="${SANDBOX_NAME:-my-assistant}"
    YES=false

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --yes|-y) YES=true ;;
        *)
          if [[ "$1" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
            TIMESTAMP="$1"
          else
            SANDBOX="$1"
          fi
          ;;
      esac
      shift || true
    done

    BACKUP_ROOT="$BACKUP_BASE/$SANDBOX"

    if [[ -z "$TIMESTAMP" ]]; then
      LATEST=$(ls -1t "$BACKUP_ROOT" 2>/dev/null | head -1)
      [[ -n "$LATEST" ]] || fail "No backups found in $BACKUP_ROOT"
      echo "No timestamp specified. Using most recent backup: $LATEST"
      TIMESTAMP="$LATEST"
    fi

    do_restore "$BACKUP_ROOT/$TIMESTAMP" "$SANDBOX" "$YES"
    ;;

  list)
    SANDBOX="${1:-${SANDBOX_NAME:-my-assistant}}"
    list_backups "$SANDBOX"
    ;;

  *)
    echo "Usage:"
    echo "  bash scripts/backup-workspace.sh backup [sandbox-name]"
    echo "  bash scripts/backup-workspace.sh restore [timestamp] [sandbox-name] [--yes]"
    echo "  bash scripts/backup-workspace.sh list [sandbox-name]"
    echo ""
    echo "sandbox-name defaults to \$SANDBOX_NAME in .env (or 'my-assistant')."
    echo "BACKUP_BASE can be set in .env to override storage location"
    echo "  (default: ~/.openclaw/backups)"
    exit 1
    ;;
esac
