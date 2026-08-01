#!/bin/bash
# exhale-reminder.sh - After a successful feature/fix commit, remind to run the exhale pass.
#
# Fires on PostToolUse:Bash. Stays silent unless the command actually committed
# something, and stays silent when the commit was itself the exhale.

set -uo pipefail

INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

printf '%s' "$COMMAND" | grep -qE '(^|(&&|\|\||;|\|)[[:space:]]*)git[[:space:]]+commit([[:space:]]|$)' || exit 0

# Already an exhale — don't ask for an exhale on an exhale.
printf '%s' "$COMMAND" | grep -qiE '(refactor|simplify|exhale)' && exit 0

# A commit rejected by a pre-commit hook must not trigger the reminder. git prints
# "[branch sha] subject" on success; if we captured output and it has no such line,
# nothing was committed. If output is unavailable, fall through and remind.
OUTPUT=$(printf '%s' "$INPUT" | jq -r '[.tool_response.stdout?, .tool_response.stderr?, (.tool_response | strings)] | map(select(. != null)) | join("\n")' 2>/dev/null)
if [ -n "${OUTPUT:-}" ]; then
  printf '%s' "$OUTPUT" | grep -qE '^\[[^]]+ [0-9a-f]{7,}\]' || exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -x "$PROJECT_DIR/bin/diff-quality" ]; then
  TOOLING="Run \`bin/diff-quality --last-commit --no-browser\` to check for rubycritic regressions and run related specs against the commit you just made."
else
  TOOLING="This project has no \`bin/diff-quality\` yet — run \`/exhale-init\` to install it if the project is Ruby."
fi

jq -n --arg tooling "$TOOLING" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("Exhale. You just committed a feature/fix. Review the changes for simplicity, duplication, and design quality against the four rules of simple design. " + $tooling + " For a deeper design review (spawns subagents, higher token cost), the user can run /simplify-with-analysis explicitly. Do not skip this step.")
  }
}'

exit 0
