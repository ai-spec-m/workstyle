---
name: adr
description: Record an architecture decision as a numbered ADR in docs/adr/ — context, the choice, alternatives rejected and why, and consequences. Use when a non-obvious technical choice is made, or when asked why the codebase is shaped a certain way.
---

## When to Activate

- The user says "record this decision", "ADR this", or "note why we did it this way"
- A choice is made between real alternatives: a library, a data-flow shape, a cache strategy, a state-management approach, an API contract, a migration path
- The user asks "why did we choose X?" — then read the existing ADRs instead of writing one
- A ticket's edge-case doc surfaces a trade-off that outlives the ticket

Do NOT write one for: routine implementation that follows an existing pattern, anything already stated in
`coding-patterns.local/`, or a choice the user has not actually settled. Plans record *what* to build and
state files record *progress*; an ADR records *why one option won*. If the answer is "it's the only way",
there is no decision to record.

## Sort by reversibility first

**Easy to reverse** — naming, internal module structure, folder layout, a feature-local helper: decide it,
note it in the plan or the pattern doc, move on. No ADR.

**Hard to reverse** — auth, a persisted-state shape or schema version, data models and migrations,
API contracts across service boundaries, service boundaries, a new dependency, a framework or major-version choice:
**do not decide these.** Write the ADR with `Status: proposed`, give 2-3 real options, state the strongest
case *against* each, name the assumptions the recommendation rests on, and stop: a human accepts it
(in a feature-factory run this is a hand-off). An agent that
settles one of these alone has made a commitment the next ticket inherits silently.

An approved ADR (`Status: accepted`) is permanent context — later runs treat it as a constraint, not a
suggestion, and a decision that contradicts one needs a superseding ADR rather than a quiet exception.

## Steps

1. Read `docs/adr/README.md` for the index and the next free number (`0001`, `0002`, …). Create
   the directory and index if neither exists.
2. Check for an existing ADR covering the same ground. If the new decision replaces it, write the new one and
   mark the old `Status: superseded by ADR-NNNN` rather than editing its history.
3. Write `docs/adr/NNNN-kebab-title.md` using the template below. Name it after the decision,
   not the ticket.
4. Add one line to the index: `- [ADR-NNNN](NNNN-kebab-title.md) — <decision in a clause> (<status>)`.
5. If the decision constrains future code, also add the rule to the matching `coding-patterns.local/` doc —
   the ADR explains the reasoning once; the pattern doc is what gets read before coding.

## Template

```markdown
# ADR-NNNN: <title>

**Date**: YYYY-MM-DD
**Status**: proposed | accepted | superseded by ADR-NNNN
**Ticket**: <ticket key> (or "none")

## Context

The situation and the constraints that forced a choice. 2-5 sentences. Name the real pressures —
an API shape we do not control, a deadline, an existing pattern, a performance limit.

## Decision

The choice, in 1-3 sentences, stated plainly.

## Alternatives Rejected

### <alternative>
Why not: <the specific reason — a cost, a risk, a constraint it violated>

## Consequences

- What this makes easier
- What this makes harder, and what we accept as a result
- What would make us revisit this
```

Keep each ADR under ~60 lines. An ADR nobody rereads is worse than none.

## Examples

**GOOD:** `0003-aggregate-orders-server-side.md` — "Context: the orders API returns per-line rows but the
dashboard needs totals. Decision: aggregate in our own server endpoint. Alternatives rejected: client-side
aggregation (ships 40k rows to the browser), asking for a new upstream endpoint (owned by another team,
multi-sprint lead time). Consequences: one more endpoint to test; upstream contract changes now break one file."

**BAD:** "ADR-0004: Use TypeScript" — not a decision, it is the existing stack.
**BAD:** An ADR restating a `coding-patterns.local/` rule with no alternatives section.
**BAD:** Writing one mid-discussion before the user has decided.
