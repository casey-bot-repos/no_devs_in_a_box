#!/usr/bin/env bash
# Runs a single poll cycle with DRY_RUN=1: every GitHub-mutating call prints
# what it *would* do instead of executing, and the final git push is
# skipped. Claude Code itself still runs for real against a scratch branch,
# so you can watch full pipeline behavior in logs with zero effect on the
# real repo. Usage: docker compose run --rm orchestrator ./scripts/dry_run.sh
set -euo pipefail
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DRY_RUN=1
exec "${TOOL_ROOT}/orchestrator/process_issue.sh"
