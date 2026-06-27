---
description: Smoke-test this project's rulekit rules against synthetic tool calls
---

Smoke-test the rulekit rules installed in this project (`.claude/rules/`).

1. Confirm `.claude/rules/write.yml` and/or `.claude/rules/read.yml` exist. If
   neither does, tell the user to run `/rules-init <preset>` first and stop.
2. Validate the YAML parses and that every rule has a recognised `type`
   (`block`, `block_once`, `warn`), at least one `files` glob (write rules) or a
   valid `tools` list / default (read rules), and a non-empty `context`.
3. For each rule, synthesise one PreToolUse payload that SHOULD trigger it and,
   where practical, one that should NOT, then pipe each through the matching hook
   and check the result:
   - Write rules → `echo '<payload>' | "${CLAUDE_PLUGIN_ROOT}/bin/write-rules-check.rb"`
   - Read rules  → `echo '<payload>' | "${CLAUDE_PLUGIN_ROOT}/bin/read-rules-check.rb"`
   A payload is JSON like
   `{"tool_name":"Edit","session_id":"rules-test","tool_input":{"file_path":"app/models/x.rb","new_string":"..."}}`.
   `block`/`block_once` rules should exit 2 and emit `permissionDecision`; `warn`
   rules should exit 0 and emit `additionalContext`.
4. Report a pass/fail table per rule. Note any rule whose detector errored or
   whose pattern never matched its own intended trigger.

Set `CLAUDE_PROJECT_DIR` to the project root for the hook invocations. Clean up
any sentinels written under `tmp/.claude-advisory/rules-test*` when done.
