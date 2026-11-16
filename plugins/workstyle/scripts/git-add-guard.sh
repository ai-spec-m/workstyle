#!/usr/bin/env bash
# PreToolUse hook on Bash: blocks staging shortcuts that make it impossible to
# review what gets committed (`git add .`/`-A`/`-f`, `git commit -a`, piping
# paths into `git add` via xargs) and staging of configured forbidden paths.
#
# Pure bash tokenizer (no python shell-out), matching the plugin's all-bash
# convention. A command string cannot be matched by a single regex in either
# direction: substring-searching the whole string blocks inert text that merely
# contains "git push" (an echo, a grep pattern, a string literal); anchoring to
# the start of the command lets real invocations through when anything precedes
# git (`git -C /tmp add .`, `env X=1 git push`, `bash -c "git add ."`). So this
# tokenizes the command, finds `git` only in command position (start, after a
# separator, or after a wrapper), re-tokenizes `bash -c "<script>"` payloads,
# steps over git's own global flags (and their value tokens), and only scans
# the resulting positional args (never flag values like `-m "..."`) against
# FORBIDDEN_PATHS.
#
# FORBIDDEN_PATHS: reads a repo's own `.workstyle/forbidden-paths.conf` (one
# substring per line, '#' comments allowed) if present; ships with just `.env`
# as a safe universal default when absent.
#
# Also blocks destructive/irreversible commands an unattended run must never run:
#   - git: push with --force/-f/--mirror/--delete/--all or a `+ref`, push to the default
#     branch (origin/HEAD, main, master), reset --hard, clean -f, branch -D
#   - any command whose words start with a line of `.workstyle/forbidden-commands.conf`, or,
#     when that file is absent, the release/infra defaults in DEFAULT_FORBIDDEN_COMMANDS below.
#     Matched in command position only, so `echo terraform apply` is not blocked.
set -u
set -f  # the tokenizer's eval must never glob-expand model-supplied text

command -v jq >/dev/null || { echo "BLOCKED: workstyle guards need jq, which is not installed." >&2; exit 2; }
input=$(cat)
command=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$command" ] && exit 0

root=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || root="${CLAUDE_PROJECT_DIR:-$PWD}"
conf="$root/.workstyle/forbidden-paths.conf"
forbidden=()
if [ -f "$conf" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    forbidden+=("$line")
  done < "$conf"
else
  forbidden=(".env")
fi

DEFAULT_FORBIDDEN_COMMANDS=(
  "terraform apply" "terraform destroy" "tofu apply" "tofu destroy" "pulumi up" "pulumi destroy"
  "kubectl apply" "kubectl delete" "helm install" "helm upgrade" "helm uninstall"
  "docker push" "npm publish" "yarn publish" "pnpm publish" "cargo publish" "twine upload"
  "gem push" "gh pr merge" "gh release create" "gh repo delete"
)
cmd_conf="$root/.workstyle/forbidden-commands.conf"
forbidden_commands=()
if [ -f "$cmd_conf" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    forbidden_commands+=("$line")
  done < "$cmd_conf"
else
  forbidden_commands=("${DEFAULT_FORBIDDEN_COMMANDS[@]}")
fi

SEP=$'\x1esep'
WRAPPERS="sudo env nohup time xargs command exec nice"
SHELL_C="bash sh zsh dash"
GIT_GLOBAL_WITH_VALUE="-C -c --git-dir --work-tree --namespace --exec-path --config-env --super-prefix"
MESSAGE_FLAGS="-m --message -F --file -C --reuse-message"

in_list() { local needle="$1"; shift; for w in "$@"; do [ "$w" = "$needle" ] && return 0; done; return 1; }

# Tokenize: normalize $(...) / `...` / separators to explicit SEP markers, then
# let the shell's own word-splitting (via eval-free array build) do quoting.
tokenize() {
  local text="$1"
  text="${text//\$(/ }"
  text="${text//\`/ }"
  text="${text//)/ }"
  text="${text//;/ $SEP }"
  text="${text//&&/ $SEP }"
  text="${text//||/ $SEP }"
  text="${text//|/ $SEP }"
  text="${text//$'\n'/ $SEP }"
  local -a out
  eval "out=($text)" 2>/dev/null || out=($text)
  printf '%s\n' "${out[@]}"
}

basename_of() { local p="${1##*/}"; printf '%s' "$p"; }

# Expand `bash -c "<script>"` (and sh/zsh/dash) payloads into re-tokenized
# tokens wrapped in SEP markers, so a git call inside the quoted script is seen.
expand_shell_c() {
  local -a tokens=("$@")
  local -a out=()
  local i=0 n=${#tokens[@]}
  while [ $i -lt $n ]; do
    local tok="${tokens[$i]}"
    local bn; bn=$(basename_of "$tok")
    if in_list "$bn" $SHELL_C; then
      local j=$((i+1))
      local matched=0
      while [ $j -lt $n ]; do
        case "${tokens[$j]}" in
          -*)
            case "${tokens[$j]}" in *c*) matched=1 ;; esac
            j=$((j+1))
            if [ "$matched" = 1 ] && [ $j -lt $n ]; then
              out+=("$SEP")
              while IFS= read -r t; do out+=("$t"); done < <(tokenize "${tokens[$j]}")
              out+=("$SEP")
              j=$((j+1))
              break
            fi
            ;;
          *) break ;;
        esac
      done
      i=$j
      continue
    fi
    out+=("$tok")
    i=$((i+1))
  done
  printf '%s\n' "${out[@]}"
}

mapfile -t raw_tokens < <(tokenize "$command")
mapfile -t tokens < <(expand_shell_c "${raw_tokens[@]}")

n=${#tokens[@]}
expect_command=1
i=0
blocked_reason=""

block() { printf 'BLOCKED: %s\n' "$1" >&2; exit 2; }

is_force_flag() {
  local f="$1"
  case "$f" in
    -f|--force) return 0 ;;
    --*) return 1 ;;
    -*) case "${f#-}" in *f*) return 0 ;; esac; return 1 ;;
  esac
  return 1
}
is_all_flag() {
  local f="$1"
  case "$f" in
    -a|--all) return 0 ;;
    --*) return 1 ;;
    -*) case "${f#-}" in *[aA]*) return 0 ;; esac; return 1 ;;
  esac
  return 1
}

default_branch=$(git -C "$root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
default_branch=${default_branch#origin/}
is_protected_branch() {
  local b="${1#refs/heads/}"
  [ "$b" = main ] || [ "$b" = master ] || { [ -n "$default_branch" ] && [ "$b" = "$default_branch" ]; }
}

while [ $i -lt $n ]; do
  tok="${tokens[$i]}"

  if [ "$tok" = "$SEP" ]; then
    expect_command=1
    i=$((i+1))
    continue
  fi
  if [ "$expect_command" != 1 ]; then
    i=$((i+1))
    continue
  fi
  bn=$(basename_of "$tok")
  if in_list "$tok" $WRAPPERS || in_list "$bn" $SHELL_C; then
    i=$((i+1))
    continue
  fi
  case "$tok" in
    *=*) if [[ "$tok" != -* ]]; then i=$((i+1)); continue; fi ;;
  esac
  case "$tok" in
    -*) i=$((i+1)); continue ;;
  esac
  if [ "$bn" != "git" ]; then
    sub="$bn"; m=$((i+1))
    while [ $m -lt $n ] && [ "${tokens[$m]}" != "$SEP" ]; do sub="$sub ${tokens[$m]}"; m=$((m+1)); done
    for fc in "${forbidden_commands[@]}"; do
      case "$sub" in "$fc"|"$fc "*) block "\`$fc\` is a release/infrastructure command an unattended run must never execute (.workstyle/forbidden-commands.conf). Hand off to a human instead." ;; esac
    done
    expect_command=0
    i=$((i+1))
    continue
  fi

  # Found a git invocation. Skip global flags (and their value tokens) to find the subcommand.
  j=$((i+1))
  while [ $j -lt $n ]; do
    cur="${tokens[$j]}"
    if in_list "$cur" $GIT_GLOBAL_WITH_VALUE; then
      j=$((j+2))
      continue
    fi
    case "$cur" in
      -*) j=$((j+1)); continue ;;
    esac
    break
  done

  if [ $j -ge $n ] || [ "${tokens[$j]}" = "$SEP" ]; then
    expect_command=0
    i=$j
    continue
  fi

  verb="${tokens[$j]}"
  k=$((j+1))
  args=()
  while [ $k -lt $n ] && [ "${tokens[$k]}" != "$SEP" ]; do
    args+=("${tokens[$k]}")
    k=$((k+1))
  done

  case "$verb" in
    push)
      push_pos=()
      for a in "${args[@]}"; do
        case "$a" in
          -f|--force|--force-with-lease*|--force-if-includes|--mirror|--delete|-d|--all|--prune)
            block "\`git push $a\` can overwrite or delete remote history. Push only new commits to the run's own branch." ;;
          -*) case "$a" in --*) ;; -*f*) block "\`git push $a\` force-pushes. Push only new commits to the run's own branch." ;; esac ;;
          +*) block "\`git push $a\` is a force-push refspec." ;;
          *) push_pos+=("$a") ;;
        esac
      done
      if [ ${#push_pos[@]} -le 1 ]; then
        cur=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)
        is_protected_branch "$cur" && block "\`git push\` from \`$cur\` would push the default branch. Work on a feature branch."
      fi
      for r in "${push_pos[@]:1}"; do
        dst="${r##*:}"; [ "$dst" = HEAD ] && dst=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null)
        is_protected_branch "$dst" && block "\`git push ... $r\` targets the default branch \`$dst\`. Push to a feature branch; a human merges."
      done ;;
    reset) for a in "${args[@]}"; do [ "$a" = --hard ] && block "\`git reset --hard\` discards work. Use \`git stash\` or a new commit instead."; done ;;
    clean) for a in "${args[@]}"; do is_force_flag "$a" && block "\`git clean $a\` deletes untracked files permanently."; done ;;
    branch) for a in "${args[@]}"; do case "$a" in -D|--delete=force) block "\`git branch -D\` deletes an unmerged branch." ;; esac; done ;;
  esac

  if [ "$verb" = "commit" ]; then
    for a in "${args[@]}"; do
      case "$a" in
        -*) is_all_flag "$a" && block "\`git commit -a\`/\`-am\` stages all modified tracked files, bypassing per-path review. Stage each file explicitly, then \`git commit -m\`." ;;
      esac
    done
  fi

  if [ "$verb" = "add" ]; then
    # positional args: drop flags and their values (message/value-taking flags)
    positional=()
    skip_next=0
    for a in "${args[@]}"; do
      if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
      case "$a" in
        -*)
          if in_list "$a" $MESSAGE_FLAGS; then skip_next=1; fi
          continue
          ;;
      esac
      positional+=("$a")
    done
    for a in "${args[@]}"; do
      case "$a" in
        -*) is_all_flag "$a" && block "\`git add .\`/\`-A\`/\`--all\` is disallowed. Stage each file individually." ;;
      esac
    done
    for p in "${positional[@]}"; do
      [ "$p" = "." ] && block "\`git add .\` is disallowed. Stage each file individually, e.g. \`git add src/lib/foo.ts\`."
    done
    for a in "${args[@]}"; do
      case "$a" in
        -*) is_force_flag "$a" && block "\`git add -f\` bypasses .gitignore and is disallowed." ;;
      esac
    done
    for p in "${positional[@]}"; do
      for f in "${forbidden[@]}"; do
        case "$p" in
          *"$f"*) block "staging '$p' references '$f', which is forbidden to stage/push." ;;
        esac
      done
    done
  fi

  if [ "$verb" = "commit" ]; then
    positional=()
    skip_next=0
    for a in "${args[@]}"; do
      if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
      case "$a" in
        -*)
          if in_list "$a" $MESSAGE_FLAGS; then skip_next=1; fi
          continue
          ;;
      esac
      positional+=("$a")
    done
    for p in "${positional[@]}"; do
      for f in "${forbidden[@]}"; do
        case "$p" in
          *"$f"*) block "committing '$p' references '$f', which is forbidden to stage/push." ;;
        esac
      done
    done
  fi

  expect_command=0
  i=$k
done

# xargs piping paths into git add/commit hides what gets staged.
if printf '%s' "$command" | grep -qE '\bxargs\b[^|;&]*\bgit\b[^|;&]*\b(add|commit)\b'; then
  block "piping paths into \`git add\`/\`git commit\` via xargs hides what gets staged. List each file explicitly instead."
fi

exit 0
