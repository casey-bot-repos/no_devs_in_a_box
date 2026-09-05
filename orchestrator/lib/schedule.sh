#!/usr/bin/env bash
# Work-window and spend-cap gating. Sourced by process_issue.sh — expects
# config.sh already sourced.
#
# This tracks operational bookkeeping (spend totals), not collaboration
# state — unlike issue/label progress, nobody needs to see it on GitHub, so
# it lives as a plain file on the /work volume instead. It resets whenever
# schedule_window_id() rolls over to a new window, and is lost only if the
# volume itself is wiped — acceptable, since worst case is just re-spending
# up to the cap once.

# True if "now" (in $TZ) falls inside the configured work window. With no
# window configured (either bound unset), the factory always runs. Simple
# per-poll-tick check rather than sleeping until the window opens — cheap
# (no Claude calls involved) even ticking every interval through idle hours.
schedule_in_work_window() {
  [[ -z "${WORK_WINDOW_START:-}" || -z "${WORK_WINDOW_END:-}" ]] && return 0

  local now="$1"
  if [[ "$WORK_WINDOW_START" < "$WORK_WINDOW_END" ]]; then
    [[ "$now" > "$WORK_WINDOW_START" && "$now" < "$WORK_WINDOW_END" ]]
  else
    # Window wraps past midnight, e.g. 23:00-03:00.
    [[ "$now" > "$WORK_WINDOW_START" || "$now" < "$WORK_WINDOW_END" ]]
  fi
}

# Identifies the current window for spend-tracking: the calendar date a
# scheduled window started (so an overnight window's post-midnight half
# still counts against last night's cap), or just today's date if running
# continuously with no window configured (i.e. a daily cap).
schedule_window_id() {
  local now="$1"
  if [[ -z "${WORK_WINDOW_START:-}" ]]; then
    date +%F
    return
  fi
  if [[ "$now" < "$WORK_WINDOW_START" ]]; then
    date -d yesterday +%F
  else
    date +%F
  fi
}

BUDGET_DIR="${WORK_DIR}/spend"

budget_file() {
  echo "${BUDGET_DIR}/$(schedule_window_id "$(date +%H:%M)").txt"
}

budget_spent() {
  local f
  f="$(budget_file)"
  [[ -f "$f" ]] && cat "$f" || echo "0"
}

# Add a dollar amount (from a single Claude invocation's reported cost) to
# the running total for the current window.
budget_add() {
  local amount="$1" f current
  [[ -z "$amount" || "$amount" == "null" ]] && return 0
  mkdir -p "$BUDGET_DIR"
  f="$(budget_file)"
  current="$(budget_spent)"
  awk -v a="$current" -v b="$amount" 'BEGIN { printf "%.4f", a + b }' > "$f"
}

# True if there's budget remaining this window, or no cap is configured.
budget_has_room() {
  [[ -z "${MAX_SPEND_PER_WINDOW:-}" ]] && return 0
  awk -v s="$(budget_spent)" -v cap="$MAX_SPEND_PER_WINDOW" 'BEGIN { exit !(s < cap) }'
}
