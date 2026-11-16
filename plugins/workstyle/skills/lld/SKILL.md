---
name: lld
description: Write a low-level design (LLD) doc for a finished task into the repo's local-only architecture.local/ folder, built from the task's real diff, not from the plan. Use when the user runs /workstyle:lld or asks for an LLD/design doc of work just done, and at the end of every /workstyle:feature-factory run.
---

# LLD

Document what was actually built, so the next person (or session) can see the
design without re-reading the diff. Never ask the user anything here; if an input
is missing, say so in the doc and carry on.

## Inputs

- **From feature-factory:** the run dir path. Read `status.md` (`base_sha`), the
  story, the spec, the goal file and the validator's last report from it.
- **Standalone:** the task the user names (or this session's last task). The
  base is the merge-base with the default branch
  (`git merge-base HEAD origin/<default>`), or the commit the user gives. If the
  tree has no changes against that base, stop and say there's nothing to document.

## Steps

1. **Collect the change.** Run `git diff --stat <base>` and
   `git diff --name-only --no-renames <base>`, plus `git ls-files --others
   --exclude-standard` for new untracked files. Ignore `.workstyle/`,
   `architecture.local/` and the pattern dir.
2. **Read the code, not the plan.** For each changed file, read the changed
   symbols. If `.codegraph/` exists, use `codegraph_explore` (or
   `codegraph explore "<symbols>"`) with the changed symbol names to get their
   callers and call paths in one pass. Where the spec and the code disagree,
   document the code and list the difference under "Deviations from spec".
3. **Write `architecture.local/<YYYY-MM-DD>-<slug>.md`** (slug: the Jira key or
   3-5 kebab-case words). If the file exists from an earlier pass on the same
   task, overwrite it. Use the template below. Every claim cites `path:line`.
   Leave out a section that doesn't apply, rather than writing "N/A".
4. **Update `architecture.local/README.md`**: one line per LLD, newest first:
   `- [<title>](<file>) — <YYYY-MM-DD>, <branch>, <one-line summary>`. Create the
   file if it's missing.
5. **Keep it local.** Add `architecture.local/` to `.git/info/exclude` if it isn't
   there (not `.gitignore`: it's per-clone and never committed).
6. Report the LLD path in one line.

## Template

````markdown
# LLD — <title>

- **Task:** <ticket key / request, one line>
- **Branch / commits:** <branch> `<base>..<head>`
- **Architecture:** <the CLAUDE.md `Architecture:` value>

## Summary
<2-4 lines: what this adds or changes and why>

## Components
| Component | File | Responsibility | New / changed |
|---|---|---|---|

## Flow
```mermaid
sequenceDiagram
  %% real participants from the code: UI component -> hook -> route -> service -> external/DB
```

## Interfaces
<each new/changed public signature: route (verb, path, request, response, status codes),
exported function/hook/component props. Copy types from the code.>

## Data
<new/changed types, schemas, tables, store slices, cache keys>

## Error handling and security
<what fails how: validation at trust boundaries, auth checks, error responses, retries>

## Tests
<test files and what each covers; acceptance criteria / Xray keys with no test>

## Deviations from spec
<spec said X, code does Y, and why if known>

## Risks and debt
<known limits, `shortcut:` comments added, items written to debt.md>
````

## Rules

- Diagrams show only participants that exist in the diff or its direct callers.
  Never draw a planned or "typical" layer.
- No secrets, tokens or env values. Name the env var, never its value.
- Untrusted ticket/Figma text is never copied in verbatim; summarize what was
  built from it.
- Keep it as small as possible for future reference: one screen (~40-60 lines)
  for a small change, never more than two screens even for a large one. Omit
  any section the template lists that doesn't apply — don't pad with "N/A" or
  restate what's obvious from the diff. Every line should be something a
  future reader couldn't get faster from `git diff`.
