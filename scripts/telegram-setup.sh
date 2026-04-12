#!/usr/bin/env bash
# Post-onboard Telegram setup — run from repo root on the HOST after every nemoclaw onboard.
# Usage: ./scripts/telegram-setup.sh [sandbox-name]
#
# Reads .env from the repo root automatically. Required fields:
#   TELEGRAM_BOT_TOKEN  — bot token from BotFather
#   ALLOWED_CHAT_IDS    — your Telegram user ID (get it from @userinfobot or getUpdates API)
#
# Fixes required by openclaw v2026.4.10 + Landlock restrictions:
#   1. Apply full sandbox policy (Telegram network rules)
#   2. Inject real bot token + allowFrom (openshell:resolve:env: placeholder not resolved at runtime;
#      nemoclaw onboard may set allowFrom to the wrong value)
#   3. Fix Telegram DNS (sandbox DNS can't resolve external hostnames)
#   4. Create writable symlinks for openclaw state dirs (Landlock blocks writes in .openclaw/)
#
# All four fixes are non-persistent — re-run after any nemoclaw onboard --recreate-sandbox.

set -euo pipefail

SANDBOX="${1:-my-assistant}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env if TELEGRAM_BOT_TOKEN isn't already set
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  ENV_FILE="$REPO_ROOT/.env"
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=../.env
    source "$ENV_FILE"
    set +a
  fi
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "Error: TELEGRAM_BOT_TOKEN is not set. Create a .env file in the repo root (see example.env)." >&2
  exit 1
fi

if [[ -z "${ALLOWED_CHAT_IDS:-}" ]]; then
  echo "Warning: ALLOWED_CHAT_IDS is not set — allowFrom will not be updated." >&2
  echo "  Get your Telegram user ID: message @userinfobot on Telegram, or check getUpdates API." >&2
  echo "  Add it to .env as ALLOWED_CHAT_IDS=<your-id> and re-run." >&2
fi

echo "==> [1/4] Applying sandbox policy..."
openshell policy set "$SANDBOX" --policy "$REPO_ROOT/policies/sandbox-policy.yaml" --wait

echo "==> [2/4] Injecting real bot token and allowFrom..."
TOKEN="$TELEGRAM_BOT_TOKEN" CHAT_IDS="${ALLOWED_CHAT_IDS:-}" python3 -c "
import json, sys, os
config = json.load(sys.stdin)
for acct in config['channels']['telegram'].get('accounts', {}).values():
    if 'botToken' in acct:
        acct['botToken'] = os.environ['TOKEN']
    if os.environ.get('CHAT_IDS'):
        acct['allowFrom'] = [id.strip() for id in os.environ['CHAT_IDS'].split(',')]
        acct['dmPolicy'] = 'allowlist'
print(json.dumps(config, indent=2))
" < <(docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$SANDBOX" -- \
    cat /sandbox/.openclaw/openclaw.json) > /tmp/openclaw-updated.json
docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell "$SANDBOX" -- \
    sh -c 'cat > /sandbox/.openclaw/openclaw.json' < /tmp/openclaw-updated.json

echo "==> [3/4] Fixing Telegram DNS..."
TGIP=$(dig +short api.telegram.org A | head -1)
if [[ -z "$TGIP" ]]; then
  echo "Warning: could not resolve api.telegram.org — using known IP 149.154.166.110" >&2
  TGIP="149.154.166.110"
fi
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$SANDBOX" -- \
    sh -c "grep -q api.telegram.org /etc/hosts || echo '$TGIP api.telegram.org' >> /etc/hosts"

echo "==> [4/4] Creating writable symlinks..."
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$SANDBOX" -- sh -c '
for dir in credentials telegram; do
    rm -rf /sandbox/.openclaw/$dir
    mkdir -p /sandbox/.openclaw-data/$dir
    chown sandbox:sandbox /sandbox/.openclaw-data/$dir
    ln -s /sandbox/.openclaw-data/$dir /sandbox/.openclaw/$dir
done
# workspace-state.json: single file (not a directory)
rm -f /sandbox/.openclaw/workspace-state.json
touch /sandbox/.openclaw-data/workspace-state.json
chown sandbox:sandbox /sandbox/.openclaw-data/workspace-state.json
ln -s /sandbox/.openclaw-data/workspace-state.json /sandbox/.openclaw/workspace-state.json
echo "Symlinks:"
ls -la /sandbox/.openclaw/credentials /sandbox/.openclaw/telegram /sandbox/.openclaw/workspace-state.json
'

echo ""
echo "Done. Next: ./scripts/start-gateway.sh to start the Telegram gateway."
