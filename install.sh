#!/usr/bin/env bash
# no_devs_in_a_box installer. The only thing this needs on the host is
# Docker (installed automatically below if missing) plus curl/tar, which
# ship on essentially every Linux distro — no git, no Node, no gh CLI, no
# Claude Code CLI. Everything that actually touches code, GitHub, or a
# browser runs inside the container this script builds and starts.
#
# All prompts read from /dev/tty explicitly, not stdin — required for the
# curl-pipe-bash form below, where stdin is the downloaded script itself,
# not your keyboard.
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

# Populates CLAUDE_CODE_OAUTH_TOKEN for write_env below by running
# `claude setup-token` inside a one-off container built from this image —
# bills against a Claude Pro/Max subscription, no separate API key needed.
prompt_auth() {
  log "Running 'claude setup-token' inside a container — follow its prompts (it may print a URL to open in your browser)."
  # --entrypoint overrides this image's fixed ENTRYPOINT (the poll loop), so
  # this actually runs `claude setup-token` instead of starting the
  # factory. < /dev/tty attaches the real terminal, not this script's own
  # (possibly piped) stdin.
  docker compose run --rm --entrypoint claude orchestrator setup-token < /dev/tty
  echo
  read -rsp "Paste the token 'claude setup-token' printed above: " CLAUDE_CODE_OAUTH_TOKEN < /dev/tty
  echo
}

prompt_config() {
  log "Let's configure the factory."
  local gh_token target_repo poll_interval max_retries
  read -rp "GitHub token (repo + issues scopes): " gh_token < /dev/tty
  prompt_auth
  read -rp "Target repo (owner/name): " target_repo < /dev/tty
  read -rp "Poll interval in seconds [300]: " poll_interval < /dev/tty
  poll_interval="${poll_interval:-300}"
  read -rp "Max retries per stage [3]: " max_retries < /dev/tty
  max_retries="${max_retries:-3}"

  cat > .env <<EOF
GITHUB_TOKEN=${gh_token}
CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}
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

  local needs_config=1
  [[ -f .env ]] && needs_config=0
  # A placeholder so `docker compose build`/`run` never choke on a missing
  # env_file — prompt_config (below) overwrites it with real values before
  # the factory actually starts.
  [[ "$needs_config" -eq 1 ]] && : > .env

  log "Building the factory image..."
  docker compose build

  if [[ "$needs_config" -eq 1 ]]; then
    prompt_config
  else
    log ".env already exists — leaving it as-is. Delete it first to reconfigure."
  fi

  log "Starting the factory..."
  docker compose up -d

  log "Factory running against ${INSTALL_DIR}."
  log "Watch progress on the target repo's Issues page on GitHub."
  log "View logs with: (cd ${INSTALL_DIR} && docker compose logs -f)"
}

main "$@"
