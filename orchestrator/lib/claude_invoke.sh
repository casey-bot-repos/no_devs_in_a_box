#!/usr/bin/env bash
# Shared headless Claude Code invocation used by every pipeline role.
# Sourced by process_issue.sh — expects config.sh already sourced.
#
# Security model: --dangerously-skip-permissions is deliberate here, not an
# oversight. The container (no host mounts beyond the /work volume, a
# repo-scoped GitHub token) is the security boundary, not per-action
# permission prompts — worst case is contained to /work and git-revertable.
# See README.md "Security model" before changing this.

# claude_invoke <role> <prompt-text>
# Runs the role's system prompt + given prompt against $REPO_DIR as cwd.
# Prints the assistant's final result text on stdout; the full JSON result
# goes to stderr for logging. Returns non-zero if the CLI failed or the
# response's is_error flag was set.
claude_invoke() {
  local role="$1" prompt="$2"
  local system_prompt_file="${ROLES_DIR}/${role}/SYSTEM_PROMPT.md"
  local raw

  if [[ ! -f "$system_prompt_file" ]]; then
    echo "no system prompt for role: $role" >&2
    return 1
  fi

  raw="$(cd "$REPO_DIR" && claude -p "$prompt" \
    --output-format json \
    --append-system-prompt "$(cat "$system_prompt_file")" \
    --dangerously-skip-permissions \
    --max-turns 40)"

  echo "$raw" >&2

  if [[ "$(echo "$raw" | jq -r '.is_error // false')" == "true" ]]; then
    echo "claude invocation for role '$role' reported an error" >&2
    return 1
  fi

  echo "$raw" | jq -r '.result'
}
