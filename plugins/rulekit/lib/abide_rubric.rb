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
#   check.question              -> judge: its type, question and criteria, and
#                                  the answers that count as a violation
#   thresholds.act (0.8)        -> judge.threshold, as a `block`
#   thresholds.flag (0.5)       -> judge.flag, a note to the user below that
#   text and source             -> context
#
# A rule is switched off by its own `status` in the rubric, or from rulekit's
# side by a write.yml entry of the same name with `enabled: false`.
#
# Left out: rules a model does not check (lint, deferred, unenforceable) and
# rules whose status is not `active`.
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
  DEFAULT_THRESHOLDS = { 'act' => 0.8, 'flag' => 0.5 }.freeze
  # Abide's question types, as `judge.type`. A yes/no question needs none.
  QUESTION_TYPES = { 'boolean' => nil, 'choice' => 'choice', 'score' => 'score' }.freeze
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

    thresholds = thresholds(rubric['thresholds'])

    Array(rubric['rules']).each_with_object({}) do |rule, rules|
      next unless judged?(rule)

      rules[rule['id']] = translate(rule, thresholds)
    end
  rescue StandardError => e
    skip(file, e.message)
  end

  def self.judged?(rule)
    rule.is_a?(Hash) && rule['id'].is_a?(String) &&
      rule.fetch('status', 'active') == 'active' &&
      rule.dig('check', 'type') == 'model' &&
      QUESTION_TYPES.key?(rule.dig('check', 'question', 'type')) &&
      !rule.dig('check', 'question', 'instructions').to_s.empty?
  end

  # The rubric's own thresholds where they are numbers, Abide's defaults where not.
  def self.thresholds(given)
    given = {} unless given.is_a?(Hash)
    DEFAULT_THRESHOLDS.to_h { |band, default| [band, given[band].is_a?(Numeric) ? given[band] : default] }
  end

  def self.translate(rule, thresholds)
    scope = Array(rule['scope'])
    {
      'type' => 'block',
      'files' => scope.empty? ? ['**/*'] : scope,
      'exclude' => EXCLUDE,
      'judge' => judge(rule['check']['question'], thresholds),
      'context' => context(rule),
    }
  end

  def self.judge(question, thresholds)
    {
      'type' => QUESTION_TYPES[question['type']],
      'question' => question['instructions'],
      'criteria' => question['criteria'],
      'violating' => question['violating'],
      'violating_from' => question['violatingFrom'],
      'threshold' => thresholds['act'],
      'flag' => thresholds['flag'],
    }.compact
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
