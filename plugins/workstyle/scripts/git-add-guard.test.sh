#!/usr/bin/env bash
# Regression test for git-add-guard.sh: the 5 cases LLD_PORT.md §5.4 calls out.
# Usage: bash scripts/git-add-guard.test.sh
set -u
G="$(cd "$(dirname "$0")" && pwd)/git-add-guard.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected rc $2, got $3)"; }

run() {
  printf '%s' "$1" | jq -Rs '{tool_name:"Bash", tool_input:{command: .}}' | bash "$G" >/dev/null 2>&1
  echo $?
}

expect "substring false-positive (echo mentioning git push) is not blocked" 0 "$(run 'echo "run git push after this"')"
expect "wrapped/env/bash-c invocation is caught" 2 "$(run 'bash -c "git add ."')"
expect "env-wrapped push-adjacent add is caught" 2 "$(run 'env X=1 bash -c "git add ."')"
expect "global-flag add . is caught" 2 "$(run 'git -C /tmp add .')"
expect "message-flag value is not scanned as a path" 0 "$(run 'git commit -m "add . to list"')"
expect "legitimate blocked case: git add ." 2 "$(run 'git add .')"

expect "git add -A is caught" 2 "$(run 'git add -A')"
expect "force push is caught" 2 "$(run 'git push --force origin ff/x')"
expect "-f push is caught" 2 "$(run 'git push -f origin ff/x')"
expect "force-with-lease is caught" 2 "$(run 'git push --force-with-lease origin ff/x')"
expect "+refspec push is caught" 2 "$(run 'git push origin +ff/x')"
expect "push to main is caught" 2 "$(run 'git push origin HEAD:main')"
expect "push to master is caught" 2 "$(run 'git -C . push origin master')"
expect "push of a feature branch is allowed" 0 "$(run 'git push -u origin ff/add-thing')"
expect "reset --hard is caught" 2 "$(run 'git reset --hard HEAD~1')"
expect "clean -fd is caught" 2 "$(run 'git clean -fd')"
expect "branch -D is caught" 2 "$(run 'git branch -D ff/old')"
expect "terraform apply is caught" 2 "$(run 'cd infra && terraform apply -auto-approve')"
expect "gh pr merge is caught" 2 "$(run 'gh pr merge 12 --squash')"
expect "wrapped publish is caught" 2 "$(run 'bash -c "npm publish"')"
expect "mentioning a forbidden command is not blocked" 0 "$(run 'echo "never run terraform apply"')"
expect "glob in a command is not expanded by the guard" 0 "$(run 'ls /*/*/*/*')"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
