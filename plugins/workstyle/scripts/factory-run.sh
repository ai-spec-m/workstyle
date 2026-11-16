#!/usr/bin/env bash
# Headless feature-factory run: a request in, a local commit or draft PR out, no
# human at the keyboard. Run from the target repo's root.
#
#   bash <plugin>/scripts/factory-run.sh "<feature request or ticket key>" [budget-usd]
#
# Exit codes (what CI should branch on, not claude's own exit code):
#   0  run ended `state: done` (gates passed, committed / draft PR per finish policy)
#   3  run handed off, failed, gates-failed or aborted: <run dir>/failure.md says why
#   4  no run dir was created: the pipeline never started (prerequisites missing, or skipped)
#   5  claude stopped while the run was still `running`/`paused` (budget, crash, early stop)
#   other non-zero: claude itself failed (auth, gateway, bad flag)
# It never merges a PR.
set -uo pipefail

REQUEST="${1:?usage: factory-run.sh \"<request>\" [budget-usd]}"
BUDGET="${2:-15}"
case "$REQUEST" in *--gated*) echo "factory-run: --gated needs a human at the keyboard; run it interactively" >&2; exit 2 ;; esac
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "factory-run: not inside a git repo" >&2; exit 4; }
cd "$REPO" || exit 4

conf=.workstyle/gates.conf
[ -f "$conf" ] || { echo "factory-run: $conf missing — run /workstyle:init in this repo first" >&2; exit 4; }

# .git is a protected path (denied under dontAsk), so the launcher, not the model, keeps
# the run's local-only folders out of git.
exclude="$(git rev-parse --git-path info/exclude)"; mkdir -p "$(dirname "$exclude")"
for p in .workstyle/ architecture.local/; do grep -qxF "$p" "$exclude" 2>/dev/null || echo "$p" >> "$exclude"; done

# The repo's own gate commands (whatever the stack) are the only build/test commands allowed.
gate_rules=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  name="${line%%:*}"; cmd="$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//')"
  [ "$name" = max_diff_lines ] || [ -z "$cmd" ] && continue
  gate_rules+=("Bash($cmd)" "Bash($cmd *)")
done < "$conf"

mkdir -p .workstyle/factory-runs
stamp="$(date +%Y%m%d-%H%M%S)"
LOG=".workstyle/factory-runs/$stamp.jsonl"
marker="$(mktemp)"; trap 'rm -f "$marker"' EXIT

case "$REQUEST" in /workstyle:feature-factory*) PROMPT="$REQUEST" ;; *) PROMPT="/workstyle:feature-factory $REQUEST" ;; esac

# dontAsk, not bypassPermissions: anything outside the allowlist is denied rather than waved
# through. --plugin-dir loads this exact copy, so the gates.sh path in the rules below matches
# the path the skill expands ${CLAUDE_PLUGIN_ROOT} to.
claude -p "$PROMPT" \
  --plugin-dir "$PLUGIN_ROOT" \
  --permission-mode dontAsk \
  --append-system-prompt "You are running /workstyle:feature-factory unattended (AUTONOMY: auto). Follow the skill exactly. Never skip the pipeline or decide a task is too small for it: the caller chose it. Nobody can answer questions; take the documented default or hand off. The run counts as successful only when gates.sh --end done succeeds." \
  --allowedTools \
    "Read" "Grep" "Glob" "Edit" "Write" "Agent" "Skill" "TodoWrite" \
    "mcp__atlassian__getJiraIssue" "mcp__atlassian__searchJiraIssuesUsingJql" \
    "mcp__atlassian__getJiraIssueRemoteIssueLinks" \
    "mcp__figma__get_figma_data" "mcp__figma__download_figma_images" \
    "Bash(git status *)" "Bash(git diff *)" "Bash(git log *)" "Bash(git branch --show-current)" \
    "Bash(git rev-parse *)" "Bash(git switch -c ff/*)" "Bash(git add *)" "Bash(git commit *)" \
    "Bash(git push -u origin ff/*)" \
    "Bash(gh pr create *)" "Bash(gh pr view *)" "Bash(gh pr checks *)" "Bash(gh run view *)" \
    "Bash(codegraph *)" \
    "Bash(bash $PLUGIN_ROOT/scripts/gates.sh *)" "Bash(bash \"$PLUGIN_ROOT/scripts/gates.sh\" *)" \
    "Bash(head -c 8 /dev/urandom)" "Bash(od -An -tx1)" "Bash(tr -d *)" "Bash(date *)" \
    "${gate_rules[@]}" \
  --max-budget-usd "$BUDGET" \
  --output-format stream-json --verbose \
  > "$LOG"
rc=$?

run="$(find .workstyle/runs -mindepth 1 -maxdepth 1 -type d -newer "$marker" 2>/dev/null | sort | tail -n 1)"
if [ -z "$run" ]; then
  [ "$rc" -ne 0 ] && { echo "factory-run: claude exited $rc before a run started — see $LOG" >&2; exit "$rc"; }
  echo "factory-run: BLOCKED — the pipeline never started a run (no .workstyle/runs/ dir). See $LOG" >&2
  exit 4
fi
state="$(sed -n 's/^state: *//p' "$run/status.md" 2>/dev/null | tail -n 1)"
echo "factory-run: $run state=${state:-unknown} (log: $LOG)" >&2
case "$state" in
  done) exit 0 ;;
  handed-off|failed|gates-failed|aborted)
    [ -f "$run/failure.md" ] && cat "$run/failure.md" >&2
    exit 3 ;;
  *) [ "$rc" -ne 0 ] && exit "$rc"; exit 5 ;;
esac
