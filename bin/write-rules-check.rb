#!/usr/bin/env ruby
# write-rules-check.rb - Enforce content + advisory rules on Edit/MultiEdit/Write.
#
# Reads stdin JSON from Claude Code and applies rules from
# <project>/.claude/rules/write.yml (override the dir with CLAUDE_RULES_DIR).
# Each YAML rule:
#
#   type:              "block"      — deny tool call every time.
#                      "block_once" — deny tool call on first hit per session;
#                                     allow silently on retry (escape hatch).
#                      "warn"       — inject context. Honours once_per_session.
#   files:             Globs (relative to project root, ** supported).
#   pattern:           Optional Ruby regex matched against the new content.
#                      Omit to fire on file-glob match alone.
#   context:           Static message returned to Claude (may be overridden by
#                      a detector).
#   once_per_session:  Optional, warn-only. When true the rule fires at most
#                      once per session (sentinel under tmp/.claude-advisory/).
#                      Block rules ignore this flag; use block_once instead.
#
# Per-rule detection logic lives in Ruby files at
# <project>/.claude/rules/detectors/<rule_name>.rb. A detector defines:
#
#   Detectors::<CamelCaseName>.call(file_path:, relative_path:, new_content:, session_id:, rule:, **)
#
# `rule` is the rule's own YAML hash (string keys), so a detector can read
# extra configuration keys declared alongside type/files/pattern/context.
#
# Return contract:
#   false / nil — rule does not fire.
#   true        — rule fires with the YAML `context`.
#   Hash        — rule fires; optional keys override behaviour:
#                   :context         — replaces YAML context for this fire.
#                   :sentinel_suffix — appended to per-session sentinel key,
#                                      enabling per-target once_per_session.
#
# If a YAML rule has no matching detector file the rule fires whenever its
# files glob (and optional pattern) match.
#
# Block rules surface as hookSpecificOutput.permissionDecision = "deny"
# (with permissionDecisionReason). Warn rules surface as additionalContext.

require 'json'
require 'yaml'
require_relative '../lib/rules_runner'

input = JSON.parse($stdin.read)
tool = input['tool_name']
session_id = input['session_id'].to_s

file_path = input.dig('tool_input', 'file_path').to_s
exit 0 if file_path.empty?

new_content = case tool
when 'Edit'   then input.dig('tool_input', 'new_string').to_s
when 'MultiEdit'
  Array(input.dig('tool_input', 'edits')).map { |edit| edit['new_string'].to_s }.join("\n")
when 'Write'  then input.dig('tool_input', 'content').to_s
else exit 0
end

project_dir = ENV['CLAUDE_PROJECT_DIR'].to_s
config_path = File.join(RulesRunner.rules_dir(project_dir), 'write.yml')
exit 0 unless File.exist?(config_path)

rules = YAML.safe_load_file(config_path) || {}
exit 0 if rules.empty?

relative_path = if !project_dir.empty? && file_path.start_with?("#{project_dir}/")
                  file_path[(project_dir.length + 1)..]
                else
                  file_path
end

fnmatch_flags = File::FNM_PATHNAME | File::FNM_DOTMATCH

runner = RulesRunner.from_env(script_name: 'write-rules-check', project_dir: project_dir, session_id: session_id)

rules.each do |name, rule|
  next unless rule.is_a?(Hash)

  type = rule['type']
  next unless %w[block block_once warn].include?(type)

  globs = Array(rule['files'])
  next if globs.empty?

  matches_file = globs.any? do |glob|
    File.fnmatch?(glob, relative_path, fnmatch_flags) ||
      File.fnmatch?(glob, file_path, fnmatch_flags)
  end
  next unless matches_file

  pattern = rule['pattern']
  if pattern && !pattern.to_s.empty?
    begin
      regex = Regexp.new(pattern)
    rescue RegexpError
      warn "[write-rules-check] invalid regex for rule '#{name}': #{pattern}"
      next
    end
    next unless regex.match?(new_content)
  end

  detector = runner.load_detector(name)
  result = if detector
             detector.call(
               file_path: file_path,
               relative_path: relative_path,
               new_content: new_content,
               session_id: session_id,
               rule: rule,
             )
           else
             true
           end

  runner.record(name: name, rule: rule, detector_result: result)
end

runner.emit!
