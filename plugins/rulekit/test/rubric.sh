#!/usr/bin/env bash
# rubric.sh — Exercise the generated rubric files and bin/rules-rubric.rb.
#
# Covers: write_rubric.yml and read_rubric.yml are loaded by all four hooks
# beside the hand-written files, a hand-written rule wins a name clash, the
# `_rubric` metadata is never treated as a rule, read rules honour `pattern`,
# `exclude` carves a path out of a rule on both sides,
# `sources` finds instruction files and reports staleness, and `validate`
# accepts a good rubric and names what is wrong with a bad one.
#
# Run from anywhere:
#   test/rubric.sh

set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$PLUGIN_ROOT/bin/write-rules-check.rb"
R="$PLUGIN_ROOT/bin/read-rules-check.rb"
S="$PLUGIN_ROOT/bin/post-write-sweep.rb"
STOP="$PLUGIN_ROOT/bin/stop-rules-check.rb"
RUBRIC="$PLUGIN_ROOT/bin/rules-rubric.rb"

command -v ruby >/dev/null || { echo "ruby not found on PATH"; exit 1; }
command -v git >/dev/null || { echo "git not found on PATH"; exit 1; }

SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/rulekit-rubric-test.XXXXXX")"
RULES="$SMOKE/.claude/rules"
LOG="$(mktemp "${TMPDIR:-/tmp}/rulekit-rubric-requests.XXXXXX")"
PORT=$((20000 + RANDOM % 20000))
mkdir -p "$RULES/detectors" "$SMOKE/app/models" "$SMOKE/apps/web" "$SMOKE/node_modules/pkg"

export CLAUDE_PROJECT_DIR="$SMOKE"
export RULEKIT_JUDGE_URL="http://127.0.0.1:$PORT/v1"
unset CLAUDE_RULES_DIR RULEKIT_JUDGE_API_KEY RULEKIT_JUDGE_MODEL TYPESAFE_AI_API_KEY TYPESAFE_AI_BASE_URL

printf '%s\n' '# Project' '' 'We do not allow default scopes.' 'Always use pnpm.' > "$SMOKE/CLAUDE.md"
printf '%s\n' 'Never show a user a raw error.' > "$SMOKE/apps/web/AGENTS.md"
printf '%s\n' 'Open a pull request.' > "$SMOKE/CONTRIBUTING.md"
printf '%s\n' 'not ours' > "$SMOKE/node_modules/pkg/CLAUDE.md"

sha() { ruby -rdigest -e 'print Digest::SHA256.file(ARGV[0]).hexdigest' "$SMOKE/$1"; }

write_rubrics() {
cat > "$RULES/write_rubric.yml" <<YAML
_rubric:
  compiled_at: "2026-10-13"
  sources:
    - { path: CLAUDE.md, sha256: "$(sha CLAUDE.md)" }
    - { path: apps/web/AGENTS.md, sha256: "$(sha apps/web/AGENTS.md)" }
  skipped:
    - { text: "Ask when unsure.", source: "CLAUDE.md:9", reason: "about the conversation" }

no_default_scope:
  type: block
  files: ["app/models/**/*.rb"]
  exclude: ["app/models/legacy/**/*"]
  pattern: '(?<!\w)default_scope(?!\w)'
  context: Default scopes are not allowed.
  text: "We do not allow default scopes."
  source: "CLAUDE.md:3"

semantic_backfill:
  type: warn
  files: ["db/migrate/**/*"]
  judge:
    question: "Does this migration backfill data?"
  context: Split the backfill out.
  text: "Never show a user a raw error."
  source: "apps/web/AGENTS.md:1"

shadowed:
  type: block
  files: ["lib/**/*"]
  context: rubric version
  text: "x"
  source: "CLAUDE.md:3"
YAML
cat > "$RULES/read_rubric.yml" <<YAML
_rubric:
  compiled_at: "2026-10-13"
  sources:
    - { path: CLAUDE.md, sha256: "$(sha CLAUDE.md)" }
    - { path: apps/web/AGENTS.md, sha256: "$(sha apps/web/AGENTS.md)" }

use_pnpm:
  type: block
  tools: [Bash]
  pattern: '(?<![\w-])npm\s+install\b'
  context: This repo uses pnpm.
  text: "Always use pnpm."
  source: "CLAUDE.md:4"
YAML
}

git -C "$SMOKE" init -q
git -C "$SMOKE" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

ruby "$PLUGIN_ROOT/test/fake_judge_server.rb" "$PORT" "$LOG" &
SERVER_PID=$!
cleanup() { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; rm -rf "$SMOKE" "$LOG"; }
trap cleanup EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.1; done

PASS=0
FAIL=0

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

write_event() { echo '{"tool_name":"Write","session_id":"r1","tool_input":{"file_path":"'"$SMOKE/$1"'","content":"'"$2"'"}}'; }
bash_event() { echo '{"tool_name":"Bash","session_id":"r1","tool_input":{"command":"'"$1"'"}}'; }

echo "==> rubric: sources before compiling"

OUT=$(cd "$SMOKE" && CLAUDE_PROJECT_DIR= "$RUBRIC" sources)
assert_contains "root file found, from the working directory" "$OUT" "CLAUDE.md  scope **/*  sha256 $(sha CLAUDE.md)  [new]"
assert_contains "nested file scoped to its directory" "$OUT" "apps/web/AGENTS.md  scope apps/web/**/*"
assert_contains "contributing is optional" "$OUT" "CONTRIBUTING.md  scope **/*  sha256 $(sha CONTRIBUTING.md)  [new]  (optional"
assert_not_contains "vendored files are not sources" "$OUT" "node_modules"
assert_contains "status before compiling" "$OUT" "status: not compiled yet"

OUT=$("$RUBRIC" validate); EC=$?
assert_contains "validate with no rubric says so" "$OUT" "Run /rules-compile"
assert_eq "validate with no rubric exit" "$EC" "1"

echo "==> rubric: hooks load the rubric files"

write_rubrics
printf '%s\n' 'shadowed:' '  type: warn' '  files: ["lib/**/*"]' '  context: hand-written version' > "$RULES/write.yml"

OUT=$(write_event app/models/x.rb 'default_scope { }' | "$W"); EC=$?
assert_contains "write_rubric rule blocks pre-write" "$OUT" "[no_default_scope]"
assert_eq "write_rubric block exit" "$EC" "2"
OUT=$(write_event app/models/x.rb 'scope :active' | "$W")
assert_silent "write_rubric pattern miss stays silent" "$OUT"
assert_not_contains "metadata is never a rule" "$(write_event app/models/x.rb 'default_scope' | "$W")" "_rubric"

OUT=$(write_event app/models/legacy/x.rb 'default_scope { }' | "$W")
assert_silent "exclude carves a path out of a write rule" "$OUT"

OUT=$(write_event lib/x.rb 'anything' | "$W"); EC=$?
assert_contains "hand-written rule wins a name clash" "$OUT" "hand-written version"
assert_not_contains "shadowed rubric rule does not run" "$OUT" "rubric version"
assert_eq "hand-written warn does not block" "$EC" "0"

OUT=$(bash_event 'npm install left-pad' | "$R"); EC=$?
assert_contains "read_rubric rule blocks a command" "$OUT" "[use_pnpm]"
assert_eq "read_rubric block exit" "$EC" "2"
OUT=$(bash_event 'pnpm install left-pad' | "$R")
assert_silent "read pattern miss stays silent" "$OUT"
OUT=$(echo '{"tool_name":"Grep","session_id":"r1","tool_input":{"pattern":"npm install","path":"docs"}}' | "$R")
assert_silent "read rule keeps to its tools" "$OUT"

printf '%s\n' 'no_legacy:' '  type: warn' '  tools: [Read]' '  files: ["legacy/**/*"]' '  exclude: ["legacy/README.md"]' '  context: legacy is deprecated' > "$RULES/read.yml"
read_event() { echo '{"tool_name":"Read","session_id":"r1","tool_input":{"file_path":"'"$SMOKE/$1"'"}}'; }
assert_contains "read rule fires inside its files" "$(read_event legacy/a.rb | "$R")" "[no_legacy]"
assert_silent "exclude carves a path out of a read rule" "$(read_event legacy/README.md | "$R")"
rm "$RULES/read.yml"

echo '{"session_id":"r1"}' | "$S" --bootstrap
sleep 1.1; echo 'default_scope { where(x: 1) }' > "$SMOKE/app/models/y.rb"
OUT=$(bash_event true | "$S")
assert_contains "sweep replays write_rubric rules" "$OUT" "[no_default_scope]"

echo '{"session_id":"r1"}' | "$STOP" --record
mkdir -p "$SMOKE/db/migrate"; sleep 1.1; echo 'User.find_each { backfill }' > "$SMOKE/db/migrate/001_x.rb"
OUT=$(echo '{"session_id":"r1"}' | "$STOP")
assert_contains "Stop judges write_rubric judge rules" "$OUT" "[semantic_backfill] db/migrate/001_x.rb"

echo "==> rubric: validate"

OUT=$("$RUBRIC" validate); EC=$?
assert_contains "clash with a hand-written rule is an issue" "$OUT" "shadowed: name is already used in write.yml"
assert_eq "one issue fails validation" "$EC" "1"

rm "$RULES/write.yml"
OUT=$("$RUBRIC" validate); EC=$?
assert_contains "good rubric is valid" "$OUT" "valid"
assert_eq "good rubric exit" "$EC" "0"
assert_contains "write summary counts shapes" "$OUT" "write_rubric.yml: 3 rules (1 pattern, 1 judge, 0 detector, 1 match only), 1 skipped"
assert_contains "read summary" "$OUT" "read_rubric.yml: 1 rules (1 pattern"
assert_contains "block on files alone is noted" "$OUT" "note:  write_rubric.yml: shadowed: blocks every edit"

OUT=$("$RUBRIC" sources)
assert_contains "compiled source is unchanged" "$OUT" "CLAUDE.md  scope **/*  sha256 $(sha CLAUDE.md)  [unchanged]"
assert_contains "optional source left out is not stale" "$OUT" "[not compiled (optional)]"
assert_contains "status when fresh" "$OUT" "status: up to date"

echo 'A new rule.' >> "$SMOKE/CLAUDE.md"
assert_contains "edited source is stale" "$("$RUBRIC" sources)" "status: out of date"
assert_contains "validate catches a stale source" "$("$RUBRIC" validate)" "source CLAUDE.md has sha256"

cat > "$RULES/write_rubric.yml" <<YAML
_rubric:
  sources:
    - { path: CLAUDE.md, sha256: "$(sha CLAUDE.md)" }
    - { path: gone.md, sha256: "abc" }
  skipped:
    - { text: "no reason given" }

Bad-Name:
  type: block
  files: ["**/*"]
  context: x
  text: x
  source: "CLAUDE.md:1"

no_files:
  type: warn
  pattern: '(unclosed'
  judge: { threshold: 3 }
  context: x
  text: x
  source: "elsewhere.md:1"

no_provenance:
  type: deny
  files: ["**/*"]
  exclude: "lib/**/*"

bad_detector:
  type: warn
  files: ["**/*"]
  context: x
  text: x
  source: "CLAUDE.md:1"
YAML
echo 'module Detectors; module Wrong; end; end' > "$RULES/detectors/bad_detector.rb"
printf '%s\n' '_rubric:' '  sources:' "    - { path: CLAUDE.md, sha256: \"$(sha CLAUDE.md)\" }" \
  'judged_read:' '  type: block_once' '  tools: [Bash, Edit]' '  judge: { question: "q" }' '  context: x' '  text: x' '  source: "CLAUDE.md:1"' \
  'no_files:' '  type: warn' '  context: x' '  text: x' '  source: "CLAUDE.md:1"' > "$RULES/read_rubric.yml"

OUT=$("$RUBRIC" validate); EC=$?
assert_eq "bad rubric exit" "$EC" "1"
assert_contains "missing source file" "$OUT" "source gone.md does not exist"
assert_contains "incomplete skipped entry" "$OUT" "skipped[0] needs text, source and reason"
assert_contains "name must be snake_case" "$OUT" "Bad-Name: name must be snake_case"
assert_contains "write rule needs files" "$OUT" "no_files: files is empty"
assert_contains "pattern must compile" "$OUT" "no_files: pattern is not a valid Ruby regex"
assert_contains "judge needs a question" "$OUT" "no_files: judge.question is empty"
assert_contains "threshold range" "$OUT" "no_files: judge.threshold must be a number between 0 and 1"
assert_contains "source must be listed" "$OUT" "no_files: source elsewhere.md is not listed"
assert_contains "unknown type" "$OUT" "no_provenance: type must be one of block, block_once, warn"
assert_contains "text is required" "$OUT" "no_provenance: text is missing"
assert_contains "context is required" "$OUT" "no_provenance: context is empty"
assert_contains "exclude must be a list" "$OUT" "no_provenance: exclude must be a list of globs"
assert_contains "detector must load" "$OUT" "bad_detector: detectors/bad_detector.rb does not load or does not define Detectors::BadDetector.call"
assert_contains "read rules have no block_once" "$OUT" "read_rubric.yml: judged_read: type must be one of block, warn"
assert_contains "read rules have no judge" "$OUT" "judged_read: judge is not supported on read rules"
assert_contains "read tools are checked" "$OUT" "judged_read: tools has unknown names: Edit"
assert_contains "names are unique across rubric files" "$OUT" "read_rubric.yml: no_files: name is already used in write_rubric.yml"

printf '%s\n' 'not: [valid' > "$RULES/read_rubric.yml"
assert_contains "unparseable rubric is reported" "$("$RUBRIC" validate)" "read_rubric.yml: does not parse"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
