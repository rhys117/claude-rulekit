#!/usr/bin/env ruby
# read-rules-check.rb - Enforce advisory rules on Bash / Grep / Glob.
#
# Reads stdin JSON from Claude Code and applies rules from
# <project>/.claude/rules/read.yml (override the dir with CLAUDE_RULES_DIR).
# Each YAML rule:
#
#   type:              "block" (deny tool call) or "warn" (inject context)
#   tools:             Optional array of tool names. Defaults to [Bash, Grep, Glob].
#                      Add "Read" to fire when the agent opens a file. Rule is
#                      skipped when tool_name is not in this list.
#   files:             Optional globs (relative to project root, ** supported)
#                      matched against the path the tool touches: the file_path
#                      for Read, the search path for Grep/Glob. Omit to fire on
#                      the tool match alone. Bash has no single path, so a rule
#                      with `files` never matches a Bash call.
#   context:           Static message returned to Claude (may be overridden by
#                      a detector).
#   once_per_session:  Optional, warn-only. When true the rule fires at most
#                      once per session (sentinel under tmp/.claude-advisory/).
#                      Block rules ignore this flag.
#
# Per-rule detection logic lives in Ruby files at
# <project>/.claude/rules/detectors/<rule_name>.rb. A detector defines:
#
#   Detectors::<CamelCaseName>.call(tool:, tool_input:, session_id:, rule:, **)
#
# `rule` is the rule's own YAML hash (string keys), so a detector can read
# extra configuration keys declared alongside type/context (e.g. `roots:`).
#
# Return contract:
#   false / nil — rule does not fire.
#   true        — rule fires with the YAML `context`.
#   Hash        — rule fires; optional keys override behaviour:
#                   :context         — replaces YAML context for this fire.
#                   :sentinel_suffix — appended to per-session sentinel key,
#                                      enabling per-target once_per_session.
#
# If a YAML rule has no matching detector file the rule fires whenever the tool
# match passes.
#
# Block rules surface as hookSpecificOutput.permissionDecision = "deny"
# (with permissionDecisionReason). Warn rules surface as additionalContext.

require 'json'
require 'yaml'
require_relative '../lib/rules_runner'

# Tools this hook may fire on. Rules without an explicit `tools:` default to the
# search tools only, so firing on Read is opt-in per rule.
READ_TOOLS = %w[Read Bash Grep Glob].freeze
DEFAULT_TOOLS = %w[Bash Grep Glob].freeze

input = JSON.parse($stdin.read)
tool = input['tool_name']
exit 0 unless READ_TOOLS.include?(tool)

session_id = input['session_id'].to_s
tool_input = input['tool_input'] || {}

project_dir = ENV['CLAUDE_PROJECT_DIR'].to_s
config_path = File.join(RulesRunner.rules_dir(project_dir), 'read.yml')
exit 0 unless File.exist?(config_path)

rules = YAML.safe_load_file(config_path) || {}
exit 0 if rules.empty?

# Path the tool touches, used for `files` globs: the file_path it reads, or the
# path it searches. Bash has neither, so a rule with `files` never matches it.
target_path = (tool_input['file_path'] || tool_input['path']).to_s
relative_path = if !project_dir.empty? && target_path.start_with?("#{project_dir}/")
                  target_path[(project_dir.length + 1)..]
                else
                  target_path
end
fnmatch_flags = File::FNM_PATHNAME | File::FNM_DOTMATCH

runner = RulesRunner.from_env(script_name: 'read-rules-check', project_dir: project_dir, session_id: session_id)

rules.each do |name, rule|
  next unless rule.is_a?(Hash)

  type = rule['type']
  next unless %w[block warn].include?(type)

  allowed_tools = Array(rule['tools'])
  allowed_tools = DEFAULT_TOOLS if allowed_tools.empty?
  next unless allowed_tools.include?(tool)

  globs = Array(rule['files'])
  unless globs.empty?
    next if target_path.empty?

    matched = globs.any? do |glob|
      File.fnmatch?(glob, relative_path, fnmatch_flags) ||
        File.fnmatch?(glob, target_path, fnmatch_flags)
    end
    next unless matched
  end

  detector = runner.load_detector(name)
  result = detector ? detector.call(tool: tool, tool_input: tool_input, session_id: session_id, rule: rule) : true

  runner.record(name: name, rule: rule, detector_result: result)
end

runner.emit!
