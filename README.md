# no_devs_in_a_box

An autonomous software dev factory. Point it at a GitHub repo, and a pipeline
of Claude Code agents — Planner, Coder, Tester, Reviewer — works your issue
backlog on a schedule, opening (and optionally merging) PRs. GitHub *is* the
project management system: no separate dashboard, database, or ticket
tracker. Everything the factory is doing is visible as labels, comments, and
PRs on your repo.

## Quickstart

```bash
git clone https://github.com/casey-bot-repos/no_devs_in_a_box.git
cd no_devs_in_a_box
./install.sh
```

(This repo is currently private — `git clone` needs your own GitHub
credentials configured first.)

The installer will:
1. Install Docker if it's missing.
2. Ask for a GitHub token (`repo` + `issues` scopes), your Anthropic API key,
   and the target repo (`owner/name`).
3. Build and start the factory container.

Then just work your GitHub Issues as usual — open one, and the factory picks
it up on its next poll (every 5 minutes by default).

## How it works

The factory polls your repo's open issues on a schedule and advances exactly
one issue by exactly one pipeline stage per cycle. All state lives in issue
**labels** and **comments** — nothing is held in memory, so restarting the
container loses no progress.

| Label | Meaning |
|---|---|
| `needs-plan` | New issue, no plan yet |
| `planned` | Planner has posted a plan |
| `in-progress` | Coder is implementing |
| `needs-tests` | Awaiting/undergoing the test stage |
| `needs-review` | Tests passed, awaiting review |
| `changes-requested` | Reviewer asked for changes; loops back to Coder |
| `ready-to-merge` | Reviewer approved; PR is open |
| `blocked` | **Terminal.** Max retries hit, or something went wrong — a human needs to look, then remove this label to retry |
| `auto-merge` | Opt-in: let this issue's PR merge without a human click |
| `no-auto-merge` | Opt-out override, even if the repo default is auto-merge |
| `factory:paused` | Safety valve — the factory skips this issue entirely |

Add `factory:paused` to any issue at any time to pull it out of the
factory's hands immediately.

### Pipeline

1. **Planner** reads the issue, writes `PLAN.md` on a `factory/issue-<N>`
   branch, and posts it as a comment.
2. **Coder** implements the plan (or a fix, on retry), commits, opens a PR.
3. **Tester** runs (or writes) tests; the orchestrator independently re-runs
   the detected test command as the authoritative pass/fail signal.
4. **Reviewer** reviews the full diff and approves or requests changes.

Failed test/review cycles loop back to the Coder, bounded by `MAX_RETRIES`
(default 3) — after that, the issue is labeled `blocked` with a diagnostic
comment rather than looping forever.

### Merging

By default every change waits for a human to click merge on the PR. To let
the factory merge autonomously (once tests pass and the reviewer approves):
- Add the `auto-merge` label to a specific issue, or
- Commit `.github/factory.yml` to the target repo with
  `auto_merge_default: true` (see `config/factory.yml.example`) to make it
  the default for the whole repo — a per-issue `no-auto-merge` label still
  overrides that back off.

## Security model

Claude Code runs inside the container with `--dangerously-skip-permissions`.
This is deliberate: the container itself — no host filesystem access beyond
the mounted `/work` volume, no secrets beyond a scoped `GITHUB_TOKEN` and
`ANTHROPIC_API_KEY` — is the safety boundary, not per-action permission
prompts. Worst case, a bad turn is contained to the work volume and
recoverable with `git reset`. Don't relax this expecting *more* safety by
switching to prompted permissions; the container boundary is what's actually
doing the work either way.

## Configuration (`.env`)

See `.env.example`. Key variables: `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`,
`TARGET_REPO`, `POLL_INTERVAL_SECONDS`, `MAX_RETRIES`, `DRY_RUN`.

## Dry-run mode

Before pointing this at anything real, test against a throwaway sandbox
repo, and use dry-run to watch a cycle without writing to GitHub:

```bash
docker compose run --rm -e DRY_RUN=1 orchestrator ./scripts/dry_run.sh
```

Claude Code still runs for real against a scratch branch, but every
GitHub-mutating call (labels, comments, PR create/merge) and the final push
are printed instead of executed.

## v1 scope

**In:** one target repo, one container, one issue processed per poll cycle,
the four roles above, label state machine with bounded retries, PR-by-default
with an auto-merge override, PAT auth.

**Deliberately deferred:** multiple target repos (run a second
`docker compose` stack for a second repo), concurrent issue processing,
GitHub App auth, webhook-driven triggering, usage dashboards (check the
Anthropic console and the issue comment trail instead), automatic handling
of a human pushing directly to a `factory/*` branch (it's detected as
`blocked` for now), non-Linux installer support (use Docker Desktop and
`docker compose up` directly).

### Roadmap: concurrency via sibling containers

`orchestrator/process_issue.sh` already processes exactly one issue per
invocation. The planned v2 path to concurrency is: mount `docker.sock`, add
`docker-ce-cli` to the image, and have the orchestrator spawn one ephemeral
worker container per issue instead of running the script in-process — a
wrapper change, not a rewrite.

## Development

Scripts are shellcheck-clean (enforced in CI). Before touching
`orchestrator/lib/`, read `orchestrator/process_issue.sh` first — it's the
one file that ties every stage together.
