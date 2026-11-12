#!/bin/bash
# clear-advisory-sentinels.sh - Reset per-session advisory guards on SessionStart.
#
# Sentinels live at $CLAUDE_PROJECT_DIR/tmp/.claude-advisory/<session_id>/<name>.
# They back the block_once / warn-once-per-session escape hatches. This hook
# fires on every SessionStart (startup, resume, /clear, /compact), clearing the
# current session's sentinels so advisories fire fresh after /clear.
#
# The snapshot state the recorders keep beside them stays: a compaction lands
# mid-turn, and losing it would hide the turn's edits from the Stop judge.
#
# Also performs lightweight GC: removes session dirs not modified for >7 days.

INPUT=$(cat 2>/dev/null || true)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)

ROOT="$CLAUDE_PROJECT_DIR/tmp/.claude-advisory"

if [ -n "$SESSION_ID" ] && [ -d "$ROOT/$SESSION_ID" ]; then
  find "$ROOT/$SESSION_ID" -mindepth 1 -maxdepth 1 \
    ! -name snapshots ! -name turn-snapshots ! -name turn-base ! -name turn-closed \
    ! -name stop-continuations ! -name judge-down ! -name judge.log \
    -exec rm -rf {} +
fi

# GC: prune session dirs older than 7 days
if [ -d "$ROOT" ]; then
  find "$ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
fi

exit 0
