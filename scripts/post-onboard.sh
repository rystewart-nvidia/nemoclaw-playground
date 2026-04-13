#!/usr/bin/env bash
# post-onboard.sh — Run this from the repo root on the HOST after every `nemoclaw onboard`.
#
# Usage:
#   ./scripts/post-onboard.sh [sandbox-name]
#   sandbox-name defaults to "my-assistant"
#
# What it does:
#   1. Apply sandbox policy  — full network policy (Telegram + SearXNG + npm + pypi)
#   2. Patch openclaw.json   — fix bot token, allowFrom, tool deny list, workspace path
#   3. Fix Telegram DNS      — add api.telegram.org to /etc/hosts (sandbox DNS is broken)
#   4. Create writable dirs  — symlink Landlock-blocked paths to writable locations
#   5. Configure SearXNG     — create TOOLS.md so the agent knows how to search
#
# Why this is needed:
#   openclaw runs inside a Landlock-hardened sandbox where /sandbox/.openclaw is read-only.
#   Several openclaw features require writes to that directory. These steps work around
#   known bugs and filesystem restrictions in openclaw v2026.3.11.
#
# Persistence:
#   ALL fixes are non-persistent — re-run after any `nemoclaw onboard --recreate-sandbox`.
#
# Prerequisites:
#   .env in the repo root with:
#     TELEGRAM_BOT_TOKEN  — bot token from BotFather
#     ALLOWED_CHAT_IDS    — your Telegram user ID (message @userinfobot to get it)

set -euo pipefail

SANDBOX="${1:-my-assistant}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Load .env
# ---------------------------------------------------------------------------
# Variables are exported via set -a so child processes (kubectl exec, python3)
# can read them. Skipped if TELEGRAM_BOT_TOKEN is already in the environment.
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
  echo "Warning: ALLOWED_CHAT_IDS is not set — allowFrom will not be updated in openclaw.json." >&2
  echo "  Your Telegram user ID: message @userinfobot on Telegram, or use the getUpdates API." >&2
  echo "  Add it to .env as ALLOWED_CHAT_IDS=<your-id> and re-run." >&2
fi

# ---------------------------------------------------------------------------
# [1/5] Apply sandbox policy
# ---------------------------------------------------------------------------
# openshell policy set replaces the ENTIRE policy — it does not merge.
# policies/sandbox-policy.yaml is the full policy: base openclaw-sandbox preset
# + Telegram (protocol:rest, tls:terminate) + SearXNG (allowed_ips for host gateway)
# + npm + pypi.
#
# Bug: openshell term approvals create allow_* override policies that break Telegram TLS.
# Always re-apply this policy after any openshell term approvals.
echo "==> [1/5] Applying sandbox policy..."
openshell policy set "$SANDBOX" --policy "$REPO_ROOT/policies/sandbox-policy.yaml" --wait

# ---------------------------------------------------------------------------
# [2/5] Patch openclaw.json
# ---------------------------------------------------------------------------
# Three separate bugs require config patches — all done in a single read/modify/write
# to avoid multiple Landlock-blocked write attempts:
#
#   a) Bot token: nemoclaw onboard stores the token as the literal string
#      "openshell:resolve:env:TELEGRAM_BOT_TOKEN". openclaw v2026.3.11 does not
#      resolve this placeholder at runtime — Telegram returns 404.
#
#   b) allowFrom: nemoclaw onboard sometimes sets allowFrom to the numeric prefix
#      of the bot token instead of the user's actual Telegram ID, silently dropping
#      all incoming messages. We overwrite it from ALLOWED_CHAT_IDS.
#
#   c) Agent config: set tools.deny (disable broken web_search) and
#      agents.defaults.workspace (required for TOOLS.md injection).
#
# Safe pattern: read to host → modify on host → write back. Never pipe read+write
# through the same command — it races and zeros the file.
echo "==> [2/5] Patching openclaw.json (token, allowFrom, tool config)..."
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$SANDBOX" -- \
    cat /sandbox/.openclaw/openclaw.json > /tmp/oc.json

TOKEN="$TELEGRAM_BOT_TOKEN" CHAT_IDS="${ALLOWED_CHAT_IDS:-}" python3 -c "
import json, sys, os

with open('/tmp/oc.json') as f:
    config = json.load(f)

# (a) + (b): fix bot token and allowFrom for every Telegram account
for acct in config['channels']['telegram'].get('accounts', {}).values():
    acct['botToken'] = os.environ['TOKEN']
    if os.environ.get('CHAT_IDS'):
        acct['allowFrom'] = [id.strip() for id in os.environ['CHAT_IDS'].split(',')]
        acct['dmPolicy'] = 'allowlist'

# (c): disable broken web_search tool; set workspace for TOOLS.md injection
config.setdefault('tools', {})['deny'] = ['web_search']
config.setdefault('agents', {}).setdefault('defaults', {})['workspace'] = \
    '/sandbox/.openclaw-data/workspace'

print(json.dumps(config, indent=2))
" > /tmp/oc-updated.json

docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell "$SANDBOX" -- \
    sh -c 'cat > /sandbox/.openclaw/openclaw.json' < /tmp/oc-updated.json

# ---------------------------------------------------------------------------
# [3/5] Fix Telegram DNS
# ---------------------------------------------------------------------------
# The sandbox /etc/resolv.conf points to 10.200.0.1 (OpenShell proxy) which has
# no DNS on port 53. OpenShell's mechanistic_mapper resolves hostnames to verify
# they are not internal IPs — if DNS fails, it blocks the connection.
#
# Fix: add a static /etc/hosts entry. Bypasses Landlock because /etc is writable.
# Not persistent — lost on sandbox pod restart.
echo "==> [3/5] Fixing Telegram DNS..."
TGIP=$(dig +short api.telegram.org A | head -1)
if [[ -z "$TGIP" ]]; then
  echo "  Warning: could not resolve api.telegram.org locally — using fallback IP 149.154.166.110" >&2
  TGIP="149.154.166.110"
fi
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$SANDBOX" -- \
    sh -c "grep -q api.telegram.org /etc/hosts || echo '$TGIP api.telegram.org' >> /etc/hosts"

# ---------------------------------------------------------------------------
# [4/5] Create writable symlinks
# ---------------------------------------------------------------------------
# Landlock marks /sandbox/.openclaw read-only. openclaw tries to write several
# subdirs/files there at runtime — these fail with EACCES without these symlinks.
#
#   credentials/         — needed for `openclaw pairing list telegram`
#   telegram/            — gateway writes Telegram update offsets here (for dedup on restart)
#   workspace-state.json — gateway writes agent workspace state; without it every
#                          Telegram message returns an error response
#
# Pattern: remove the path, create the real dir/file under .openclaw-data (writable),
# then symlink .openclaw/<path> -> .openclaw-data/<path>.
echo "==> [4/5] Creating writable symlinks..."
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$SANDBOX" -- sh -c '
for dir in credentials telegram; do
    rm -rf /sandbox/.openclaw/$dir
    mkdir -p /sandbox/.openclaw-data/$dir
    chown sandbox:sandbox /sandbox/.openclaw-data/$dir
    ln -s /sandbox/.openclaw-data/$dir /sandbox/.openclaw/$dir
done
# workspace-state.json is a single file, not a directory
rm -f /sandbox/.openclaw/workspace-state.json
touch /sandbox/.openclaw-data/workspace-state.json
chown sandbox:sandbox /sandbox/.openclaw-data/workspace-state.json
ln -s /sandbox/.openclaw-data/workspace-state.json /sandbox/.openclaw/workspace-state.json
echo "  Symlinks created:"
ls -la /sandbox/.openclaw/credentials /sandbox/.openclaw/telegram /sandbox/.openclaw/workspace-state.json
'

# ---------------------------------------------------------------------------
# [5/5] Configure SearXNG
# ---------------------------------------------------------------------------
# openclaw v2026.3.11 has no MCP support and no native SearXNG provider.
# Workaround: inject instructions into AGENTS.md in the agent workspace.
# openclaw reads AGENTS.md on every agent run and injects it into the system
# prompt, teaching the agent to use `exec` + curl to reach SearXNG.
#
# File must be named AGENTS.md (not TOOLS.md) — openclaw only reads:
#   AGENTS.md, BOOTSTRAP.md, HEARTBEAT.md
#
# Write pattern: heredoc provides stdin to `docker exec -i` → `kubectl exec -i`
# → `sh -c 'cat > file'`. Both -i flags are required to thread stdin through.
#
# TODO: replace with a proper MCP tool when upgrading past openclaw v2026.3.11.
# See: https://docs.openclaw.ai/cli (mcp subcommand added in later versions).
echo "==> [5/5] Configuring SearXNG workspace context..."
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell "$SANDBOX" -- \
    mkdir -p /sandbox/.openclaw-data/workspace

docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell "$SANDBOX" -- \
    sh -c 'cat > /sandbox/.openclaw-data/workspace/AGENTS.md' << 'EOF'
## Web Search: SearXNG

Use the `exec` tool with curl to search the web — do NOT use `web_fetch` (blocked for internal hostnames by openclaw SSRF protection).

curl -sf -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36" "http://host.openshell.internal:8888/search?q=YOUR+QUERY&format=json"

Replace YOUR+QUERY with URL-encoded search terms (spaces → +).

IMPORTANT: the `number_of_results` field in the response is always 0 — ignore it. Results are in the `results[]` array. Always check `results` length to determine if the search succeeded.

Key fields in each results[] entry: title, url, content (snippet).

Example — search and print top 5:
curl -sf -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36" "http://host.openshell.internal:8888/search?q=python+async+best+practices&format=json" | python3 -c "import json,sys; r=json.load(sys.stdin)['results']; print(len(r),'results'); [print(x['title'], x['url']) for x in r[:5]]"
EOF

echo ""
echo "Done. Next: ./scripts/start-openclaw-gateway.sh to start the openclaw gateway."
