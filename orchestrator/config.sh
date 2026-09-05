#!/usr/bin/env bash
# Shared configuration for the factory orchestrator.
# Sourced by run_loop.sh, process_issue.sh, and scripts/*.sh — do not execute directly.

set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set}"
: "${TARGET_REPO:?TARGET_REPO must be set (owner/name)}"

# Either credential works -- `claude` reads whichever is present. API key
# for console.anthropic.com billing, OAuth token (from `claude setup-token`)
# to bill against a Claude subscription instead.
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
if [[ -z "$ANTHROPIC_API_KEY" && -z "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
  echo "Either ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN must be set" >&2
  exit 1
fi

POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-300}"
MAX_RETRIES="${MAX_RETRIES:-3}"
DRY_RUN="${DRY_RUN:-0}"

# Optional work-window scheduling ("HH:MM", 24h clock, in $TZ) and a spend
# cap (USD) per window — see lib/schedule.sh. All unset means: always on,
# no cap.
WORK_WINDOW_START="${WORK_WINDOW_START:-}"
WORK_WINDOW_END="${WORK_WINDOW_END:-}"
MAX_SPEND_PER_WINDOW="${MAX_SPEND_PER_WINDOW:-}"
export TZ="${TZ:-UTC}"

FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_DIR="$(cd "${FACTORY_ROOT}/../roles" && pwd)"
WORK_DIR="${WORK_DIR:-/work}"
REPO_DIR="${WORK_DIR}/repo"

# Label names — the entire state machine. Keep this in sync with README.md.
LABEL_NEEDS_PLAN="needs-plan"
LABEL_PLANNED="planned"
LABEL_IN_PROGRESS="in-progress"
LABEL_NEEDS_TESTS="needs-tests"
LABEL_NEEDS_REVIEW="needs-review"
LABEL_CHANGES_REQUESTED="changes-requested"
LABEL_READY_TO_MERGE="ready-to-merge"
LABEL_BLOCKED="blocked"
LABEL_AUTO_MERGE="auto-merge"
LABEL_NO_AUTO_MERGE="no-auto-merge"
LABEL_PAUSED="factory:paused"

# All labels the factory treats as mutually-exclusive "stage" labels — exactly
# one of these (or none, for a brand new issue) should be present at a time.
STAGE_LABELS=(
  "$LABEL_NEEDS_PLAN" "$LABEL_PLANNED" "$LABEL_IN_PROGRESS"
  "$LABEL_NEEDS_TESTS" "$LABEL_NEEDS_REVIEW" "$LABEL_CHANGES_REQUESTED"
  "$LABEL_READY_TO_MERGE" "$LABEL_BLOCKED"
)

# `gh` reads GH_TOKEN for auth — every script that sources this file gets it.
export GH_TOKEN="${GITHUB_TOKEN}"

export GITHUB_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN TARGET_REPO POLL_INTERVAL_SECONDS MAX_RETRIES DRY_RUN
export WORK_WINDOW_START WORK_WINDOW_END MAX_SPEND_PER_WINDOW
export FACTORY_ROOT ROLES_DIR WORK_DIR REPO_DIR
export LABEL_NEEDS_PLAN LABEL_PLANNED LABEL_IN_PROGRESS LABEL_NEEDS_TESTS LABEL_NEEDS_REVIEW \
  LABEL_CHANGES_REQUESTED LABEL_READY_TO_MERGE LABEL_BLOCKED LABEL_AUTO_MERGE LABEL_NO_AUTO_MERGE LABEL_PAUSED
