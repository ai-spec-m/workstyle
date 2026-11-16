Run from `plugins/workstyle/` (needs jq, bubblewrap and socat for the sandbox):

    claude plugin eval . --trust-plugin --scaffold --ablation none --max-cost-usd 10 \
      --allow-tools Read Edit Write Agent Skill "Bash(git *)" "Bash(python3 *)" "Bash(bash *)" "Bash(head *)"

Add `evals/results/` to `.gitignore`.
