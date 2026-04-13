# NemoClaw + Ollama Setup Guide

Get [NemoClaw](https://github.com/NVIDIA/NemoClaw) running with local [Ollama](https://ollama.com) inference, SearXNG for web search, then wire up a Telegram bot. Tested on Mac M-series; targets DGX Spark (ARM + NVIDIA GPU) next.

## Reference Docs

| Tool | Documentation |
|---|---|
| NemoClaw CLI | https://docs.nvidia.com/nemoclaw/latest/reference/commands.html |
| OpenClaw CLI | https://docs.openclaw.ai/cli |
| OpenClaw Channels | https://docs.openclaw.ai/channels/index |
| OpenClaw Telegram | https://docs.openclaw.ai/channels/telegram |
| OpenShell | https://docs.nvidia.com/openshell/latest/get-started |

## Which CLI does what

| CLI | Runs on | Responsibility |
|---|---|---|
| `nemoclaw` | Host | Create/manage sandboxes, apply policies, start tunnel/services, onboard |
| `openshell` | Host | Inspect sandboxes, set network/filesystem policy, view logs, SSH config |
| `openclaw` | Inside sandbox | Run agents, configure channels/plugins, manage sessions, TUI |

> `openclaw` is NOT installed on the host. All `openclaw` commands run inside the sandbox — either interactively via `nemoclaw <name> connect`, or non-interactively via the SSH pattern in [Connecting to the sandbox](#connecting-to-the-sandbox).

---

## Prerequisites

- **Docker** — [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Mac) or native Docker (Linux/DGX)
- **Ollama** — installed and a model pulled
  ```bash
  # Mac
  brew install ollama
  ollama pull <your-preferred-model>   # e.g. nemotron-cascade-2, qwen3.5:9b, gpt-oss:20b
  ```
  Pull any model you like. If results are poor (slow responses, ignores tool calls), try a larger or different model.
  Linux/DGX: see [ollama.com/download](https://ollama.com/download)
- **Mac only**: Xcode CLI tools
  ```bash
  xcode-select --install
  ```

---

## 1. Install NemoClaw

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

---

## 2. Start services

### 2a. Ollama (host-accessible for sandbox)

The sandbox needs to reach Ollama over the Docker host gateway, so bind to `0.0.0.0`:

**Mac (run directly):**
```bash
OLLAMA_HOST=0.0.0.0:11434 OLLAMA_KEEP_ALIVE=15m ollama serve
```

**Linux/DGX (systemd service):**

Ollama on Linux runs as a systemd service. Configure it via a drop-in override (this adds to the existing service config, not replace it):
```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d/
sudo tee /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=15m"
EOF
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

Verify it's listening on all interfaces:
```bash
ss -tlnp | grep 11434
# Should show 0.0.0.0:11434 (not 127.0.0.1:11434)
```

**WSL only:**
```bash
OLLAMA_KEEP_ALIVE=15m ollama serve
```

> `OLLAMA_KEEP_ALIVE=15m` keeps the model loaded for 15 minutes after the last request. The default is 5 minutes — too short for a Telegram bot with sporadic messages. Set to `-1` to never unload.

Verify it's up:
```bash
curl -sf http://localhost:11434/api/tags
```

### 2b. SearXNG

```bash
docker compose up -d
```

Verify it's up:
```bash
curl -sf -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36" "http://localhost:8888/search?q=test&format=json" | python3 -m json.tool | head -100
```

> **Note:** Port 8080 is used by the OpenShell gateway cluster. SearXNG runs on **8888**.

---

## 3. Onboard

### 3a. First-time onboard

**Host:**
```bash
nemoclaw onboard
```

When prompted:
- **Inference provider** → choose `Local Ollama (localhost:11434)`
- **Model** → pick from the list (your pulled models will appear)
- **Brave Web Search** → `N` (we use SearXNG instead)
- **Messaging channels** → toggle Telegram and paste your bot token + Telegram user ID
- **Sandbox name** → choose anything, e.g. `my-assistant`

### 3b. Rebuild an existing sandbox

Use this to switch models, upgrade openclaw, or re-wire Telegram:

**Host:**
```bash
nemoclaw onboard --recreate-sandbox --yes-i-accept-third-party-software
```

> This command is **interactive** — `--non-interactive` mode requires `NVIDIA_API_KEY` and defaults to NIM, not ollama.
> After rebuilding, re-run `./scripts/post-onboard.sh` and `./scripts/start-openclaw-gateway.sh`.

Verify onboarding succeeded:
```bash
nemoclaw list
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"
```

Expected: your sandbox appears in `nemoclaw list` and `openshell-cluster-nemoclaw` is running in Docker.

---

## 4. Test Chat

Connect interactively:

**Host:**
```bash
nemoclaw my-assistant connect
```

Then run a message:

**Sandbox:**
```bash
openclaw agent --agent main --local -m "hi" --session-id test
# or open the interactive TUI:
openclaw tui
```

**Expected**: the agent responds and walks through initial OpenClaw setup (asks what to call itself, etc.).

> **Dashboard alternative**: You can also send messages and watch responses from the NemoClaw dashboard — see [the dashboard URL](#dashboard) in the Connecting to the sandbox section.

---

## 5. Test Tool Calling

**Date (no extra config needed)**

**Sandbox:**
```bash
openclaw agent --agent main --local -m "What is today's date?" --session-id test2
```
Expected: correct date returned via tool call.

> **Dashboard alternative**: The NemoClaw dashboard shows each tool call and its result inline as the agent runs — useful for verifying tool use without parsing CLI output. See [the dashboard URL](#dashboard) in the Connecting to the sandbox section.

**Internet search** — requires SearXNG (see next section).

---

## 6. SearXNG Web Search

> `web_search` in openclaw only supports Brave Search (API key required).
> Instead, we run SearXNG locally and the agent calls it via the `bash` tool with curl — no API key needed.
> Note: `web_fetch` is also blocked for internal IPs by openclaw's own SSRF protection, so use `bash` + curl.

SearXNG should already be running from [Step 2b](#2b-searxng). Verify:

**Host:**
```bash
curl -sf -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36" "http://localhost:8888/search?q=test&format=json" | python3 -m json.tool | head -100
```

If not running: `docker compose up -d` (host)

### 6a. Host gateway IP

The SearXNG policy entry whitelists the IP that `host.openshell.internal` resolves to inside the sandbox. `policies/sandbox-policy.yaml` already includes both known values:

- `192.168.65.254` — macOS Docker Desktop
- `172.17.0.1` — Linux / DGX Spark

If you're on an unusual network setup and SearXNG isn't reachable, check the actual IP:
```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  getent hosts host.openshell.internal
```

If it's something different, add it to `allowed_ips` under the `searxng` endpoint in `policies/sandbox-policy.yaml` and re-apply the policy. See [SearXNG not reachable from sandbox](#searxng-not-reachable) in Troubleshooting.

> **How SearXNG gets wired up**: `post-onboard.sh` (step 7d) makes two config changes — (1) sets `tools.deny: [web_search]` in `openclaw.json` to hide the non-functional Brave Search tool, and (2) writes a `TOOLS.md` to the agent workspace instructing the agent to use `exec` + curl for any search request. This is a temporary workaround until openclaw supports MCP (added in versions after v2026.3.11), which will replace it with a registered `search` tool.

---

## 7. Telegram Bridge

### 7a. Configure secrets

Secrets are stored in a local `.env` file (gitignored). Copy the example and fill it in:

**Host:**
```bash
cp example.env .env
# edit .env and fill in your values
```

`.env` contents:
```
TELEGRAM_BOT_TOKEN=   # from BotFather (see below)
SANDBOX_NAME=my-assistant
ALLOWED_CHAT_IDS=     # your Telegram chat ID (optional but recommended)
```

Load the variables into your shell before running any `nemoclaw` commands:

**Host:**
```bash
source .env
```

> `source .env` only lasts for the current shell session. Run it again if you open a new terminal.
> Never commit `.env` — the `.gitignore` in this repo already excludes it.

### 7b. Get a bot token

Message [@BotFather](https://t.me/BotFather) on Telegram, send `/newbot`, follow the prompts. Copy the token into `.env`.

### 7c. Get your chat ID

The easiest way is to message [@userinfobot](https://t.me/userinfobot) on Telegram — it replies with your user ID immediately.

Alternatively, send any message to your new bot, then:

**Host:**
```bash
source .env && curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" | python3 -m json.tool | grep -A3 '"chat"'
```
Find `"id": <your-id>` in the response.

> ⚠️ `getUpdates` only returns messages the gateway hasn't consumed yet. Run this **before** starting the gateway, or the updates will already be gone.

Add your ID to `ALLOWED_CHAT_IDS` in `.env`:
```
ALLOWED_CHAT_IDS=<your-telegram-user-id>
```

> `ALLOWED_CHAT_IDS` must be set before running `post-onboard.sh` — the script injects it into `allowFrom` in the openclaw config. If it's not set, the bot will silently drop your messages. `nemoclaw onboard` may set `allowFrom` to the wrong value (the bot token's numeric prefix instead of your user ID) — the setup script overwrites it.

### 7d. Post-onboard setup (required after every onboard)

After onboarding, run the setup script. It handles everything in one shot — Telegram fixes, SearXNG config, and workspace setup.

> ⚠️ All changes are **not persistent** — re-run after any `nemoclaw onboard --recreate-sandbox`.

> 🚫 **Disconnect VPN before running this script.** The script resolves `api.telegram.org` and writes the IP into the sandbox's `/etc/hosts`. If VPN is on, it will write a VPN-intercepted IP — the gateway will connect but get a certificate for the wrong server (`TLS L7 relay error: UnknownIssuer`). Disconnect VPN first, then run the script.

**Host** (repo root):
```bash
./scripts/post-onboard.sh
```

> `openclaw configure` is blocked by Landlock inside the sandbox — the script uses `kubectl exec` to patch `openclaw.json` directly from the host.

<details>
<summary>What each step does</summary>

**Step 1 — Policy**: Applies the full sandbox policy (Telegram network rules, SearXNG rules, npm, pypi). `openshell policy set` replaces the entire policy — always use `policies/sandbox-policy.yaml`.

**Step 2 — Patch openclaw.json**: Three fixes in one write:
- *Bot token*: openclaw stores the token as a literal placeholder string after onboarding — injects the real token from `.env`
- *allowFrom*: nemoclaw onboard may set this to the bot token's numeric prefix instead of your Telegram user ID — overwrites from `ALLOWED_CHAT_IDS` in `.env`
- *Agent config*: sets `tools.deny: [web_search]` (disables broken Brave Search) and `agents.defaults.workspace` (required for TOOLS.md injection)

**Step 3 — Telegram DNS**: The sandbox nameserver (`10.200.0.1`) has no DNS on port 53. OpenShell's `mechanistic_mapper` resolves hostnames to verify they're not internal IPs; DNS failure = blocked connection. Adds a static `/etc/hosts` entry to bypass this.

**Step 4 — Writable symlinks**: Landlock marks `/sandbox/.openclaw` read-only. openclaw writes to several paths there at runtime — creates symlinks to the writable `/sandbox/.openclaw-data/`:
- `credentials/` — needed for `openclaw pairing list telegram`
- `telegram/` — gateway writes update offsets here (prevents message re-delivery on restart)
- `workspace-state.json` — gateway writes agent state here; missing = every message returns an error

**Step 5 — SearXNG TOOLS.md**: Creates a `TOOLS.md` in the agent workspace teaching the agent to use `exec` + curl for web search. Temporary workaround until openclaw supports MCP (later versions).
</details>

### 7e. Start the openclaw gateway

Complete the [7d setup script](#7d-post-onboard-telegram-setup-required-after-every-onboard) first, then:

**Host:**
```bash
./scripts/start-openclaw-gateway.sh
```

The script starts the gateway and prints channel status. To confirm the bot is actively polling:

**Host:**
```bash
openshell logs --tail
# Expected: repeated L7_REQUEST ... l7_target=/bot.../getUpdates
```

> Note: `nemoclaw start` is for cloudflared tunnel only — it does NOT start the Telegram bot.
> `nemoclaw stop` / `nemoclaw status` do not reflect Telegram channel status.
> `/tmp/gateway.log` inside the sandbox only shows lifecycle events (errors, restarts) — not individual message polls.
> Use `openclaw channels status` (inside sandbox) and `openshell logs --tail` (host) to verify Telegram.

> **If `nemoclaw onboard` auto-started a gateway**: `start-openclaw-gateway.sh` will fail with "gateway already running". This is safe to ignore — the existing gateway is running. If it's not responding to messages, kill it and restart:
> ```bash
> # Kill the existing gateway
> docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
>   sh -c 'kill -9 146 2>/dev/null; true'
> # Start fresh
> ./scripts/start-openclaw-gateway.sh
> ```
> Note: the PID may differ — check with `nemoclaw connect` then look for the gateway process.

> **If `nemoclaw connect` says "gateway not running, recovering..."**: nemoclaw detected the gateway is down and tried to restart it automatically. If recovery fails, it drops you into the sandbox shell — run `openclaw gateway run` there to start it in the foreground and see any errors.

### 7f. Pair your Telegram account

If `dmPolicy` is `allowlist` and your user ID is in `allowFrom` (set during onboarding), you can DM the bot directly — no pairing needed. If `dmPolicy` is `pairing`, the first DM generates a code:

**Host:**
```bash
ssh ... 'openclaw pairing list telegram'
```

Approve it:

**Host:**
```bash
ssh ... 'openclaw pairing approve telegram <CODE>'
```

Pairing codes expire after 1 hour.

---

## 8. Verify Everything Works

### 8a. SearXNG

**Sandbox:**
```bash
openclaw agent --agent main --local \
  -m "Search for Airbnbs in Bergamo" \
  --session-id search1
```

Expected: the agent uses the `bash` tool to curl SearXNG and returns results — no URL needed in the prompt.

> **Dashboard alternative**: You can send the same queries from the NemoClaw dashboard and watch the curl tool call execute in real time — helpful for confirming SearXNG is being used. See [the dashboard URL](#dashboard) in the Connecting to the sandbox section.

### 8b. Telegram end-to-end

Send these messages to your Telegram bot and confirm the responses:

| Message | Expected |
|---|---|
| `hi` | Agent responds (may walk through naming setup on first run) |
| `What's today's date?` | Correct date from tool call |
| `Find Airbnbs in Bergamo` | Search results via SearXNG |

---

## Connecting to the sandbox

openclaw runs **inside** the sandbox — not on the host. There are two ways to reach it.

### Interactive shell

```bash
nemoclaw my-assistant connect
```

This drops you into a shell inside the sandbox. From there you can run any openclaw command:

```bash
openclaw agent --agent main --local -m "hi" --session-id test
openclaw tui
```

### Non-interactive (single command from host)

Use SSH with the sandbox ProxyCommand. Get the exact ProxyCommand for your sandbox:

```bash
openshell sandbox ssh-config my-assistant
```

Then run commands without entering the sandbox:

```bash
ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o "ProxyCommand=$(openshell sandbox ssh-config my-assistant | grep ProxyCommand | sed 's/.*ProxyCommand //')" \
  -l sandbox localhost \
  'openclaw agent --agent main --local -m "hi" --session-id test'
```

Or hardcode the ProxyCommand value (copy it from `openshell sandbox ssh-config my-assistant`) to avoid the subshell.

### Direct kubectl exec (bypassing SSH)

NemoClaw runs a k3s cluster inside `openshell-cluster-nemoclaw`. You can exec directly into the sandbox pod without going through the SSH tunnel — useful for debugging when SSH isn't sufficient:

```bash
# List sandbox pods
docker exec openshell-cluster-nemoclaw kubectl get all -n openshell

# Run a command directly in the sandbox pod
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- <command>

# Read openclaw config
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  cat /sandbox/.openclaw/openclaw.json
```

> Note: the sandbox pod name matches your sandbox name (e.g. `my-assistant`).

### Dashboard

At the end of onboarding, a tokenized Control UI URL is printed:

```
OpenClaw UI (tokenized URL; treat it like a password)
Port 18789 must be forwarded before opening this URL.
http://127.0.0.1:18789/#token=<token>
```

Open that URL in your browser to access the NemoClaw dashboard. From the dashboard you can:
- Send messages to the agent directly (no CLI needed)
- Watch tool calls and their results inline as the agent runs
- Review conversation history

The token is tied to this sandbox — keep it secret (it grants full UI access).

> If the port isn't forwarded yet, it will show an "origin not allowed" or connection error until the dashboard is reachable.

---

## Sandbox management

**Restart the stopped sandbox:**

The `openshell-cluster-nemoclaw` Docker container has no auto-restart policy — it must be started manually after a host reboot. The non-persistent fixes from `post-onboard.sh` (DNS, symlinks) are also lost on restart.

```bash
# Host
docker start openshell-cluster-nemoclaw
```

Wait ~30 seconds for the k3s cluster to come back up, then verify:

```bash
# Host
nemoclaw my-assistant status   # expect Phase: Ready
```

Then re-apply all non-persistent fixes and start the gateway:

```bash
# Host
./scripts/post-onboard.sh
./scripts/start-openclaw-gateway.sh
```

**Restart just the openclaw gateway (sandbox still running):**
```bash
# Host
./scripts/start-openclaw-gateway.sh
```

**Full clean slate (destroy gateway + all sandboxes):**
```bash
openshell gateway destroy   # destroys the openshell cluster Docker container + all sandboxes + state
nemoclaw onboard            # creates a fresh gateway and sandbox
```

> `openshell gateway destroy` removes the `openshell-cluster-nemoclaw` Docker container and all k3s state, including any sandboxes (registered or not). `nemoclaw onboard` recreates the gateway as part of the onboarding flow. Use this when you want a completely clean environment.

**Delete a sandbox (keep gateway running):**
```bash
nemoclaw my-assistant destroy        # prompts for confirmation
nemoclaw my-assistant destroy --yes  # skip confirmation
```

**Delete an unregistered sandbox** (e.g. created by a different nemoclaw install — shows in `kubectl get all -n openshell` but not in `nemoclaw list`):
```bash
docker exec openshell-cluster-nemoclaw kubectl delete pod/<name> service/<name> -n openshell
```

**List all sandboxes (nemoclaw view):**
```bash
nemoclaw list
```

**List all sandboxes (k3s view, includes unregistered):**
```bash
docker exec openshell-cluster-nemoclaw kubectl get all -n openshell
```

---

## Recommended terminals

Keep these two terminal sessions open whenever you are working with the sandbox:

**Terminal 1 — live network log:**
```bash
openshell logs --tail
```
Shows every connection the sandbox makes — Telegram `getUpdates`/`sendMessage` polls, SearXNG requests, blocked connections. This is the primary signal for whether the gateway is healthy and whether requests are getting through.

**Terminal 2 — interactive policy approvals:**
```bash
openshell term
```
Shows blocked outbound requests in real-time and lets you approve them interactively. Useful when adding new network destinations (npm packages, new APIs, etc.).

> ⚠️ Do NOT use `openshell term` to approve Telegram connections — it creates an `allow_*` override policy that breaks TLS. Re-apply the full policy after any approval: `openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait`

**Terminal 3 — SearXNG request log:**
```bash
docker compose logs -f searxng
```
Shows every search query hitting SearXNG, which engines handled it, and any errors (rate limits, blocked engines, etc.). Debug logging is enabled in `searxng/settings.yml` (`general.debug: true`) so you get per-engine request detail — useful for diagnosing why searches return empty or partial results.

---

## Troubleshooting

**Check gateway and Telegram status:**
```bash
# Is the gateway process running inside the sandbox?
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  ps aux | grep "openclaw gateway"

# Is Telegram actively polling? (primary health check — look for getUpdates lines)
openshell logs --tail
# Expected: repeated lines like:
# [sandbox] L7_REQUEST dst_host=api.telegram.org ... l7_target=/bot.../getUpdates

# Full Telegram channel status (from host, non-interactive)
ssh \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -o "ProxyCommand=$(openshell sandbox ssh-config my-assistant | grep ProxyCommand | sed 's/.*ProxyCommand //')" \
  -l sandbox localhost \
  'openclaw channels status'

# Just see recent network activity (Telegram + SearXNG hits)
openshell logs --tail | grep -E "api.telegram.org|host.openshell.internal"
```

> `nemoclaw status` and `nemoclaw my-assistant status` do NOT show Telegram state.
> `/tmp/gateway.log` only logs lifecycle events — not individual polls or messages.
> The definitive Telegram health signal is `getUpdates` appearing in `openshell logs --tail`.

**Check sandbox health:**
```bash
nemoclaw my-assistant status
openshell logs --tail
openshell logs --tail --source sandbox --level debug
```

**Ollama not reachable from sandbox:**
```bash
# Check host side
curl -sf http://localhost:11434/api/tags

# Check container can reach host
docker run --rm --add-host host.openshell.internal:host-gateway \
  curlimages/curl:8.10.1 \
  -sf http://host.openshell.internal:11434/api/tags
```

**SearXNG not reachable from sandbox:**

First confirm SearXNG itself is up:
```bash
# From host
curl -sf -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36" "http://localhost:8888/search?q=test&format=json" | head -c 200
```

If that's fine, the issue is likely a mismatched IP in the policy. Check what `host.openshell.internal` resolves to inside the sandbox:

```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  getent hosts host.openshell.internal
# Mac Docker Desktop: typically 192.168.65.254. Linux/DGX: likely 172.17.0.1 or similar.

# Compare against the policy file
grep -A1 "allowed_ips" policies/sandbox-policy.yaml
```

The policy already includes both `192.168.65.254` (macOS) and `172.17.0.1` (Linux/DGX). If you're on a different network setup and neither matches, add the correct IP to `allowed_ips` under the `searxng` endpoint in `policies/sandbox-policy.yaml`:
```yaml
  searxng:
    endpoints:
      - host: host.openshell.internal
        port: 8888
        access: full
        allowed_ips:
          - 192.168.65.254   # macOS Docker Desktop
          - 172.17.0.1       # Linux/DGX
          - x.x.x.x          # add your IP here
```

Then re-apply:
```bash
openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
```

Confirm it's now reachable from inside the sandbox:
```bash
ssh ... 'curl -sf -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36" "http://host.openshell.internal:8888/search?q=test&format=json" | python3 -c "import json,sys; [print(r[\"title\"]) for r in json.load(sys.stdin)[\"results\"][:3]]"'
```

**Agent isn't using SearXNG (uses `web_fetch` on google.com or similar instead):**

This means `agents.defaults.workspace` isn't set, so TOOLS.md isn't being injected. Verify the config:
```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  cat /sandbox/.openclaw/openclaw.json | python3 -c "
import json,sys
c=json.load(sys.stdin)
print('workspace:', c.get('agents',{}).get('defaults',{}).get('workspace','NOT SET'))
print('tools.deny:', c.get('tools',{}).get('deny','NOT SET'))
"
```
If workspace is `NOT SET`, re-run `./scripts/post-onboard.sh`.

**Agent fails with `session file locked`:**

A previous session timed out and left a stale lock file. Clear it:
```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  sh -c 'rm -f /sandbox/.openclaw-data/agents/main/sessions/*.lock && echo "Locks cleared"'
```

**`openclaw.json` got zeroed out (empty file):**

This happens if you read and write `openclaw.json` through the same pipeline — e.g. `cat openclaw.json | python3 ... | cat > openclaw.json`. The write truncates the file before the read completes.

Always use a host-side temp file as an intermediate:
```bash
# Safe pattern — read to host, modify on host, write back
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  cat /sandbox/.openclaw/openclaw.json > /tmp/oc.json

# modify /tmp/oc.json on host ...

docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell my-assistant -- \
  sh -c 'cat > /sandbox/.openclaw/openclaw.json' < /tmp/oc.json
```

To restore from backup (openclaw keeps `openclaw.json.bak`):
```bash
# Restore from backup, re-inject bot token, re-add customizations
source .env
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  cat /sandbox/.openclaw/openclaw.json.bak > /tmp/oc-restore.json

TOKEN="$TELEGRAM_BOT_TOKEN" python3 -c "
import json,sys,os
with open('/tmp/oc-restore.json') as f:
    c = json.load(f)
for acct in c['channels']['telegram'].get('accounts',{}).values():
    if 'botToken' in acct:
        acct['botToken'] = os.environ['TOKEN']
c.get('channels',{}).get('defaults',{}).pop('configWrites', None)  # remove stale key
if not c['channels'].get('defaults'): c['channels'].pop('defaults', None)
c.setdefault('tools',{})['deny'] = ['web_search']
c['agents']['defaults']['workspace'] = '/sandbox/.openclaw-data/workspace'
print(json.dumps(c,indent=2))
" > /tmp/oc-fixed.json

docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell my-assistant -- \
  sh -c 'cat > /sandbox/.openclaw/openclaw.json' < /tmp/oc-fixed.json
```
Then restart the gateway: `./scripts/start-openclaw-gateway.sh`

**Policy blocking requests:**
```bash
openshell term   # approve blocked requests interactively
```
> ⚠️ Do NOT approve Telegram connections via `openshell term` — it creates an `allow_api_telegram_org_443` policy with `access: full` that overrides the named `telegram` policy and breaks TLS. If you already did, re-apply the full policy immediately:
> ```bash
> openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
> ```

**openclaw gateway fails:**

Run the [7d consolidated script](#7d-post-onboard-telegram-setup-required-after-every-onboard) first — it covers the most common failures. For individual symptoms:

| Symptom | Cause | Fix |
|---|---|---|
| `deleteWebhook` 404 loop | Bot token placeholder not resolved | Fix 2 in §7d script |
| CONNECT tunnel fails / TLS drops | Policy using `access: full` | Fix 1 in §7d script (apply policy) |
| HTTP returns 0 bytes silently | `enforcement: monitor` instead of `enforce` | Fix 1 in §7d script (apply policy) |
| Connection blocked by mechanistic_mapper | Sandbox DNS can't resolve `api.telegram.org` | Fix 3 in §7d script |
| `openclaw pairing list` EACCES | Missing writable credentials dir | Fix 4 in §7d script |
| `failed to persist update offset` | Missing writable telegram state dir | Fix 4 in §7d script |
| Bot replies "something went wrong" to every message | `workspace-state.json` EACCES (missing writable file symlink) | Fix 4 in §7d script |
| Bot receives messages but never responds (no `sendMessage` in logs) | `allowFrom` set to wrong value — `nemoclaw onboard` may set it to the bot token's numeric prefix instead of your Telegram user ID | Re-run `post-onboard.sh` with `ALLOWED_CHAT_IDS` set in `.env` |
| All connections blocked after `openshell term` | Term approvals create broken `allow_*` override policies | Re-apply full policy |
| Telegram unreachable from host | VPN SNI-filters `api.telegram.org` | Disconnect VPN |
| `TLS L7 relay error: UnknownIssuer` in openshell logs | `/etc/hosts` has wrong IP for `api.telegram.org` — was resolved with VPN on | See below |

**`TLS L7 relay error: UnknownIssuer` — wrong IP in `/etc/hosts`:**

The gateway connects to `api.telegram.org` but gets a certificate from the wrong server. Caused by running `post-onboard.sh` with VPN on — `dig` returned a VPN-intercepted IP which was written into the sandbox's `/etc/hosts`. Disconnect VPN, then fix the entry:

```bash
TGIP=$(dig +short api.telegram.org A | head -1)
echo "Resolved: $TGIP"  # should be 149.154.x.x or 91.108.x.x
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  sh -c "grep -v 'api.telegram.org' /etc/hosts > /tmp/hosts.new && cp /tmp/hosts.new /etc/hosts && echo '$TGIP api.telegram.org' >> /etc/hosts"
```

**Policy must use `protocol: rest, tls: terminate`** (not `access: full`):
```bash
openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
```
> ⚠️ `openshell term` approvals create an `allow_api_telegram_org_443` policy with `access: full` that overrides this. Always re-apply the full policy after any `openshell term` approvals.

Track upstream: [openclaw/openclaw#30338](https://github.com/openclaw/openclaw/issues/30338) and [openclaw/openclaw#33013](https://github.com/openclaw/openclaw/issues/33013).

---

## Platforms

| Platform | Status |
|---|---|
| Mac M-series (ARM) | Tested |
| Linux x86 (NVIDIA GPU) | Tested |
| DGX Spark (ARM + NVIDIA GPU) | Planned |
| WSL2 | Untested |
