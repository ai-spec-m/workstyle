#!/usr/bin/env bash
# PreToolUse hook on Edit|Write: hard-blocks `any` and `as unknown as` in new TS/TSX
# code, per-edit, before the file ever saves — not just caught later when gates.sh
# runs typecheck at a builder's stop. Mirrors the old .claude.old setup's
# type-safety-guard.py, kept in bash to match gates.sh's own runtime (no Python
# dependency assumed).
#
# Only inspects the NEW text being written: `new_string` for Edit, `content` for
# Write. Only `.ts`/`.tsx` files. `as unknown as` is blocked unconditionally outside
# test files. `any` (`: any`, `<any>`, `, any`, `as any`) is blocked everywhere
# except test files, where only `as any` (mock typing) is allowed — `: any`/`<any>`
# stay blocked even in tests.
#
# Opt-in per repo: a no-op unless `.workstyle/type-safety.conf` exists (init writes it only
# for TypeScript repos). The plugin itself assumes no language.
set -u

input=$(cat)
root=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -f "$root/.workstyle/type-safety.conf" ] || exit 0
command -v jq >/dev/null || { echo "BLOCKED: workstyle guards need jq, which is not installed." >&2; exit 2; }

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

case "$file_path" in
  *.ts|*.tsx) ;;
  *) exit 0 ;;
esac

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
case "$tool_name" in
  Edit) new_text=$(printf '%s' "$input" | jq -r '.tool_input.new_string // empty' 2>/dev/null) ;;
  Write) new_text=$(printf '%s' "$input" | jq -r '.tool_input.content // empty' 2>/dev/null) ;;
  *) exit 0 ;;
esac
[ -z "$new_text" ] && exit 0

is_test=0
case "$file_path" in
  *.spec.ts|*.spec.tsx|*.test.ts|*.test.tsx) is_test=1 ;;
esac

violations=""

if printf '%s' "$new_text" | grep -qE 'as unknown as'; then
  if [ "$is_test" -eq 0 ]; then
    violations="${violations}\`as unknown as\` is not allowed in production code — use generics, narrowing, or a schema's inferred type instead. (Sanctioned in *.spec.*/*.test.* files for shaping mocks.)\n"
  fi
fi

# `any` outside tests: any spelling. In tests: only bare `: any`/`<any>` stay blocked;
# `as any` is the sanctioned mock-typing idiom there.
if [ "$is_test" -eq 0 ]; then
  if printf '%s' "$new_text" | grep -qE '(:\s*any\b|<any>|,\s*any\b|\bas\s+any\b)'; then
    violations="${violations}\`any\` is never allowed — add a real type, narrow it, or use \`unknown\` with a type guard.\n"
  fi
else
  if printf '%s' "$new_text" | grep -qE '(:\s*any\b|<any>)'; then
    violations="${violations}\`: any\`/\`<any>\` are not allowed even in test files — \`as any\` is the sanctioned idiom for mock typing (e.g. \`useAppStore as unknown as jest.Mock\`), a bare \`any\` type is not.\n"
  fi
fi

if [ -n "$violations" ]; then
  printf 'workstyle type-safety-guard BLOCKED this edit to %s:\n%b' "$file_path" "$violations" >&2
  exit 2
fi

exit 0
