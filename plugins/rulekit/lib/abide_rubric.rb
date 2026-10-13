require 'json'

# Optional: judge the rules in an Abide rubric (https://github.com/coldteadotai/abide)
# on Stop, alongside the project's own `judge:` rules.
#
# Abide compiles instruction files into .abide/rubric.json, where each
# model-checked rule is a typed question for the same decision model the judge
# talks to. This reads that file and hands back its rules in the shape of
# write.yml `judge:` rules, so stop-rules-check.rb treats them like any other:
#
#   id                          -> the rule's name
#   scope (absent: every file)  -> files
#   check.question              -> judge.question, criteria folded into the text
#   thresholds.act (0.8)        -> judge.threshold, as a `block`
#   text and source             -> context
#
# A rule is switched off by its own `status` in the rubric, or from rulekit's
# side by a write.yml entry of the same name with `enabled: false`.
#
# Left out: rules a model does not check (lint, deferred, unenforceable), rules
# whose status is not `active`, and `choice` and `score` questions, which the
# judge protocol here has no shape for. Abide's flag band — a note to the user
# between thresholds.flag and thresholds.act — has no counterpart either.
#
# It is opt in and fails open. Unset, nothing is read. A rubric that is
# missing, is not JSON, is a version this does not know, or is not shaped
# like one yields no rules.
#
# Env:
#   RULEKIT_ABIDE_RUBRIC  1, true, yes or on reads <project>/.abide/rubric.json.
#                         Anything else is the path of the rubric, absolute or
#                         relative to the project. Unset, empty, 0, false, no
#                         or off leaves it off.
module AbideRubric
  ENV_NAME = 'RULEKIT_ABIDE_RUBRIC'.freeze
  DEFAULT_PATH = File.join('.abide', 'rubric.json').freeze
  VERSION = 1
  DEFAULT_THRESHOLD = 0.8
  ON = %w[1 true yes on].freeze
  OFF = ['', '0', 'false', 'no', 'off'].freeze
  # Abide never judges its own directory.
  EXCLUDE = ['.abide/**/*'].freeze

  # Path of the rubric to read, or nil when the feature is off.
  def self.path(project_dir)
    value = ENV[ENV_NAME].to_s.strip
    return nil if OFF.include?(value.downcase)

    File.expand_path(ON.include?(value.downcase) ? DEFAULT_PATH : value, project_dir)
  end

  # { name => rule } for every rule the judge can be asked about. Empty when
  # the feature is off or the rubric cannot be read.
  def self.rules(project_dir)
    file = path(project_dir)
    return {} if file.nil? || !File.exist?(file)

    rubric = JSON.parse(File.read(file))
    return skip(file, 'is not a version 1 rubric') unless rubric.is_a?(Hash) && rubric['version'] == VERSION

    threshold = rubric.dig('thresholds', 'act')
    threshold = DEFAULT_THRESHOLD unless threshold.is_a?(Numeric)

    Array(rubric['rules']).each_with_object({}) do |rule, rules|
      next unless judged?(rule)

      rules[rule['id']] = translate(rule, threshold)
    end
  rescue StandardError => e
    skip(file, e.message)
  end

  def self.judged?(rule)
    rule.is_a?(Hash) && rule['id'].is_a?(String) &&
      rule.fetch('status', 'active') == 'active' &&
      rule.dig('check', 'type') == 'model' &&
      rule.dig('check', 'question', 'type') == 'boolean' &&
      !rule.dig('check', 'question', 'instructions').to_s.empty?
  end

  def self.translate(rule, threshold)
    scope = Array(rule['scope'])
    {
      'type' => 'block',
      'files' => scope.empty? ? ['**/*'] : scope,
      'exclude' => EXCLUDE,
      'judge' => { 'question' => question(rule['check']['question']), 'threshold' => threshold },
      'context' => context(rule),
    }
  end

  # The judge takes one string per question, so the criteria ride in it.
  def self.question(question)
    criteria = question['criteria'].is_a?(Hash) ? question['criteria'] : {}
    [
      question['instructions'],
      ("Yes, for example: #{criteria['true']}" unless criteria['true'].to_s.empty?),
      ("No, for example: #{criteria['false']}" unless criteria['false'].to_s.empty?),
    ].compact.join("\n")
  end

  def self.context(rule)
    source = rule['source'].is_a?(Hash) ? rule['source'] : {}
    origin = [source['path'], source['line']].compact.join(':')
    text = rule['text'].to_s.empty? ? rule['check']['question']['instructions'] : rule['text']
    origin.empty? ? text : "#{text} (#{origin})"
  end

  def self.skip(file, why)
    warn "[abide-rubric] #{file} ignored: #{why}"
    {}
  end
end
