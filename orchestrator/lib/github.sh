#!/usr/bin/env bash
# GitHub CLI wrapper functions. All state-machine writes (labels, comments,
# PRs) go through here so DRY_RUN handling and error handling live in one
# place. Sourced by process_issue.sh — expects config.sh already sourced.

# Run a GitHub-mutating gh command, or just print it under DRY_RUN.
_gh_mutate() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY_RUN] gh $*" >&2
    return 0
  fi
  gh "$@"
}

gh_default_branch() {
  gh repo view "$TARGET_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name'
}

gh_list_issues_json() {
  gh issue list --repo "$TARGET_REPO" --state open \
    --json number,title,body,labels,comments,updatedAt --limit 100
}

# Print issue numbers actionable this cycle, oldest-updated first. `blocked`
# and `factory:paused` issues are terminal/human-held and never picked up.
gh_list_actionable_issues() {
  gh_list_issues_json | jq -r '
    map(select(
      (.labels | map(.name) | index("factory:paused") | not)
      and (.labels | map(.name) | index("blocked") | not)
    ))
    | sort_by(.updatedAt)
    | .[].number
  '
}

gh_issue_json() {
  local issue_num="$1"
  gh issue view "$issue_num" --repo "$TARGET_REPO" \
    --json number,title,body,labels,comments,updatedAt
}

gh_issue_labels() {
  local issue_num="$1"
  gh_issue_json "$issue_num" | jq -r '.labels[].name'
}

gh_has_label() {
  local issue_num="$1" label="$2"
  gh_issue_labels "$issue_num" | grep -qxF "$label"
}

# Remove every managed stage label and add exactly one new one, atomically.
gh_set_stage_label() {
  local issue_num="$1" new_label="$2"
  local args=()
  for l in "${STAGE_LABELS[@]}"; do
    args+=(--remove-label "$l")
  done
  args+=(--add-label "$new_label")
  _gh_mutate issue edit "$issue_num" --repo "$TARGET_REPO" "${args[@]}"
}

gh_add_label() {
  local issue_num="$1" label="$2"
  _gh_mutate issue edit "$issue_num" --repo "$TARGET_REPO" --add-label "$label"
}

gh_remove_label() {
  local issue_num="$1" label="$2"
  _gh_mutate issue edit "$issue_num" --repo "$TARGET_REPO" --remove-label "$label"
}

gh_comment() {
  local issue_num="$1" body="$2"
  _gh_mutate issue comment "$issue_num" --repo "$TARGET_REPO" --body "$body"
}

gh_issue_comments_raw() {
  local issue_num="$1"
  gh_issue_json "$issue_num" | jq -r '.comments[].body'
}

# Find any PR (open or merged) whose head branch is factory/issue-<N>.
gh_pr_for_issue() {
  local issue_num="$1"
  gh pr list --repo "$TARGET_REPO" --head "factory/issue-${issue_num}" \
    --state all --json number,state,url --jq '.[0] // empty'
}

gh_create_pr() {
  local issue_num="$1" branch="$2" title="$3" body="$4"
  _gh_mutate pr create --repo "$TARGET_REPO" --head "$branch" \
    --base "$(gh_default_branch)" --title "$title" --body "$body"
}

gh_merge_pr() {
  local pr_num="$1"
  _gh_mutate pr merge "$pr_num" --repo "$TARGET_REPO" --squash --delete-branch
}

gh_close_issue() {
  local issue_num="$1"
  _gh_mutate issue close "$issue_num" --repo "$TARGET_REPO"
}

# Fetch a file from the target repo's default branch; empty string if absent.
# Used for the repo-side .github/factory.yml override — best-effort, never
# fatal if it's missing or unparsable.
gh_repo_file() {
  local path="$1"
  gh api "repos/${TARGET_REPO}/contents/${path}" --jq '.content' 2>/dev/null \
    | base64 -d 2>/dev/null || echo ""
}
