#!/usr/bin/env bash
# Regression test for factory-run.sh: exit codes and the generated allowlist, with a fake
# `claude` on PATH, so no model is called. Runs only in throwaway repos under a temp dir.
# Usage: bash scripts/factory-run.test.sh
set -u
F="$(cd "$(dirname "$0")" && pwd)/factory-run.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected $2, got $3)"; }

mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_ARGS"
d=.workstyle/runs/20990101-0000-x
case "$FAKE_MODE" in
  done) mkdir -p $d; printf 'state: running\nstate: done\n' > $d/status.md ;;
  handoff) mkdir -p $d; printf 'state: handed-off\n' > $d/status.md; echo "arch decision" > $d/failure.md ;;
  running) mkdir -p $d; printf 'state: running\n' > $d/status.md ;;
  crash) exit 7 ;;
esac
exit 0
EOF
chmod +x "$T/bin/claude"
run() { (cd "$T/r" && FAKE_MODE="$1" FAKE_ARGS="$T/args" PATH="$T/bin:$PATH" bash "$F" "do x" 1 >/dev/null 2>"$T/err"; echo $?); }

mkdir -p "$T/r"
expect "not a git repo -> 4" 4 "$(run done)"
git -C "$T/r" init -q .
expect "no gates.conf -> 4" 4 "$(run done)"

mkdir -p "$T/r/.workstyle"
printf '# comment\ntest: pytest -q\nlint: ruff check .\nmax_diff_lines: 5\n\naudit: pip-audit\n' > "$T/r/.workstyle/gates.conf"
expect "no run dir created -> 4" 4 "$(run none)"
expect "state: done -> 0" 0 "$(run done)"
rm -rf "$T/r/.workstyle/runs"
expect "handed off -> 3" 3 "$(run handoff)"
grep -q "arch decision" "$T/err" && ok "failure.md is printed" || bad "failure.md is printed"
rm -rf "$T/r/.workstyle/runs"
expect "stopped mid-run -> 5" 5 "$(run running)"
rm -rf "$T/r/.workstyle/runs"
expect "claude failed before a run -> its exit code" 7 "$(run crash)"

run done >/dev/null
grep -qxF 'Bash(pytest -q)' "$T/args" && grep -qxF 'Bash(pytest -q *)' "$T/args" && ok "gate command is allowlisted" || bad "gate command is allowlisted"
grep -qxF 'Bash(ruff check .)' "$T/args" && grep -qxF 'Bash(pip-audit)' "$T/args" && ok "every gate command is allowlisted" || bad "every gate command is allowlisted"
grep -q 'max_diff\|comment' "$T/args" && bad "settings and comments aren't allowlisted" || ok "settings and comments aren't allowlisted"
grep -qxF '/workstyle:feature-factory do x' "$T/args" && ok "plain request is wrapped in the skill command" || bad "plain request is wrapped in the skill command"
grep -qE '^Bash\((bash \*|git push:\*|git push \*)\)$|^WebFetch$' "$T/args" && bad "no broad bash/push/WebFetch grant" || ok "no broad bash/push/WebFetch grant"
grep -qxF '.workstyle/' "$(git -C "$T/r" rev-parse --absolute-git-dir)/info/exclude" && ok ".workstyle/ is git-excluded" || bad ".workstyle/ is git-excluded"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
