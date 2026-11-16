# my-workstyle-marketplace

A personal Claude Code marketplace holding `workstyle`: an autonomous,
language- and framework-agnostic SDLC pipeline that runs unattended
(`claude -p`) and stops with a truthful exit code instead of asking.

## Layout

```
.claude-plugin/marketplace.json       <- marketplace manifest (workstyle + pinned ponytail)
.github/workflows/ci.yml              <- validate --strict + script tests on every push
plugins/workstyle/
  .claude-plugin/plugin.json
  skills/init/                        <- /workstyle:init — one-time per-repo setup
  skills/feature-factory/             <- /workstyle:feature-factory [--gated] — the pipeline
  skills/lld/                         <- design doc from the real diff (end of every run)
  skills/adr/                         <- record an architecture decision in docs/adr/
  skills/capture-learning/            <- logs a correction/gate lesson to ${CLAUDE_PLUGIN_DATA}
  skills/review-learnings/            <- manual: review the log and promote rules into the plugin
  agents/codebase-researcher.md       <- read-only map of existing code + rated precedent
  agents/story-writer.md              <- story + source-tagged TARGET GOAL
  agents/spec-writer.md               <- technical spec, shaped by ARCHITECTURE
  agents/backend-builder.md           <- server side, or the only builder for a single-codebase repo
  agents/frontend-builder.md          <- client side, built against what backend actually built
  agents/test-verifier.md             <- tests per acceptance criterion / Xray scenario
  agents/implementation-validator.md  <- judges the diff against the goal (not the builders' claims)
  agents/advisor.md                   <- read-only second opinion: spec, stuck loop, final diff
  hooks/hooks.json                    <- guards (PreToolUse) + gates (Stop/SubagentStop)
  scripts/gates.sh                    <- deterministic gates: gates.conf commands, secret scan, diff size
  scripts/git-add-guard.sh            <- blocks force-push, push to default branch, reset --hard,
                                         clean -f, branch -D, deploy/publish/IaC, `git add .`/-A
  scripts/protected-file-guard.sh     <- opt-in: .workstyle/protected-files.conf
  scripts/type-safety-guard.sh        <- opt-in: TypeScript `any` ban (init enables it for TS repos)
  scripts/factory-run.sh              <- headless entry point
  scripts/*.test.sh                   <- regression tests for every script (no model calls)
  evals/headless-python-feature/      <- `claude plugin eval` case: a headless run must end `done`
```

## Install

```
claude plugin marketplace add <your-github-user>/<your-repo>
claude plugin install workstyle@my-workstyle-marketplace
```

Needs `bash` ≥ 4, `git`, `jq` and GNU coreutils (Linux or WSL). Without `jq` the
guards block every Bash/Edit/Write call rather than silently letting them through.
`gh` is needed only for the `draft-pr` finish policy.

Local testing without installing: `claude --plugin-dir ./plugins/workstyle`.

## Per repo, once: `/workstyle:init`

Detects everything from the repo's own files, never from a framework name:
- **Gate commands** (`.workstyle/gates.conf`): the typecheck/lint/test/build commands
  the repo's CI and manifests actually use, whatever the stack (npm, pytest, go,
  cargo, make, …). Each must be a single command.
- **Architecture** (`bff | fullstack | separate | single`) and **finish policy**
  (`local | draft-pr`) as two lines in `CLAUDE.md`.
- Optional: CodeGraph index, the matching LSP plugin, per-layer pattern docs in
  `coding-patterns.local/`, a `.workstyle/debt.md` of defects found.

Init never waits for an answer: unclear choices take the documented default and are
listed in its report. `.workstyle/`, `coding-patterns.local/`, `architecture.local/`
and `.codegraph/` go in `.git/info/exclude`, never `.gitignore`.

## Per feature: `/workstyle:feature-factory <ticket or request>`

Pipeline, on its own `ff/<slug>` branch: researcher → story → spec (advisor check)
→ **gates armed** → backend → frontend → tests → validator (≤ 3 builder passes,
advisor on a stuck loop) → advisor final check → commit → finish policy → LLD.

- **Autonomous by default.** It never asks. The story is auto-approved (assumed lines
  go to Out of scope), the advisor's verdict is the spec gate, and every assumption is
  listed in the summary. `--gated` adds human approval after the story and the spec.
- **Hands off instead of guessing** on a one-way architecture decision, an advisor
  `BLOCK`, a failed tests-first check, a diff over `max_diff_lines`, or `NEEDS HUMAN
  DECISION`. Work in progress is committed locally, `failure.md` says what a human must
  decide, and nothing is pushed.
- **Gates are hooks, not prompts.** Once armed (always before the first builder), a
  builder can't finish while any `gates.conf` command fails, a secret appears in the
  diff, or the dependency audit fails. The hook trusts a copy of the config frozen
  outside the repo at run start. After 3 blocked stops the run is `gates-failed`.
- **Never merges, never force-pushes, never deploys.** `git-add-guard.sh` blocks it.
  Add your own forbidden commands in `.workstyle/forbidden-commands.conf`.
- No Jira writes. Jira/Xray/Figma are read once if their MCP tools are present; their
  text is fenced as untrusted data.

## Headless

```
cd <repo> && bash <plugin>/scripts/factory-run.sh "<ticket or request>" [budget-usd]
```

Runs `claude -p --permission-mode dontAsk` with an allowlist built from the repo's
`gates.conf`, logs to `.workstyle/factory-runs/<stamp>.jsonl`, and exits with the
run's real outcome:

| Exit | Meaning |
|---|---|
| 0 | `state: done`: gates passed, committed (and draft PR if `draft-pr`) |
| 3 | handed off / failed / gates-failed: `failure.md` printed to stderr |
| 4 | the pipeline never started (no init, dirty tree, or skipped) |
| 5 | Claude stopped mid-run (budget, crash) |

## Learning

`capture-learning` appends real incidents (a repeated validator gap, an advisor
`BLOCK`, your correction) to `${CLAUDE_PLUGIN_DATA}/learnings.md`; `gates.sh` appends
one line per run to `history.log`. Nothing edits the plugin automatically:
`/workstyle:review-learnings` shows both and promotes the tags you pick, preferring a
gate or hook over a prose rule.

## Developing the plugin

```
bash plugins/workstyle/scripts/gates.test.sh
bash plugins/workstyle/scripts/git-add-guard.test.sh
bash plugins/workstyle/scripts/edit-guards.test.sh
bash plugins/workstyle/scripts/factory-run.test.sh
claude plugin validate . --strict && claude plugin validate plugins/workstyle --strict
```

See `plugins/workstyle/evals/README.md` for the end-to-end eval.
