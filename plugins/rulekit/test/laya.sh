#!/usr/bin/env bash
# laya.sh — Exercise `laya:` rules against a fake Laya server.
#
# Covers: fires above threshold, stays silent below it, `pattern` prefilters
# before any request, a detector file takes precedence, and an unreachable
# server fails open and is only tried once per session.
#
# Run from anywhere:
#   test/laya.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$PLUGIN_ROOT/bin/write-rules-check.rb"

command -v ruby >/dev/null || { echo "ruby not found on PATH"; exit 1; }

SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/rulekit-laya-test.XXXXXX")"
RULES="$SMOKE/rules"
LOG="$SMOKE/requests.log"
PORT=$((20000 + RANDOM % 20000))
mkdir -p "$RULES/detectors"
: > "$LOG"

export CLAUDE_PROJECT_DIR="$SMOKE"
export CLAUDE_RULES_DIR="$RULES"
export LAYA_URL="http://127.0.0.1:$PORT"

cat > "$RULES/write.yml" <<'YAML'
semantic_backfill:
  type: warn
  files: ["db/migrate/**/*"]
  laya:
    question: "Does this migration backfill data?"
    threshold: 0.8
  context: Split the backfill into its own migration.

prefiltered:
  type: warn
  files: ["app/**/*"]
  pattern: 'never_matches_this'
  laya:
    question: "Anything?"
  context: should never fire

detector_wins:
  type: warn
  files: ["lib/**/*"]
  laya:
    question: "Anything?"
  context: detector wins
YAML

cat > "$RULES/detectors/detector_wins.rb" <<'RUBY'
module Detectors
  module DetectorWins
    def self.call(**) = true
  end
end
RUBY

ruby "$PLUGIN_ROOT/test/fake_laya_server.rb" "$PORT" "$LOG" &
SERVER_PID=$!

cleanup() { kill "$SERVER_PID" 2>/dev/null; rm -rf "$SMOKE"; }
trap cleanup EXIT

for _ in $(seq 50); do curl -sf "$LAYA_URL/health" >/dev/null && break; sleep 0.1; done
: > "$LOG"

PASS=0
FAIL=0

run() { echo "$1" | "$W"; }
edit() { echo '{"tool_name":"Write","session_id":"'"$1"'","tool_input":{"file_path":"'"$SMOKE/$2"'","content":"'"$3"'"}}'; }
requests() { wc -l < "$LOG" | tr -d ' '; }

assert_contains() {
  if [[ "$2" == *"$3"* ]]; then echo "  PASS  $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1"; echo "         want substring: $3"; echo "         got: $2"; FAIL=$((FAIL+1)); fi
}
assert_silent() {
  if [[ -z "$2" ]]; then echo "  PASS  $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1 (expected no stdout)"; echo "         got: $2"; FAIL=$((FAIL+1)); fi
}
assert_eq() {
  if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1 (want $3, got $2)"; FAIL=$((FAIL+1)); fi
}

echo "==> laya: server up"

OUT=$(run "$(edit s1 db/migrate/001_x.rb 'User.find_each { backfill slug }')")
assert_contains "above threshold fires" "$OUT" "semantic_backfill"

OUT=$(run "$(edit s1 db/migrate/002_x.rb 'add_index :users, :email')")
assert_silent "below threshold stays silent" "$OUT"
assert_contains "request carries the file path" "$(tail -1 "$LOG")" "db/migrate/002_x.rb"

BEFORE=$(requests)
OUT=$(run "$(edit s1 app/models/x.rb 'backfill')")
assert_silent "pattern miss stays silent" "$OUT"
assert_eq "pattern miss makes no request" "$(requests)" "$BEFORE"

BEFORE=$(requests)
OUT=$(run "$(edit s1 lib/x.rb 'anything')")
assert_contains "detector file takes precedence" "$OUT" "detector_wins"
assert_eq "detector path makes no request" "$(requests)" "$BEFORE"

echo "==> laya: server down"

kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null

OUT=$(run "$(edit s2 db/migrate/003_x.rb 'backfill')"); EC=$?
assert_silent "unreachable server fails open" "$OUT"
assert_eq "unreachable server exit" "$EC" "0"
[[ -f "$SMOKE/tmp/.claude-advisory/s2/laya-down" ]] && R=yes || R=no
assert_eq "down marker written" "$R" "yes"

START=$(ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)')
OUT=$(run "$(edit s2 db/migrate/004_x.rb 'backfill')")
END=$(ruby -e 'puts Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)')
assert_silent "second call while down stays silent" "$OUT"
[[ $((END - START)) -lt 1000 ]] && R=fast || R="slow ($((END - START))ms)"
assert_eq "second call skips the connect" "$R" "fast"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
