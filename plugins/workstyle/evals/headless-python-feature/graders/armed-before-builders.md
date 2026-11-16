---
type: tool_order
before: { tool: Bash, input_match: 'gates\.sh[^"]*--arm' }
after: { tool: Agent, input_match: '"subagent_type"\s*:\s*"[^"]*builder"' }
---
