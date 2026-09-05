#!/usr/bin/env bash
# Git checkout/branch management for the single-clone, serial v1 orchestrator.
# Sourced by process_issue.sh — expects config.sh already sourced.

git_ensure_repo() {
  if [[ ! -d "${REPO_DIR}/.git" ]]; then
    git clone "https://x-access-token:${GITHUB_TOKEN}@github.com/${TARGET_REPO}.git" "$REPO_DIR"
  fi
  git -C "$REPO_DIR" config user.name "no-devs-in-a-box"
  git -C "$REPO_DIR" config user.email "no-devs-in-a-box@users.noreply.github.com"
  git -C "$REPO_DIR" fetch origin
}

git_default_branch() {
  git -C "$REPO_DIR" remote show origin | awk '/HEAD branch/ {print $NF}'
}

# Check out (creating if new) the branch for an issue. A fresh issue starts
# from the current default branch; a returning issue resumes exactly where
# its remote branch left off.
git_checkout_issue_branch() {
  local issue_num="$1"
  local branch="factory/issue-${issue_num}"
  local default_branch
  default_branch="$(git_default_branch)"

  git -C "$REPO_DIR" fetch origin
  if git -C "$REPO_DIR" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    git -C "$REPO_DIR" checkout "$branch"
    git -C "$REPO_DIR" reset --hard "origin/${branch}"
  else
    git -C "$REPO_DIR" checkout "$default_branch"
    git -C "$REPO_DIR" reset --hard "origin/${default_branch}"
    git -C "$REPO_DIR" checkout -b "$branch"
  fi
  echo "$branch"
}

git_has_changes() {
  [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]
}

git_commit_all() {
  local message="$1"
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -m "$message"
}

git_push_branch() {
  local branch="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY_RUN] git push origin $branch" >&2
    return 0
  fi
  git -C "$REPO_DIR" push -u origin "$branch"
}

git_diff_against_default() {
  local default_branch
  default_branch="$(git_default_branch)"
  git -C "$REPO_DIR" diff "origin/${default_branch}...HEAD"
}
