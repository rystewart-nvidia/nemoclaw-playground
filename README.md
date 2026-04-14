# OpenShell + OpenClaw Personal Assistant

An openshell sandbox running openclaw as a personal AI assistant, accessible via Telegram with SearXNG web search. Uses openclaw's native SearXNG plugin — no workarounds needed.

**Architecture:** openshell runs on the host and manages the sandbox. openclaw runs inside the sandbox and handles Telegram messaging and tool use. SearXNG runs on the host via Docker and is reachable inside the sandbox at `host.openshell.internal:8888`.

## Reference Docs

| | |
|---|---|
| OpenShell | https://github.com/NVIDIA/OpenShell |
| OpenClaw docs | https://docs.openclaw.ai/ |
| OpenClaw Telegram | https://docs.openclaw.ai/channels/telegram |
| OpenClaw SearXNG | https://docs.openclaw.ai/tools/searxng-search |

## Prerequisites

- Docker (Docker Desktop on Mac, native Docker on Linux)
- openshell installed on the host
- A Telegram bot token — create one via [@BotFather](https://t.me/BotFather) (`/newbot`)
- Your Telegram chat ID (see step 2)
- Ollama running on the host with a model pulled (default: `qwen3.5:9b`)

## Setup

### 1. Install openshell

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
```

### 2. Configure credentials

```bash
cp example.env .env
```

Edit `.env` and fill in:
- `TELEGRAM_BOT_TOKEN` — from @BotFather
- `ALLOWED_CHAT_IDS` — your Telegram user ID
- `OLLAMA_MODEL` — model to use (default: `qwen3.5:9b`)

To find your chat ID, send any message to your bot first, then run:
```bash
curl "https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates"
# Look for "from": { "id": <YOUR_CHAT_ID> }
```

### 3. Start SearXNG

```bash
docker compose up -d
```

Verify it's working (wait a few seconds for startup):
```bash
curl -sf -A "Mozilla/5.0" "http://localhost:8888/search?q=test&format=json" | python3 -c "import sys,json; r=json.load(sys.stdin); print(f'OK — {len(r[\"results\"])} results')"
```

### 4. Pull Ollama model

```bash
ollama pull qwen3.5:9b
# Or whatever OLLAMA_MODEL is set to in your .env
```

### 5. Build sandbox image and create sandbox

The custom Dockerfile (at repo root) extends the openclaw base image with `dnsutils` (needed for Telegram DNS fix) and pins `openclaw@latest`.

```bash
source .env
openshell sandbox create \
  --name $SANDBOX_NAME \
  --from Dockerfile \
  --policy policies/sandbox-policy.yaml
```

> **Note:** Filesystem and process policies are locked at sandbox creation time. Network policies can be hot-reloaded at any time with `openshell policy set`.

### 6. Configure openclaw

`configure-openclaw.sh` (copied into the sandbox image at `/usr/local/bin/configure-openclaw`) configures openclaw and starts the gateway. `run-setup.sh` is the host-side wrapper that handles SSH config generation and IP resolution automatically.

#### Option A — run-setup.sh (recommended, scriptable from host)

```bash
bash run-setup.sh
```

This script:
1. Generates an SSH config for the sandbox via `openshell sandbox ssh-config`
2. Resolves `api.telegram.org` IP on the host (the sandbox nameserver has no external DNS)
3. Uploads the current `configure-openclaw.sh` from the repo into the sandbox (so you can iterate on it without rebuilding the Docker image)
4. SSHes into the sandbox and runs the uploaded script with all required env vars

`openshell sandbox ssh-config` outputs an SSH `Host` block with a `ProxyCommand` that routes traffic through the openshell runtime. The host alias is always `openshell-<sandbox-name>`.

> **Note:** `configure-openclaw.sh` is also baked into the image at `/usr/local/bin/configure-openclaw` by the Dockerfile. `run-setup.sh` uploads the repo version each time, so you only need to rebuild the image if the base image or installed packages change.

#### Option B — Interactive (shell session)

```bash
source .env
# Resolve Telegram IP on the host first (required — sandbox nameserver has no external DNS)
TELEGRAM_IP=$(dig +short api.telegram.org A | grep -m1 '^[0-9]')
openshell sandbox connect $SANDBOX_NAME
# You are now inside the sandbox shell. Export all required vars, then run setup:
export TELEGRAM_BOT_TOKEN="<your-token>"
export ALLOWED_CHAT_IDS="<your-chat-id>"
export OLLAMA_MODEL="qwen3.5:9b"
export TELEGRAM_IP="<ip-from-above>"
bash /usr/local/bin/configure-openclaw
```

#### Verify setup completed

Watch the gateway log to confirm Telegram polling started:
```bash
openshell logs --tail
# Should show repeated outbound requests to api.telegram.org:443 (getUpdates)
```

Or from inside the sandbox:
```bash
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh.conf
ssh -F /tmp/os-ssh.conf openshell-$SANDBOX_NAME "tail -20 /tmp/gateway.log"
```

### 7. Apply sandbox policy (if not applied at creation)

The `--policy` flag in step 5 applies the policy at creation. To re-apply after any changes:

```bash
source .env
openshell policy set $SANDBOX_NAME --policy policies/sandbox-policy.yaml --wait
```

> **Critical:** Do NOT use `openshell term` to approve Telegram connections. It creates an `access: full` rule that overrides the `tls: terminate` setting and breaks TLS. If you already did, re-apply the policy file immediately.

## Testing

Run these in order to verify all three capabilities:

**1. Onboarding — send "hi" to your Telegram bot**

Expected: the agent walks through a brief setup/onboarding conversation.
On subsequent messages, it responds normally.

**2. Date tool call — ask "what is today's date?"**

Expected: agent uses a tool call to retrieve the date (not hardcoded text).
Verify via `openshell logs --tail` — you should see a tool invocation in the network log.

**3. Web search — ask "search for recent news about AI agents"**

Expected: agent calls the `web_search` tool, SearXNG returns results, agent summarizes them.
Verify via `docker compose logs -f searxng` — you should see an inbound search query.
The agent response should cite sources, not use shell/exec tool calls.

## Recommended Terminals

Keep these running while using the assistant:

| Terminal | Command | Purpose |
|---|---|---|
| 1 | `openshell logs --tail` | Network activity — Telegram polling, SearXNG hits, policy blocks |
| 2 | `docker compose logs -f searxng` | Confirm search queries are reaching SearXNG |

## Lifecycle Management

There are three independent layers to manage. They have a dependency order: openshell gateway → openshell sandbox → openclaw gateway.

### Layer 1: openshell gateway (host)

The openshell gateway is the host-level runtime — a Docker container that manages sandbox networking, filesystem policy, and SSH tunneling. Everything else depends on it.

| When | Command |
|---|---|
| Initial setup / after host reboot | `openshell gateway start` |
| Pause without losing state | `openshell gateway stop` |
| Full wipe (removes all sandboxes too) | `openshell gateway destroy` |
| Check status | `openshell gateway info` |

> `openshell gateway stop` preserves sandboxes and state. `openshell gateway destroy` wipes everything — you'll need to recreate the sandbox from scratch.

After a **host reboot**, the gateway doesn't start automatically. Run `openshell gateway start` before anything else.

### Layer 2: openshell sandbox

The sandbox is the isolated container where openclaw runs. It persists across gateway restarts (unless you destroy the gateway).

| When | Command |
|---|---|
| Initial setup | `openshell sandbox create --name $SANDBOX_NAME --from Dockerfile --policy policies/sandbox-policy.yaml` |
| Inspect | `openshell sandbox list` / `openshell sandbox status $SANDBOX_NAME` |
| Interactive shell | `openshell sandbox connect $SANDBOX_NAME` |
| Non-interactive SSH | `openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh.conf && ssh -F /tmp/os-ssh.conf openshell-$SANDBOX_NAME '<cmd>'` |
| Re-apply network policy | `openshell policy set $SANDBOX_NAME --policy policies/sandbox-policy.yaml --wait` |
| Delete and recreate from scratch | `openshell sandbox delete $SANDBOX_NAME` then recreate |

> **Filesystem and process policies** are locked at creation time. Only network policies can be hot-reloaded via `openshell policy set`.

> Re-apply the policy after any `openshell term` approvals — they create `access: full` overrides that break Telegram TLS.

### Layer 3: openclaw gateway (inside sandbox)

The openclaw gateway is a process inside the sandbox that handles Telegram polling and agent dispatch. It's started by `run-setup.sh` / `configure-openclaw.sh` and must be restarted manually if it stops.

**Start (or restart):**
```bash
source .env && bash run-setup.sh
```

Or restart just the gateway without re-running full setup:
```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh.conf
ssh -F /tmp/os-ssh.conf openshell-$SANDBOX_NAME \
  "pkill -f 'openclaw gateway run' 2>/dev/null || true; setsid openclaw gateway run > /tmp/gateway.log 2>&1 < /dev/null &"
```

**Check if running:**
```bash
openshell logs --tail
# Look for repeated: L7_REQUEST ... api.telegram.org ... getUpdates
```

**View gateway logs:**
```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh.conf
ssh -F /tmp/os-ssh.conf openshell-$SANDBOX_NAME "tail -50 /tmp/gateway.log"
```

> The openclaw gateway must be restarted after: sandbox recreation, config changes to `openclaw.json`, or if Telegram stops responding.

> `openshell gateway stop`/`start` does NOT automatically restart the openclaw gateway — you need to re-run setup or restart it manually.

### After a host reboot

```bash
source .env
openshell gateway start          # 1. bring the host runtime back up
# wait ~10s for gateway to be ready
bash run-setup.sh                # 2. restart the openclaw gateway (sandbox persists)
```

### Changing the Ollama model

Edit `.env` to update `OLLAMA_MODEL`, then reconfigure inside the sandbox:
```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh.conf
ssh -F /tmp/os-ssh.conf openshell-$SANDBOX_NAME \
  "openclaw config set agents.defaults.model.primary 'ollama/$OLLAMA_MODEL'"
```

### Accessing the openclaw dashboard

The openclaw canvas (dashboard) runs inside the sandbox at `http://127.0.0.1:18789/__openclaw__/canvas/`. Use `openshell forward` to tunnel it to the host:

```bash
source .env
openshell forward start 18789 $SANDBOX_NAME -d
```

Then open [http://localhost:18789/__openclaw__/canvas/](http://localhost:18789/__openclaw__/canvas/) in your browser.

To stop the forward:
```bash
openshell forward stop 18789
```

> The `-d` flag runs the forward in the background. `openshell forward list` shows active forwards.

### Restarting the gateway

The gateway runs as a background process (`setsid`). To restart it:
```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh.conf
ssh -F /tmp/os-ssh.conf openshell-$SANDBOX_NAME \
  "pkill -f 'openclaw gateway run' 2>/dev/null || true; setsid openclaw gateway run > /tmp/gateway.log 2>&1 < /dev/null &"
```

> **Why not `openclaw gateway install`?** The base image does not run systemd. The `install` command attempts to register a systemd service and fails. The `setsid` approach starts the gateway as a detached background process that survives the SSH session.

## Troubleshooting

**Telegram not working / "Network request failed" in gateway log**
This is usually a DNS issue. The sandbox nameserver has no external DNS, so openshell's hostname verifier can't resolve `api.telegram.org`. `configure-openclaw.sh` fixes this by writing a static `/etc/hosts` entry. Re-run `run-setup.sh` if it was skipped.

**Telegram TLS error / `UnknownIssuer` in logs**
Re-apply the policy file. This happens when `openshell term` creates an `access: full` override:
```bash
source .env && openshell policy set $SANDBOX_NAME --policy policies/sandbox-policy.yaml --wait
```

**SearXNG not reachable from sandbox**
Check the `allowed_ips` in `policies/sandbox-policy.yaml`. The correct host gateway IP depends on your platform:
- macOS Docker Desktop: `192.168.65.254`
- Linux / native Docker: `172.17.0.1`

**Web search returns no results (but SearXNG logs show a request)**
Check that `web_search` is not in a deny list in `openclaw.json` inside the sandbox:
```bash
ssh -F /tmp/os-ssh.conf openshell-$SANDBOX_NAME "openclaw config get tools"
```

**Bot not responding / no `getUpdates` in logs**
```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh.conf
ssh -F /tmp/os-ssh.conf openshell-$SANDBOX_NAME "tail -50 /tmp/gateway.log"
```
If the gateway isn't running, see "Restarting the gateway" above.

**`model-pricing bootstrap failed: TypeError: fetch failed` in gateway log**
Expected — openclaw tries to fetch model pricing from `openrouter.ai` which is not in the sandbox policy (intentionally). This warning is harmless and does not affect functionality.

**Bot token rejected / "unauthorized" from Telegram**
Verify no extra whitespace in the token value. If needed, regenerate via @BotFather and re-run setup.

**`openclaw.json` was zeroed or corrupted**
Re-run the full setup:
```bash
source .env && bash run-setup.sh
```
