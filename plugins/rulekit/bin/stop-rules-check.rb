#!/usr/bin/env ruby
# stop-rules-check.rb - Judge `judge:` rules once, when the agent finishes a turn.
#
# A write.yml rule with a `judge:` block is decided by a model (see
# lib/judge_client.rb). That may be a paid network call, so the per-edit hooks
# skip those rules and this hook asks about them on Stop instead:
#
#   PreToolUse / PostToolUse  -> glob, pattern and detector rules
#   Stop                      -> `judge:` rules, over what the turn changed
#
# How it finds what the turn changed
# ----------------------------------
# Same machinery as post-write-sweep.rb (lib/working_tree.rb), with its own
# snapshots under tmp/.claude-advisory/<session_id>/turn-snapshots/. Run with
# --record on SessionStart and UserPromptSubmit, it notes the state of the
# working tree without asking anything, so edits the user made between turns
# are not pinned on the agent. On Stop it sends each file's lines added since
# then — one request per file, carrying every `judge:` rule that matched — and
# records the new state. A file that has not moved since the last Stop is not
# asked about again, so a finding the agent chose to leave does not come back.
#
# What the agent sees
# -------------------
# Either way the turn stays open so the agent can act on the finding:
#   block / block_once -> decision: "block" with the reason
#   warn               -> additionalContext ("Stop hook feedback")
# After MAX_CONTINUATIONS of those in one turn, later findings go to the user
# as a systemMessage and the turn is allowed to end.
#
# It stays silent — recording only — when the judge is not configured, when it
# cannot be reached, on the first pass of a session, and when more than
# MAX_FILES files moved at once.

require 'json'
require 'fileutils'
require_relative '../lib/rules_runner'
require_relative '../lib/working_tree'

# Above this many files changed in one turn, record and stay silent.
MAX_FILES = 25

# How many times one turn may be kept open: the first finding, plus one
# re-check of whatever the agent changed in response.
MAX_CONTINUATIONS = 2

input = begin
  JSON.parse($stdin.read)
rescue JSON::ParserError
  {}
end

record_only = ARGV.include?('--record')
session_id = input['session_id'].to_s

project_dir = ENV['CLAUDE_PROJECT_DIR'].to_s
exit 0 if project_dir.empty?

rules = RulesRunner.load_rules(project_dir, 'write')
runner = RulesRunner.from_env(
  script_name: 'stop-rules-check',
  project_dir: project_dir,
  session_id: session_id,
  event: 'Stop',
)

stop_rules = runner.stop_rules(rules)
exit 0 if stop_rules.empty?

session_dir = RulesRunner.session_dir(project_dir, session_id)
snapshots = WorkingTree::Snapshots.new(File.join(session_dir, 'turn-snapshots'))
was_initialized = snapshots.initialized?

changes = WorkingTree.moved_files(project_dir, snapshots)
exit 0 if changes.nil?

silent = record_only ||
         !was_initialized ||
         changes.length > MAX_FILES ||
         !runner.judge_configured?
snapshots.initialize! unless was_initialized

# Continuations this turn. Only a fresh prompt starts the count again.
counter = File.join(session_dir, 'stop-continuations')
FileUtils.rm_f(counter) if record_only

rule_globs = stop_rules.each_value.flat_map { |rule| Array(rule['files']) }.uniq

changes.each do |change|
  content = WorkingTree.read_source(change.absolute)
  next if content.nil?

  baseline = WorkingTree.baseline(project_dir, snapshots, change)
  snapshots.write(change.relative, content)

  next if silent
  next unless runner.matches_globs?(rule_globs, change.relative, change.absolute)

  added = WorkingTree.added_lines(baseline, content)
  next if added.strip.empty?

  runner.apply_stop_rules(
    stop_rules,
    file_path: change.absolute,
    relative_path: change.relative,
    new_content: added,
  )
end

if runner.pending?
  continuations = File.exist?(counter) ? File.read(counter).to_i : 0

  if continuations >= MAX_CONTINUATIONS
    runner.demote_to_notice!
  else
    FileUtils.mkdir_p(session_dir)
    File.write(counter, (continuations + 1).to_s)
  end
end

runner.emit!
