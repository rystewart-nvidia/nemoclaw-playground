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
  ollama pull qwen3:8b   # or qwen3:4b for less RAM, qwen3:14b for more quality
  ```
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

## 2. Start Ollama (host-accessible for sandbox)

The sandbox needs to reach Ollama over the Docker host gateway, so bind to `0.0.0.0`:

```bash
# Mac / Linux / DGX Spark
OLLAMA_HOST=0.0.0.0:11434 ollama serve

# WSL only (default binding is fine)
ollama serve
```

Verify it's up:
```bash
curl -sf http://localhost:11434/api/tags
```

---

## 3. Onboard

```bash
nemoclaw onboard
```

When prompted:
- **Inference provider** → choose `Local Ollama (localhost:11434)`
- **Model** → pick from the list (your pulled models will appear), e.g. `qwen3:8b` or `qwen3:30b`
- **Brave Web Search** → `N` (we use SearXNG instead)
- **Messaging channels** → toggle Telegram and paste your bot token + Telegram user ID
- **Sandbox name** → choose anything, e.g. `my-assistant`

> To rebuild an existing sandbox (e.g. to upgrade openclaw or re-wire Telegram through the provider pipeline):
> ```bash
> source .env && nemoclaw onboard --recreate-sandbox --yes-i-accept-third-party-software
> ```
> This command is **interactive** — `--non-interactive` mode requires `NVIDIA_API_KEY` and defaults to NIM, not ollama.

---

## 4. Test Chat

Connect interactively and run a message (see [Connecting to the sandbox](#connecting-to-the-sandbox) for the non-interactive SSH alternative):

```bash
nemoclaw my-assistant connect
```

Then inside the sandbox:
```bash
openclaw agent --agent main --local -m "hi" --session-id test
# or open the interactive TUI:
openclaw tui
```

**Expected**: the agent responds and walks through initial OpenClaw setup (asks what to call itself, etc.).

---

## 5. Test Tool Calling

**Date (no extra config needed)** — run from inside the sandbox:
```bash
openclaw agent --agent main --local -m "What is today's date?" --session-id test2
```
Expected: correct date returned via tool call.

**Internet search** — requires SearXNG (see next section).

---

## 6. SearXNG Web Search

> `web_search` in openclaw only supports Brave Search (API key required).
> Instead, we run SearXNG locally and the agent calls it via the `bash` tool with curl — no API key needed.
> Note: `web_fetch` is also blocked for internal IPs by openclaw's own SSRF protection, so use `bash` + curl.

### 6a. Check port availability

> **Note:** Port 8080 is used by the OpenShell gateway cluster. SearXNG runs on **8888**.

```bash
lsof -i :8080   # should show openshell-cluster
lsof -i :8888   # should be free
```

### 6b. Start SearXNG

```bash
docker compose up -d
```

Verify from host:
```bash
curl -sf "http://localhost:8888/search?q=test&format=json" | python3 -m json.tool | head -20
```

### 6c. Find the host gateway IP (required for policy)

OpenShell blocks connections to internal/RFC1918 addresses unless explicitly listed in `allowed_ips`. You need to know what IP `host.openshell.internal` resolves to in your sandbox:

```bash
# From inside the sandbox:
ssh ... 'getent hosts host.openshell.internal'
# e.g. returns: 192.168.65.254  host.docker.internal host.openshell.internal
```

> **Mac Docker Desktop**: typically `192.168.65.254`
> **Linux/DGX**: likely `172.17.0.1` or similar — always verify with `getent hosts`

Update `policies/sandbox-policy.yaml` if the IP differs:
```yaml
  searxng:
    endpoints:
      - host: host.openshell.internal
        port: 8888
        access: full
        allowed_ips:
          - 192.168.65.254   # replace with your actual gateway IP
```

### 6d. Apply network policy

The sandbox uses deny-all egress by default. `policies/sandbox-policy.yaml` in this repo is the **full** sandbox policy (base + pypi + npm + searxng). Apply it **from the host** (not inside the sandbox):

```bash
openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
```

> ⚠️ `openshell policy set` **replaces** the entire policy — it does not merge.
> Always use the full policy file in `policies/sandbox-policy.yaml`.
>
> ⚠️ The `allowed_ips` field is required. Without it, OpenShell blocks connections to internal
> addresses even with `access: full`. Error in logs: `FORWARD blocked: internal IP without allowed_ips`.

### 6e. Test internet search via agent

Connect to the sandbox and ask:
```bash
openclaw agent --agent main --local \
  -m "Use the bash tool to run: curl -sf 'http://host.openshell.internal:8888/search?q=Airbnb+Bergamo&format=json' | python3 -m json.tool | head -30. Then summarise the results." \
  --session-id search1
```

> Note: use `bash` + curl, not `web_fetch`. OpenClaw's `web_fetch` blocks internal/private IPs
> (SSRF protection). The `bash` tool can reach `host.openshell.internal` once the network policy allows it.

---

## 7. Telegram Bridge

### 7a. Configure secrets

Secrets are stored in a local `.env` file (gitignored). Copy the example and fill it in:

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
```bash
source .env
```

> `source .env` only lasts for the current shell session. Run it again if you open a new terminal.
> Never commit `.env` — the `.gitignore` in this repo already excludes it.

### 7b. Get a bot token

Message [@BotFather](https://t.me/BotFather) on Telegram, send `/newbot`, follow the prompts. Copy the token into `.env`.

### 7c. Get your chat ID

Send any message to your new bot, then:
```bash
curl "https://api.telegram.org/bot<TOKEN>/getUpdates"
```
Find `"chat":{"id":<your-id>}` in the response. Add it to `ALLOWED_CHAT_IDS` in `.env`.

### 7d. Post-onboard Telegram setup (required after every onboard)

The cleanest way to wire up Telegram is to provide the bot token and your user ID **during `nemoclaw onboard`** (or `nemoclaw onboard --recreate-sandbox`). The wizard asks for them at step [5/8].

After onboarding, four fixes are required due to bugs and Landlock filesystem restrictions in the current openclaw version.

> ⚠️ **VPN**: Disconnect any VPN before starting — VPNs commonly SNI-filter `api.telegram.org`.
> ⚠️ All four fixes are **not persistent** — re-run after any `nemoclaw onboard --recreate-sandbox`.

Run from the **host**, in the repo root:

```bash
source .env && ./scripts/telegram-setup.sh
```

> Note: `openclaw configure` is blocked by Landlock inside the sandbox — the script uses `kubectl exec` to update `openclaw.json` directly.

<details>
<summary>Why each fix is needed</summary>

**Fix 1 — Bot token**: openclaw stores the token as `openshell:resolve:env:TELEGRAM_BOT_TOKEN` after onboarding. As of v2026.4.10, this placeholder is not resolved at runtime — the literal string gets sent to Telegram, returning 404.

**Fix 2 — Telegram DNS**: The sandbox `/etc/resolv.conf` nameserver (`10.200.0.1`) has no DNS on port 53 — all queries time out. OpenShell's `mechanistic_mapper` resolves hostnames to verify they're not internal IPs; if DNS fails, it blocks. Adding the hostname to `/etc/hosts` bypasses this check.

**Fix 3 — Credentials dir**: `openclaw pairing list telegram` writes to `/sandbox/.openclaw/credentials/`. That path is read-only under Landlock. Symlinking to `/sandbox/.openclaw-data/credentials/` (already read-write) fixes it.

**Fix 4 — Telegram state dir**: The gateway writes update offsets to `/sandbox/.openclaw/telegram/`. Without the symlink it logs `failed to persist update offset` — messages still arrive but may be re-delivered after a gateway restart.
</details>

<details>
<summary>Why each fix is needed</summary>

**Fix 1 — Bot token**: openclaw stores the token as `openshell:resolve:env:TELEGRAM_BOT_TOKEN` after onboarding. As of v2026.4.10, this placeholder is not resolved at runtime — the literal string gets sent to Telegram, returning 404.

**Fix 2 — Telegram DNS**: The sandbox `/etc/resolv.conf` nameserver (`10.200.0.1`) has no DNS on port 53 — all queries time out. OpenShell's `mechanistic_mapper` resolves hostnames to verify they're not internal IPs; if DNS fails, it blocks. Adding the hostname to `/etc/hosts` bypasses this check.

**Fix 3 — Credentials dir**: `openclaw pairing list telegram` writes to `/sandbox/.openclaw/credentials/`. That path is read-only under Landlock. Symlinking to `/sandbox/.openclaw-data/credentials/` (already read-write) fixes it.

**Fix 4 — Telegram state dir**: The gateway writes update offsets to `/sandbox/.openclaw/telegram/`. Without the symlink it logs `failed to persist update offset` — messages still arrive but may be re-delivered after a gateway restart.
</details>

### 7e. Start the openclaw gateway

Complete the [7d setup script](#7d-post-onboard-telegram-setup-required-after-every-onboard) first, then start the gateway from the **host**:

```bash
./scripts/start-gateway.sh
```

The script starts the gateway and prints channel status. To confirm the bot is actively polling:

```bash
openshell logs --tail
# Expected: repeated L7_REQUEST ... l7_target=/bot.../getUpdates
```

> Note: `nemoclaw start` is for cloudflared tunnel only — it does NOT start the Telegram bot.
> `nemoclaw stop` / `nemoclaw status` do not reflect Telegram channel status.
> `/tmp/gateway.log` inside the sandbox only shows lifecycle events (errors, restarts) — not individual message polls.
> Use `openclaw channels status` (inside sandbox) and `openshell logs --tail` (host) to verify Telegram.

### 7f. Pair your Telegram account

If `dmPolicy` is `allowlist` and your user ID is in `allowFrom` (set during onboarding), you can DM the bot directly — no pairing needed. If `dmPolicy` is `pairing`, the first DM generates a code:

```bash
ssh ... 'openclaw pairing list telegram'
```

Approve it:

```bash
ssh ... 'openclaw pairing approve telegram <CODE>'
```

Pairing codes expire after 1 hour.

---

## 8. Verify Telegram End-to-End

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

---

## Sandbox management

**Delete a sandbox:**
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

## Troubleshooting

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

**SearXNG not reachable:**
```bash
# From host
curl -sf "http://localhost:8888/search?q=test&format=json" | head -c 200

# Reapply policy if needed
openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
```

**Policy blocking requests:**
```bash
openshell term   # approve blocked requests interactively
```
> ⚠️ Do NOT approve Telegram connections via `openshell term` — it creates an `allow_api_telegram_org_443` policy with `access: full` that overrides the named `telegram` policy and breaks TLS. If you already did, re-apply the full policy immediately:
> ```bash
> openshell policy set my-assistant --policy policies/sandbox-policy.yaml --wait
> ```

**Telegram gateway fails:**

Run the [7d consolidated script](#7d-post-onboard-telegram-setup-required-after-every-onboard) first — it covers the most common failures. For individual symptoms:

| Symptom | Cause | Fix |
|---|---|---|
| `deleteWebhook` 404 loop | Bot token placeholder not resolved | Fix 2 in §7d script |
| CONNECT tunnel fails / TLS drops | Policy using `access: full` | Fix 1 in §7d script (apply policy) |
| HTTP returns 0 bytes silently | `enforcement: monitor` instead of `enforce` | Fix 1 in §7d script (apply policy) |
| Connection blocked by mechanistic_mapper | Sandbox DNS can't resolve `api.telegram.org` | Fix 3 in §7d script |
| `openclaw pairing list` EACCES | Missing writable credentials dir | Fix 4 in §7d script |
| `failed to persist update offset` | Missing writable telegram state dir | Fix 4 in §7d script |
| All connections blocked after `openshell term` | Term approvals create broken `allow_*` override policies | Re-apply full policy |
| Telegram unreachable from host | VPN SNI-filters `api.telegram.org` | Disconnect VPN |

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
| Mac M-series (ARM) | Testing |
| DGX Spark (ARM + NVIDIA GPU) | Planned |
| Linux x86 | Untested |
| WSL2 | Untested |
