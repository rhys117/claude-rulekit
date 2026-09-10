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
# `git status` supplies the candidate set (cheap, and it respects .gitignore).
# Content comes from a per-session snapshot of each file's last-seen state
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
require 'yaml'
require 'digest'
require 'fileutils'
require_relative '../lib/rules_runner'

# Tools whose writes write-rules-check.rb already vetted.
PRE_CHECKED_TOOLS = %w[Edit MultiEdit Write NotebookEdit].freeze

# Above this many files moving in a single tool call, record and stay silent.
# Counted against what changed since the last sweep, not against everything the
# branch has dirty, so a big working tree does not switch the sweep off.
MAX_FILES = 25

# Skip anything bigger; it is generated or vendored, not hand-written.
MAX_BYTES = 512 * 1024

# Commands that move git's own state rather than author code.
GIT_STATE_COMMAND = /\bgit\s+(?:-\S+\s+|--\S+\s+)*
                     (?:checkout|switch|restore|reset|rebase|merge|stash|pull|
                        cherry-pick|revert|apply|clean|am|bisect)\b/x

# Per-session record of each changed file's last-seen content. The diff against
# it is what a sweep evaluates; writing it back is what keeps a rule from
# re-firing until the file changes again.
class Snapshots
  def initialize(dir)
    @dir = dir
  end

  def initialized?
    File.exist?(marker)
  end

  def initialize!
    FileUtils.mkdir_p(@dir)
    FileUtils.touch(marker)
  end

  def read(relative_path)
    path = path_for(relative_path)
    File.exist?(path) ? scrub(File.read(path, mode: 'r:UTF-8')) : nil
  end

  # A cheap "has this moved since we last looked?" so a sweep only reads the
  # files one tool call touched. The snapshot is written straight after the
  # source is read, so an untouched file's snapshot is never older than it.
  def stale?(relative_path, source_path)
    snapshot = path_for(relative_path)
    return true unless File.exist?(snapshot)

    File.mtime(source_path) > File.mtime(snapshot)
  end

  def write(relative_path, content)
    FileUtils.mkdir_p(@dir)
    File.write(path_for(relative_path), content, mode: 'w:UTF-8')
  end

  def forget(relative_path)
    FileUtils.rm_f(path_for(relative_path))
  end

  private

  def marker
    File.join(@dir, '.initialized')
  end

  # Hashed so a path's separators and length cannot escape the snapshot dir.
  def path_for(relative_path)
    File.join(@dir, Digest::SHA256.hexdigest(relative_path))
  end

  def scrub(text)
    text.valid_encoding? ? text : text.scrub
  end
end

def git(project_dir, *args)
  output = IO.popen(['git', '-C', project_dir, *args], err: File::NULL, &:read)
  return nil unless $?.success?

  output.force_encoding('UTF-8').scrub
end

# [[status_code, repo_relative_path], ...]. NUL-delimited so paths with spaces
# survive; rename and copy entries carry a trailing source path to consume.
def changed_entries(project_dir)
  raw = git(project_dir, 'status', '--porcelain', '--untracked-files=all', '-z')
  return nil if raw.nil?

  fields = raw.split("\0")
  entries = []

  until fields.empty?
    field = fields.shift
    next if field.nil? || field.length < 4

    code = field[0, 2]
    entries << [code, field[3..]]
    fields.shift if code.start_with?('R', 'C')
  end

  entries
end

# Lines present in `current` that `baseline` does not account for, in order.
# A multiset difference rather than a real LCS diff: rules match by regex, so
# what matters is that unchanged lines stay out of the content being scanned.
def added_lines(baseline, current)
  return current if baseline.nil? || baseline.empty?

  remaining = Hash.new(0)
  baseline.each_line { |line| remaining[line] += 1 }

  added = current.each_line.reject do |line|
    next false if remaining[line].zero?

    remaining[line] -= 1
    true
  end

  added.join
end

def read_source(path)
  content = File.read(path, mode: 'r:UTF-8')
  content = content.scrub unless content.valid_encoding?
  content.include?("\0") ? nil : content
end

# The path an already-vetted tool call wrote, if this event is one.
def pre_checked_path(input, project_dir)
  return nil unless PRE_CHECKED_TOOLS.include?(input['tool_name'].to_s)

  tool_input = input['tool_input'] || {}
  raw = (tool_input['file_path'] || tool_input['notebook_path']).to_s
  raw.empty? ? nil : real_path(File.expand_path(raw, project_dir))
end

# git reports real paths, but CLAUDE_PROJECT_DIR and tool arguments can arrive
# through a symlink (/var vs /private/var on macOS). Compare resolved paths or
# nothing inside the project looks like it is inside the project.
def real_path(path)
  File.realpath(path)
rescue Errno::ENOENT
  File.expand_path(path)
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

config_path = File.join(RulesRunner.rules_dir(project_dir), 'write.yml')
exit 0 unless File.exist?(config_path)

rules = YAML.safe_load_file(config_path) || {}
exit 0 if rules.empty?

repo_root = git(project_dir, 'rev-parse', '--show-toplevel')&.strip
exit 0 if repo_root.nil? || repo_root.empty?

entries = changed_entries(project_dir)
exit 0 if entries.nil?

snapshots = Snapshots.new(File.join(RulesRunner.session_dir(project_dir, session_id), 'snapshots'))
project_root = real_path(project_dir)
scratch_root = File.join(project_root, 'tmp', '.claude-advisory')
was_initialized = snapshots.initialized?

# Everything git calls dirty, narrowed to what has actually moved since the last
# sweep. A long-lived branch is dirty in dozens of files; only the handful this
# tool call touched are worth reading, and only they count against MAX_FILES.
candidates = entries.filter_map do |code, repo_path|
  absolute = File.expand_path(File.join(repo_root, repo_path))
  next unless absolute.start_with?("#{project_root}/")
  next if absolute.start_with?("#{scratch_root}/") # the sweep's own snapshots

  relative = absolute[(project_root.length + 1)..]

  unless File.file?(absolute)
    snapshots.forget(relative)
    next
  end
  next if File.size(absolute) > MAX_BYTES
  next unless snapshots.stale?(relative, absolute)

  [code, repo_path, absolute, relative]
end

# Record-only passes: the starting state of a session, a changeset too big to
# be authored code, and git moving its own state.
silent = bootstrap ||
         !was_initialized ||
         candidates.length > MAX_FILES ||
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

candidates.each do |code, repo_path, absolute, relative|
  content = read_source(absolute)
  next if content.nil?

  # An untracked file is new in full; a tracked one is only new since HEAD.
  baseline = snapshots.read(relative) ||
             (code.start_with?('?') ? '' : git(project_dir, 'show', "HEAD:#{repo_path}").to_s)
  snapshots.write(relative, content)

  next if silent
  next if absolute == already_checked
  next unless runner.matches_globs?(rule_globs, relative, absolute)

  added = added_lines(baseline, content)
  next if added.strip.empty?

  runner.apply_write_rules(
    rules,
    file_path: absolute,
    relative_path: relative,
    new_content: added,
    session_id: session_id,
  )
end

runner.emit!
