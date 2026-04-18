
# ARG OPENCLAW_SANDBOX_VERSION=8f7d0da
ARG OPENCLAW_SANDBOX_VERSION=latest
FROM ghcr.io/nvidia/openshell-community/sandboxes/openclaw:${OPENCLAW_SANDBOX_VERSION}

# The openclaw base image runs as the sandbox user. Switch to root for installs.
USER root

# Upgrade openclaw to latest stable.
# Update the version pin when a new stable release is available.
# RUN npm install -g openclaw@latest

# Copy the openclaw configuration script (run once by the user after sandbox creation).
COPY configure-openclaw.sh /usr/local/bin/configure-openclaw
RUN chmod +x /usr/local/bin/configure-openclaw

# Drop back to sandbox user for runtime.
USER sandbox

# NOTE: CMD is ignored by OpenShell — the sandbox supervisor replaces it.
# Start the gateway with: ssh ... 'setsid openclaw gateway run > /tmp/gateway.log 2>&1 &'
CMD ["bash"]
