# CLAUDE.md

## Purpose
This repo is a living setup guide for running NemoClaw + Ollama (+ Telegram). The primary artifact is `README.md`.

## Open todos
- ✅ **Verify Telegram bridge end-to-end** — DONE 2026-04-12. Bot responds to DMs.
- ⏳ **Make post-onboard fixes persistent** — `/etc/hosts`, symlinks, and token injection are all lost on sandbox restart. Currently handled by `scripts/telegram-setup.sh`. Permanent fix would require HostAlias + Landlock policy changes at `nemoclaw onboard` time.
- ✅ **Test initial openclaw onboarding flow** — verified 2026-04-12 on fresh sandbox; bot replied and remembered user's name
- ⏳ **SearXNG as a dedicated tool** — currently the agent can search via `bash` + curl when explicitly told the SearXNG endpoint. Goal: wire SearXNG up so the agent searches automatically without needing the URL in the prompt. Options to investigate: MCP tool, custom tool config in openclaw.json, system prompt injection, or replacing `web_search`. See openclaw docs.
- ⏳ **Disable/hide unusable `web_search` tool** — the default Brave `web_search` tool is visible to the agent but non-functional without an API key. Agent should not see tools it can't use. Need to find how to disable it in openclaw config.
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
- Gateway must be started manually after config changes: `nohup openclaw gateway run > /tmp/gateway.log 2>&1 &` inside sandbox (or use `./scripts/start-gateway.sh` from host)
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

## Current environment state (as of 2026-04-12)
- **nemoclaw**: v0.0.9, installed at `~/.local/bin/nemoclaw`
- **ollama**: running at `localhost:11434` with qwen3 family + gpt-oss:20b models
- **Docker**: running; port 8080 is taken by `openshell-cluster-nemoclaw`
- **sandbox**: `my-assistant`, model `qwen3:30b`, provider `ollama-local`, phase `Ready` (rebuilt fresh 2026-04-12, end-to-end verified)
- **openclaw**: v2026.3.11 (from fresh sandbox rebuild 2026-04-12)
- **Telegram**: fully working — gateway running (mode:polling, @whiskey_papa_bot), bot responds to DMs; user ID `8362082345` in `allowFrom`
- **SearXNG**: running via Docker Compose on host port **8888** (not 8080 — conflict with openshell cluster)
- **Active policy**: v5 (applied via `telegram-setup.sh` 2026-04-12)
- **Scripts**: `scripts/telegram-setup.sh` and `scripts/start-gateway.sh` — run after every onboard

## What works
- ✅ Basic chat: `openclaw agent --agent main --local -m "hi" --session-id test`
- ✅ Date tool call: returns correct date
- ✅ SearXNG reachable from host on port 8888
- ✅ SearXNG reachable from inside sandbox — fixed with `allowed_ips` in policy (see below)
- ✅ Sandbox rebuilt with fresh openclaw; Telegram configured via provider pipeline
- ✅ Telegram gateway running (mode:polling) — bot token injected, DNS fixed, VPN off
- ✅ `openclaw pairing list telegram` works — credentials symlink created
- ✅ Telegram end-to-end DM — bot responds to DMs (2026-04-12)

## Known Bugs / Workarounds

### Telegram gateway — RESOLVED as of 2026-04-12
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

# Verify Telegram gateway is polling (look for getUpdates in the output)
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

## SearXNG integration approach
- SearXNG runs in Docker Compose on host port 8888
- From inside sandbox: `http://host.openshell.internal:8888`
- Plan: agent uses `web_fetch` tool to call SearXNG's JSON API
- `web_search` tool only supports Brave Search API (native openclaw, not configurable)
- `web_fetch` and `browser` tools work with any URL once network policy allows it
- Policy file: `policies/sandbox-policy.yaml` (full policy including all presets)
