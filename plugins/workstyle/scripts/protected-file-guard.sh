#!/usr/bin/env bash
# PreToolUse hook on Edit|Write: hard-blocks edits to protected files/literals.
#
# Generalized from the old per-repo protected-file-guard.py: no repo-specific
# defaults ship with the plugin. A repo opts in by writing
# `.workstyle/protected-files.conf`: one entry per line, '#' comments allowed.
#   - a bare line is a substring match against file_path — block any edit
#   - `literal:<FILE>:<NAME>` marks a numeric literal `<NAME> = <n>;` in <FILE>
#     that must never be decremented (bumping up, or leaving it alone, is fine)
# Ships empty (no-op) when the conf file is absent.
set -u

command -v jq >/dev/null || { echo "BLOCKED: workstyle guards need jq, which is not installed." >&2; exit 2; }
input=$(cat)
file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$file_path" ] && exit 0

root=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || root="${CLAUDE_PROJECT_DIR:-$PWD}"
conf="$root/.workstyle/protected-files.conf"
[ -f "$conf" ] || exit 0

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
old_text=$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
new_text=$(printf '%s' "$input" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null)

while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in
    literal:*)
      spec="${line#literal:}"
      target_file="${spec%%:*}"
      name="${spec#*:}"
      case "$file_path" in
        *"$target_file")
          case "$new_text$old_text" in
            *"$name"*) touches=1 ;;
            *) touches=0 ;;
          esac
          if [ "$touches" = 0 ] && [ -n "$old_text" ] && [ -f "$file_path" ]; then
            literal=$(grep -oE "${name}[[:space:]]*=[[:space:]]*[0-9]+" "$file_path" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
            if [ -n "$literal" ]; then
              old_numbers=$(printf '%s' "$old_text" | grep -oE '\b[0-9]+\b')
              new_numbers=$(printf '%s' "$new_text" | grep -oE '\b[0-9]+\b')
              if printf '%s\n' "$old_numbers" | grep -qxF "$literal" && [ "$old_numbers" != "$new_numbers" ]; then
                touches=1
              fi
            fi
          fi
          if [ "$touches" = 1 ]; then
            printf 'BLOCKED: edit touches protected literal %s in %s (.workstyle/protected-files.conf).\n' "$name" "$target_file" >&2
            exit 2
          fi
          ;;
      esac
      ;;
    *)
      case "$file_path" in
        *"$line"*)
          printf "BLOCKED: '%s' is protected by .workstyle/protected-files.conf — never edit it without explicit user instruction this turn.\n" "$line" >&2
          exit 2
          ;;
      esac
      ;;
  esac
done < "$conf"

exit 0
