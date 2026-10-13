#!/usr/bin/env ruby
# rules-rubric.rb - The deterministic half of /rules-compile.
#
# /rules-compile has the agent turn a project's instruction files (CLAUDE.md,
# AGENTS.md, ...) into rules in rulekit's own format, written beside the
# hand-written ones:
#
#   .claude/rules/write_rubric.yml   loaded with write.yml
#   .claude/rules/tools_rubric.yml   loaded with tools.yml
#
# The agent does the reading and the judgement. This script does what should
# not be left to judgement:
#
#   rules-rubric.rb sources    list the instruction files to compile from, with
#                              the glob each one's rules apply to, its sha256,
#                              and whether the rubric is out of date with it
#   rules-rubric.rb validate   check both rubric files against what the hooks
#                              will accept; exit 1 if anything is wrong
#
# A rubric file is an ordinary rules file plus provenance. Each rule carries
# `text` (the user's words) and `source` ("CLAUDE.md:41"), and one reserved
# top-level key records what it was compiled from:
#
#   _rubric:
#     compiled_at: "2026-10-13"
#     sources:
#       - { path: CLAUDE.md, sha256: "9f2c..." }
#     skipped:
#       - { text: "Ask when unsure.", source: "CLAUDE.md:12", reason: "about the conversation, not the code" }
#
# The hooks skip `_rubric` (it has no `type`) and ignore `text` and `source`.
#
# Run from the project root, or set CLAUDE_PROJECT_DIR.

require 'digest'
require 'yaml'
require_relative '../lib/rules_runner'

# Finds the instruction files a rubric is compiled from.
module Sources
  ROOT_NAMES = ['AGENTS.override.md', 'AGENTS.md', 'CLAUDE.md', '.claude/CLAUDE.md', '.cursorrules'].freeze
  NESTED_NAMES = ['AGENTS.override.md', 'AGENTS.md', 'CLAUDE.md'].freeze
  # Read only for sentences that instruct; most of it is process, not rules.
  OPTIONAL_NAMES = ['CONTRIBUTING.md'].freeze
  SKIP_DIRS = %w[node_modules dist build out vendor coverage target tmp log].freeze
  MAX_DEPTH = 6

  Source = Struct.new(:path, :scope, :required)

  module_function

  def discover(root)
    found = ROOT_NAMES.select { |name| File.file?(File.join(root, name)) }
                      .map { |name| Source.new(name, '**/*', true) }
    walk(root, '', 1, found)
    found + OPTIONAL_NAMES.select { |name| File.file?(File.join(root, name)) }
                          .map { |name| Source.new(name, '**/*', false) }
  end

  # A nested instruction file applies only to its own directory.
  def walk(root, relative, depth, found)
    return if depth > MAX_DEPTH

    Dir.children(File.join(root, relative)).sort.each do |entry|
      next if entry.start_with?('.') || SKIP_DIRS.include?(entry)

      sub = relative.empty? ? entry : File.join(relative, entry)
      next unless File.directory?(File.join(root, sub)) && !File.symlink?(File.join(root, sub))

      NESTED_NAMES.each do |name|
        found << Source.new(File.join(sub, name), "#{sub}/**/*", true) if File.file?(File.join(root, sub, name))
      end
      walk(root, sub, depth + 1, found)
    end
  rescue SystemCallError
    nil
  end

  def sha256(root, path)
    file = File.join(root, path)
    File.file?(file) ? Digest::SHA256.file(file).hexdigest : nil
  end
end

# One <kind>_rubric.yml, read without the hand-written file merged in.
class RubricFile
  TYPES = { 'write' => %w[block block_once warn], 'tools' => %w[block warn] }.freeze
  SUPPORTED_TOOLS = %w[Read Bash Grep Glob].freeze
  NAME = /\A[a-z][a-z0-9_]*\z/

  attr_reader :kind, :issues, :notes

  def initialize(root, kind)
    @root = root
    @kind = kind
    @rules_dir = RulesRunner.rules_dir(root)
    @path = RulesRunner.rules_file(root, kind, '_rubric') || File.join(@rules_dir, "#{kind}_rubric.yml")
    @issues = []
    @notes = []
    @data = load
  end

  def name
    File.basename(@path)
  end

  def exist?
    File.exist?(@path)
  end

  def rules
    @data.reject { |key, _| key == '_rubric' }
  end

  def meta
    @data['_rubric'].is_a?(Hash) ? @data['_rubric'] : {}
  end

  # { path => sha256 } as recorded when the file was compiled.
  def recorded_sources
    Array(meta['sources']).each_with_object({}) do |source, found|
      found[source['path'].to_s] = source['sha256'].to_s if source.is_a?(Hash)
    end
  end

  def skipped
    Array(meta['skipped'])
  end

  # How each rule decides, for the summary: detector, judge, pattern, or the
  # files/tools match alone.
  def shape_counts
    rules.each_with_object(Hash.new(0)) do |(rule_name, rule), counts|
      next unless rule.is_a?(Hash)

      counts[shape(rule_name, rule)] += 1
    end
  end

  def validate(taken_names)
    return unless exist?

    validate_meta
    rules.each do |rule_name, rule|
      if taken_names.key?(rule_name)
        issue rule_name, "name is already used in #{taken_names[rule_name]}, so one of the two never runs"
      end
      rule.is_a?(Hash) ? validate_rule(rule_name, rule) : issue(rule_name, 'is not a mapping')
    end
  end

  private

  def load
    return {} unless exist?

    loaded = YAML.safe_load_file(@path)
    return loaded if loaded.is_a?(Hash)

    @issues << "#{name}: top level must be a mapping of rule name to rule"
    {}
  rescue Psych::Exception => e
    @issues << "#{name}: does not parse: #{e.message}"
    {}
  end

  def issue(rule_name, message)
    @issues << "#{name}: #{rule_name}: #{message}"
  end

  def note(rule_name, message)
    @notes << "#{name}: #{rule_name}: #{message}"
  end

  def detector_path(rule_name)
    File.join(@rules_dir, 'detectors', "#{rule_name}.rb")
  end

  def shape(rule_name, rule)
    return 'detector' if File.exist?(detector_path(rule_name))
    return 'judge' if rule['judge']
    return 'pattern' unless rule['pattern'].to_s.empty?

    'match only'
  end

  def validate_meta
    return issue('_rubric', 'is missing; it records the sources this file was compiled from') if meta.empty?

    issue('_rubric', 'sources is empty') if recorded_sources.empty?
    recorded_sources.each do |path, recorded|
      current = Sources.sha256(@root, path)
      if current.nil?
        issue('_rubric', "source #{path} does not exist")
      elsif current != recorded
        issue('_rubric', "source #{path} has sha256 #{current}, not the one recorded")
      end
    end
    skipped.each_with_index do |entry, index|
      next if entry.is_a?(Hash) && %w[text source reason].all? { |key| !entry[key].to_s.empty? }

      issue('_rubric', "skipped[#{index}] needs text, source and reason")
    end
  end

  def validate_rule(rule_name, rule)
    issue rule_name, 'name must be snake_case (a detector is found by it)' unless NAME.match?(rule_name.to_s)
    unless TYPES[@kind].include?(rule['type'])
      issue rule_name, "type must be one of #{TYPES[@kind].join(', ')}"
    end

    validate_provenance(rule_name, rule)
    %w[files exclude].each do |key|
      issue rule_name, "#{key} must be a list of globs" if rule.key?(key) && !rule[key].is_a?(Array)
    end
    validate_pattern(rule_name, rule)
    validate_detector(rule_name)
    issue rule_name, 'context is empty, so the rule can never fire' if rule['context'].to_s.strip.empty?
    if rule['once_per_session'] && rule['type'] != 'warn'
      note rule_name, 'once_per_session only applies to warn; use block_once'
    end

    @kind == 'write' ? validate_write(rule_name, rule) : validate_tools(rule_name, rule)
  end

  def validate_provenance(rule_name, rule)
    issue rule_name, 'text is missing: quote the instruction this rule comes from' if rule['text'].to_s.strip.empty?

    path, line = rule['source'].to_s.split(':', 2)
    if path.to_s.empty? || line.to_s !~ /\A\d+\z/
      issue rule_name, 'source must be "<path>:<line>"'
    elsif !recorded_sources.key?(path)
      issue rule_name, "source #{path} is not listed under _rubric.sources"
    end
  end

  def validate_pattern(rule_name, rule)
    return if rule['pattern'].to_s.empty?

    Regexp.new(rule['pattern'].to_s)
  rescue RegexpError => e
    issue rule_name, "pattern is not a valid Ruby regex: #{e.message}"
  end

  # Loaded in a child process: a detector that does not load takes the hook
  # down with it on every tool call.
  def validate_detector(rule_name)
    path = detector_path(rule_name)
    return unless File.exist?(path)

    module_name = rule_name.to_s.split('_').map(&:capitalize).join
    script = 'require ARGV[0]; exit(Detectors.const_get(ARGV[1]).respond_to?(:call) ? 0 : 1)'
    return if system('ruby', '-e', script, path, module_name, out: File::NULL, err: File::NULL)

    issue rule_name, "detectors/#{rule_name}.rb does not load or does not define Detectors::#{module_name}.call"
  end

  def validate_write(rule_name, rule)
    globs = Array(rule['files'])
    issue rule_name, 'files is empty; a write rule never matches without a glob (use ["**/*"] for everywhere)' if globs.empty?
    issue rule_name, 'tools is a tool-rule key' if rule.key?('tools')
    validate_judge(rule_name, rule['judge']) if rule.key?('judge')
    note_reach(rule_name, rule, globs)

    return unless shape(rule_name, rule) == 'match only'

    if rule['type'] == 'block'
      note rule_name, 'blocks every edit to its files; intended only for files nobody should edit'
    elsif !rule['once_per_session'] && rule['type'] == 'warn'
      note rule_name, 'warns on every edit to its files; add once_per_session or a pattern'
    end
  end

  # The two ways a generated rule most often misses: globs that point at a
  # directory that is not there, and a judge asked about every file.
  def note_reach(rule_name, rule, globs)
    if globs.any? && globs.grep(String).none? { |glob| matches_any_file?(glob) }
      note rule_name, "files (#{globs.join(', ')}) match nothing in the repo yet; check the path"
    end
    return unless rule['judge'] && globs.include?('**/*')

    note rule_name, 'asks the judge about every changed file; narrow files to where the rule applies'
  end

  def matches_any_file?(glob)
    Dir.glob(glob, File::FNM_DOTMATCH, base: @root) { return true }
    false
  end

  def validate_judge(rule_name, judge)
    return issue(rule_name, 'judge must be a mapping with a question') unless judge.is_a?(Hash)

    issue rule_name, 'judge.question is empty' if judge['question'].to_s.strip.empty?
    return unless judge.key?('threshold')

    threshold = judge['threshold']
    issue rule_name, 'judge.threshold must be a number between 0 and 1' unless threshold.is_a?(Numeric) &&
                                                                                threshold.between?(0, 1)
  end

  def validate_tools(rule_name, rule)
    issue rule_name, 'judge is not supported on tool rules' if rule.key?('judge')
    unknown = Array(rule['tools']) - SUPPORTED_TOOLS
    issue rule_name, "tools has unknown names: #{unknown.join(', ')}" unless unknown.empty?
    return unless shape(rule_name, rule) == 'match only' && Array(rule['files']).empty?

    note rule_name, 'fires on every call of its tools; add files, a pattern or once_per_session' unless rule['once_per_session']
  end
end

# { rule name => file } for the hand-written rules, which win a name clash.
def hand_written_names(root)
  %w[write tools].each_with_object({}) do |kind, names|
    path = RulesRunner.rules_file(root, kind)
    next if path.nil?

    loaded = YAML.safe_load_file(path)
    loaded.each_key { |name| names[name] = File.basename(path) } if loaded.is_a?(Hash)
  end
end

def print_sources(root, rubrics)
  recorded = rubrics.map(&:recorded_sources).reduce({}, :merge)
  compiled = rubrics.any?(&:exist?)
  stale = false

  puts "rubric files: #{rubrics.map { |r| "#{r.name} (#{r.exist? ? "#{r.rules.size} rules" : 'missing'})" }.join(', ')}"
  puts 'sources:'
  discovered = Sources.discover(root)
  discovered.each do |source|
    sha = Sources.sha256(root, source.path)
    status = if !recorded.key?(source.path) then source.required || !compiled ? 'new' : 'not compiled (optional)'
             elsif recorded[source.path] != sha then 'changed'
             else 'unchanged'
             end
    stale ||= %w[new changed].include?(status)
    optional = source.required ? '' : '  (optional: only if it carries instructions about code)'
    puts "  #{source.path}  scope #{source.scope}  sha256 #{sha}  [#{status}]#{optional}"
  end
  (recorded.keys - discovered.map(&:path)).each do |path|
    sha = Sources.sha256(root, path)
    status = sha.nil? ? 'gone' : (sha == recorded[path] ? 'unchanged' : 'changed')
    stale ||= status != 'unchanged'
    puts "  #{path}  sha256 #{sha || '-'}  [#{status}]  (listed in the rubric, e.g. a file another one points at)"
  end
  puts '  (none found)' if discovered.empty? && recorded.empty?

  puts "status: #{if !compiled then 'not compiled yet'
                  elsif stale then 'out of date'
                  else 'up to date'
                  end}"
end

def print_validation(rubrics)
  if rubrics.none?(&:exist?)
    puts 'No rubric files yet. Run /rules-compile.'
    return 1
  end

  taken = hand_written_names(ROOT)
  rubrics.each do |rubric|
    rubric.validate(taken)
    rubric.rules.each_key { |name| taken[name] ||= rubric.name }
    next unless rubric.exist?

    counts = rubric.shape_counts
    shapes = ['pattern', 'judge', 'detector', 'match only'].map { |shape| "#{counts[shape]} #{shape}" }.join(', ')
    puts "#{rubric.name}: #{rubric.rules.size} rules (#{shapes}), #{rubric.skipped.size} skipped"
  end

  notes = rubrics.flat_map(&:notes)
  issues = rubrics.flat_map(&:issues)
  notes.each { |note| puts "note:  #{note}" }
  issues.each { |issue| puts "issue: #{issue}" }
  puts issues.empty? ? 'valid' : "#{issues.size} issue(s) to fix"
  issues.empty? ? 0 : 1
end

ROOT = ENV['CLAUDE_PROJECT_DIR'].to_s.empty? ? Dir.pwd : ENV['CLAUDE_PROJECT_DIR']
rubrics = %w[write tools].map { |kind| RubricFile.new(ROOT, kind) }

case ARGV[0]
when 'sources'
  print_sources(ROOT, rubrics)
when 'validate'
  exit print_validation(rubrics)
else
  warn 'usage: rules-rubric.rb sources | validate'
  exit 64
end
