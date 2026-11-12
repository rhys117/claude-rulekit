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
# working tree and the HEAD commit without asking anything, so edits the user
# made between turns are not pinned on the agent. Files the turn committed are
# no longer dirty by Stop, so the commits since that HEAD (merges aside) add to
# what git status reports. On Stop it sends each file's lines added since
# then — one request per file, carrying every `judge:` rule that matched — and
# records the new state. A file that has not moved since the last Stop is not
# asked about again, so a finding the agent chose to leave does not come back.
#
# A record pass only starts a new turn once a Stop has let the last one end.
# UserPromptSubmit also fires for task notifications and SessionStart for a
# compaction, both mid-turn; recording then would pass the agent's own edits
# off as the user's.
#
# What the agent sees
# -------------------
# Either way the turn stays open so the agent can act on the finding:
#   block / block_once -> decision: "block" with the reason
#   warn               -> additionalContext ("Stop hook feedback")
# After MAX_CONTINUATIONS of those in one turn, later findings go to the user
# as a systemMessage and the turn is allowed to end.
#
# Abide rubrics
# -------------
# With RULEKIT_ABIDE_RUBRIC set, the model-checked rules of an Abide rubric
# (lib/abide_rubric.rb) are judged here too, as `block` rules. Only this hook
# reads them, and a write.yml rule of the same name wins — including one that
# is only `enabled: false`, which switches the Abide rule off.
#
# It stays silent — recording only — when the judge is not configured, when it
# cannot be reached, on the first pass of a session, and when more than
# MAX_JUDGED_FILES judged files moved at once.

require 'json'
require 'fileutils'
require_relative '../lib/abide_rubric'
require_relative '../lib/judge_log'
require_relative '../lib/rules_runner'
require_relative '../lib/working_tree'

# How many times one turn may be kept open: the first finding, plus one
# re-check of whatever the agent changed in response.
MAX_CONTINUATIONS = 2

# Above this many judged files at once the Stop records and stays silent: that
# is history arriving, not a turn's work. Only files a `judge:` rule covers
# count, and JUDGE_THREADS requests run at a time so a large turn still fits in
# the hook's timeout.
MAX_JUDGED_FILES = 100
JUDGE_THREADS = 6

input = begin
  JSON.parse($stdin.read)
rescue JSON::ParserError
  {}
end

record_only = ARGV.include?('--record')
session_id = input['session_id'].to_s

project_dir = ENV['CLAUDE_PROJECT_DIR'].to_s
exit 0 if project_dir.empty?

rules = RulesRunner.enabled(AbideRubric.rules(project_dir).merge(RulesRunner.all_rules(project_dir, 'write')))
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

# The commit the turn started from, so work the agent committed before
# stopping is judged too. Re-read on every pass, so a turn's Stops agree.
turn_base = File.join(session_dir, 'turn-base')
turn_closed = File.join(session_dir, 'turn-closed')
if record_only && File.exist?(turn_base) && !File.exist?(turn_closed)
  JudgeLog.append(session_dir, event: 'record', skipped: 'turn still open')
  exit 0
end

FileUtils.rm_f(turn_closed) if record_only
if record_only || !File.exist?(turn_base)
  head = WorkingTree.git(project_dir, 'rev-parse', 'HEAD')&.strip
  FileUtils.mkdir_p(session_dir)
  File.write(turn_base, head.to_s)
end
since = File.read(turn_base).strip
since = nil if since.empty?

changes = WorkingTree.moved_files(project_dir, snapshots, since: since)
exit 0 if changes.nil?

rule_globs = stop_rules.each_value.flat_map { |rule| Array(rule['files']) }.uniq
judged = changes.select { |change| runner.matches_globs?(rule_globs, change.relative, change.absolute) }

skipped = if record_only then 'record pass'
          elsif !was_initialized then 'first pass of the session'
          elsif judged.length > MAX_JUDGED_FILES then "more than #{MAX_JUDGED_FILES} judged files"
          elsif !runner.judge_configured? then 'judge not configured'
          end
silent = !skipped.nil?
snapshots.initialize! unless was_initialized

if record_only
  JudgeLog.append(session_dir, event: 'record', since: since)
else
  JudgeLog.append(session_dir, event: 'stop', moved: changes.length, judged: judged.length, skipped: skipped)
end

# Continuations this turn. Only a fresh prompt starts the count again.
counter = File.join(session_dir, 'stop-continuations')
FileUtils.rm_f(counter) if record_only

queue = Queue.new
WorkingTree.each_addition(project_dir, snapshots, changes) do |change, added|
  queue << [change, added] if !silent && judged.include?(change)
end
queue.close

Array.new([JUDGE_THREADS, queue.size].min) do
  Thread.new do
    while (change, added = queue.pop)
      runner.apply_stop_rules(
        stop_rules,
        file_path: change.absolute,
        relative_path: change.relative,
        new_content: added,
      )
    end
  end
end.each(&:join)

if runner.pending?
  continuations = File.exist?(counter) ? File.read(counter).to_i : 0

  if continuations >= MAX_CONTINUATIONS
    runner.demote_to_notice!
  else
    FileUtils.mkdir_p(session_dir)
    File.write(counter, (continuations + 1).to_s)
  end
end

# Only a block is sure to keep the turn going; after a warning or a quiet pass
# the next prompt starts a new turn.
unless record_only
  JudgeLog.append(session_dir, event: 'done', findings: runner.pending?, turn: runner.blocking? ? 'open' : 'closed')
  FileUtils.touch(turn_closed) unless runner.blocking?
end

runner.emit!
