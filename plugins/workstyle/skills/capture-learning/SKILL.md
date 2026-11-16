---
name: capture-learning
description: Append a durable note about a workstyle preference, correction, or pattern the user just taught, so it survives plugin updates. Use whenever the user corrects an approach, confirms a non-obvious choice worked, or states a standing preference for how to work in a repo.
---

# Capture Learning

Append a short, dated entry to `${CLAUDE_PLUGIN_DATA}/learnings.md` (create the file
and its parent directory if they don't exist).

Each entry should be 1-3 lines, with a stable `tag` so repeats of the same
underlying learning can be counted by `review-learnings` later:

```
## YYYY-MM-DD
- tag: <kebab-case, stable across repeats of the same pattern — e.g.
  "builder-missed-pagination-edge-case", not a new tag each time>
- <the rule or preference, stated generally enough to apply beyond this one task>
- Why: <the reason given, if any>
```

Choosing the tag: before writing a new entry, read the existing file and reuse
an existing tag if this is the same underlying pattern recurring (even if the
specific file/feature differs) — a new tag per occurrence defeats the point,
since occurrences are counted *per tag*, not per entry.

Rules:
- Only capture things that are non-obvious and would otherwise need to be re-explained
  in a future session (corrections, confirmed judgment calls, standing preferences).
- Do not capture one-off task details, secrets, or anything project-specific that
  wouldn't generalize across repos.
- Only capture what actually happened: a gate or validator output, an advisor verdict,
  or a correction the user made, with its run dir or file:line. Never a lesson inferred
  from nothing.
- Do not rewrite or delete prior entries — this file only grows; `review-learnings`
  marks an occurrence done by appending ` (promoted: <date>)` to the end of
  that occurrence's existing `- tag: <name>` line, in place — never a new
  line, never a delete. A `- tag:` line with no `(promoted: ...)` suffix is
  still open; counting open occurrences per tag is exactly `grep '^- tag: X'
  <file> | grep -vc 'promoted:'`.
- Keep entries terse. This file is read back in full by `review-learnings`,
  so bloat makes that harder, not more useful.
