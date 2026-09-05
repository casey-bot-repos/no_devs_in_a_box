# no_devs_in_a_box

An autonomous software dev factory. Point it at a GitHub repo, and a pipeline
of Claude Code agents — Planner, Coder, Tester, Reviewer — works your issue
backlog on a schedule, opening (and optionally merging) PRs. GitHub *is* the
project management system: no separate dashboard, database, or ticket
tracker. Everything the factory is doing is visible as labels, comments, and
PRs on your repo.

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/casey-bot-repos/no_devs_in_a_box/main/install.sh | bash
```

That's the whole install. The only thing it needs on your host is Docker
(installed automatically if missing) and curl/tar — no git, no Node, no `gh`
CLI, no Claude Code CLI. Everything that touches code, GitHub, or a browser
runs inside the container it builds. The installer will:
1. Install Docker if it's missing.
2. Ask for a GitHub token (`repo` + `issues` scopes), your Anthropic API key,
   and the target repo (`owner/name`).
3. Build and start the factory container.

Then just work your GitHub Issues as usual — open one, and the factory picks
it up on its next poll (every 5 minutes by default).

## How it works

The factory polls your repo's open issues on a schedule and advances one
issue by one pipeline stage per cycle — but it sticks with whichever issue
is already mid-pipeline, working it stage by stage every cycle, until it
resolves (either `blocked`, or all the way through review) before starting
the next one. Issues aren't drained round-robin; they're drained one at a
time, in the order they were opened. All state lives in issue **labels** and
**comments** — nothing is held in memory, so restarting the container loses
no progress. The one exception is already-reviewed PRs sitting at
`ready-to-merge`: those get checked every cycle regardless of which issue is
currently active, since checking costs no Claude calls.

A brand-new issue takes two poll cycles to show first activity: the first
cycle just tags it `needs-plan`, the second actually runs the Planner — at
the 300s default that's up to ~10 minutes of apparent silence before
anything visible happens.

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
   the detected test command as the authoritative pass/fail signal. A headless
   Chromium is baked into the image (see below), so a target repo's own
   Playwright/Puppeteer/Cypress e2e suite can run without extra setup.
4. **Reviewer** reviews the full diff and approves or requests changes.

Failed test/review cycles loop back to the Coder, bounded by `MAX_RETRIES`
(default 3) — after that, the issue is labeled `blocked` with a diagnostic
comment rather than looping forever.

### Merging

By default every change waits for a human to click merge on the PR. **To
make auto-merge the default** (merge automatically once tests pass and the
reviewer approves, most issues, most of the time): commit a file to the
**target repo** — not this tool's repo — at `.github/factory.yml`:

```yaml
auto_merge_default: true
```

(Template: `config/factory.yml.example` in this repo.) With that in place,
every issue auto-merges unless you add `no-auto-merge` to a specific one you
want to hold back for manual review. Going the other way — leave the repo
default alone and opt in per issue — just add the `auto-merge` label to
that one issue instead.

If an auto-merge attempt actually fails (a real merge conflict, a branch
protection rule, an unmet required check), the factory doesn't retry it
blindly forever: it comments with the likely reason, drops the `auto-merge`
label, and leaves the PR at `ready-to-merge` for a human to resolve directly.

**Branches are fully independent per issue** — every issue gets its own
`factory/issue-<N>` branch and its own PR, so unrelated issues never step on
each other's work in progress. The one thing v1 does *not* do is detect or
resolve conflicts *between* issues' PRs: if two issues touch the same file
and the first one merges (auto or manual) before the second, the second PR
can end up conflicting with the now-updated default branch, same as it
would for two human-authored PRs — nothing here rebases it for you.

## Headless Chrome

The image installs Playwright's Chromium build plus the OS-level shared
libraries any headless Chromium needs (`npx playwright install --with-deps
chromium` at build time) — not `apt install chromium`, since Ubuntu's apt
package is a snap wrapper that doesn't run in a container. This means a
target repo's existing browser-based test suite generally just works via
`npm test` with no per-repo configuration. It's best-effort: a repo pinned to
a very different Playwright version may still trigger its own (network)
download, which the container has the network access to do anyway.

## Security model

Claude Code runs inside the container with `--dangerously-skip-permissions`.
This is deliberate: the container itself — no host filesystem access beyond
the mounted `/work` volume, no secrets beyond a scoped `GITHUB_TOKEN` and
`ANTHROPIC_API_KEY` — is the safety boundary, not per-action permission
prompts. Worst case, a bad turn is contained to the work volume and
recoverable with `git reset`. Don't relax this expecting *more* safety by
switching to prompted permissions; the container boundary is what's actually
doing the work either way.

## Scheduling & spend caps

Two independent knobs, both optional, both in `.env`:

- **Work windows** — `WORK_WINDOW_START` / `WORK_WINDOW_END` (24h `HH:MM`,
  interpreted in `TZ`) restrict *agent* work to a daily window, e.g. nightly
  11pm-3am:
  ```
  WORK_WINDOW_START=23:00
  WORK_WINDOW_END=03:00
  TZ=America/Los_Angeles
  ```
  Outside the window the factory still polls (cheaply) and still merges
  already-approved PRs sitting at `ready-to-merge` — it just won't start or
  advance any Claude-driven pipeline work until the window reopens. Leave
  both unset to run continuously (the default).

- **Spend cap** — `MAX_SPEND_PER_WINDOW` (USD) caps total Claude spend,
  tracked from each call's own reported cost, per window (one scheduled
  window if configured above, otherwise one calendar day). Work pauses once
  the cap is hit and resumes automatically at the start of the next window.
  This depends on the installed `claude` CLI reporting `total_cost_usd` in
  its JSON output — worth a quick check (`docker compose logs` will show
  the full JSON per call) if spend tracking looks like it's staying at zero.

Unlike issue/label state, spend totals aren't collaboration-relevant, so
they live as a plain file under `/work/spend/` rather than in GitHub — they
reset when a new window starts, and are lost only if that volume is wiped.

## Configuration (`.env`)

See `.env.example`. Key variables: `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`,
`TARGET_REPO`, `POLL_INTERVAL_SECONDS`, `MAX_RETRIES`, `DRY_RUN`,
`WORK_WINDOW_START`/`WORK_WINDOW_END`/`TZ`, `MAX_SPEND_PER_WINDOW`.

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

**Known limitations, not just deferred:**
- The factory doesn't watch for human review comments left directly on a
  PR — it only reacts to its own Reviewer role's verdict on the issue. Your
  options as a human are to merge the PR, push commits to its branch
  yourself, or relabel/comment on the *issue*.
- Removing `blocked` doesn't resume the failed stage — it clears all stage
  labels, so the next cycle treats the issue as brand-new and restarts from
  Planner. The `factory/issue-<N>` branch and any open PR aren't reset
  though, so Planner runs against whatever was already left there, not a
  clean slate.

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
