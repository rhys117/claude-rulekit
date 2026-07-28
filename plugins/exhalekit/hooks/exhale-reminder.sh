#!/bin/bash
# exhale-reminder.sh - Remind to review for simplicity after committing

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

echo "$COMMAND" | grep -qE '(^|(&&|\|\||;|\|)[[:space:]]*)git[[:space:]]+commit([[:space:]]|$)' || exit 0

# Extract the commit message to check if this was already a refactor/simplify pass
if echo "$COMMAND" | grep -qiE "(refactor|simplify|exhale)"; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

if [ -x "$PROJECT_DIR/bin/diff-quality" ]; then
  EVIDENCE="Run \`bin/diff-quality --no-browser\` to check for rubycritic regressions and run related specs against the base branch. For a deeper design review (higher token cost), the user can run /simplify-with-analysis explicitly."
else
  EVIDENCE="This project has no \`bin/diff-quality\` yet — the user can run /exhale-init to install it, which makes the next exhale evidence-backed rather than from memory."
fi

jq -n --arg evidence "$EVIDENCE" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("Exhale. You just committed a feature/fix. Review the changes for simplicity, duplication, and design quality. " + $evidence + " Do not skip this step.")
  }
}'
exit 0
