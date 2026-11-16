#!/usr/bin/env bash
# feature-factory deterministic gates.
#   --baseline     start a run: freeze gates.conf, base_sha and the untracked-file list
#                  outside the repo, and record each already-failing gate's failure lines
#                  (gates-baseline.md); an interrupted --baseline can be re-run
#   --arm          turn the Stop/SubagentStop hook on for this session's run (before builders);
#                  refuses on a gates-failed run
#   --pause        turn the hook off while the run waits for the user; --arm turns it back on.
#                  A gates-failed run stays gates-failed
#   --run          run every gate, write gates-latest.md; exit 1 on any failure
#   --hook         Stop/SubagentStop hook: no-op unless a run is armed in this repo, or while a
#                  background subagent still runs; exit 2 (stderr fed back to the model) blocks
#                  the stop on failure. After 3 blocks it re-runs once more, then releases the
#                  stop and marks the run gates-failed if the gates still fail
#   --end <state>  finish the run: done (only if gates pass and needs_human is unset) | failed |
#                  aborted | handed-off. --arm/--snapshot/--baseline then refuse on that run
#   --snapshot     print a hash of the working tree's changes since base_sha (for resume)
#   --changed      list the files the run changed since base_sha, both sides of renames and
#                  deletions included (what to stage at commit)
# What the hook trusts lives in <state dir>/runs/<repo key>/, outside the repo, so editing
# .workstyle/ (gates.conf, status.md, current) can't switch the gates off. The state dir is
# $CLAUDE_PLUGIN_DATA in hooks; skills pass it as a leading --state-dir=<dir> (an argument, not
# an env-var prefix, so a `Bash(bash …/gates.sh *)` allow rule matches it in headless runs);
# WORKSTYLE_STATE_DIR still works for tests.
# Gate commands: one `name: command` per line. `audit: <cmd>` runs only when a lockfile
# changed; `max_diff_lines: <n>` asks for a human when the diff is bigger.
# Each gate gets WORKSTYLE_GATE_TIMEOUT s (600), all gates together WORKSTYLE_GATES_BUDGET s
# (1500, under the hook's 1800 s timeout: a hook the harness times out lets the stop through).
# A gate that times out or never runs for lack of budget blocks.
set -u
case "${1:-}" in --state-dir=*) WORKSTYLE_STATE_DIR="${1#--state-dir=}"; shift ;; esac
mode="${1:---run}"
input=""; [ "$mode" = "--hook" ] && input=$(cat)

root=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || exit 0
ws="$root/.workstyle"
data="${CLAUDE_PLUGIN_DATA:-${WORKSTYLE_STATE_DIR:-}}"
if [ -z "$data" ]; then
  [ "$mode" = "--hook" ] && exit 0
  echo "workstyle gates: run as bash gates.sh --state-dir=\${CLAUDE_PLUGIN_DATA} $mode" >&2
  exit 1
fi
fz="$data/runs/$(printf %s "$root" | git hash-object --stdin)"

if [ "$mode" = "--hook" ]; then
  [ -f "$fz/armed" ] || exit 0
  # An armed run gates every session in this repo (they share the tree). One that saw no
  # stop for 24 h was abandoned by a crash; it stops gating instead of nagging forever.
  [ -n "$(find "$fz/armed" -mmin -1440 2>/dev/null)" ] || exit 0
  touch "$fz/armed"
  # The main turn can stop while a background builder still edits; its SubagentStop gates it.
  # Not on SubagentStop: a builder's own stop gates even while a sibling builder runs.
  # shortcut: grep, not a JSON parser; a `]` or `}` inside a task's text makes it gate (the safe side)
  printf '%s' "$input" | grep -qE '"hook_event_name"[[:space:]]*:[[:space:]]*"SubagentStop"' || {
    printf '%s' "$input" | tr -d '\n' | grep -o '"background_tasks"[[:space:]]*:[[:space:]]*\[[^]]*\]' | tr '}' '\n' \
      | grep '"type"[[:space:]]*:[[:space:]]*"subagent"' | grep -qE '"status"[[:space:]]*:[[:space:]]*"(running|pending)"' && exit 0; }
fi
ended() { [ -f "$fz.ended" ] && awk -F '\t' -v r="$1" '$1==r{s=$2} END{printf "%s", s}' "$fz.ended"; }

if [ "$mode" = "--baseline" ]; then
  [ -f "$ws/current" ] || { echo "workstyle gates: $ws/current is missing" >&2; exit 1; }
  run_name=$(cat "$ws/current")
  st=$(ended "$run_name")
  [ -n "$st" ] && { echo "workstyle gates: run $run_name already ended ($st); start fresh" >&2; exit 1; }
  if [ "$(cat "$fz/run" 2>/dev/null)" = "$run_name" ]; then
    echo "workstyle gates: run $run_name already has a baseline; on resume use --arm, never --baseline" >&2; exit 1
  fi
  base=$(sed -n 's/^base_sha: *//p' "$ws/runs/$run_name/status.md" 2>/dev/null | head -1)
  git -C "$root" rev-parse -q --verify "${base:-x}^{commit}" >/dev/null \
    || { echo "workstyle gates: base_sha '$base' in status.md isn't a commit" >&2; exit 1; }
  [ -f "$ws/gates.conf" ] || { echo "workstyle gates: $ws/gates.conf is missing — run /workstyle:init" >&2; exit 1; }
  if git -C "$root" ls-files --error-unmatch .workstyle/gates.conf >/dev/null 2>&1; then
    echo "workstyle gates: .workstyle/gates.conf is committed to this repo, so its commands weren't written by /workstyle:init here. Review it, then run /workstyle:init." >&2; exit 1
  fi
  rm -rf "$fz"; mkdir -p "$fz/baseline"
  cp "$ws/gates.conf" "$fz/gates.conf"; echo "$base" > "$fz/base_sha"
  git -C "$root" ls-files --others --exclude-standard -- . ':(exclude).workstyle' > "$fz/untracked.txt"
fi

# $fz/run is written only when --baseline completes.
if [ "$mode" != "--baseline" ] && [ ! -f "$fz/run" ]; then
  [ "$mode" = "--hook" ] && exit 0
  r=$(cat "$ws/current" 2>/dev/null || tail -n 1 "$fz.ended" 2>/dev/null | cut -f1); st=$(ended "$r")
  [ -n "$st" ] && { echo "workstyle gates: run $r already ended ($st); start fresh" >&2; exit 1; }
  echo "workstyle gates: no run started in $root — run --baseline first" >&2; exit 1
fi
run="$ws/runs/${run_name:-$(cat "$fz/run")}"; status="$run/status.md"; mkdir -p "$run"
base=$(cat "$fz/base_sha")
put() { { grep -v "^$1:" "$status" 2>/dev/null; echo "$1: $2"; } > "$status.tmp" && mv "$status.tmp" "$status"; }
finish() {
  put state "$1"
  # One line per run, outside the repo, so run outcomes survive and can be reviewed.
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$run")" "$1" \
    "$(grep -E '^(builder_passes|gates|needs_human):' "$status" 2>/dev/null | tr '\n' ' ')" >> "$data/history.log"
  printf '%s\t%s\n' "$(basename "$run")" "$1" >> "$fz.ended"; rm -rf "$fz"
  [ "$(cat "$ws/current" 2>/dev/null)" = "$(basename "$run")" ] && rm -f "$ws/current"
  exit 0
}

ending=""
case "$mode" in
  --arm)
    [ -f "$fz/gates-failed" ] && { echo "workstyle gates: run $(basename "$run") is gates-failed; start a fresh run" >&2; exit 1; }
    # A run-level lock: two instances (two terminals/sessions) arming the same run_name
    # would otherwise race gates.sh's shared state with no coordination. A lock held by a
    # dead PID (crashed session) is stale and safe to steal.
    if [ -f "$fz/lock" ]; then
      lock_pid=$(cat "$fz/lock" 2>/dev/null)
      if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        echo "workstyle gates: run $(basename "$run") is already armed by another session (pid $lock_pid). Use a different run_name, or wait for that session to --pause/--end." >&2
        exit 1
      fi
    fi
    echo $$ > "$fz/lock"
    echo 0 > "$fz/blocks"; : > "$fz/armed"; put state running; exit 0 ;;
  --pause) rm -f "$fz/armed" "$fz/lock"; [ -f "$fz/gates-failed" ] || put state paused; exit 0 ;;
  --end)
    case "${2:-}" in
      done) ending=done; mode=--run ;;
      failed|aborted|handed-off) finish "$2" ;;
      *) echo "usage: gates.sh --end done|failed|aborted|handed-off" >&2; exit 1 ;;
    esac ;;
  --snapshot)
    cd "$root" && { git diff --binary "$base" -- . ':(exclude).workstyle'
      git ls-files -z --others --exclude-standard -- . ':(exclude).workstyle' | xargs -0 -r sha1sum; } \
      | git hash-object --stdin; exit 0 ;;
  --baseline|--run|--hook|--changed) ;;
  *) echo "usage: gates.sh --baseline|--arm|--pause|--run|--hook|--end <state>|--snapshot|--changed" >&2; exit 1 ;;
esac

if [ "$mode" = "--hook" ]; then
  # Counted before the gates run, so a hook the harness cancels on timeout still counts.
  blocks=$(( $(tr -cd '0-9' < "$fz/blocks" 2>/dev/null | sed 's/^$/0/') + 1 ))
  echo "$blocks" > "$fz/blocks"
fi

cd "$root" || exit 1
report="$run/gates-latest.md"
gate_timeout="${WORKSTYLE_GATE_TIMEOUT:-600}"; budget="${WORKSTYLE_GATES_BUDGET:-1500}"; t0=$SECONDS
tmo() { if command -v timeout >/dev/null; then timeout "$@"; else shift; "$@"; fi; }
# Lines that look like failures (a multiset: a repeat is a new failure), with every number blanked
# except failure counts, so timings, line:col and pass counts don't make them "new".
sig() { grep -iE 'fail|error|✗|✕|●' | sed -E 's/(^|[^0-9.:])([0-9]+)( (failed|errors?|problems?|warnings?))/\1#\2#\3/g
  s/(^|[^#0-9])[0-9]+([.:][0-9]+)*/\1N/g; s/#([0-9]+)#/\1/g; s/[[:space:]]+/ /g' | sort; }

# The run's own files never count as feature changes (reports quote secrets, add lines).
skip=':(exclude).workstyle'
# shortcut: files untracked before the run are never scanned, even if a builder edits them; snapshot their hashes if that matters
untracked() { git ls-files -z --others --exclude-standard -- . "$skip" | tr '\0' '\n' | grep -vxF -f "$fz/untracked.txt" | tr '\n' '\0'; }
changed_names() { git diff --name-only --no-renames "$base" -- . "$skip" 2>/dev/null; untracked | tr '\0' '\n'; }
[ "$mode" = "--changed" ] && { changed_names | sort -u; exit 0; }
lockfile_re='(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|poetry\.lock|Pipfile\.lock|uv\.lock|requirements[^/]*\.txt|go\.sum|Cargo\.lock|Gemfile\.lock|composer\.lock)$'

failed=""; tails=""; max_diff=""
{ echo "# Gates — $(date -u +%Y-%m-%dT%H:%M:%SZ) @ $(git rev-parse --short HEAD)"; echo; } > "$report.tmp"
fail() { # fail <name> <report line> <output for the model>
  failed="$failed $1"; printf '%s\n' "$2" >> "$report.tmp"
  tails="$tails
--- $1
$3"
}

if [ "$mode" != "--baseline" ] && ! cmp -s "$fz/gates.conf" "$ws/gates.conf"; then
  fail gates-config "- gates-config: FAIL — .workstyle/gates.conf differs from the copy frozen at run start" \
    ".workstyle/gates.conf was changed or deleted during the run. Gates still run from the copy frozen at run start; undo your change to .workstyle/gates.conf"
fi

while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  name=$(printf '%s' "${line%%:*}" | tr -cd 'A-Za-z0-9_-')
  cmd=$(printf '%s' "${line#*:}" | sed 's/^[[:space:]]*//')
  [ -n "$name" ] && [ -n "$cmd" ] || continue
  if [ "$name" = "max_diff_lines" ]; then max_diff=$cmd; continue; fi
  if [ "$name" = "audit" ] && [ "$mode" != "--baseline" ] && ! changed_names | grep -qE "$lockfile_re"; then
    echo "- audit: skipped (no lockfile changed)" >> "$report.tmp"; continue
  fi
  left=$((budget - SECONDS + t0)); t=$gate_timeout; [ "$left" -lt "$t" ] && t=$left
  if [ "$t" -le 0 ]; then
    [ "$mode" = "--baseline" ] && { echo "- $name: not run, gates budget exhausted" >> "$report.tmp"; continue; }
    fail "$name" "- $name: FAIL — not run, gates budget exhausted" "$name: not run, the gates budget ($budget s) ran out: $cmd"; continue
  fi
  out=$(tmo "$t" bash -c "$cmd" </dev/null 2>&1); rc=$?
  if [ $rc -eq 0 ]; then echo "- $name: pass" >> "$report.tmp"; continue; fi
  tail_out=$(printf '%s\n' "$out" | tail -n 40)
  # A timeout hides how the gate would have ended, so it never counts as a pre-existing failure.
  if [ $rc -eq 124 ]; then
    [ "$mode" = "--baseline" ] && { echo "- $name: timed out after ${t}s — no baseline" >> "$report.tmp"; continue; }
    fail "$name" "- $name: FAIL — timed out after ${t}s" "$name: timed out after ${t}s: $cmd"; continue
  fi
  if [ "$mode" = "--baseline" ]; then
    printf '%s\n' "$out" | sig > "$fz/baseline/$name"
    failed="$failed $name"; echo "- $name: pre-existing failure (exit $rc) — baseline" >> "$report.tmp"; continue
  fi
  # A baseline with no failure-looking lines can't be compared, so that gate still blocks.
  if [ -s "$fz/baseline/$name" ]; then
    # A failure count that only went down (old failures fixed) isn't a new failure.
    new=$(printf '%s\n' "$out" | sig | comm -13 "$fz/baseline/$name" - | awk '{ k = $0; gsub(/[0-9]+/, "N", k) }
      NR == FNR { b[k] = b[k] "\n" $0; next }
      /[0-9]/ { n = split($0, x, /[^0-9]+/); m = split(b[k], L, "\n")
        for (i = 2; i <= m; i++) { split(L[i], y, /[^0-9]+/); up = 0; down = 0
          for (j = 1; j <= n; j++) { if (x[j] + 0 > y[j] + 0) up = 1; if (x[j] + 0 < y[j] + 0) down = 1 }
          if (down && !up) next } }
      { print }' "$fz/baseline/$name" -)
    if [ -z "$new" ]; then
      echo "- $name: pre-existing failures only (exit $rc) — not blocking" >> "$report.tmp"; continue
    fi
    tail_out="New failures (not present before the run):
$(printf '%s\n' "$new" | head -n 40)"
  fi
  fail "$name" "$(printf -- '- %s: FAIL (exit %s) — `%s`\n```\n%s\n```' "$name" "$rc" "$cmd" "$tail_out")" \
    "$name (exit $rc): $cmd
$tail_out"
done < "$fz/gates.conf"

if [ "$mode" = "--baseline" ]; then
  mv "$report.tmp" "$run/gates-baseline.md"; echo "$run_name" > "$fz/run"
  put gates "baseline recorded (already failing:${failed:- none})"
  exit 0
fi

# Built-in secret scan over lines added since base_sha, plus new untracked files.
# A line containing `workstyle:allow-secret` is ignored (for deliberate test fixtures).
# Hits are reported as file:line only, so the value never reaches the model or the report.
# Lines arrive as file:line:text. A key=value hit is skipped when the value is a reference
# (process.env, ${X}, $X, <placeholder>...). An unquoted value counts only when it ends the line
# (.env, YAML), so code like `token: accessToken,` or `password = hash(x)` doesn't.
key_re='(api[_-]?key|secret|passw(or)?d|token)'
token_re='AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36}|xox[abprs]-[A-Za-z0-9-]{10,}|(^|[^a-z0-9])(sk-ant-[a-z0-9_-]{20,}|sk_live_[a-z0-9]{16,}|sk-[a-z0-9_-]{32,})'
kv_re="$key_re[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'[:space:]]{12,}|^[^:]*:[0-9]+:[[:space:]]*(export[[:space:]]+)?[a-z0-9_.-]*$key_re[a-z0-9_-]*[[:space:]]*[:=][[:space:]]*[^\"'[:space:],;()]{12,}[[:space:]]*\$"
ref_re="$key_re[a-z0-9_-]*[\"']?[[:space:]]*[:=][[:space:]]*[\"']?(process\\.env|os\\.environ|[a-z_.]*getenv|\\\$|env\\[|<)"
added_lines=$( { git diff -U0 --no-color --no-renames "$base" -- . "$skip" 2>/dev/null \
            | awk '/^\+\+\+ /{f=substr($0,7); next} /^@@/{split($3,a,","); n=substr(a[1],2)+0; next} /^\+/{print f":"n":"substr($0,2); n++}'
          untracked | xargs -0 -r grep -nIH -- '' 2>/dev/null; } | grep -v 'workstyle:allow-secret')
hits=$( { printf '%s\n' "$added_lines" | grep -iE "$token_re"
          printf '%s\n' "$added_lines" | grep -iE "$kv_re" | grep -viE "$ref_re"; } \
        | cut -d: -f1,2 | sort -t: -k1,1 -k2,2n -u | head -n 10)
if [ -n "$hits" ]; then
  fail secret-scan "$(printf -- '- secret-scan: FAIL (values not shown)\n```\n%s\n```' "$hits")" \
    "possible secrets added at (values not shown):
$hits"
else
  echo "- secret-scan: pass" >> "$report.tmp"
fi

# Diff size never blocks a builder (it can't fix that by itself); it asks for a human instead.
added=$(git diff --numstat --no-renames "$base" -- . "$skip" 2>/dev/null | awk '{a+=$1+$2} END{print a+0}')
new_lines=$(untracked | xargs -0 -r cat 2>/dev/null | wc -l | tr -d ' ')
diff_lines=$((added + new_lines))
echo "- diff size: $diff_lines lines${max_diff:+ (max $max_diff)}" >> "$report.tmp"
if [ -n "$max_diff" ] && [ "$diff_lines" -gt "$max_diff" ] 2>/dev/null; then
  put needs_human "diff-size $diff_lines > $max_diff"
elif grep -q '^needs_human: diff-size' "$status" 2>/dev/null; then
  grep -v '^needs_human: diff-size' "$status" > "$status.tmp" && mv "$status.tmp" "$status"
fi

mv "$report.tmp" "$report"
sha=$(git rev-parse --short HEAD)
if [ -z "$failed" ]; then
  put gates "pass @ $sha"; echo 0 > "$fz/blocks"
  if [ "$ending" = done ]; then
    # Checked after the run, which may have just set needs_human (diff size).
    nh=$(sed -n 's/^needs_human: *//p' "$status" | head -1)
    [ -n "$nh" ] && { echo "workstyle gates: can't end the run as done while needs_human is set: $nh" >&2; exit 1; }
    finish done
  fi
  exit 0
fi
put gates "FAIL ($(echo $failed)) @ $sha"
if [ "$mode" = "--hook" ] && [ "$blocks" -gt 3 ]; then
  rm -f "$fz/armed"; : > "$fz/gates-failed"; put state gates-failed
  echo "workstyle gates still failing after 3 blocked stops; run marked gates-failed — see $report" >&2
  exit 0
fi
if [ "$mode" = "--run" ]; then
  [ "$ending" = done ] && echo "workstyle gates: can't end the run as done while gates fail — see $report" >&2
  exit 1
fi
{
  echo "workstyle gates FAILED:${failed} (attempt $blocks of 3). Fix these before finishing."
  echo "Don't weaken, skip or delete tests or checks to get past this. Full report: $report"
  printf '%s\n' "$tails" | tail -n 120
} >&2
exit 2
