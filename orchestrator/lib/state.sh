#!/usr/bin/env bash
# Retry-counter and verdict helpers. All factory "memory" lives in GitHub
# issue comments as HTML-comment markers, so a container restart loses
# nothing — everything here is re-derived by reading the issue fresh.
# Sourced by process_issue.sh — expects config.sh and lib/github.sh already
# sourced.

# Last recorded retry count for a stage ("test" or "review") on an issue,
# default 0. Comments are append-only, so the last match wins.
state_get_retry_count() {
  local issue_num="$1" stage="$2"
  local n
  n="$(gh_issue_comments_raw "$issue_num" \
    | grep -o "factory:retry-count:${stage}=[0-9]\+" \
    | tail -n1 \
    | grep -o '[0-9]\+' || true)"
  echo "${n:-0}"
}

# Post a comment recording the bumped retry count for a stage (prefixed with
# extra_body, e.g. the failure output), and print the new count.
state_bump_retry_count() {
  local issue_num="$1" stage="$2" extra_body="${3:-}"
  local current next
  current="$(state_get_retry_count "$issue_num" "$stage")"
  next=$((current + 1))
  gh_comment "$issue_num" "${extra_body}

<!-- factory:retry-count:${stage}=${next} -->"
  echo "$next"
}

# Full body of the most recent comment containing a given marker substring —
# used to feed prior failure/review context back into the Coder's prompt.
state_latest_comment_matching() {
  local issue_num="$1" marker="$2"
  gh_issue_json "$issue_num" | jq -r --arg m "$marker" '
    [.comments[] | select(.body | contains($m))] | last | .body // ""
  '
}
