# CLAUDE.md

## Purpose
This repo is a living setup guide for running NemoClaw + Ollama (+ Telegram). The primary artifact is `README.md`.

## Open todos
- ✅ **Verify Telegram bridge end-to-end** — DONE 2026-04-12. Bot responds to DMs.
- ⏳ **Make post-onboard fixes persistent** — `/etc/hosts`, symlinks, and token injection are all lost on sandbox restart. Currently handled by `scripts/post-onboard.sh`. Permanent fix would require HostAlias + Landlock policy changes at `nemoclaw onboard` time.
- ⏳ **Investigate native gateway lifecycle management** — `start-openclaw-gateway.sh` is a collection of hacks: `nohup` + background process with no PID file, `sleep 2` timing guess before status check, no kill-before-start (starting twice conflicts), and brittle `sed` parsing of `ssh-config` output. Check if newer openclaw/nemoclaw versions provide: (1) `openclaw gateway start/stop/status` commands with proper daemon management, (2) nemoclaw managing the gateway as part of sandbox lifecycle (auto-start on onboard, restart on crash), (3) a first-class API for running commands in the sandbox without raw SSH + ProxyCommand parsing.
- ⏳ **Investigate native alternatives to post-onboard.sh workarounds** — The script is a collection of hacks. Check if newer versions address: (1) `openshell:resolve:env:` placeholder resolution at runtime (eliminating token injection), (2) a HostAlias or DNS config in `nemoclaw onboard` for external hostnames (eliminating `/etc/hosts` injection), (3) Landlock policy that makes `/sandbox/.openclaw/` writable for specific subdirs/files (eliminating all the symlink surgery), (4) a supported way to pass post-onboard setup hooks to nemoclaw so these steps don't have to be run manually after every `--recreate-sandbox`.
- ✅ **Test initial openclaw onboarding flow** — verified 2026-04-12 on fresh sandbox; bot replied and remembered user's name
- ✅ **SearXNG as a dedicated tool** — DONE 2026-04-12. `web_fetch` blocked by openclaw SSRF layer for `.internal` domains. Final approach: `exec` + `curl` to `http://host.openshell.internal:8888/search?q=...&format=json`. Agent taught via `TOOLS.md` in workspace (`/sandbox/.openclaw-data/workspace/TOOLS.md`). NOT solvable via plugin in v2026.3.11 — used workspace context injection instead.
- ✅ **Disable/hide unusable `web_search` tool** — DONE 2026-04-12. `tools.deny: ["web_search"]` in `openclaw.json` (top-level key). Validated working.
- ⏳ **SearXNG TOOLS.md not being injected** — `TOOLS.md` is 0 bytes (heredoc write in `post-onboard.sh` is broken — heredoc is consumed by local shell, not passed to kubectl exec) AND openclaw may not read `TOOLS.md` at all. Injected files are: `AGENTS.md`, `BOOTSTRAP.md`, `HEARTBEAT.md`. Need to: (1) fix the write approach in `post-onboard.sh` (use `kubectl exec -i` with piped stdin instead of heredoc), (2) confirm whether to append to `AGENTS.md` or whether `TOOLS.md` is also read. Check existing `AGENTS.md` content before overwriting.
- ⏳ **Replace SearXNG TOOLS.md workaround with MCP tool** — Current approach (TOOLS.md context injection + `exec`/curl) is intentionally temporary. openclaw v2026.3.11 has no MCP support; it was confirmed added in later versions. When upgrading openclaw, replace with a proper registered MCP `search` tool: write a minimal stdio MCP server that wraps SearXNG, register it via `openclaw mcp set`. This eliminates the TOOLS.md hack and gives the agent a first-class named tool.
- ⏳ **`openclaw doctor --fix` config migration blocked by Landlock** — `doctor --fix` wants to restructure `channels.telegram` accounts in `openclaw.json` but fails with EACCES (Landlock blocks writes inside sandbox). The migration was not saved. Investigate: (1) whether the migration matters for correct operation, (2) whether it should be applied via `kubectl exec` in `post-onboard.sh`, (3) whether newer openclaw/Landlock versions resolve this.
- ⏳ **Investigate live model swapping** — `NEMOCLAW_MODEL` and `NEMOCLAW_PRIMARY_MODEL_REF` are baked into the sandbox pod's environment variables at `nemoclaw onboard` time. Changing the model in `openclaw.json` alone has no effect — the gateway reads the env vars. Investigate: (1) whether nemoclaw provides a `nemoclaw my-assistant set-model <model>` or equivalent command, (2) whether patching the pod env vars via `kubectl patch` + pod restart is viable without a full onboard, (3) whether there's a nemoclaw API for this.
- ⏳ **Policy builder/applier UI** — the current policy workflow (hand-editing YAML, running `openshell policy set`, knowing about full-replacement semantics, `allowed_ips` for internal IPs, etc.) is too complex for most users. Build a simple interface that lets users add/remove endpoints and applies the full policy file correctly.

## Documentation references
- NemoClaw CLI: https://docs.nvidia.com/nemoclaw/latest/reference/commands.html
- OpenClaw CLI: https://docs.openclaw.ai/cli
- OpenClaw Channels: https://docs.openclaw.ai/channels/index
- OpenClaw Telegram: https://docs.openclaw.ai/channels/telegram
- OpenShell: https://docs.nvidia.com/openshell/latest/get-started

## Which CLI does what
- `nemoclaw` (host): create/manage sandboxes, apply policies, start tunnel/services, onboard
- `openshell` (host): inspect sandboxes, set network/filesystem policy, view logs, SSH config
- `openclaw` (inside sandbox only): run agents, configure channels/plugins, manage sessions, TUI
- Channel messaging (Telegram, Discord) is configured during `nemoclaw onboard` or by writing to `openclaw.json` via kubectl exec — NOT via `nemoclaw start` (that's cloudflared tunnel only)
- `nemoclaw start` = cloudflared tunnel. `nemoclaw status` = sandbox list + cloudflared. Neither reflects Telegram state.
- Telegram status: `openclaw channels status` inside sandbox
- Gateway must be started manually after config changes: `nohup openclaw gateway run > /tmp/gateway.log 2>&1 &` inside sandbox (or use `./scripts/start-openclaw-gateway.sh` from host)
- Pairing: only needed if `dmPolicy: pairing` — first DM generates a code → `openclaw pairing list telegram` → `openclaw pairing approve telegram <CODE>`. With `dmPolicy: allowlist` and user in `allowFrom`, DMs work without pairing.

## Architecture note
openclaw is NOT installed directly on the host. nemoclaw creates a Docker sandbox running an OpenShell gateway (which controls network, filesystem, and process access) with openclaw running inside it. All openclaw interaction goes through that sandbox.

## NemoClaw k3s cluster internals
NemoClaw runs the OpenShell cluster as a **k3s Kubernetes cluster** inside a single Docker container (`openshell-cluster-nemoclaw`). Key pods in the `openshell` namespace:

```
pod/openshell-0        # OpenShell server (port 8080/30051). Runs openshell-server, manages policy and SSH tunnels.
pod/my-assistant       # The sandbox pod. This is where openclaw runs.
pod/baseten-assistant  # Another sandbox (if multiple sandboxes created).
```

kube-system pods include CoreDNS and the k3s infrastructure.

**Why this matters for debugging**:
- `docker exec openshell-cluster-nemoclaw kubectl ...` gives direct access to the cluster
- The sandbox pod (`my-assistant`) is the running environment — you can kubectl exec into it directly, bypassing the SSH tunnel. This is useful for low-level network/config inspection when SSH doesn't give enough access.
- The sandbox's `/etc/resolv.conf` points to `10.200.0.1` (OpenShell proxy), which does NOT forward DNS queries to external resolvers. `getent hosts <external>` returns nothing from inside the sandbox. This is by design — all outbound traffic routes through the proxy, not direct DNS/TCP.
- The network proxy at `10.200.0.1:3128` is the OpenShell policy enforcement point. It intercepts all egress from the sandbox.
- OpenShell's `mechanistic_mapper` does its own DNS resolution (separate from the sandbox) to verify destination IPs aren't internal. If that DNS fails, it blocks the connection.

**Useful kubectl commands**:
```bash
# List sandbox pods
docker exec openshell-cluster-nemoclaw kubectl get all -n openshell

# Exec into sandbox directly (no SSH needed)
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- <command>

# Exec into openshell server pod
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell openshell-0 -- <command>

# Read sandbox openclaw config
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- cat /sandbox/.openclaw/openclaw.json
```

## Safe config edit pattern (avoid zeroing openclaw.json)
**NEVER** pipe `cat openclaw.json | ... | cat > openclaw.json` in a single pipeline — it races and zeros the file.
Always use a host-side temp file:
```bash
# 1. Read to host
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  cat /sandbox/.openclaw/openclaw.json > /tmp/oc.json

# 2. Modify on host (example: add tools.deny)
python3 -c "
import json
with open('/tmp/oc.json') as f: c = json.load(f)
c.setdefault('tools',{})['deny'] = ['web_search']
print(json.dumps(c,indent=2))
" > /tmp/oc-updated.json

# 3. Write back
docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell my-assistant -- \
  sh -c 'cat > /sandbox/.openclaw/openclaw.json' < /tmp/oc-updated.json
```

## Current environment state (as of 2026-04-12)
- **nemoclaw**: v0.0.9, installed at `~/.local/bin/nemoclaw`
- **ollama**: running at `localhost:11434` with qwen3 family + gpt-oss:20b models
- **Docker**: running; port 8080 is taken by `openshell-cluster-nemoclaw`
- **sandbox**: `my-assistant`, model `qwen3:30b`, provider `ollama-local`, phase `Ready` (rebuilt fresh 2026-04-12, end-to-end verified)
- **openclaw**: v2026.3.11 (from fresh sandbox rebuild 2026-04-12)
- **Telegram**: fully working — gateway running (mode:polling, @whiskey_papa_bot), bot responds to DMs; user ID `8362082345` in `allowFrom`
- **SearXNG**: running via Docker Compose on host port **8888** (not 8080 — conflict with openshell cluster)
- **Active policy**: v5 (applied via `post-onboard.sh` 2026-04-12)
- **Scripts**: `scripts/post-onboard.sh` and `scripts/start-openclaw-gateway.sh` — run after every onboard

## What works
- ✅ Basic chat: `openclaw agent --agent main --local -m "hi" --session-id test`
- ✅ Date tool call: returns correct date
- ✅ SearXNG reachable from host on port 8888
- ✅ SearXNG reachable from inside sandbox — fixed with `allowed_ips` in policy (see below)
- ✅ Sandbox rebuilt with fresh openclaw; Telegram configured via provider pipeline
- ✅ openclaw gateway running (mode:polling) — bot token injected, DNS fixed, VPN off
- ✅ `openclaw pairing list telegram` works — credentials symlink created
- ✅ Telegram end-to-end DM — bot responds to DMs (2026-04-12)

## Known Bugs / Workarounds

### openclaw gateway — RESOLVED as of 2026-04-12
**Status**: Gateway running (mode:polling, @whiskey_papa_bot). Three separate issues were fixed.

**Upstream issues tracked**:
- [openclaw/openclaw#30338](https://github.com/openclaw/openclaw/issues/30338) — undici dispatcher workaround
- [openclaw/openclaw#33013](https://github.com/openclaw/openclaw/issues/33013) — Telegram channel broken with undici + VPN
- [NVIDIA/NemoClaw#391](https://github.com/NVIDIA/NemoClaw/issues/391) — missing `node` in policy binaries causing 403s

**Issue 1 — Policy mode**: `access: full` causes OpenShell to close the TCP socket during TLS upgrade (Node.js can't complete handshake). Fix: use `protocol: rest, tls: terminate` — OpenShell terminates TLS itself and forwards HTTP to Telegram.

**Issue 2 — Sandbox DNS doesn't resolve external domains**: `/etc/resolv.conf` points to `10.200.0.1` which has NO DNS on port 53. OpenShell's `mechanistic_mapper` does hostname→IP checks from inside the sandbox pod — if it can't resolve, it blocks the connection as "potentially internal".

Fix: add `api.telegram.org` to sandbox `/etc/hosts` via kubectl exec (bypasses Landlock):
```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  sh -c 'echo "149.154.166.110 api.telegram.org" >> /etc/hosts'
```
> ⚠️ Not persistent — lost when sandbox pod restarts. Re-run after any `nemoclaw onboard --recreate-sandbox`.

**Issue 3 — `openshell:resolve:env:TELEGRAM_BOT_TOKEN` not resolved**: openclaw v2026.4.10 uses the literal placeholder string as the bot token → Telegram returns 404. Fix: inject real token directly into `openclaw.json` via kubectl exec:
```bash
set -a && source .env && set +a
TOKEN="$TELEGRAM_BOT_TOKEN" python3 -c "
import json, sys, os
config = json.load(open('/dev/stdin'))
config['channels']['telegram']['accounts']['main']['botToken'] = os.environ['TOKEN']
print(json.dumps(config, indent=2))
" < <(docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- cat /sandbox/.openclaw/openclaw.json) > /tmp/openclaw-updated.json

docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell my-assistant -- \
  sh -c 'cat > /sandbox/.openclaw/openclaw.json' < /tmp/openclaw-updated.json
```
> ⚠️ Also not persistent — lost on sandbox rebuild. Re-run after any `nemoclaw onboard --recreate-sandbox`.

**Issue 4 — VPN blocks Telegram**: Host network SNI-filtering blocks `api.telegram.org`. Disconnect VPN.

**openshell term approvals break policy**: Approvals create `allow_*` policies that override named policies with unpredictable access modes. Always re-apply full policy after any approval:
```bash
openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
```

### `openclaw pairing list telegram` fails with EACCES — RESOLVED as of 2026-04-12
**Cause**: openclaw tries to write to `/sandbox/.openclaw/credentials/` which doesn't exist and is under the Landlock read-only path `/sandbox/.openclaw`.

**Fix**: Create the directory as a symlink to the read-write `/sandbox/.openclaw-data/` path (following the existing pattern used by other writable openclaw dirs):
```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  sh -c 'rm -rf /sandbox/.openclaw/credentials && mkdir -p /sandbox/.openclaw-data/credentials && chown sandbox:sandbox /sandbox/.openclaw-data/credentials && ln -s /sandbox/.openclaw-data/credentials /sandbox/.openclaw/credentials'
```
Also added `/sandbox/.openclaw/credentials` to `read_write` in `policies/sandbox-policy.yaml` (policy v28).
> ⚠️ Not persistent — symlink is lost on sandbox rebuild. Re-run after `nemoclaw onboard --recreate-sandbox`.

### `EACCES /sandbox/.openclaw/workspace-state.json` — RESOLVED as of 2026-04-12
**Cause**: openclaw writes a `workspace-state.json` file to `/sandbox/.openclaw/` when processing agent runs (even without explicit `agents.defaults.workspace` config). Landlock blocks writes.

**Impact**: Gateway dispatches fail — every Telegram message gets an error response. Bot is "non-responsive" (sends error messages the user may not see, but doesn't respond to queries).

**Fix**: Same symlink pattern:
```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  sh -c 'rm -f /sandbox/.openclaw/workspace-state.json && touch /sandbox/.openclaw-data/workspace-state.json && chown sandbox:sandbox /sandbox/.openclaw-data/workspace-state.json && ln -s /sandbox/.openclaw-data/workspace-state.json /sandbox/.openclaw/workspace-state.json'
```
Also added `/sandbox/.openclaw/workspace-state.json` to `read_write` in `policies/sandbox-policy.yaml`.
> ⚠️ Not persistent — lost on sandbox rebuild. Now included in step [4/4] of `scripts/post-onboard.sh`.

**Note (2026-04-12)**: `agents.defaults.workspace` is now set (required for TOOLS.md injection). The symlink + policy `read_write` entry appears sufficient for openclaw to write workspace-state.json without EACCES. If EACCES returns after a rebuild, re-run `scripts/post-onboard.sh` (step 4 creates the symlink).

### `openclaw.json` zeroed out after config edit
**Cause**: Reading and writing `openclaw.json` through the same pipeline races — `cat > openclaw.json` truncates the file before `cat openclaw.json` finishes reading. Symptom: file size becomes 0.

**Fix**: Always use a host-side temp file. Read → modify on host → write back as separate commands (not a single pipeline). See "Safe config edit pattern" in the Useful debug commands section.

**Recovery**: Use `openclaw.json.bak` (openclaw creates this automatically). See "openclaw.json got zeroed out" in the Troubleshooting section of README.md.

### `session file locked (timeout 10000ms)` after a timeout
**Cause**: A previous agent run timed out (e.g. LLM response too slow on qwen3:30b) and left a stale `.lock` file in `/sandbox/.openclaw-data/agents/main/sessions/`.

**Fix**:
```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  sh -c 'rm -f /sandbox/.openclaw-data/agents/main/sessions/*.lock && echo "Locks cleared"'
```

### `failed to persist update offset: EACCES /sandbox/.openclaw/telegram` — RESOLVED as of 2026-04-12
**Cause**: Same Landlock pattern — gateway tries to write update offsets to `/sandbox/.openclaw/telegram` (read-only path).

**Impact**: Non-fatal — gateway still receives and responds to messages. But without persistence, the bot may re-process old messages after a restart.

**Fix**: Same symlink pattern:
```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  sh -c 'rm -rf /sandbox/.openclaw/telegram && mkdir -p /sandbox/.openclaw-data/telegram && chown sandbox:sandbox /sandbox/.openclaw-data/telegram && ln -s /sandbox/.openclaw-data/telegram /sandbox/.openclaw/telegram'
```
Also added `/sandbox/.openclaw/telegram` to `read_write` in `policies/sandbox-policy.yaml` (policy v30).
> ⚠️ Not persistent — lost on sandbox rebuild. Re-run after `nemoclaw onboard --recreate-sandbox`.

## Logging: gateway.log vs openshell logs

`/tmp/gateway.log` (openclaw's own log) only captures **lifecycle events**: startup, restarts, errors, config hot-reloads. It does NOT log individual message polls or message receipt.

`openshell logs --tail` captures **network-level activity**: every CONNECT and L7_REQUEST through the proxy. This is the useful log for debugging Telegram connectivity — you'll see `getUpdates`, `sendMessage`, etc. actively polling.

## Architecture note: policy set replaces entire policy
`openshell policy set` **replaces** the full sandbox policy — it does not merge.
Always use `policies/sandbox-policy.yaml` (in this repo) as the full policy file.
It includes: base openclaw-sandbox policy + pypi + npm + searxng + telegram.

To apply:
```bash
openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
```

To sync live policy back to file after `openshell term` approvals add new rules:
```bash
openshell policy get my-assistant --full
# copy the network_policies section back into policies/sandbox-policy.yaml manually
```

⚠️ **Never use `openshell term` approvals for Telegram (or other `protocol: rest` endpoints).** Approvals create new `allow_*` policies that override named policies with unpredictable access modes:
- In some OpenShell versions: `access: full` — which breaks TLS for Node.js
- In other versions: no access mode — which breaks OPA evaluation entirely and 403s all connections

After any `openshell term` approval, immediately re-apply the full policy to clean up:
```bash
openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
```

> **Policy changes take effect immediately** — OpenShell reloads the policy on the fly (no sandbox or gateway restart needed). The gateway log will show "Policy reloaded successfully" within a few seconds of `openshell policy set`.

## How to run commands in sandbox non-interactively
```bash
ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o GlobalKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o "ProxyCommand=/Users/rystewart/.local/bin/openshell ssh-proxy --gateway-name nemoclaw --name my-assistant" \
  -l sandbox localhost \
  '<command>'
```
Get the ProxyCommand for any sandbox with: `openshell sandbox ssh-config <sandbox-name>`

## Secrets
Secrets (bot tokens, chat IDs, etc.) go in `.env` (gitignored). `.env.example` is committed and shows what's needed. Never inline secrets in README commands — always reference `source .env` + the variable name.

## Key rules
**Keep README.md in sync with reality.**

**Always document both ways to run sandbox commands** — whenever a new openclaw command or workflow is added to the README, show both:
1. Interactive: `nemoclaw <name> connect` → run command inside
2. Non-interactive: SSH with ProxyCommand from `openshell sandbox ssh-config <name>` If we run a command and it behaves differently than documented — different flags, extra steps, workarounds needed — update README.md immediately before moving on.

## Useful debug commands
```bash
# Watch sandbox logs live (primary Telegram debug tool — shows every getUpdates/sendMessage)
openshell logs --tail
openshell logs --tail --source sandbox --level debug

# Verify openclaw gateway is polling (look for getUpdates in the output)
openshell logs --tail | grep -i telegram

# Check Telegram channel status (run from host via SSH)
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -o "ProxyCommand=/Users/rystewart/.local/bin/openshell ssh-proxy --gateway-name nemoclaw --name my-assistant" \
  -l sandbox localhost 'openclaw channels status'

# Check sandbox status
nemoclaw my-assistant status

# Check what's on a port
lsof -i :8080

# Check running containers
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"

# Verify SearXNG from host
curl -sf "http://localhost:8888/search?q=test&format=json" | python3 -m json.tool | head -20

# Apply sandbox policy (full replacement)
openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
```

## openclaw configure and plugins are sandboxed
`openclaw configure` and `openclaw plugins enable` cannot be run inside the sandbox — Landlock enforces read-only on `/sandbox/.openclaw/openclaw.json`. Both fail with `EACCES: permission denied`.
To change config or enable plugins: exit sandbox and run `nemoclaw onboard --resume` on the host.

## Platform targets
- **Current**: Mac M-series (ARM, tested now)
- **Future**: DGX Spark (ARM CPU + NVIDIA GPU) — guide should not be Mac-specific; note platform differences where they exist

## Models
Available in ollama: qwen3 family (0.6b–32b), gpt-oss:20b
Sandbox configured with: qwen3:30b
Recommended for testing: qwen3:8b

## SearXNG: internal IP blocking (solved)
OpenShell has a second protection layer beyond `access: full`: connections to internal/RFC1918 IPs are blocked unless explicitly whitelisted via `allowed_ips` in the endpoint config. The error looks like:
```
FORWARD blocked: internal IP without allowed_ips dst_host=host.openshell.internal dst_port=8888 reason=host.openshell.internal resolves to internal address 192.168.65.254, connection rejected
```
Fix: add `allowed_ips: [192.168.65.254]` to the endpoint. The IP `192.168.65.254` is Docker Desktop's host gateway on Mac. Linux/DGX may use a different IP (check with `getent hosts host.openshell.internal` from inside sandbox).

This is logged at `[sandbox]` source, not `[gateway]`. Always use `openshell logs --tail` (no `--source` filter) to see both.

## web_fetch and internal URL security

openclaw's `web_fetch` tool has its own security layer that blocks internal/private hostnames and IPs **before** the request reaches the OpenShell proxy:

```
[security] blocked URL fetch (url-fetch) target=http://host.openshell.internal:8888/search
reason=Blocked hostname or private/internal/special-use IP address
```

This blocks `.internal` domains and RFC1918 IPs regardless of what the OpenShell policy allows. The config key to bypass it is `allowPrivateNetwork: true` (found in `config/zod-schema.d.ts`), but the exact path in `openclaw.json` is not yet determined.

**Workaround**: Use `exec` + `curl` via bash instead of `web_fetch` for internal URLs (curl goes through the OpenShell proxy and IS allowed). Or tell the agent to use curl explicitly.

## Gateway restart: pkill is unreliable — use kill -9 via kubectl

`pkill -f "openclaw gateway"` sent via SSH sometimes doesn't stop the gateway (nohup process ignores SIGTERM). The reliable way to kill it:

```bash
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  sh -c 'kill -9 $(pgrep -f "openclaw gateway") 2>/dev/null; pkill -9 -f "openclaw gateway" 2>/dev/null; true'
```

Then start a new one:
```bash
# Via SSH
nohup openclaw gateway run > /tmp/gateway.log 2>&1 &
# Or from host:
./scripts/start-openclaw-gateway.sh
```

The `start-openclaw-gateway.sh` script already handles kill + restart but uses SIGTERM. If the gateway is stuck, use `kill -9` via kubectl as above.

## SearXNG integration approach
- SearXNG runs in Docker Compose on host port 8888
- From inside sandbox: `http://host.openshell.internal:8888`
- **Final approach: `exec` + `curl`** — NOT `web_fetch` (openclaw's SSRF layer blocks `.internal` domains)
- `web_search` tool only supports Brave Search API (native openclaw, not configurable)
- `web_fetch` is blocked for internal hostnames by hardcoded openclaw security module — not configurable via `tools.web.fetch` config in v2026.3.11
- `exec` + `curl` works: curl goes through OpenShell proxy, which allows `host.openshell.internal:8888` per policy
- Agent is taught to use SearXNG via `TOOLS.md` in the workspace (`/sandbox/.openclaw-data/workspace/TOOLS.md`)
- `tools.deny: ["web_search"]` hides the non-functional Brave search tool from the agent
- Policy file: `policies/sandbox-policy.yaml` (full policy including all presets)

## openclaw config internals (v2026.3.11)

### Tool allow/deny
```json
{
  "tools": {
    "deny": ["web_search"],
    "allow": ["web_fetch", "read", "write"]
  }
}
```
- `tools` is a **top-level key** in `openclaw.json`
- `tools.deny` takes precedence over `tools.allow`
- Built-in tool IDs: `web_search`, `web_fetch`, `browser`, `read`, `write`, `edit`, `exec`, `code_execution`, etc.
- Tool profiles: `"profile": "full" | "coding" | "messaging" | "minimal"`

### What web_search supports (v2026.3.11)
`tools.web.search.provider` accepts ONLY: `"brave"`, `"gemini"`, `"grok"`, `"kimi"`, `"perplexity"`.
**SearXNG is NOT a built-in provider** in this version. The docs describing a `searxng` provider or plugin are for a different/later version.

### Plugin API (v2026.3.11)
- `openclaw plugins list` shows 38 available plugins — **no SearXNG plugin**
- The plugin SDK has `api.registerTool()` but NO `api.registerWebSearchProvider()`
- Writing a custom plugin requires TypeScript + openclaw SDK compilation — not practical in sandbox
- `openclaw configure` and `openclaw plugins enable` fail with EACCES inside sandbox (Landlock read-only)

### Workspace context files (AGENTS.md, BOOTSTRAP.md, HEARTBEAT.md)
openclaw reads these markdown files from the agent workspace directory and injects them into the agent's context:
- `AGENTS.md` — persistent agent instructions (always injected; use for tool config, behaviors, SearXNG URL)
- `BOOTSTRAP.md` — bootstrap context (created by openclaw's doctor/wizard; may contain initial guidance)
- `HEARTBEAT.md` — heartbeat prompt context (read during scheduled heartbeat runs)

To use: set `agents.defaults.workspace` in `openclaw.json` to point to a writable directory, then create the file there.
The workspace directory must be readable. `/sandbox` is writable and accessible.

### Injecting config into openclaw.json (kubectl exec approach)
Since Landlock prevents writes to `/sandbox/.openclaw/` from inside the sandbox, all config changes must go via kubectl exec from the host:
```bash
# Read → modify → write back
docker exec openshell-cluster-nemoclaw kubectl exec -n openshell my-assistant -- \
  cat /sandbox/.openclaw/openclaw.json | python3 -c "
import json, sys
config = json.load(sys.stdin)
# modify config here
print(json.dumps(config, indent=2))
" > /tmp/updated.json

docker exec -i openshell-cluster-nemoclaw kubectl exec -i -n openshell my-assistant -- \
  sh -c 'cat > /sandbox/.openclaw/openclaw.json' < /tmp/updated.json
```
Gateway hot-reloads config on change (no restart needed for most keys).
