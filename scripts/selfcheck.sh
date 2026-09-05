#!/usr/bin/env bash
# Fail fast and loudly at container startup if the factory can't actually do
# its job, rather than discovering a broken credential mid-poll-loop.
set -euo pipefail

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../orchestrator/config.sh
source "${TOOL_ROOT}/orchestrator/config.sh"

echo "selfcheck: verifying GitHub auth..."
if ! gh auth status >/dev/null 2>&1; then
  echo "selfcheck FAILED: GITHUB_TOKEN is not valid" >&2
  exit 1
fi

echo "selfcheck: verifying access to ${TARGET_REPO}..."
if ! gh repo view "$TARGET_REPO" >/dev/null 2>&1; then
  echo "selfcheck FAILED: cannot access repo ${TARGET_REPO} with this token" >&2
  exit 1
fi

echo "selfcheck: verifying claude CLI is authenticated..."
if ! claude -p "reply with just the word ok" --output-format json --max-turns 1 \
     | jq -e '.is_error == false' >/dev/null 2>&1; then
  echo "selfcheck FAILED: claude CLI could not complete a basic call — check ANTHROPIC_API_KEY" >&2
  exit 1
fi

echo "selfcheck: OK"
