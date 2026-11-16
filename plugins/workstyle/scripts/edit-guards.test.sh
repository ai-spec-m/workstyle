#!/usr/bin/env bash
# Regression test for the Edit/Write guards: type-safety-guard.sh (opt-in per repo) and
# protected-file-guard.sh. Runs only in throwaway repos under a temp dir.
# Usage: bash scripts/edit-guards.test.sh
set -u
D="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
expect() { [ "$2" = "$3" ] && ok "$1" || bad "$1 (expected rc $2, got $3)"; }
# edit <script> <file_path> <new text> [old text]
edit() {
  jq -n --arg f "$T/r/$2" --arg n "$3" --arg o "${4:-}" '{tool_name:"Edit", tool_input:{file_path:$f, new_string:$n, old_string:$o}}' \
    | CLAUDE_PROJECT_DIR="$T/r" bash "$D/$1" >/dev/null 2>&1; echo $?
}

mkdir -p "$T/r/.workstyle"; git -C "$T/r" init -q .

expect "type-safety: off without type-safety.conf" 0 "$(edit type-safety-guard.sh a.ts 'const x: any = 1')"
: > "$T/r/.workstyle/type-safety.conf"
expect "type-safety: blocks ': any'" 2 "$(edit type-safety-guard.sh a.ts 'const x: any = 1')"
expect "type-safety: blocks 'as unknown as'" 2 "$(edit type-safety-guard.sh a.tsx 'y as unknown as Z')"
expect "type-safety: allows 'as any' in tests" 0 "$(edit type-safety-guard.sh a.spec.ts 'm as any')"
expect "type-safety: ignores non-TS files" 0 "$(edit type-safety-guard.sh a.py 'x: any = 1')"
expect "type-safety: allows real types" 0 "$(edit type-safety-guard.sh a.ts 'const x: number = 1')"

expect "protected: off without protected-files.conf" 0 "$(edit protected-file-guard.sh migrations/001.sql 'drop')"
printf 'migrations/\nliteral:store.ts:STORE_VERSION\n' > "$T/r/.workstyle/protected-files.conf"
expect "protected: blocks a listed path" 2 "$(edit protected-file-guard.sh migrations/001.sql 'drop')"
expect "protected: allows other paths" 0 "$(edit protected-file-guard.sh app/main.py 'x = 1')"
expect "protected: blocks touching a protected literal" 2 "$(edit protected-file-guard.sh store.ts 'STORE_VERSION = 3;' 'STORE_VERSION = 4;')"

echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
