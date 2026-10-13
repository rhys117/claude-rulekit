#!/usr/bin/env bash
# judge.sh — Exercise `judge:` rules and the Stop hook against a fake judge server.
#
# Covers: the per-edit hooks leave `judge:` rules alone, Stop judges what the
# turn changed in one request per file, thresholds and `pattern` prefilter,
# block vs warn output, an unchanged tree is not asked about twice, edits made
# between turns are not judged, the per-turn continuation cap, the env names
# and their TypeSafe fallbacks, and failing open when unconfigured or
# unreachable.
#
# Run from anywhere:
#   test/judge.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$PLUGIN_ROOT/bin/write-rules-check.rb"
S="$PLUGIN_ROOT/bin/post-write-sweep.rb"
STOP="$PLUGIN_ROOT/bin/stop-rules-check.rb"

command -v ruby >/dev/null || { echo "ruby not found on PATH"; exit 1; }
command -v git >/dev/null || { echo "git not found on PATH"; exit 1; }

SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/rulekit-judge-test.XXXXXX")"
RULES="$SMOKE/.claude/rules"
LOG="$(mktemp "${TMPDIR:-/tmp}/rulekit-judge-requests.XXXXXX")"
PORT=$((20000 + RANDOM % 20000))
mkdir -p "$RULES/detectors" "$SMOKE/db/migrate" "$SMOKE/app" "$SMOKE/lib"

export CLAUDE_PROJECT_DIR="$SMOKE"
URL="http://127.0.0.1:$PORT/v1"
export RULEKIT_JUDGE_URL="$URL"
export RULEKIT_JUDGE_API_KEY="test-key"
unset CLAUDE_RULES_DIR RULEKIT_JUDGE_MODEL RULEKIT_JUDGE_TIMEOUT TYPESAFE_AI_API_KEY TYPESAFE_AI_BASE_URL

cat > "$RULES/write.yml" <<'YAML'
semantic_backfill:
  type: block
  files: ["db/migrate/**/*"]
  judge:
    question: "Does this migration backfill data?"
    threshold: 0.8
  context: Split the backfill into its own migration.

strict_backfill:
  type: block
  files: ["db/migrate/**/*"]
  judge:
    question: "Is this certainly a backfill?"
    threshold: 0.95
  context: should never fire

advisory:
  type: warn
  files: ["app/**/*"]
  judge:
    question: "Does this backfill?"
  context: Keep backfills out of app code.

prefiltered:
  type: warn
  files: ["app/**/*"]
  pattern: 'never_matches_this'
  judge:
    question: "Anything?"
  context: should never fire

detector_wins:
  type: warn
  files: ["lib/**/*"]
  judge:
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

git -C "$SMOKE" init -q
git -C "$SMOKE" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

ruby "$PLUGIN_ROOT/test/fake_judge_server.rb" "$PORT" "$LOG" &
SERVER_PID=$!

cleanup() { kill "$SERVER_PID" 2>/dev/null; rm -rf "$SMOKE" "$LOG"; }
trap cleanup EXIT

for _ in $(seq 50); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.1; done
: > "$LOG"

PASS=0
FAIL=0

requests() { wc -l < "$LOG" | tr -d ' '; }
record() { echo '{"session_id":"'"$1"'"}' | "$STOP" --record; }
stop() { echo '{"session_id":"'"$1"'","hook_event_name":"Stop"}' | "$STOP"; }
# Snapshots go by mtime, so a rewrite inside the same second needs a nudge.
write() { mkdir -p "$(dirname "$SMOKE/$1")"; sleep 1.1; printf '%s\n' "$2" >> "$SMOKE/$1"; }

assert_contains() {
  if [[ "$2" == *"$3"* ]]; then echo "  PASS  $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1"; echo "         want substring: $3"; echo "         got: $2"; FAIL=$((FAIL+1)); fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then echo "  PASS  $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1"; echo "         unwanted substring: $3"; echo "         got: $2"; FAIL=$((FAIL+1)); fi
}
assert_silent() {
  if [[ -z "$2" ]]; then echo "  PASS  $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1 (expected no stdout)"; echo "         got: $2"; FAIL=$((FAIL+1)); fi
}
assert_eq() {
  if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; PASS=$((PASS+1))
  else echo "  FAIL  $1 (want $3, got $2)"; FAIL=$((FAIL+1)); fi
}

echo "==> judge: per-edit hooks defer to Stop"

OUT=$(echo '{"tool_name":"Write","session_id":"s1","tool_input":{"file_path":"'"$SMOKE"'/db/migrate/001_x.rb","content":"User.find_each { backfill }"}}' | "$W"); EC=$?
assert_silent "pre-write hook skips judge rules" "$OUT"
assert_eq "pre-write hook exit" "$EC" "0"

OUT=$(echo '{"tool_name":"Write","session_id":"s1","tool_input":{"file_path":"'"$SMOKE"'/lib/x.rb","content":"anything"}}' | "$W")
assert_contains "detector file still decides pre-write" "$OUT" "detector_wins"

echo '{"session_id":"s1"}' | "$S" --bootstrap
write db/migrate/001_x.rb 'User.find_each { backfill slug }'
OUT=$(echo '{"tool_name":"Bash","session_id":"s1","tool_input":{"command":"true"}}' | "$S")
assert_silent "post-write sweep skips judge rules" "$OUT"
assert_eq "per-edit hooks make no request" "$(requests)" "0"

echo "==> judge: Stop judges the turn"

OUT=$(stop s1)
assert_silent "first pass of a session only records" "$OUT"
assert_eq "first pass makes no request" "$(requests)" "0"

OUT=$(record s2)
assert_silent "record pass is silent" "$OUT"

write db/migrate/002_x.rb 'User.find_each { backfill slug }'
write db/migrate/003_x.rb 'add_index :users, :email'
write lib/y.rb 'backfill'
OUT=$(stop s2); EC=$?
assert_contains "block rule holds the turn open" "$OUT" '"decision":"block"'
assert_contains "finding names the rule" "$OUT" "[semantic_backfill]"
assert_contains "finding names the file" "$OUT" "db/migrate/002_x.rb: Split the backfill"
assert_not_contains "below its threshold a rule stays silent" "$OUT" "strict_backfill"
assert_not_contains "file below threshold is not named" "$OUT" "003_x.rb"
assert_not_contains "detector-backed rule is not asked about" "$OUT" "detector_wins"
assert_eq "stop exit" "$EC" "0"
assert_eq "one request per matching file" "$(requests)" "2"
assert_contains "request carries every matching rule" "$(grep 002_x "$LOG")" '"strict_backfill":{"type":"noul"'
assert_contains "request carries the api key" "$(grep 002_x "$LOG")" "Bearer test-key"
assert_contains "request names the default model" "$(grep 002_x "$LOG")" '"model":"jev-latest"'
assert_not_contains "files changed before the turn are not judged" "$(cat "$LOG")" "001_x"

BEFORE=$(requests)
OUT=$(stop s2)
assert_silent "unchanged tree is not judged twice" "$OUT"
assert_eq "unchanged tree makes no request" "$(requests)" "$BEFORE"

echo "==> judge: warn, prefilter, edits between turns"

write db/migrate/004_user_edit.rb 'backfill by hand'
record s2
BEFORE=$(requests)
write app/models/x.rb 'def backfill; end'
OUT=$(stop s2)
assert_contains "warn rule comes back as feedback" "$OUT" '"additionalContext":"[advisory] app/models/x.rb'
assert_contains "feedback is a Stop output" "$OUT" '"hookEventName":"Stop"'
assert_not_contains "warn rule does not block" "$OUT" '"decision"'
assert_not_contains "pattern miss is not asked" "$(tail -1 "$LOG")" "prefiltered"
assert_eq "edits made between turns are not judged" "$(requests)" "$((BEFORE + 1))"

echo "==> judge: continuation cap"

record s3
write db/migrate/010_x.rb 'backfill one'
OUT=$(stop s3)
assert_contains "first finding blocks" "$OUT" '"decision":"block"'
write db/migrate/010_x.rb 'backfill two'
OUT=$(stop s3)
assert_contains "the repair is re-checked and can block" "$OUT" '"decision":"block"'
write db/migrate/010_x.rb 'backfill three'
OUT=$(stop s3)
assert_contains "past the cap the user is told instead" "$OUT" '"systemMessage"'
assert_not_contains "past the cap the turn may end" "$OUT" '"decision"'
record s3
write db/migrate/010_x.rb 'backfill four'
OUT=$(stop s3)
assert_contains "a fresh prompt starts the count again" "$OUT" '"decision":"block"'

echo "==> judge: configuration"

record s4
BEFORE=$(requests)
write db/migrate/020_x.rb 'backfill'
OUT=$(RULEKIT_JUDGE_URL= RULEKIT_JUDGE_API_KEY= stop s4); EC=$?
assert_silent "unconfigured stays silent" "$OUT"
assert_eq "unconfigured exit" "$EC" "0"
assert_eq "unconfigured makes no request" "$(requests)" "$BEFORE"

write db/migrate/021_x.rb 'backfill'
OUT=$(RULEKIT_JUDGE_API_KEY= RULEKIT_JUDGE_MODEL=english stop s4)
assert_contains "a url alone is enough for a keyless backend" "$OUT" "021_x.rb"
assert_not_contains "keyless request sends no bearer" "$(tail -1 "$LOG")" "Bearer"
assert_contains "model is configurable" "$(tail -1 "$LOG")" '"model":"english"'

record s4
write db/migrate/022_x.rb 'backfill'
OUT=$(RULEKIT_JUDGE_URL= RULEKIT_JUDGE_API_KEY= TYPESAFE_AI_BASE_URL="$URL" TYPESAFE_AI_API_KEY=ts-key stop s4)
assert_contains "typesafe env names still work" "$OUT" "022_x.rb"
assert_contains "typesafe key is sent" "$(tail -1 "$LOG")" "Bearer ts-key"

echo "==> judge: fails open"

kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null

record s5
write db/migrate/030_x.rb 'backfill'
write db/migrate/031_x.rb 'backfill'
OUT=$(stop s5); EC=$?
assert_silent "unreachable api fails open" "$OUT"
assert_eq "unreachable api exit" "$EC" "0"
[[ -f "$SMOKE/tmp/.claude-advisory/s5/judge-down" ]] && R=yes || R=no
assert_eq "down marker written" "$R" "yes"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
