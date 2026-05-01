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
| OpenClaw plugin quick start | https://docs.openclaw.ai/plugins/building-plugins#quick-start-tool-plugin |
| OpenClaw plugin CLI | https://docs.openclaw.ai/cli/plugins |

## Prerequisites

- Docker (Docker Desktop on Mac, native Docker on Linux)
- openshell installed on the host
- A Telegram bot token — create one via [@BotFather](https://t.me/BotFather) (`/newbot`)
- Your Telegram chat ID (see step 2)
- Ollama running on the host with a model pulled (default: `qwen3.5:9b`)

## Setup

### 1. Install openshell

```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | OPENSHELL_VERSION=v0.0.32 sh
```

### 2. Configure credentials

```bash
cp example.env .env
```

Edit `.env` and fill in:
- `TELEGRAM_BOT_TOKEN` — from @BotFather
- `ALLOWED_CHAT_IDS` — your Telegram user ID (see options below)
- `OLLAMA_MODEL` — model to use (default: `qwen3.5:9b`)

**Option A — allowlist (recommended for personal use)**

Set `ALLOWED_CHAT_IDS` to your Telegram user ID. Get it from [@userinfobot](https://t.me/userinfobot). Multiple IDs are comma-separated: `ALLOWED_CHAT_IDS=111111,222222`

Only users in the list can message the bot. Unknown users are silently dropped.

**Option B — pairing codes (no chat ID needed)**

Leave `ALLOWED_CHAT_IDS` unset and edit `configure-openclaw.sh` to use `dmPolicy: pairing`:

```bash
# in configure-openclaw.sh, replace the allowFrom loop and dmPolicy lines with:
openclaw config set channels.telegram.dmPolicy pairing
```

With pairing mode, the first DM from any user generates a code. Approve it from inside the sandbox:
```bash
openclaw pairing list telegram
openclaw pairing approve telegram <CODE>
```

Pairing is useful when you want to add users dynamically or don't know chat IDs at setup time. The tradeoff: anyone who finds your bot's username can send a pairing request, so you need to actively approve codes.

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
  --name "$SANDBOX_NAME" \
  --from ./Dockerfile \
  --policy ./policies/sandbox-policy.yaml \
  -- exit
```

> **Note:** `-- exit` passes `exit` as the command to run in the sandbox on creation, which causes it to exit immediately instead of dropping into an interactive shell. To open a shell manually: `openshell sandbox connect $SANDBOX_NAME`

> **Note:** Filesystem and process policies are locked at sandbox creation time. Network policies can be hot-reloaded at any time with `openshell policy set`.

### 6. Configure openclaw

`configure-openclaw.sh` runs inside the sandbox and does three things:
1. Sets the Telegram channel config (bot token, allowed chat IDs, dm policy)
2. Writes the Ollama provider, SearXNG plugin, and enabled plugin entries to `openclaw.json` via Python (required because `openclaw config set` validates the full schema after each write and rejects partial provider objects)
3. Validates the OpenClaw config

`run-setup.sh` is the host-side wrapper that handles SSH config generation, optional workspace restore, linked local plugin install, configuration, and gateway start.

#### Option A — run-setup.sh (recommended, scriptable from host)

```bash
bash run-setup.sh [options]
```

Options:
| Flag | Effect |
|---|---|
| `--from-backup [timestamp]` | Restore workspace from backup after setup (most recent if no timestamp given) |
| `--no-restore` | Skip the backup restore prompt entirely |
| `--regenerate-ssh` | Auto-confirm SSH config regeneration without prompting |

This script:
1. Generates an SSH config for the sandbox via `openshell sandbox ssh-config`
2. Uploads the current `configure-openclaw.sh` from the repo into the sandbox (so you can iterate on it without rebuilding the Docker image)
3. Prompts to restore a workspace backup if one exists (unless `--no-restore` or `--from-backup` is passed)
4. Uploads `plugins/zenquotes-random-quote` into the OpenClaw workspace
5. Installs ZenQuotes with `openclaw plugins install --force -l` so OpenClaw owns the linked local plugin registration
6. SSHes into the sandbox and runs the config script with all required env vars
7. Starts the openclaw gateway

`openshell sandbox ssh-config` outputs an SSH `Host` block with a `ProxyCommand` that routes traffic through the openshell runtime. The host alias is always `openshell-<sandbox-name>`.

> **Note:** `configure-openclaw.sh` is also baked into the image at `/usr/local/bin/configure-openclaw` by the Dockerfile. `run-setup.sh` uploads the repo version each time, so you only need to rebuild the image if the base image or installed packages change.

#### Option B — Interactive (shell session)

```bash
source .env
openshell sandbox connect $SANDBOX_NAME
# You are now inside the sandbox shell. Export all required vars, then run setup:
export TELEGRAM_BOT_TOKEN="<your-token>"
export ALLOWED_CHAT_IDS="<your-chat-id>"
export OLLAMA_MODEL="qwen3.5:9b"
bash /usr/local/bin/configure-openclaw
```

> **Note:** The interactive path does not upload or install local plugins. Use `run-setup.sh` when you want the ZenQuotes plugin installed and enabled.

#### Custom Plugin Example

This repo includes a minimal local OpenClaw tool plugin at `plugins/zenquotes-random-quote`. It registers `zenquotes_random_quote`, which fetches a random quote from `https://zenquotes.io/api/random`.

`run-setup.sh` uploads the local plugin folder into the sandbox workspace and installs it with OpenClaw's linked local plugin flow:
```bash
openclaw plugins install --force -l /sandbox/.openclaw/workspace/openclaw-plugins/zenquotes-random-quote
```

The sandbox policy includes a narrow `zenquotes` rule for `GET /api/random`. After setup, verify the plugin from the host with:
```bash
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh-${SANDBOX_NAME}.conf
ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME "openclaw plugins inspect zenquotes"
```

#### Verify setup completed

Watch the gateway log to confirm Telegram polling started:
```bash
openshell logs --tail
# Should show repeated outbound requests to api.telegram.org:443 (getUpdates)
```

Or from inside the sandbox:
```bash
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh-${SANDBOX_NAME}.conf
ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME "tail -20 /tmp/gateway.log"
```

### 7. Apply sandbox policy (if not applied at creation)

The `--policy` flag in step 5 applies the policy at creation. To re-apply after any changes:

```bash
source .env
openshell policy set $SANDBOX_NAME --policy policies/sandbox-policy.yaml --wait
```

> **Critical:** Do NOT use `openshell term` to approve Telegram connections. It creates an `access: full` rule that overrides the `tls: terminate` setting and breaks TLS. If you already did, re-apply the policy file immediately.

## Testing

Run these in order to verify the core capabilities:

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

**4. Random quote tool — ask "fetch a random ZenQuotes quote"**

Expected: agent calls the `zenquotes_random_quote` tool and returns a quote plus author.
Verify via `openshell logs --tail` — you should see an allowed `GET` request to `zenquotes.io:443` for `/api/random`.

## Logs

There are three independent log sources, each showing a different layer of the system:

### openshell network log

```bash
openshell logs --tail
```

Shows every outbound connection the sandbox makes — protocol, destination, path, and whether it was allowed or blocked. This is the primary signal for connectivity issues.

Key patterns to look for:
- `L7_REQUEST ... api.telegram.org ... /bot.../getUpdates` — gateway is polling (healthy)
- `L7_REQUEST ... host.openshell.internal:8888 ... /search` — SearXNG being called
- `FORWARD blocked` — a connection was denied by policy (shows reason and destination)
- `TLS` errors — usually means wrong policy mode (`access: full` instead of `tls: terminate`)

Useful variants:
```bash
openshell logs --tail --source sandbox --level debug   # more verbose
openshell logs --tail | grep api.telegram.org          # Telegram only
openshell logs --tail | grep BLOCKED                   # policy blocks only
```

### openclaw gateway log

```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh-${SANDBOX_NAME}.conf
ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME "tail -f /tmp/gateway.log"
```

Shows openclaw gateway lifecycle events: startup, config loads, channel connect/disconnect, and application-level errors. Does NOT show individual message polls — use the openshell network log for that.

Useful for diagnosing:
- Gateway startup failures (bad config, missing token)
- Channel errors (`deleteWebhook` failures, auth errors from Telegram)
- Config hot-reload events

### SearXNG log

```bash
docker compose logs -f searxng
```

Shows every search query hitting SearXNG, which engines handled it, per-engine latency, and errors (rate limits, blocked engines). Debug logging is enabled in `searxng/settings.yml` (`general.debug: true`).

Useful for diagnosing why search results are empty or partial.

---

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
| Initial setup | `openshell sandbox create --name "$SANDBOX_NAME" --from ./Dockerfile --policy ./policies/sandbox-policy.yaml --keep -- exit` |
| Inspect | `openshell sandbox list` / `openshell sandbox status $SANDBOX_NAME` |
| Interactive shell | `openshell sandbox connect $SANDBOX_NAME` |
| Non-interactive SSH | `openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh-${SANDBOX_NAME}.conf && ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME '<cmd>'` |
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
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh-${SANDBOX_NAME}.conf
ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME bash << 'ENDSSH'
openclaw gateway stop >/dev/null 2>&1 || true
kill -9 $(pgrep -f "openclaw gateway" 2>/dev/null) 2>/dev/null || true
kill -9 $(pgrep -f "openclaw-gateway" 2>/dev/null) 2>/dev/null || true
setsid openclaw gateway run > /tmp/gateway.log 2>&1 < /dev/null &
ENDSSH
```

**Check if running:**
```bash
openshell logs --tail
# Look for repeated: L7_REQUEST ... api.telegram.org ... getUpdates
```

**View gateway logs:**
```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh-${SANDBOX_NAME}.conf
ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME "tail -50 /tmp/gateway.log"
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

### Backup and restore

The agent workspace (`/sandbox/.openclaw/workspace`) holds personality and memory files that accumulate over time (SOUL.md, USER.md, IDENTITY.md, AGENTS.md, MEMORY.md, memory/). These are lost when the sandbox is destroyed or recreated. Back up before any destructive operation.

**Create a backup:**
```bash
bash scripts/backup-workspace.sh backup
```

Backups are stored at `$BACKUP_BASE/<sandbox-name>/<timestamp>/` (default: `./backups/`). Override the location by setting `BACKUP_BASE` in `.env`.

**List available backups:**
```bash
bash scripts/backup-workspace.sh list
```

**Restore most recent backup:**
```bash
bash scripts/backup-workspace.sh restore
```

**Restore a specific backup:**
```bash
bash scripts/backup-workspace.sh restore 20260421-143022
```

All restore commands prompt for confirmation before uploading. Pass `--yes` to skip:
```bash
bash scripts/backup-workspace.sh restore --yes
```

**Restore automatically as part of setup:**

If a backup exists, `run-setup.sh` prompts to restore after configuration. To restore without prompting:
```bash
bash run-setup.sh --from-backup
```

**Typical rebuild-and-restore workflow:**
```bash
# 1. Back up before destroying
bash scripts/backup-workspace.sh backup

# 2. Recreate the sandbox
source .env
openshell sandbox delete $SANDBOX_NAME
openshell sandbox create --name "$SANDBOX_NAME" --from ./Dockerfile --policy ./policies/sandbox-policy.yaml -- exit

# 3. Set up and restore in one step
bash run-setup.sh --regenerate-ssh --from-backup
```

### Changing the Ollama model

Edit `.env` to update `OLLAMA_MODEL`, then reconfigure inside the sandbox:
```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh-${SANDBOX_NAME}.conf
ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME \
  "openclaw config set agents.defaults.model.primary 'ollama/$OLLAMA_MODEL'"
```

### Accessing the openclaw dashboard

First, get the dashboard URL and auth token:
```bash
source .env
openshell sandbox exec $SANDBOX_NAME openclaw dashboard
```

This prints the local URL and token. Then forward the port to your host:
```bash
openshell forward start 18789 $SANDBOX_NAME -d
```

Open the URL from the output above in your browser.

To stop the forward:
```bash
openshell forward stop 18789
```

> The `-d` flag runs the forward in the background. `openshell forward list` shows active forwards.

### Restarting the gateway

The gateway runs as a background process (`setsid`). To restart it:
```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh-${SANDBOX_NAME}.conf
ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME bash << 'ENDSSH'
openclaw gateway stop >/dev/null 2>&1 || true
kill -9 $(pgrep -f "openclaw gateway" 2>/dev/null) 2>/dev/null || true
kill -9 $(pgrep -f "openclaw-gateway" 2>/dev/null) 2>/dev/null || true
setsid openclaw gateway run > /tmp/gateway.log 2>&1 < /dev/null &
ENDSSH
```

> **Why not `openclaw gateway install`?** The base image does not run systemd. The `install` command attempts to register a systemd service and fails. The `setsid` approach starts the gateway as a detached background process that survives the SSH session.

## Troubleshooting

**Telegram not working / "Network request failed" in gateway log**
Check that the gateway is running (`openshell logs --tail` should show `getUpdates` requests). If not, re-run `run-setup.sh` to restart it.

**Telegram TLS error / `UnknownIssuer` in logs**
Re-apply the policy file. This happens when `openshell term` creates an `access: full` override:
```bash
source .env && openshell policy set $SANDBOX_NAME --policy policies/sandbox-policy.yaml --wait
```

**Ollama or SearXNG not reachable from sandbox**
Check the `allowed_ips` in `policies/sandbox-policy.yaml`. The correct host gateway IP depends on your platform:
- macOS Docker Desktop: `192.168.65.254`
- Linux / native Docker: `172.17.0.1`
- OpenShell bridge: `172.29.0.254`

**Web search returns no results (but SearXNG logs show a request)**
Check that `web_search` is not in a deny list in `openclaw.json` inside the sandbox:
```bash
ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME "openclaw config get tools"
```

**Bot not responding / no `getUpdates` in logs**
```bash
source .env
openshell sandbox ssh-config $SANDBOX_NAME > /tmp/os-ssh-${SANDBOX_NAME}.conf
ssh -F /tmp/os-ssh-${SANDBOX_NAME}.conf openshell-$SANDBOX_NAME "tail -50 /tmp/gateway.log"
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
