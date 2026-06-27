#!/usr/bin/env bash
# test.sh — Smoke-test the rulekit Rails preset against the rulekit engine.
#
# Pipes synthetic Claude Code PreToolUse events into bin/write-rules-check.rb
# and bin/read-rules-check.rb with CLAUDE_RULES_DIR pointed at this preset, then
# asserts on stdout + exit code. Every rule gets a positive case and, where it
# matters, a negative one; the detector-backed rules, block_once, and the
# read-side `roots:` config are all exercised.
#
# Run from anywhere:
#   presets/rails/test.sh
#
# A throwaway project dir is created with mktemp (for sentinels and the
# model-wrapper fixture) and removed on exit. No repo state is mutated.

set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PRESET="$REPO/presets/rails"
W="$REPO/bin/write-rules-check.rb"
R="$REPO/bin/read-rules-check.rb"

command -v ruby >/dev/null || { echo "ruby not found on PATH"; exit 1; }

SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/rulekit-rails-test.XXXXXX")"
export CLAUDE_PROJECT_DIR="$SMOKE"
export CLAUDE_RULES_DIR="$PRESET"

# Fixture for model_wrapper_delegation: a root model with an extracted sibling.
mkdir -p "$SMOKE/app/models/order"
echo "class Order < ApplicationRecord; end" > "$SMOKE/app/models/order.rb"
echo "class Order::LineItem; end"            > "$SMOKE/app/models/order/line_item.rb"

cleanup() { rm -rf "$SMOKE"; }
trap cleanup EXIT

PASS=0
FAIL=0

run() { echo "$2" | "$1"; }   # $1 = hook script, $2 = JSON payload

assert_contains() {
  local label="$1" out="$2" needle="$3"
  if [[ "$out" == *"$needle"* ]]; then echo "  PASS  $label"; PASS=$((PASS+1))
  else echo "  FAIL  $label"; echo "         want substring: $needle"; echo "         got: $out"; FAIL=$((FAIL+1)); fi
}
assert_not_contains() {
  local label="$1" out="$2" needle="$3"
  if [[ "$out" != *"$needle"* ]]; then echo "  PASS  $label"; PASS=$((PASS+1))
  else echo "  FAIL  $label"; echo "         did not want: $needle"; echo "         got: $out"; FAIL=$((FAIL+1)); fi
}
assert_silent() {
  local label="$1" out="$2"
  if [[ -z "$out" ]]; then echo "  PASS  $label"; PASS=$((PASS+1))
  else echo "  FAIL  $label (expected no stdout)"; echo "         got: $out"; FAIL=$((FAIL+1)); fi
}
assert_exit() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then echo "  PASS  $label exit=$expected"; PASS=$((PASS+1))
  else echo "  FAIL  $label exit (want $expected, got $actual)"; FAIL=$((FAIL+1)); fi
}

echo "==> read.yml"

SID="r-broad-bash"
P='{"tool_name":"Bash","session_id":"'"$SID"'","tool_input":{"command":"grep -r foo app/"}}'
OUT=$(run "$R" "$P"); EC=$?
assert_contains "broad grep -r fires advisory" "$OUT" "broad_search_advisory"
assert_exit     "broad grep -r" "$EC" "0"
OUT=$(run "$R" "$P"); EC=$?
assert_silent "second broad grep silenced (once_per_session)" "$OUT"

SID="r-broad-path"
OUT=$(run "$R" '{"tool_name":"Grep","session_id":"'"$SID"'","tool_input":{"pattern":"foo","path":"app"}}'); EC=$?
assert_contains "Grep over a source root fires" "$OUT" "broad_search_advisory"

SID="r-narrow"
OUT=$(run "$R" '{"tool_name":"Grep","session_id":"'"$SID"'","tool_input":{"pattern":"foo","path":"app/models/order.rb"}}'); EC=$?
assert_silent "narrow Grep path stays silent" "$OUT"

SID="r-roots"
OUT=$(run "$R" '{"tool_name":"Grep","session_id":"'"$SID"'","tool_input":{"pattern":"foo","path":"src"}}'); EC=$?
assert_silent "Grep over src stays silent (not a Rails root)" "$OUT"

SID="r-oob"
OUT=$(run "$R" '{"tool_name":"Read","session_id":"'"$SID"'","tool_input":{"file_path":"x"}}'); EC=$?
assert_silent "out-of-scope tool silent" "$OUT"
assert_exit   "out-of-scope tool" "$EC" "0"

echo
echo "==> write.yml — pattern-only rules"

SID="w-defscope"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"app/models/post.rb","new_string":"class Post\n  default_scope { where(active: true) }\nend"}}'); EC=$?
assert_contains "default_scope blocks" "$OUT" "no_default_scope"
assert_contains "default_scope emits deny" "$OUT" "permissionDecision"
assert_exit     "default_scope" "$EC" "2"

SID="w-defscope-neg"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"app/models/post.rb","new_string":"class Post\nend"}}'); EC=$?
assert_silent "plain model edit silent" "$OUT"

SID="w-rubysql"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"app/models/post.rb","new_string":"  names = Comment.all.map(&:name)"}}'); EC=$?
assert_contains "all.map fires ruby_vs_sql" "$OUT" "ruby_vs_sql"
assert_exit     "all.map" "$EC" "0"

SID="w-viewquery"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"app/views/posts/index.html.erb","new_string":"<%= Post.where(active: true).count %>"}}'); EC=$?
assert_contains "model query in view fires view_query_logic" "$OUT" "view_query_logic"

SID="w-view-neg"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"app/views/posts/index.html.erb","new_string":"<div>hello</div>"}}'); EC=$?
assert_silent "plain view markup silent" "$OUT"

SID="w-letspec"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"spec/models/post_spec.rb","new_string":"  let(:post) { build(:post) }"}}'); EC=$?
assert_contains "let in spec fires spec_let_fixture_nudge" "$OUT" "spec_let_fixture_nudge"

SID="w-letspec-neg"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"spec/models/post_spec.rb","new_string":"  before { sign_in user }"}}'); EC=$?
assert_silent "non-let spec edit silent" "$OUT"

echo
echo "==> write.yml — block_once (service_call_idiom)"

SID="w-call"
P='{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"app/services/charge.rb","new_string":"  def call\n    do_thing\n  end"}}'
OUT=$(run "$W" "$P"); EC=$?
assert_contains "def call blocks first time" "$OUT" "service_call_idiom"
assert_exit     "def call first hit" "$EC" "2"
OUT=$(run "$W" "$P"); EC=$?
assert_not_contains "def call yields on retry (block_once)" "$OUT" "service_call_idiom"
assert_exit         "def call retry" "$EC" "0"

SID="w-call-neg"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"app/models/widget.rb","new_string":"  def caller_id\n    1\n  end"}}'); EC=$?
assert_not_contains "def caller_id does not fire service_call_idiom" "$OUT" "service_call_idiom"

SID="w-service"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"app/services/report.rb","new_string":"  def perform\n    build_report\n  end"}}'); EC=$?
assert_contains "service file edit fires service_design_advisory" "$OUT" "service_design_advisory"
assert_exit     "service file edit" "$EC" "0"

echo
echo "==> write.yml — detector-backed migrations"

SID="w-backfill"
MIG='class X < ActiveRecord::Migration[8.0]\n  def up\n    add_column :posts, :slug, :string, null: false\n    Post.find_each { |p| p.update!(slug: p.title.parameterize) }\n  end\nend'
OUT=$(run "$W" '{"tool_name":"Write","session_id":"'"$SID"'","tool_input":{"file_path":"db/migrate/20260101000000_x.rb","content":"'"$MIG"'"}}'); EC=$?
assert_contains "NOT NULL + backfill fires migration_backfill" "$OUT" "migration_backfill"
assert_contains "migration edit also fires design advisory" "$OUT" "migration_design_advisory"
assert_exit     "NOT NULL + backfill" "$EC" "0"

SID="w-backfill-fresh"
MIG='class X < ActiveRecord::Migration[8.0]\n  def change\n    create_table :widgets do |t|\n      t.string :name, null: false\n    end\n    Widget.find_each { |w| w.update!(name: \"x\") }\n  end\nend'
OUT=$(run "$W" '{"tool_name":"Write","session_id":"'"$SID"'","tool_input":{"file_path":"db/migrate/20260101000001_x.rb","content":"'"$MIG"'"}}'); EC=$?
assert_not_contains "fresh-table migration does not fire migration_backfill" "$OUT" "migration_backfill"
assert_contains     "fresh-table migration still evaluated (design advisory present)" "$OUT" "migration_design_advisory"
assert_exit         "fresh-table migration" "$EC" "0"

SID="w-fkindex"
MIG='class X < ActiveRecord::Migration[8.0]\n  def change\n    add_column :posts, :author_id, :bigint\n  end\nend'
OUT=$(run "$W" '{"tool_name":"Write","session_id":"'"$SID"'","tool_input":{"file_path":"db/migrate/20260101000002_x.rb","content":"'"$MIG"'"}}'); EC=$?
assert_contains "FK column without index fires migration_missing_fk_index" "$OUT" "migration_missing_fk_index"
assert_contains "detector names the column" "$OUT" "author_id"

SID="w-fkindex-neg"
MIG='class X < ActiveRecord::Migration[8.0]\n  def change\n    add_column :posts, :author_id, :bigint\n    add_index :posts, :author_id\n  end\nend'
OUT=$(run "$W" '{"tool_name":"Write","session_id":"'"$SID"'","tool_input":{"file_path":"db/migrate/20260101000003_x.rb","content":"'"$MIG"'"}}'); EC=$?
assert_not_contains "FK column with index does not fire" "$OUT" "migration_missing_fk_index"

echo
echo "==> write.yml — detector-backed model wrapper (uses on-disk fixture)"

SID="w-wrapper"
OUT=$(run "$W" '{"tool_name":"Edit","session_id":"'"$SID"'","tool_input":{"file_path":"'"$SMOKE"'/app/models/order.rb","new_string":"  def total\n    1\n  end"}}'); EC=$?
assert_contains "editing a model with siblings fires model_wrapper_delegation" "$OUT" "model_wrapper_delegation"
assert_contains "detector names the sibling" "$OUT" "line_item"
assert_exit     "model wrapper" "$EC" "0"

echo
echo "==================================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "==================================="

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
