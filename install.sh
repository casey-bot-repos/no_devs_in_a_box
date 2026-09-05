#!/usr/bin/env bash
# no_devs_in_a_box installer. The only thing this needs on the host is
# Docker (installed automatically below if missing) plus curl/tar, which
# ship on essentially every Linux distro — no git, no Node, no gh CLI, no
# Claude Code CLI. Everything that actually touches code, GitHub, or a
# browser runs inside the container this script builds and starts.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/casey-bot-repos/no_devs_in_a_box/main/install.sh | bash
# Or, from an existing checkout:
#   ./install.sh
set -euo pipefail

TARBALL_URL="${NO_DEVS_TARBALL_URL:-https://github.com/casey-bot-repos/no_devs_in_a_box/archive/refs/heads/main.tar.gz}"
INSTALL_DIR="${NO_DEVS_INSTALL_DIR:-$HOME/.no_devs_in_a_box}"

log() { echo "[install] $*"; }

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed."
    return
  fi
  log "Docker not found — installing via Docker's official convenience script..."
  curl -fsSL https://get.docker.com | sh
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker install failed. Install it manually: https://docs.docker.com/engine/install/"
    exit 1
  fi
}

ensure_docker_permissions() {
  if docker info >/dev/null 2>&1; then
    return
  fi
  if getent group docker >/dev/null 2>&1 && ! id -nG "$USER" | grep -qw docker; then
    log "Adding $USER to the docker group (log out/in afterward, or run: newgrp docker)"
    sudo usermod -aG docker "$USER"
  fi
}

# Fetches the tool's own source onto the host — just enough for `docker
# compose` to have a Dockerfile/compose file to build from. No git required:
# a tarball of the public repo works with curl/tar alone. Re-running this
# script (e.g. to update) simply re-fetches over the same directory; your
# .env isn't part of the tarball, so it's untouched.
fetch_source() {
  if [[ -f "./docker-compose.yml" && -d "./orchestrator" ]]; then
    log "Running from an existing checkout — using $(pwd)."
    INSTALL_DIR="$(pwd)"
    return
  fi
  log "Fetching latest source into ${INSTALL_DIR}..."
  mkdir -p "$INSTALL_DIR"
  curl -fsSL "$TARBALL_URL" | tar xz --strip-components=1 -C "$INSTALL_DIR"
  cd "$INSTALL_DIR"
}

prompt_config() {
  if [[ -f .env ]]; then
    log ".env already exists — leaving it as-is. Delete it first to reconfigure."
    return
  fi
  log "Let's configure the factory."
  read -rp "GitHub token (repo + issues scopes): " gh_token
  read -rsp "Anthropic API key: " anthropic_key; echo
  read -rp "Target repo (owner/name): " target_repo
  read -rp "Poll interval in seconds [300]: " poll_interval
  poll_interval="${poll_interval:-300}"
  read -rp "Max retries per stage [3]: " max_retries
  max_retries="${max_retries:-3}"

  cat > .env <<EOF
GITHUB_TOKEN=${gh_token}
ANTHROPIC_API_KEY=${anthropic_key}
TARGET_REPO=${target_repo}
POLL_INTERVAL_SECONDS=${poll_interval}
MAX_RETRIES=${max_retries}
DRY_RUN=0
EOF
  chmod 600 .env
  log "Wrote .env (chmod 600). Edit it any time; restart the container to pick up changes."
}

main() {
  ensure_docker
  ensure_docker_permissions
  fetch_source
  prompt_config

  log "Building and starting the factory..."
  docker compose build
  docker compose up -d

  log "Factory running against ${INSTALL_DIR}."
  log "Watch progress on the target repo's Issues page on GitHub."
  log "View logs with: (cd ${INSTALL_DIR} && docker compose logs -f)"
}

main "$@"
