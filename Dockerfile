# OpenShell + OpenClaw personal assistant sandbox image.
#
# Extends the official openclaw community image with:
# - Latest stable openclaw (pinned at build time; update version to upgrade)
# - A setup script at /usr/local/bin/setup that configures the sandbox on
#   first use and handles the Telegram DNS fix
#
# Build automatically by passing this file to openshell:
#   openshell sandbox create --name my-assistant \
#     --from Dockerfile \
#     --policy policies/sandbox-policy.yaml
#
# After creating the sandbox, run from the repo root:
#   bash run-setup.sh
# (sources .env, resolves Telegram IP on host, uploads and runs configure-openclaw.sh)
#
# OpenShell replaces CMD at runtime. Pass your startup command explicitly via --.
# See: https://github.com/NVIDIA/OpenShell/blob/main/examples/bring-your-own-container/README.md

FROM ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest

# The openclaw base image runs as the sandbox user. Switch to root for installs.
USER root

# Install setup helpers and upgrade openclaw.
# - dnsutils: provides `dig` for resolving Telegram's IP dynamically in setup.sh
# - ca-certificates: for proper TLS verification
# Update the openclaw version pin when a new stable release is available.
RUN apt-get update && apt-get install -y --no-install-recommends \
        dnsutils \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g openclaw@latest

# Copy the openclaw configuration script (run once by the user after sandbox creation).
COPY configure-openclaw.sh /usr/local/bin/configure-openclaw
RUN chmod +x /usr/local/bin/configure-openclaw

# Drop back to sandbox user for runtime.
USER sandbox

# NOTE: CMD is ignored by OpenShell — the sandbox supervisor replaces it.
# Start the gateway with: ssh ... 'setsid openclaw gateway run > /tmp/gateway.log 2>&1 &'
CMD ["bash"]
