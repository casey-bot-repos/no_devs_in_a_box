#!/usr/bin/env bash
# Single poll cycle: pick the next actionable issue and advance it exactly
# one pipeline stage. Called repeatedly by run_loop.sh. Always resolves to
# either a clean stage transition or `blocked` + a diagnostic comment —
# never leaves an issue in an ambiguous mid-stage state.
set -euo pipefail

FACTORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
source "${FACTORY_ROOT}/config.sh"
# shellcheck source=./lib/github.sh
source "${FACTORY_ROOT}/lib/github.sh"
# shellcheck source=./lib/state.sh
source "${FACTORY_ROOT}/lib/state.sh"
# shellcheck source=./lib/git.sh
source "${FACTORY_ROOT}/lib/git.sh"
# shellcheck source=./lib/claude_invoke.sh
source "${FACTORY_ROOT}/lib/claude_invoke.sh"

mkdir -p "$WORK_DIR"
git_ensure_repo

# Repo-side override (.github/factory.yml on the TARGET repo, not this tool's
# repo). Best-effort single-key parse — good enough for v1's one setting.
AUTO_MERGE_DEFAULT="false"
load_repo_config() {
  local raw
  raw="$(gh_repo_file ".github/factory.yml")"
  if [[ -n "$raw" ]]; then
    local val
    val="$(echo "$raw" | { grep -m1 '^auto_merge_default:' || true; } | awk '{print $2}')"
    [[ -n "$val" ]] && AUTO_MERGE_DEFAULT="$val"
  fi
}

effective_auto_merge() {
  local issue_num="$1"
  if gh_has_label "$issue_num" "$LABEL_AUTO_MERGE"; then
    echo "true"; return
  fi
  if [[ "$AUTO_MERGE_DEFAULT" == "true" ]] && ! gh_has_label "$issue_num" "$LABEL_NO_AUTO_MERGE"; then
    echo "true"; return
  fi
  echo "false"
}

# Land on `blocked` with a diagnostic comment, whatever went wrong. A human
# removes the label to let the factory retry from scratch.
fail_to_blocked() {
  local issue_num="$1" reason="$2"
  gh_comment "$issue_num" "🛑 Factory stopped work on this issue: ${reason}

A human needs to look at this. Remove the \`blocked\` label to let the factory retry."
  gh_set_stage_label "$issue_num" "$LABEL_BLOCKED"
}

stage_planner() {
  local issue_num="$1" title="$2" body="$3"
  local branch plan_comment

  branch="$(git_checkout_issue_branch "$issue_num")"

  if ! claude_invoke planner "Issue #${issue_num}: ${title}

${body}

Write a concise implementation plan to PLAN.md at the repo root and commit it."; then
    fail_to_blocked "$issue_num" "planner invocation failed"
    return
  fi

  if git_has_changes; then
    git_commit_all "factory: plan for #${issue_num}"
  fi

  if [[ ! -f "${REPO_DIR}/PLAN.md" ]]; then
    fail_to_blocked "$issue_num" "planner did not produce PLAN.md"
    return
  fi

  git_push_branch "$branch"

  plan_comment="$(cat "${REPO_DIR}/PLAN.md")"
  gh_comment "$issue_num" "### 📋 Plan

${plan_comment}"
  gh_set_stage_label "$issue_num" "$LABEL_PLANNED"
}

stage_coder() {
  local issue_num="$1" title="$2"
  local branch context prompt

  branch="$(git_checkout_issue_branch "$issue_num")"

  if gh_has_label "$issue_num" "$LABEL_CHANGES_REQUESTED"; then
    context="$(state_latest_comment_matching "$issue_num" "factory:review:changes-requested")"
    prompt="Address this reviewer feedback on issue #${issue_num}: ${title}

${context}

PLAN.md and the existing branch are already checked out. Make the requested changes and commit."
  elif gh_has_label "$issue_num" "$LABEL_IN_PROGRESS"; then
    context="$(state_latest_comment_matching "$issue_num" "factory:test-result:fail")"
    prompt="The tests failed for issue #${issue_num}: ${title}. Fix the code so they pass:

${context}

PLAN.md and the existing branch are already checked out."
  else
    prompt="Implement PLAN.md (already in this checkout) for issue #${issue_num}: ${title}. Commit your work."
  fi

  if ! claude_invoke coder "$prompt"; then
    fail_to_blocked "$issue_num" "coder invocation failed"
    return
  fi

  if git_has_changes; then
    git_commit_all "factory: implement #${issue_num}"
  fi

  local unpushed
  unpushed="$(git -C "$REPO_DIR" log "origin/${branch}..HEAD" --oneline 2>/dev/null || true)"
  if [[ -z "$unpushed" ]]; then
    fail_to_blocked "$issue_num" "coder made no changes"
    return
  fi

  git_push_branch "$branch"

  local pr
  pr="$(gh_pr_for_issue "$issue_num")"
  if [[ -z "$pr" ]]; then
    gh_create_pr "$issue_num" "$branch" "Factory: ${title}" "Closes #${issue_num}

Automated implementation by no_devs_in_a_box."
  fi

  gh_set_stage_label "$issue_num" "$LABEL_NEEDS_TESTS"
}

# Best-effort test runner: try common project conventions in order. Its exit
# code is the authoritative pass/fail signal — the Tester role's own
# self-report is never trusted alone.
detect_and_run_tests() {
  cd "$REPO_DIR"
  if [[ -f package.json ]] && jq -e '.scripts.test' package.json >/dev/null 2>&1; then
    npm test
  elif [[ -f Makefile ]] && grep -q '^test:' Makefile; then
    make test
  elif [[ -f pyproject.toml || -f pytest.ini || -f setup.cfg ]]; then
    python3 -m pytest
  elif [[ -x ./test.sh ]]; then
    ./test.sh
  else
    echo "no recognized test command found; treating as pass (nothing to verify)"
    return 0
  fi
}

stage_tester() {
  local issue_num="$1" title="$2"
  local branch test_output test_exit retry_count attempt

  branch="$(git_checkout_issue_branch "$issue_num")"

  if ! claude_invoke tester "Run the test suite for the change on this branch (issue #${issue_num}: ${title}). Write minimal tests first if none exist for this change. Report clearly whether tests pass or fail."; then
    fail_to_blocked "$issue_num" "tester invocation failed"
    return
  fi

  if git_has_changes; then
    git_commit_all "factory: tests for #${issue_num}"
    git_push_branch "$branch"
  fi

  set +e
  test_output="$(detect_and_run_tests 2>&1)"
  test_exit=$?
  set -e

  if [[ $test_exit -eq 0 ]]; then
    gh_comment "$issue_num" "✅ Tests passed.

<details><summary>output</summary>

\`\`\`
${test_output}
\`\`\`
</details>"
    gh_set_stage_label "$issue_num" "$LABEL_NEEDS_REVIEW"
  else
    attempt=$(( $(state_get_retry_count "$issue_num" "test") + 1 ))
    retry_count="$(state_bump_retry_count "$issue_num" "test" "❌ Tests failed (attempt ${attempt}/${MAX_RETRIES}).

<details><summary>output</summary>

\`\`\`
${test_output}
\`\`\`
</details>

<!-- factory:test-result:fail -->")"
    if (( retry_count >= MAX_RETRIES )); then
      fail_to_blocked "$issue_num" "tests still failing after ${MAX_RETRIES} attempts"
    else
      gh_set_stage_label "$issue_num" "$LABEL_IN_PROGRESS"
    fi
  fi
}

stage_reviewer() {
  local issue_num="$1" title="$2"
  local branch diff verdict retry_count attempt review_file

  branch="$(git_checkout_issue_branch "$issue_num")"
  diff="$(git_diff_against_default)"
  review_file="$(mktemp)"

  if ! claude_invoke reviewer "Review this diff for issue #${issue_num}: ${title}.

\`\`\`diff
${diff}
\`\`\`

End your response with exactly one of these markers on its own line:
<!-- factory:review:approve -->
or
<!-- factory:review:changes-requested -->
followed by specific, actionable feedback if requesting changes." > "$review_file"; then
    rm -f "$review_file"
    fail_to_blocked "$issue_num" "reviewer invocation failed"
    return
  fi

  gh_comment "$issue_num" "### 🔍 Review

$(cat "$review_file")"

  verdict="$(grep -o 'factory:review:\(approve\|changes-requested\)' "$review_file" | tail -n1)"
  rm -f "$review_file"

  if [[ "$verdict" == "factory:review:approve" ]]; then
    gh_set_stage_label "$issue_num" "$LABEL_READY_TO_MERGE"
  elif [[ "$verdict" == "factory:review:changes-requested" ]]; then
    attempt=$(( $(state_get_retry_count "$issue_num" "review") + 1 ))
    retry_count="$(state_bump_retry_count "$issue_num" "review" "🔁 Requesting changes (attempt ${attempt}/${MAX_RETRIES}).")"
    if (( retry_count >= MAX_RETRIES )); then
      fail_to_blocked "$issue_num" "reviewer kept requesting changes after ${MAX_RETRIES} attempts"
    else
      gh_set_stage_label "$issue_num" "$LABEL_CHANGES_REQUESTED"
    fi
  else
    fail_to_blocked "$issue_num" "reviewer did not return a parseable approve/changes-requested marker"
  fi
}

stage_merge_check() {
  local issue_num="$1"
  local pr merge_state
  pr="$(gh_pr_for_issue "$issue_num")"
  [[ -z "$pr" ]] && return 0

  merge_state="$(echo "$pr" | jq -r '.state')"
  if [[ "$merge_state" == "MERGED" ]]; then
    gh_comment "$issue_num" "✅ PR merged. Closing issue."
    gh_close_issue "$issue_num"
    return 0
  fi

  if [[ "$(effective_auto_merge "$issue_num")" == "true" ]]; then
    gh_merge_pr "$(echo "$pr" | jq -r '.number')"
    gh_comment "$issue_num" "✅ Auto-merged (auto-merge policy in effect for this issue)."
    gh_close_issue "$issue_num"
  fi
}

process_one_issue() {
  local issue_num="$1"
  local issue_json title body labels

  issue_json="$(gh_issue_json "$issue_num")"
  title="$(echo "$issue_json" | jq -r '.title')"
  body="$(echo "$issue_json" | jq -r '.body')"
  labels="$(echo "$issue_json" | jq -r '.labels[].name')"

  echo "[$(date -u +%FT%TZ)] processing issue #${issue_num}: ${title}"

  if echo "$labels" | grep -qxF "$LABEL_READY_TO_MERGE"; then
    stage_merge_check "$issue_num"
  elif echo "$labels" | grep -qxF "$LABEL_NEEDS_REVIEW"; then
    stage_reviewer "$issue_num" "$title"
  elif echo "$labels" | grep -qxF "$LABEL_NEEDS_TESTS"; then
    stage_tester "$issue_num" "$title"
  elif echo "$labels" | grep -qxF "$LABEL_CHANGES_REQUESTED"; then
    stage_coder "$issue_num" "$title"
  elif echo "$labels" | grep -qxF "$LABEL_IN_PROGRESS"; then
    stage_coder "$issue_num" "$title"
  elif echo "$labels" | grep -qxF "$LABEL_PLANNED"; then
    stage_coder "$issue_num" "$title"
  elif echo "$labels" | grep -qxF "$LABEL_NEEDS_PLAN"; then
    stage_planner "$issue_num" "$title" "$body"
  else
    echo "[$(date -u +%FT%TZ)] issue #${issue_num} has no factory label yet — marking needs-plan"
    gh_set_stage_label "$issue_num" "$LABEL_NEEDS_PLAN"
  fi
}

main() {
  load_repo_config
  local next_issue
  next_issue="$(gh_list_actionable_issues | head -n1)"
  if [[ -z "$next_issue" ]]; then
    echo "[$(date -u +%FT%TZ)] no actionable issues this cycle"
    return 0
  fi
  process_one_issue "$next_issue"
}

main "$@"
