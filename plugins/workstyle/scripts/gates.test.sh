#!/usr/bin/env bash
# Regression test for gates.sh: replays the bypass attempts it must hold against.
# Runs only in throwaway repos under a temp dir. Usage: bash scripts/gates.test.sh
set -u
G="$(cd "$(dirname "$0")" && pwd)/gates.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export WORKSTYLE_STATE_DIR="$T/data"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected rc $2, got $3)"; }

mkrepo() { # mkrepo <name> <gates.conf>
  R="$T/$1"; mkdir -p "$R"; cd "$R" || exit 1
  git init -q . && git config user.email t@t && git config user.name t
  echo base > a.txt; git add .; git commit -qm init
  mkdir -p .workstyle/runs/r1; echo r1 > .workstyle/current; echo .workstyle/ >> .git/info/exclude
  printf 'run: r1\nbase_sha: %s\nstate: running\n' "$(git rev-parse HEAD)" > .workstyle/runs/r1/status.md
  printf '%s\n' "$2" > .workstyle/gates.conf
  S=$R/.workstyle/runs/r1/status.md
}
g()    { CLAUDE_PROJECT_DIR=$R bash "$G" "$@" </dev/null >/dev/null 2>&1; echo $?; }
hook() { local j=${1:-'{"session_id":"s","hook_event_name":"Stop"}'}; printf '%s\n' "$j" | CLAUDE_PROJECT_DIR=$R bash "$G" --hook >"$T/out" 2>&1; echo $?; }
err()  { CLAUDE_PROJECT_DIR=$R bash "$G" "$@" </dev/null 2>&1 >/dev/null; }
fz()   { echo "$WORKSTYLE_STATE_DIR/runs/$(printf %s "$R" | git hash-object --stdin)"; }
L=.workstyle/runs/r1/gates-latest.md
start() { g --baseline >/dev/null; g --arm >/dev/null; }

mkrepo plain 'test: test ! -f broken'; start
expect "passing gate lets the stop through" 0 "$(hook)"
touch broken
expect "failing gate blocks the stop" 2 "$(hook)"

mkrepo conf 'test: test ! -f broken'; start; touch broken
printf 'test: true\n' > .workstyle/gates.conf
expect "weakened gates.conf still blocks" 2 "$(hook)"
grep -q gates-config "$T/out" && ok "weakened gates.conf is reported" || bad "weakened gates.conf is reported"
grep -qF "$WORKSTYLE_STATE_DIR" "$T/out" $L && bad "frozen gates.conf path never shown" || ok "frozen gates.conf path never shown"
rm .workstyle/gates.conf
expect "deleted gates.conf still blocks" 2 "$(hook)"

mkrepo inject 'test: true'; start; rm -f "$T/pwned"
printf 'test: touch %s/pwned\n' "$T" > .workstyle/gates.conf
hook >/dev/null; [ -e "$T/pwned" ] && bad "command added to gates.conf mid-run never runs" || ok "command added to gates.conf mid-run never runs"

mkrepo status 'test: test ! -f broken'; start; touch broken
grep -q '^gates_required:' "$S" && bad "--arm writes no gates_required" || ok "--arm writes no gates_required"
sed -i 's/^state: running/state: done/' "$S"
sed -i "s/^base_sha: .*/base_sha: nonsense/" "$S"
expect "editing status.md doesn't switch gates off" 2 "$(hook)"
rm .workstyle/current
expect "deleting .workstyle/current doesn't switch gates off" 2 "$(hook)"

mkrepo clone 'test: true'; rm -f "$T/pwned2"
printf 'test: touch %s/pwned2\n' "$T" > .workstyle/gates.conf
hook >/dev/null; [ -e "$T/pwned2" ] && bad "unarmed repo's .workstyle never runs" || ok "unarmed repo's .workstyle never runs"
git add -f .workstyle; git commit -qm c
expect "committed gates.conf refuses to start a run" 1 "$(g --baseline)"

mkrepo stale 'test: test ! -f broken'; start; touch broken
expect "an armed run gates any session in the repo" 2 "$(hook)"
touch -d '2 days ago' "$(fz)/armed"
expect "a run abandoned for 24 h stops gating" 0 "$(hook)"

mkrepo resume 'test: test ! -f broken'; start; echo 'builder work' > feature.js
expect "--baseline refuses on the same run (resume)" 1 "$(g --baseline)"
expect "--arm re-arms a resumed run" 0 "$(g --arm)"
echo 'token = "abcdefghijklmnopqrstu"' >> feature.js
expect "builder files stay in scope after resume" 2 "$(hook)"
s1=$(CLAUDE_PROJECT_DIR=$R bash "$G" --snapshot); s2=$(CLAUDE_PROJECT_DIR=$R bash "$G" --snapshot)
[ -n "$s1" ] && [ "$s1" = "$s2" ] && ok "--snapshot is stable" || bad "--snapshot is stable"
echo more >> feature.js
[ "$s1" != "$(CLAUDE_PROJECT_DIR=$R bash "$G" --snapshot)" ] && ok "--snapshot changes when the tree changes" || bad "--snapshot changes when the tree changes"

mkrepo blocks 'test: test ! -f broken'; start; touch broken
r="$(hook) $(hook) $(hook) $(hook)"
expect "3 blocks then release" "2 2 2 0" "$r"
grep -q '^state: gates-failed' "$S" && ok "release marks gates-failed" || bad "release marks gates-failed"
expect "--pause succeeds on a gates-failed run" 0 "$(g --pause)"
grep -q '^state: gates-failed' "$S" && ok "--pause keeps gates-failed" || bad "--pause keeps gates-failed"
sed -i 's/^state: .*/state: running/' "$S"
expect "--arm refuses on a gates-failed run" 1 "$(g --arm)"
err --arm | grep -q 'run r1 is gates-failed; start a fresh run' && ok "--arm says the run is gates-failed" || bad "--arm says the run is gates-failed"

mkrepo blocks2 'test: test ! -f broken'; start; touch broken
r="$(hook) $(hook)"; printf 'blocks: 0\nhook_blocks: 0\n' >> "$S"; r="$r $(hook) $(hook)"
expect "editing status.md can't reset the block count" "2 2 2 0" "$r"

mkrepo recover 'test: test ! -f broken'; start; touch broken
r="$(hook) $(hook) $(hook)"; rm broken; r="$r $(hook)"
expect "4th stop re-runs the gates first" "2 2 2 0" "$r"
grep -q '^state: gates-failed' "$S" && bad "passing 4th run doesn't mark gates-failed" || ok "passing 4th run doesn't mark gates-failed"

mkrepo base 'test: bash t.sh'; printf 'echo "FAIL old"; exit 1\n' > t.sh; git add t.sh; git commit -qm t
sed -i "s/^base_sha: .*/base_sha: $(git rev-parse HEAD)/" "$S"; start
expect "same failures as before the run don't block" 0 "$(hook)"
printf 'echo "FAIL old"; echo "FAIL new one"; exit 1\n' > t.sh
expect "new failures in a baseline-failing gate block" 2 "$(hook)"
printf 'echo "FAIL old"; exit 1\n' > t.sh; hook >/dev/null
grep -q '^- test: pre-existing failures only (exit 1) — not blocking$' $L && ok "pre-existing-only gate is reported as not blocking" || bad "pre-existing-only gate is reported as not blocking"
grep -q '^- test: pre-existing failure (exit 1) — baseline$' .workstyle/runs/r1/gates-baseline.md && ok "baseline reports pre-existing failure" || bad "baseline reports pre-existing failure"
grep -q FAIL $L .workstyle/runs/r1/gates-baseline.md && bad "pre-existing failures never say FAIL" || ok "pre-existing failures never say FAIL"
expect "--baseline can't be re-run mid-run" 1 "$(g --baseline)"
printf 'echo "FAIL old"; echo "FAIL old"; exit 1\n' > t.sh
expect "a repeated failure line is a new failure" 2 "$(hook)"
printf 'echo "FAIL old"; sleep 3; exit 1\n' > t.sh
expect "a baseline-failing gate that times out blocks" 2 "$(WORKSTYLE_GATE_TIMEOUT=1 hook)"

mkrepo jest 'test: bash t.sh'; printf 'echo "  ● a › works"; exit 1\n' > t.sh; git add t.sh; git commit -qm t
sed -i "s/^base_sha: .*/base_sha: $(git rev-parse HEAD)/" "$S"; start
expect "same jest ● failures don't block" 0 "$(hook)"
printf 'echo "  ● a › works"; echo "  ● b › breaks"; exit 1\n' > t.sh
expect "a new jest ● failure blocks" 2 "$(hook)"

mkrepo counts 'test: bash t.sh'; printf 'echo "Tests: 1 failed, 4 passed (1.2 s)"; exit 1\n' > t.sh; git add t.sh; git commit -qm t
sed -i "s/^base_sha: .*/base_sha: $(git rev-parse HEAD)/" "$S"; start
printf 'echo "Tests: 1 failed, 5 passed (3.4 s)"; exit 1\n' > t.sh
expect "changed pass counts and timings don't block" 0 "$(hook)"
printf 'echo "Tests: 2 failed, 4 passed (1.2 s)"; exit 1\n' > t.sh
expect "a higher failure count blocks" 2 "$(hook)"
printf 'echo "Tests: 2 failed, 4 passed"; echo "Tests: 2 failed, 4 passed"; exit 1\n' > t.sh; g --end aborted >/dev/null
echo r2 > .workstyle/current; mkdir -p .workstyle/runs/r2; cp "$S" .workstyle/runs/r2/status.md; S=$R/.workstyle/runs/r2/status.md; start
printf 'echo "Tests: 1 failed, 5 passed"; echo "Tests: 2 failed, 4 passed"; exit 1\n' > t.sh
expect "a lower failure count doesn't block" 0 "$(hook)"

mkrepo timeout 'test: sleep 3'; start
expect "a gate that times out blocks" 2 "$(WORKSTYLE_GATE_TIMEOUT=1 hook)"
grep -q '^- test: FAIL — timed out after 1s$' $L && ok "timeout is reported" || bad "timeout is reported"

mkrepo budget $'slow: sleep 3\nnext: true'; start
expect "a gate the budget never reached blocks" 2 "$(WORKSTYLE_GATES_BUDGET=1 hook)"
grep -q '^- next: FAIL — not run, gates budget exhausted$' $L && ok "budget exhaustion is reported" || bad "budget exhaustion is reported"
grep -q onFailure "$(dirname "$G")/../hooks/hooks.json" && bad "hooks.json has no onFailure" || ok "hooks.json has no onFailure"

mkrepo interrupt 'test: sleep 3'
CLAUDE_PROJECT_DIR=$R timeout 1 bash "$G" --baseline >/dev/null 2>&1
printf 'test: true\n' > .workstyle/gates.conf
expect "an interrupted --baseline can be re-run" 0 "$(g --baseline)"

mkrepo secrets 'test: true'; start
printf '%s\n' 'API_KEY=${API_KEY_FROM_VAULT}' 'TOKEN=$GITHUB_TOKEN_VALUE' 'password: <your-password-here>' > refs.env
printf '%s\n' 'const apiKey = process.env.STRIPE_API_KEY;' 'secret = os.environ["APP_SECRET_KEY"]' 'token = os.getenv("GITHUB_TOKEN_X")' 'token = ENV["SOME_LONG_TOKEN"]' '  token: accessTokenValue,' > refs.js
expect "secret references don't block" 0 "$(hook)"
echo 'DB_PASSWORD=hunter2hunter2hunter2' > .env.local
printf 'db:\n  password: SuperSecretValue99\n' > config.yml
echo 'const k = "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123"' > k.js
echo 'stripe sk_live_abcdefghijklmnop1234' > s.txt
hook >/dev/null; h=$(grep -oE '[a-z.-]+:[0-9]+' "$T/out" | sort -u | tr '\n' ' ')
[ "$h" = ".env.local:1 config.yml:2 k.js:1 s.txt:1 " ] && ok "unquoted, YAML and sk- secrets are found" || bad "unquoted, YAML and sk- secrets are found (got '$h')"

mkrepo untracked 'test: true'; echo 'token = "abcdefghijklmnopqrstu"' > mine.txt; start
expect "secret in a file untracked before the run isn't charged to the run" 0 "$(hook)"
echo 'password = "RealProdPassw0rd123"' > new.js
expect "secret in a new file blocks" 2 "$(hook)"
grep -q RealProdPassw0rd123 "$T/out" .workstyle/runs/r1/gates-latest.md && bad "secret value never shown" || ok "secret value never shown"
grep -q 'new.js:1' "$T/out" && ok "secret reported as file:line" || bad "secret reported as file:line"

mkrepo diffsz $'test: true\nmax_diff_lines: 3'; start; seq 1 10 > big.txt; hook >/dev/null
grep -q '^needs_human:' "$S" && ok "big diff asks for a human" || bad "big diff asks for a human"
rm big.txt; hook >/dev/null
grep -q '^needs_human:' "$S" && bad "needs_human clears when the diff shrinks" || ok "needs_human clears when the diff shrinks"

mkrepo end 'test: test ! -f broken'; start; touch broken
expect "--end done refuses while gates fail" 1 "$(g --end done)"
rm broken
echo 'needs_human: validator asks about scope' >> "$S"
expect "--end done refuses while needs_human is set" 1 "$(g --end done)"
err --end done | grep -q "can't end the run as done while needs_human is set: validator asks about scope" && ok "--end done names the needs_human reason" || bad "--end done names the needs_human reason"
sed -i '/^needs_human:/d' "$S"
expect "--end done succeeds when gates pass" 0 "$(g --end done)"
[ -e .workstyle/current ] && bad "--end removes .workstyle/current" || ok "--end removes .workstyle/current"
expect "hook is a no-op after the run ends" 0 "$(touch broken; hook)"
err --arm | grep -q 'run r1 already ended (done); start fresh' && ok "--arm refuses on an ended run" || bad "--arm refuses on an ended run"
expect "--snapshot refuses on an ended run" 1 "$(g --snapshot)"
echo r1 > .workstyle/current
err --baseline | grep -q 'run r1 already ended (done); start fresh' && ok "--baseline refuses on an ended run" || bad "--baseline refuses on an ended run"

grep -q "$(printf 'r1\tdone')" "$WORKSTYLE_STATE_DIR/history.log" && ok "--end logs the run to history.log" || bad "--end logs the run to history.log"

mkrepo pause 'test: test ! -f broken'; start; touch broken
expect "--pause succeeds" 0 "$(g --pause)"
expect "a paused run doesn't gate stops" 0 "$(hook)"
grep -q '^state: paused' "$S" && ok "--pause marks state paused" || bad "--pause marks state paused"
g --arm >/dev/null
expect "--arm re-arms a paused run" 2 "$(hook)"

mkrepo changed 'test: true'; echo old > pre.txt; start
echo more >> a.txt; echo new > added.js; echo x > .workstyle/runs/r1/note.md
c=$(CLAUDE_PROJECT_DIR=$R bash "$G" --changed | tr '\n' ' ')
[ "$c" = "a.txt added.js " ] && ok "--changed lists modified + new files only" || bad "--changed lists modified + new files only (got '$c')"

mkrepo renames 'test: true'; seq 1 50 > old.txt; echo x > gone.txt; git add .; git commit -qm f
sed -i "s/^base_sha: .*/base_sha: $(git rev-parse HEAD)/" "$S"; start
git mv old.txt new.txt; git rm -q gone.txt; git commit -qm mv
c=$(CLAUDE_PROJECT_DIR=$R bash "$G" --changed | tr '\n' ' ')
[ "$c" = "gone.txt new.txt old.txt " ] && ok "--changed lists deletions and both sides of a rename" || bad "--changed lists deletions and both sides of a rename (got '$c')"

mkrepo silent 'test: false'; start
expect "gate failing before the run with no output still blocks" 2 "$(hook)"

mkrepo bg 'test: test ! -f broken'; start; touch broken
running='{"session_id":"s","hook_event_name":"Stop","background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"backend builder"}],"stop_hook_active":false}'
expect "Stop waits for a running background subagent" 0 "$(hook "$running")"
expect "... and doesn't count a block" 2 "$(hook)"
grep -q 'attempt 1 of 3' "$T/out" && ok "background skip didn't count a block" || bad "background skip didn't count a block"
expect "a finished background subagent doesn't skip" 2 "$(hook "${running/running/completed}")"
expect "a running background shell doesn't skip" 2 "$(hook "${running/subagent/shell}")"
g --arm >/dev/null
expect "SubagentStop gates even while a sibling runs" 2 "$(hook "${running/\"Stop\"/\"SubagentStop\"}")"

for m in baseline arm pause run hook end snapshot changed; do grep -q "^#   --$m " "$G" || bad "header documents --$m"; done; ok "header documents every mode"
grep -q GATES_BUDGET "$G" && sed -n '2,30p' "$G" | grep -q GATES_BUDGET && ok "header documents the budget" || bad "header documents the budget"

mkdir -p "$T/nogit"; expect "no-op outside git" 0 "$(echo '{}' | CLAUDE_PROJECT_DIR=$T/nogit bash "$G" --hook >/dev/null 2>&1; echo $?)"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
