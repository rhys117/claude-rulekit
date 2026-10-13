#!/usr/bin/env ruby
# post-write-sweep.rb - Apply write.yml rules to writes that bypassed the
# pre-write hook.
#
# write-rules-check.rb only sees Edit/MultiEdit/Write. A heredoc, `sed -i`, a
# throwaway python script, an MCP filesystem server or a subagent can all put
# code on disk without any of them firing. This hook closes that gap by
# guarding the working tree instead of the tool call: it runs on PostToolUse
# for every tool, finds what actually changed, and replays the same
# `write.yml` rules over it.
#
#   PreToolUse(Edit|Write)  -> rules run on the content about to be written
#   PostToolUse(*)          -> rules run on the lines that did get written
#
# How it finds changes
# --------------------
# lib/working_tree.rb does the reading. `git status` supplies the candidate set
# (cheap, and it respects .gitignore). Content comes from a per-session snapshot of each file's last-seen state
# under tmp/.claude-advisory/<session_id>/snapshots/, so `new_content` is the
# lines this one tool call added — not the whole file, and not the whole branch
# diff. A tracked file with no snapshot yet falls back to its HEAD version, so
# a one-line `sed` into a committed file does not re-flag everything already in
# it. Updating the snapshot is also what stops a rule re-firing on every
# subsequent tool call: once swept, a file shows no delta until it changes again.
#
# What it deliberately ignores
# ----------------------------
#   * the file an Edit/MultiEdit/Write/NotebookEdit just wrote — the pre-write
#     hook already checked that content, so re-checking would warn twice
#   * git state moves (checkout, rebase, stash, ...) — that is history arriving,
#     not the agent authoring code
#   * more than MAX_FILES files moving at once, for the same reason
#   * the first sweep of a session, which only records the starting state
#
# Run with --bootstrap (SessionStart) to record the starting state without
# evaluating anything.
#
# Block rules surface as decision: "block" with a reason, since the write has
# already landed and cannot be denied. Warn rules surface as additionalContext.

require 'json'
require_relative '../lib/rules_runner'
require_relative '../lib/working_tree'

# Tools whose writes write-rules-check.rb already vetted.
PRE_CHECKED_TOOLS = %w[Edit MultiEdit Write NotebookEdit].freeze

# Commands that move git's own state rather than author code.
GIT_STATE_COMMAND = /\bgit\s+(?:-\S+\s+|--\S+\s+)*
                     (?:checkout|switch|restore|reset|rebase|merge|stash|pull|
                        cherry-pick|revert|apply|clean|am|bisect)\b/x

# The path an already-vetted tool call wrote, if this event is one.
def pre_checked_path(input, project_dir)
  return nil unless PRE_CHECKED_TOOLS.include?(input['tool_name'].to_s)

  tool_input = input['tool_input'] || {}
  raw = (tool_input['file_path'] || tool_input['notebook_path']).to_s
  raw.empty? ? nil : WorkingTree.real_path(File.expand_path(raw, project_dir))
end

def git_state_command?(input)
  return false unless input['tool_name'].to_s == 'Bash'

  GIT_STATE_COMMAND.match?(input.dig('tool_input', 'command').to_s)
end

input = begin
  JSON.parse($stdin.read)
rescue JSON::ParserError
  {}
end

bootstrap = ARGV.include?('--bootstrap')
session_id = input['session_id'].to_s

project_dir = ENV['CLAUDE_PROJECT_DIR'].to_s
exit 0 if project_dir.empty?

rules = RulesRunner.load_rules(project_dir, 'write')
exit 0 if rules.empty?

snapshots = WorkingTree::Snapshots.new(File.join(RulesRunner.session_dir(project_dir, session_id), 'snapshots'))
was_initialized = snapshots.initialized?

candidates = WorkingTree.moved_files(project_dir, snapshots)
exit 0 if candidates.nil?

# Record-only passes: the starting state of a session, a changeset too big to
# be authored code, and git moving its own state.
silent = bootstrap ||
         !was_initialized ||
         candidates.length > WorkingTree::MAX_FILES ||
         git_state_command?(input)
snapshots.initialize! unless was_initialized

runner = RulesRunner.from_env(
  script_name: 'post-write-sweep',
  project_dir: project_dir,
  session_id: session_id,
  event: 'PostToolUse',
)

rule_globs = rules.each_value.flat_map { |rule| rule.is_a?(Hash) ? Array(rule['files']) : [] }.uniq
already_checked = pre_checked_path(input, project_dir)

WorkingTree.each_addition(project_dir, snapshots, candidates) do |change, added|
  next if silent
  next if change.absolute == already_checked
  next unless runner.matches_globs?(rule_globs, change.relative, change.absolute)

  runner.apply_write_rules(
    rules,
    file_path: change.absolute,
    relative_path: change.relative,
    new_content: added,
    session_id: session_id,
  )
end

runner.emit!
