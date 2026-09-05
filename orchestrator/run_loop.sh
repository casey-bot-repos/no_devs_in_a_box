#!/usr/bin/env bash
# The scheduled poll loop — the container's foreground process. A plain
# while+sleep rather than cron/systemd: stdout goes straight to `docker
# compose logs`, and `restart: unless-stopped` handles crash recovery.
set -euo pipefail
FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=orchestrator/config.sh
source "${FACTORY_ROOT}/config.sh"

echo "no_devs_in_a_box: polling ${TARGET_REPO} every ${POLL_INTERVAL_SECONDS}s"

while true; do
  echo "[$(date -u +%FT%TZ)] poll cycle start"
  if ! "${FACTORY_ROOT}/process_issue.sh"; then
    echo "[$(date -u +%FT%TZ)] cycle failed, will retry next interval" >&2
  fi
  echo "[$(date -u +%FT%TZ)] poll cycle end, sleeping ${POLL_INTERVAL_SECONDS}s"
  sleep "${POLL_INTERVAL_SECONDS}"
done
