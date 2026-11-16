---
name: review-learnings
description: Show the learnings capture-learning logged and the feature-factory run history, and promote the ones the user picks into the plugin's own skill/agent files. The only path by which the plugin edits itself. Invoke only when the user explicitly asks to review or promote learnings.
disable-model-invocation: true
---

# Review Learnings

1. Read `learnings.md` and `history.log` from `${CLAUDE_PLUGIN_DATA}` **and** from every
   sibling `workstyle-*` data directory next to it (`${CLAUDE_PLUGIN_DATA}/../workstyle-*/`):
   headless runs load the plugin with `--plugin-dir`, which gives them their own data
   directory. If none exist or all are empty, say so and stop.
2. Print its full contents to the user, grouped by date, noting which entries
   already carry a `(promoted: <date>)` suffix on their `- tag:` line. Group by tag with
   its occurrence count: a tag seen 3+ times is the strongest candidate. If
   `${CLAUDE_PLUGIN_DATA}/history.log` exists (one line per feature-factory
   run: time, run, outcome, passes, gates), summarise it too: runs per
   outcome, average builder passes, and which gates failed most.
3. Ask the user which *unpromoted* tags (if any) should be promoted now. Prefer a
   mechanical check (a gate in `gates.conf`, a hook rule, a test) over a prose rule,
   and propose deleting any existing rule the history shows never fired. Do not
   re-promote anything already marked `promoted`.
4. If the user confirms promotions:
   - Edit the relevant source file(s) in the plugin's own repo checkout (not the
     installed cache copy) to reflect the promoted learning.
   - Mark each promoted occurrence by appending ` (promoted: <date>)` to the end of its `- tag: <name>` line in `learnings.md`.
   - Bump `version` in `.claude-plugin/plugin.json` (patch bump is usually enough).
   - Remind the user to commit, push, and run `claude plugin update workstyle` (or
     equivalent) on any other machine to pick up the change.
5. Leave unpromoted entries as-is. Never delete anything from `learnings.md`.
