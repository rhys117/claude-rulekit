---
description: Smoke-test this project's rulekit rules against synthetic tool calls
---

Smoke-test the rulekit rules installed in this project (`.claude/rules/`).

1. Confirm at least one of `.claude/rules/write.yml`, `read.yml`,
   `write_rubric.yml` or `read_rubric.yml` exists. If none does, tell the user
   to run `/rules-init <preset>` or `/rules-compile` first and stop. Test the
   rules from all of them; the `_rubric` key in a rubric file is metadata, not
   a rule. If a rubric file exists, also run
   `ruby "${CLAUDE_PLUGIN_ROOT}/bin/rules-rubric.rb" validate` and report its
   output.
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
   For a read rule with a `pattern`, the payload's `command` (Bash), `pattern`
   (Grep/Glob) or `file_path` (Read) is what has to match it.
   `block`/`block_once` rules should exit 2 and emit `permissionDecision`; `warn`
   rules should exit 0 and emit `additionalContext`.
   Rules with a `judge:` block (and no detector file) never fire from these two
   hooks: they are judged on Stop by `bin/stop-rules-check.rb`, which may be a
   paid call to a hosted model. Do not send them anything; check the block has
   a `question`, report whether a judge is configured (`RULEKIT_JUDGE_API_KEY`,
   `RULEKIT_JUDGE_URL` or their `TYPESAFE_AI_*` fallbacks), and mark them
   SKIPPED.
4. Report a pass/fail table per rule. Note any rule whose detector errored or
   whose pattern never matched its own intended trigger.

Set `CLAUDE_PROJECT_DIR` to the project root for the hook invocations. Clean up
any sentinels written under `tmp/.claude-advisory/rules-test*` when done.
