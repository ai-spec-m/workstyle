---
name: init
description: One-time per-repo setup for feature-factory, for any language or framework — detects the repo's own typecheck/lint/test/build commands into .workstyle/gates.conf, classifies its architecture and finish policy into CLAUDE.md, and optionally builds a local CodeGraph index, LSP plugin and per-layer pattern docs. Never waits for an answer. Run explicitly as /workstyle:init.
disable-model-invocation: true
---

# Init

Scaffold this repo with the user's standing preferences, without clobbering anything
repo-specific that already exists.

## Steps

0. **Index the repo with CodeGraph (local-only).** See steps 1-4 of
   `## Pattern extraction (CodeGraph)` below. If CodeGraph can't be installed, report
   it as skipped and continue to step 1. Never block the rest of init on it.

0.5. **Set up a type-aware language server for this repo's language(s), if one
   exists.** See `## Code intelligence (LSP)` below. This gives Claude live type
   diagnostics after every edit and precise go-to-definition — complements
   CodeGraph, doesn't replace it. If no official plugin covers the repo's
   language(s), or setup fails, report it as skipped and continue to step 1.

0.6. **Install the curated third-party plugin list.** See `## Auto-installed
   plugins` below. These install without a per-run prompt — the user already
   reviewed and approved each one being on this list in advance.

1. **Check for an existing root `CLAUDE.md`.**
   - If none exists, proceed to step 2 and write a new one.
   - If one exists, never rewrite it. Only add or replace, in place, the lines and
     sections this skill owns (`- Architecture:`, `- Finish policy:` and the
     `## Extracted coding patterns` routing table). Leave everything else, including any
     `<!-- codegraph -->` marker-fenced section, untouched.

2. **Generate `CLAUDE.md`** from the template below, only when none exists.
   Keep the repo-specific parts
   empty or lightly inferred (manifest file scripts — `package.json`, `pyproject.toml`,
   `go.mod`, `Cargo.toml`, `Gemfile`, or whatever this repo actually uses — plus
   framework and test runner). Leave out the `## Extracted coding patterns`
   section; step 2.7 adds it.

2.3. **Architecture and finish policy.** See `## Architecture and finish policy`
   below. Runs with or without CodeGraph.

2.5. **Gates config.** See `## Gates config` below. Writes
   `.workstyle/gates.conf` (the commands `/workstyle:feature-factory`'s hooks
   run).

2.7. **Extract coding patterns.** Step 5 of `## Pattern extraction (CodeGraph)`.
   Only if step 0 built the index; otherwise report it as skipped.

3. **Language-specific guards.** If the repo's primary language is TypeScript, write an
   empty `.workstyle/type-safety.conf` so the plugin's `any`-ban hook applies here.
   Never for other languages.

4. **Report** what was created/changed/left alone, including the
   `Architecture:` line and its evidence, and whether CodeGraph
   indexing, the language server, and pattern extraction ran, were skipped, or
   failed.

## Architecture and finish policy

`/workstyle:feature-factory` reads these two lines from `CLAUDE.md` and won't
start without the `Architecture:` one. Classify once, here, from real files —
never from the framework name (a Next.js app with no database is `bff`, one
with its own ORM/schema is `fullstack`, one with no server code is `single`).

1. **Gather evidence.** Start from the language/framework found in
   `## Code intelligence (LSP)` step 1.
   - Manifest roots: `git ls-files` filtered to the manifest names (`package.json`,
     `pyproject.toml`, `go.mod`, `Cargo.toml`, `Gemfile`, `pom.xml`,
     `build.gradle`, …). Note which roots start a server of their own.
   - Persistence: `git ls-files` for schema/migration/ORM config (`schema.prisma`,
     `migrations/`, `*.sql`, `alembic.ini`, `drizzle.config.*`, `db/schema.rb`, …).
   - Route handlers: with CodeGraph, `codegraph explore "route handler outbound
     HTTP client database ORM client"` and follow the calls down through
     services/data layers to the client they end at. Without it, find the
     handler files (`git grep -l` for the framework's routing calls or its
     route-file convention) and read their imports down to the client they end at.
2. **Classify** from that evidence only:
   - `bff` — handlers end at an outbound HTTP client; no schema/migrations in use.
   - `fullstack` — handlers end at a DB/ORM client this repo configures; schema present.
   - `separate` — two independently deployable codebases (two manifest roots,
     each with its own server), backend owns persistence.
   - `single` — no app-owned server layer: no route handlers or server entry
     point in the repo (a CLI, a library, a pure frontend calling someone
     else's API).
   - Mixed or unclear (ORM installed but no handler reaches it): pick the class the
     handlers' actual call chains support, and append `(assumed: <why>)` to the line.
3. **Write** under `## Repo-specific notes` in `CLAUDE.md`, replacing any
   existing line in place, never keeping two:
   `- Architecture: bff — route handlers → services → outbound HTTP client; no schema/migration files @ 1a2b3c4`
   (value, one-line evidence, `git rev-parse --short HEAD`; feature-factory uses
   the sha to spot a stale line), and `- Finish policy: draft-pr` unless a
   `Finish policy:` line already exists. Add the `## Repo-specific notes` heading if
   it's missing. Report the two finish policy values:
   - `local`: commit on the run branch, never push.
   - `draft-pr` (default): push, open a draft PR, watch CI; a human merges.

## Gates config

`/workstyle:feature-factory` runs these commands as hard gates: its hooks block a
builder from finishing while any of them fails. Detect them from the repo; never
assume a stack.

1. Read the manifest(s) and task files actually present (`package.json` scripts,
   `pyproject.toml`/`tox.ini`/`noxfile.py`, `Makefile`/`justfile`, `go.mod`,
   `Cargo.toml`, `Gemfile`/`Rakefile`, `build.gradle`/`pom.xml`, …) and the CI
   workflow files (`.github/workflows/*`, `.gitlab-ci.yml`) to see which
   commands the team really runs.
2. Pick at most one command each for `typecheck`, `lint`, `test`, `build`.
   Prefer what CI runs, then the repo's own script names. Leave a gate out if
   the repo has nothing for it; don't invent one. Use non-interactive,
   non-watch forms (e.g. `CI=1`, `--watchAll=false`, `-count=1`). Each command must
   be one simple command (no `&&`, `|`, `;`): the headless allowlist is built from
   these lines and a compound command won't match it. Wrap a multi-step check in a
   repo script or `make` target instead.
3. `audit`: the ecosystem's own dependency audit (`npm audit --audit-level=high`,
   `pip-audit`, `cargo audit`, `govulncheck ./...`, `bundle audit`) only if that
   tool is already installed. It runs only when a lockfile changes.
4. `max_diff_lines: 800`. Above this a run stops for a human, under any finish
   policy.
5. Run each command once now and report pass/fail. Don't fix anything: gates
   that fail already are recorded as the baseline at the start of each run and
   skipped.
6. Write the file and show it in the report. Never copy an example; write only the
   commands detected above. Examples of the shape, for three stacks:
   ```
   # .workstyle/gates.conf — one `name: command` per line; run from the repo root
   # npm repo                       # Python repo                  # Go repo
   typecheck: npm run typecheck     typecheck: mypy .              typecheck: go vet ./...
   lint: npm run lint               lint: ruff check .             lint: golangci-lint run
   test: npm test -- --watchAll=false  test: pytest -q             test: go test ./...
   build: npm run build             build: python -m build         build: go build ./...
   max_diff_lines: 800              max_diff_lines: 800            max_diff_lines: 800
   ```
   Add `.workstyle/` to `.git/info/exclude`, the same way as `.codegraph/`.

## Code intelligence (LSP)

A code intelligence plugin wires Claude Code to a real language server (the same
engine the user's editor uses) over LSP — type-checking diagnostics after every
edit, plus an `LSP` tool for compiler-accurate go-to-definition/references. This is
separate from CodeGraph: CodeGraph maps structure/call-paths on demand, this catches
type errors and bad imports automatically, right after `backend-builder` /
`frontend-builder` write code, before `test-verifier`/`implementation-validator` run.

1. **Detect the repo's primary language(s) and framework.** Official LSP plugins
   are per-language, not per-framework (there's no separate "nextjs-lsp" — Next.js
   uses `typescript-lsp` the same as plain TypeScript), so framework detection
   doesn't change which plugin gets installed. Detect it anyway, for two reasons:
   report what was actually found ("Next.js (TypeScript) detected" is more useful
   to the user than just "TypeScript"), and pass it to
   `## Architecture and finish policy`, which classifies the repo once and saves it
   to `CLAUDE.md` for `/workstyle:feature-factory`. A framework alone never
   implies the architecture; that section detects it from real files.
   - Framework signals: dependency names in `package.json`/equivalent manifest
     (`next`, `react` + `express`, `@nestjs/core`, `vue`, `nuxt`, `django`, `flask`,
     `fastapi`, `rails`, `spring-boot`, etc.), plus telltale structure (an `app/` or
     `pages/` router folder for Next.js, a `manage.py` for Django, and so on).
   - Map the detected **language** to the matching official plugin — e.g.
     TypeScript/JS (including Next.js, React, Express, NestJS — all TS/JS under the
     hood) -> `typescript-lsp`, Python (including Django/Flask/FastAPI) ->
     `pyright-lsp`, Go -> `gopls-lsp`, Rust -> `rust-analyzer-lsp` (full list: the
     "Install a code intelligence plugin" table at
     https://code.claude.com/docs/en/plugins/code-intelligence). If the language
     isn't in that table, skip this section — don't try to hand-write an `.lsp.json`.
   - A monorepo or polyglot repo may need more than one plugin (e.g. a TS frontend
     with a Go backend) — detect and install each language found, not just the
     first one.

2. **Check if the plugin is already installed:** `claude plugin list` (or equivalent)
   — if the matching plugin is present, skip to step 4.

3. **Install the language server binary, then the plugin.** An npm-distributed
   server comes from public npm only. Example for TypeScript/JS:
   ```bash
   npm i -g typescript-language-server typescript --registry=https://registry.npmjs.org/
   claude plugin install typescript-lsp@claude-plugins-official --yes
   ```
   Substitute the binary-install command and plugin name for the detected language
   per the official table — each plugin's README gives its exact binary-install
   command. A server that isn't on npm comes from the language's own official
   toolchain (e.g. `go install` for `gopls`, `rustup component add` for
   `rust-analyzer`), if that toolchain is already installed. Never use
   `curl | sh` or another source; if neither path applies, report it and skip.

4. **Confirm the binary is on `PATH`** (`command -v <binary>`). If it's missing after
   install, report it — the plugin alone doesn't start the server.

5. **Tell the user a new session is needed** for the language server to activate;
   it doesn't take effect in the current session.

6. **Carry the detected language/framework forward** rather than re-deriving it —
   hand it to `## Architecture and finish policy` as the starting point for the
   `Architecture:` line.

## Auto-installed plugins

A short, user-curated list of third-party marketplace plugins installed
automatically, no per-run prompt — the user has already reviewed and approved
each one being here. Default list is empty; add an entry here only after you
(the user) have actually looked at the plugin, not on an agent's say-so from a
web search.

Current list:

- **ponytail** — a coding-style ruleset plugin (YAGNI/reuse-first/stdlib-first
  discipline for agent-written code). MIT licensed, no `.mcp.json`/no `bin/`
  (no external server or added executable), verified by inspecting its real repo
  tree and `marketplace.json` rather than trusting its landing page alone.
  Source: `DietrichGebert/ponytail`, **pinned** to the reviewed commit
  `09c434ab73ca43761c5d8b0c5d341926c2fba710` (v5.3.2) through an entry in this
  plugin's own `marketplace.json`, so it installs as
  `ponytail@my-workstyle-marketplace`. The CLI can't pin, so the pin lives there.
  To upgrade: re-review the new commit, then change the `sha` in
  `marketplace.json`. Default level is `full`;
  this plugin wants `ultra` (its strictest) **persisted**, not just set for one
  session — `/ponytail ultra` alone does NOT survive a real restart (confirmed
  from the installed hook's own source: a fresh session always calls
  `getDefaultMode()`, which ignores the last live level). After install, write
  `{"defaultMode": "ultra"}` to `~/.config/ponytail/config.json` (create the
  file/dir if missing; if it already exists, merge in just this key, don't
  clobber other settings the user may have set there). Also wired into
  `feature-factory`'s builder agents at `ultra`; see that skill's Step 4.

For each entry in this list, in order:

1. Check if already installed (`claude plugin list`) — if present, skip to 3.
2. Install without asking:
   ```bash
   claude plugin marketplace add <source>
   claude plugin install <name>@<name>
   ```
   For ponytail, the pinned entry ships in this plugin's own marketplace, which is
   already added, so only the install runs:
   `claude plugin install ponytail@my-workstyle-marketplace`. If an older
   unpinned `ponytail@ponytail` is also installed, uninstall it
   (`claude plugin uninstall ponytail@ponytail`) so the ruleset isn't loaded twice, and
   say so in the report.
3. If the entry specifies a persisted default level/config (see ponytail above),
   write it now, merging rather than overwriting any existing config file.
4. Report what was installed/already-present/failed per plugin in the final
   summary. A failed install here never blocks the rest of `init`.
5. If anything was newly installed, tell the user a new session is needed for
   it to activate.

Adding a new entry to this list is a deliberate edit to this skill file by the
user (or by an agent only after the user has explicitly reviewed the
plugin — installed it, inspected what it actually contains, not just read its
marketing page) — not something to add automatically because a user mentioned
a URL in passing. Once added here, it installs unconditionally on every future
`/workstyle:init` run on any repo — that's the tradeoff for skipping the prompt.

## Pattern extraction (CodeGraph)

Everything this step produces is stored only on this machine. Nothing is committed or pushed. (The model still reads your code, as in any Claude Code session.)

1. **Make sure the CodeGraph CLI is available, installed only from public npm.**
   - If `command -v codegraph` succeeds, skip to step 2.
   - If `npm` isn't available, report "CodeGraph skipped: no npm" and skip this section.
   - Otherwise install from the public registry explicitly, for this one command
     only. Don't edit any `.npmrc`; the project's own packages still come from its
     configured registry:
     ```bash
     CODEGRAPH_NO_DOWNLOAD=1 npm i -g @colbymchenry/codegraph --registry=https://registry.npmjs.org/
     ```
   - **Verify the platform bundle came from npm too.** The real binary ships as a
     separate package (`@colbymchenry/codegraph-<os>-<arch>`). If npm skips it, the
     launcher quietly downloads it from GitHub Releases on first run instead. Check
     it exists:
     ```bash
     ls "$(npm root -g)/@colbymchenry/codegraph/node_modules/@colbymchenry/" | grep -q "codegraph-$(node -p 'process.platform+"-"+process.arch')"
     ```
     If that fails, don't run `codegraph` at all. Report that the platform package
     is missing and stop this section.
   - Never use the `curl | sh` installer or `codegraph upgrade` without the registry
     override. Both fetch from GitHub or the default registry, not public npm.
   - If the install fails, report the exact error and skip the rest of this section.

   To upgrade later, use the same registry override rather than `codegraph upgrade`:
   ```bash
   npm i -g @colbymchenry/codegraph@latest --registry=https://registry.npmjs.org/
   ```

2. **Wire CodeGraph into Claude Code (one-time machine step, not per repo).** If
   no `codegraph` MCP server is configured yet (`claude mcp list` doesn't show it),
   tell the user to run `codegraph install` themselves, once on this machine. It's
   interactive and writes to their global agent config, so don't run it on their
   behalf. Continue with step 3 either way; the CLI
   works without the MCP wiring.

3. **Keep the index local-only before building it.** Add these lines to
   `.git/info/exclude` (create the file if it's missing, and skip any line that's
   already there):
   ```
   .codegraph/
   coding-patterns.local/
   ```
   Use `.git/info/exclude`, not `.gitignore`. It's per-clone and never committed, so
   the ignore rules themselves don't leak into a team PR. Verify with
   `git check-ignore -q .codegraph/` before going on.

4. **Build the index:** `codegraph init --yes` at the repo root. It creates
   `.codegraph/codegraph.db` and auto-syncs on file changes afterwards, so there's
   nothing to re-run during normal work.

5. **Extract architecture pattern docs, with a routing table in `CLAUDE.md`.**
   Runs as main step 2.7, after the CLAUDE.md question. See `## Pattern extraction (deep architecture pass)` below for the full
   procedure. This replaces any single monolithic patterns file — it produces
   one file per real architectural layer, each with real code and an explicit
   dependency rule, plus a routing table so this and future sessions know which
   doc to read before touching a given file.

## Pattern extraction (deep architecture pass)

Everything this step produces is stored only on this machine; nothing is committed or
pushed. Work through this autonomously once started — don't stop for
permission between its own steps, only for the genuine ambiguities Step 5
("Report," item 4 — an unresolved structural contradiction) calls out.

### Step 1 — Discover structure (sequential, always first)

This defines the units of work for Step 2, so it must finish before any fan-out.

- Map top-level directories under the detected source root and identify every
  distinct architectural layer/domain actually present (e.g. route handlers,
  services, data-fetching layer, feature modules, shared components, hooks,
  global state/store, utilities, shared types, validation, config, tests). Use
  `codegraph files` and `codegraph status` for this, not a manual directory walk.
- For each layer, note its directory path(s) and roughly how many files live
  there (`codegraph status` / file counts).
- Identify naming/structural conventions that repeat 3+ times. Treat anything
  appearing fewer than 3 times as an outlier, not a convention — don't document it
  as one.
- Produce a short manifest: one line per layer, with its directory path(s) and
  file count. This manifest is the task list for Step 2 — each layer becomes
  one unit of work. Skip a layer entirely if it doesn't apply to this repo
  (e.g. no "API routes" layer for a pure frontend library).

### Step 1.5 — Locate or create the pattern directory

Before writing anything, check whether a pattern-docs directory already exists
(names like `coding-patterns.local/`, `.claude.local/patterns/`,
`.cursor/rules/`, `docs/patterns/`, or anything referenced from an existing
AI-instructions file).

- If one exists: write into it, matching its existing naming scheme and index
  format exactly. Do not create a second, competing pattern directory.
- If none exists: create `coding-patterns.local/` at the repo root. Add it to
  `.git/info/exclude` (not `.gitignore` — see the reasoning in step 3 above) if
  it isn't already covered. These docs are a working aid for Claude sessions,
  not a deliverable meant for the repo's history.

Use whichever directory you resolved to for the rest of this section — read
"the pattern directory" below as that path.

### Step 2 — Extract patterns per layer (parallelizable)

For EACH layer in Step 1's manifest, produce one file in the pattern directory.
**Dispatch one `general-purpose` subagent per layer, all in a single message**,
so they run in parallel — one call, then wait, then another call is sequential
and defeats the point. Each subagent needs no context beyond the layer name,
its directory path(s), and the output spec below; it needs Bash to run
`codegraph` commands, so don't use a read-only agent type.

**Tool order inside each subagent, required**: `codegraph status`/`files`/
`explore "<query>"` FIRST for anything structural (what exists, call paths,
blast radius) — survey the actual folders by name, not just by topic. Reach
for Grep/Glob/Read only afterward, and only for what CodeGraph can't answer:
proving something is absent/unused repo-wide (CodeGraph matches lexically, not
exhaustively — "zero uses of X" needs a real grep to back it up), confirming a
real anti-pattern/violation actually exists before documenting it, or reading
a specific file's full content once CodeGraph has pointed at it.

Each layer's file must start with one line, `Generated: <YYYY-MM-DD> @ <git short sha>`
(so a later run can tell how stale it is), then contain, in this order:

1. **Purpose** — one sentence: what this layer is responsible for in *this*
   codebase, not a generic definition.
2. **Structural tree** — a real directory/file tree (3-8 lines) pulled from an
   actual example in the repo, showing file layout/naming shape. Don't fabricate.
3. **Canonical example** — the single best real file exemplifying this layer,
   quoted in full or a representative excerpt, with its file path as a heading.
4. **Anti-patterns** — 2-5 "Wrong vs. Correct" comparisons using REAL code from
   this repo wherever a violation or near-violation actually exists (search for
   it, don't invent). If no real violation exists, a plausible constructed one
   is fine but must be labeled `(illustrative, not found in repo)`. Security or
   RBAC concerns found while surveying a layer (e.g. an auth helper with a
   hardcoded fallback, or disabled permission checks) belong here as a
   documented anti-pattern for that layer — not a separate file.
5. **Naming rule** — the exact convention observed, stated as a rule (e.g.
   "handler files: `<resource>_handler.<ext>`, one per resource, under the
   layer's directory").
6. **Dependency rule** — what this layer is allowed to import from and what it
   must never import from, inferred from actual imports across 5+ files in
   this layer. This is the rule `implementation-validator` checks against most
   directly (e.g. "frontend components must never import the external API
   client directly — only through this app's own route handlers").
7. **References** — 3-5 real file paths that best exemplify the pattern,
   ranked best-first.

Each subagent also returns, separately from its doc, every *real* (not
illustrative) anti-pattern or defect it found as one line:
`- <layer>: <defect> — <file:line> — <security | data-loss | correctness | scale | style>`.

Keep each file terse: decisions and shapes only, no narration, no restating
what the code visibly does. Do not invent a convention not observed 3+ times.
If a layer has no consistent pattern, write just the Purpose section plus:
"Not yet standardized — N different approaches found: [list with file paths]."
Don't silently pick a winner.

### Step 3 — Cross-layer consistency pass (sequential, after Step 2 completes)

Requires ALL Step 2 outputs — a synchronization point even though Step 2 ran
in parallel. Don't start until every layer file exists.

- Read every pattern file just produced.
- Check for cross-layer contradictions (e.g. one layer's doc says components
  must never call an external API directly, but another layer's canonical
  example does exactly that).
- Check for naming collisions/inconsistent terminology between docs (e.g. one
  doc calls something a "service," another calls the same thing a "client").
- Resolve terminology inconsistencies directly. Flag structural contradictions
  as open questions in the final report — don't resolve those yourself.
- **Check every doc against the repo.** Every file path a doc cites must exist
  (`test -e`, expanding any `{a,b}` list), and every "Wrong" example not labelled
  `(illustrative, not found in repo)` must be found by `grep -F` on a
  distinctive line of it in the cited file. Fix or remove what fails; a doc
  that cites code that isn't there teaches the wrong thing.
- **Write `.workstyle/debt.md`** (never in the pattern directory, which can be
  committed) from the subagents' defect lines, sorted security → data-loss → correctness → scale → style, headed
  `Generated: <YYYY-MM-DD> @ <git short sha>`. Keep any line from an earlier
  `debt.md` whose file:line still shows the defect; drop fixed ones.
  feature-factory reads it so new code doesn't copy these, and each line can
  become its own `fix` run.

### Step 4 — Build the routing layer in CLAUDE.md

In the repo's `CLAUDE.md` (from step 1-2 of the main flow above), add or update
a routing table mapping file path patterns to the relevant pattern doc, paths
relative to the pattern directory. Use the real layer paths from Step 1's manifest;
the shape is (illustrative paths, not a convention to copy):

   | File pattern | Pattern doc |
   |---|---|
   | `<layer path>/**` | <layer>.md |
   | `internal/handlers/**` | handlers.md |
   | `app/services/**` | services.md |

Add this instruction verbatim near the table: "Before writing, editing, or
reviewing any file matching a pattern above, read the corresponding doc in the
pattern directory first. If a change would contradict a documented pattern,
either conform to the pattern or explicitly flag the deviation and why."

If `CLAUDE.md` already has a routing table from a prior run, extend it with any
new layers rather than duplicating or forking it.

### Refresh mode

When feature-factory (or the user) asks to refresh specific layers, or when a
doc's `Generated:` sha has commits since on its layer's paths, re-run Steps 2-4
for only those layers, then the Step 3 checks and `.workstyle/debt.md` merge across all
docs. Skip the CodeGraph/LSP/plugin install steps and the CLAUDE.md
preferences merge. A layer whose paths no longer exist is removed from the
routing table and its doc deleted, after telling the user.

### Step 5 — Report

In this order:
1. The architecture line written by `## Architecture and finish policy`, and its evidence.
2. Every pattern file created/modified, one line each with a one-line description.
3. Any layer flagged "not yet standardized," with the competing approaches found,
   and the count of `.workstyle/debt.md` lines by severity (security ones listed in full).
4. Any structural contradiction from Step 3 you did not resolve, stated as an open
   question in the report (init never waits for an answer).
5. Confirmation that no application source code was modified — this pass is
   documentation-only. If a source file was touched for any reason, name it
   and justify why.

## CLAUDE.md template

```markdown
# <repo name>

## Extracted coding patterns
<!-- Only include if the pattern directory from Step 1.5 of the extraction section exists -->
For live code lookups use `codegraph_explore` (or `codegraph explore "<query>"`
from Bash) before grep/read. Before writing, editing, or reviewing any file
matching a pattern below, read the corresponding doc in `coding-patterns.local/`
first (local-only, regenerate with `/workstyle:init`). If a change would
contradict a documented pattern, either conform to it or explicitly flag the
deviation and why.

| File pattern | Pattern doc |
|---|---|
<!-- rows added by /workstyle:init's Step 4; one per layer discovered -->

## Repo-specific notes
<!-- Architecture: and Finish policy: lines are added by step 2.3 once classified; no placeholder -->
- Build/test commands: (same commands as `.workstyle/gates.conf`)
- Conventions: (leave blank for the user/team to fill in)
```

## Notes

- Do every per-repo setup step yourself and never wait for an answer: where a choice
  is unclear, take the documented default and list the assumption in the report.
- Edit this skill's templates in the plugin source when preferences change, then bump
  `version` in `.claude-plugin/plugin.json`.
- Don't invent repo-specific conventions. If unsure whether something is a convention,
  leave it out.
