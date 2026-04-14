# TODOs

Open items from the openshell + openclaw migration.

## In Progress

- [ ] **Move hardcoded config out of setup.sh** — `setup.sh` currently has the Ollama provider model list, SearXNG URL, and other config values embedded in the Python snippet. Move these to a tracked config file (e.g. `openclaw-config.json` at repo root) that `setup.sh` reads and merges into the sandbox's `openclaw.json`. This makes config changes version-controlled and eliminates the need to edit `setup.sh` directly.

## Pending

- [ ] **Run proof point tests** — ✅ Telegram responding, SearXNG working. Still need to confirm: (1) "hi" onboarding walks through questions, (2) date question triggers a tool call (not hardcoded text), (3) web search query logs in `docker compose logs -f searxng`. Update README with exact tested commands after.

## Known Warnings (non-blocking)

- **`model-pricing bootstrap failed: TypeError: fetch failed`** — openclaw tries to fetch model pricing from `openrouter.ai` which is not in the sandbox policy. Harmless; documented in README troubleshooting.

- **`Failed to query allowed_ips from endpoint config error=duplicated definition of local variable ep`** — openshell-internal OPA evaluation warning when multiple policy blocks use `allowed_ips`. Functionality unaffected. Likely an openshell bug; not fixable from policy file.

- **`openclaw gateway install` requires systemd** — Not available in the openshell container. Workaround: `setsid openclaw gateway run > /tmp/gateway.log 2>&1 < /dev/null &`. Documented in README.

## Completed

- [x] **Telegram `/etc/hosts` DNS fix** — Sandbox nameserver has no external DNS. Fix: resolve `api.telegram.org` on the host (`run-setup.sh` does this automatically) and pass as `TELEGRAM_IP` env var to `setup.sh`, which writes to `/etc/hosts`. Policy has `/etc/hosts` in `read_write`.

- [x] **Build custom Dockerfile** — `Dockerfile` at repo root extends the openclaw base image, installs `dnsutils` (for `dig`), and pins `openclaw@latest` as root. Bakes `setup.sh` into image at `/usr/local/bin/setup`. `run-setup.sh` uploads the current repo version before running, so iteration doesn't require rebuilds.

- [x] **Create `run-setup.sh`** — Host-side wrapper that: generates SSH config, resolves Telegram IP on host, uploads latest `setup.sh`, runs it in sandbox with all env vars. Sources `.env` automatically. Usage: `bash run-setup.sh`.

- [x] **Recreate sandbox** — Sandbox recreated from custom Dockerfile with updated policy. Setup ran successfully, gateway is running, Telegram is connected.

- [x] **Fix `openclaw config set models.providers.ollama.baseUrl` validation error** — openclaw validates the full config schema after each `config set`. Setting only `baseUrl` fails because `models[]` is required. Fix: write the full Ollama provider config in a single Python JSON pass in `setup.sh`.

- [x] **Fix binary paths in policy** — All policy binary paths were `/usr/local/bin/*` but actual paths in the openclaw base image are `/usr/bin/*`. Fixed across all policy blocks.

- [x] **Document both interactive and non-interactive options** — README shows both `openshell sandbox connect` and SSH approach. `run-setup.sh` uses SSH; interactive option documents `export` approach with note about Telegram IP needing to be resolved on host first.

- [x] **`run-setup.sh` sources `.env` automatically** — Uses `set -a; source .env; set +a` so env vars are exported to child processes. No need to `source .env` before running.

- [x] **Update README with correct commands** — README rewritten to reflect: correct `openshell sandbox create` syntax, `run-setup.sh` as primary setup path, `setsid` gateway start, both interactive/non-interactive options, Ollama config, Dockerfile note.
