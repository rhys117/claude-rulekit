require 'fileutils'
require 'json'

# Shared engine for write-rules-check.rb and read-rules-check.rb.
#
# The hook scripts handle their own input parsing and rule-shape gating
# (file globs / content patterns for write; tool name for read), then call
# `record` once per fired rule and `emit!` once at the end.
class RulesRunner
  # Resolves the rules directory. Defaults to <project>/.claude/rules, but
  # CLAUDE_RULES_DIR overrides it (useful for tests or non-standard layouts).
  def self.rules_dir(project_dir)
    override = ENV['CLAUDE_RULES_DIR'].to_s
    override.empty? ? File.join(project_dir, '.claude', 'rules') : override
  end

  def self.from_env(script_name:, project_dir:, session_id:)
    new(
      script_name: script_name,
      session_dir: File.join(project_dir, 'tmp', '.claude-advisory', session_id.empty? ? 'unknown-session' : session_id),
      detector_dir: File.join(rules_dir(project_dir), 'detectors'),
    )
  end

  def initialize(script_name:, session_dir:, detector_dir:)
    @script_name = script_name
    @session_dir = session_dir
    @detector_dir = detector_dir
    @blocks = []
    @warns = []
    @sentinels = []
  end

  # Returns the detector module for `name`, or nil if no file exists.
  # Raises through any LoadError/SyntaxError — those are detector bugs.
  def load_detector(name)
    path = File.join(@detector_dir, "#{name}.rb")
    return nil unless File.exist?(path)

    require path
    module_name = name.split('_').map(&:capitalize).join
    Detectors.const_get(module_name)
  rescue NameError
    warn "[#{@script_name}] detector '#{name}' loaded but Detectors::#{module_name} not defined"
    nil
  end

  # Records a rule firing into the buffered output. `rule` is the YAML hash
  # for the rule (string keys: type, context, once_per_session, ...).
  # detector_result follows the contract documented in the hook scripts:
  # false/nil = no fire, true = fire with rule['context'], Hash = fire with
  # optional :context / :sentinel_suffix overrides.
  #
  # Type semantics:
  #   block       — deny tool call every time.
  #   block_once  — deny tool call on first hit per session; allow silently
  #                 on retry (escape hatch for legitimate uses).
  #   warn        — inject context. Honours once_per_session.
  def record(name:, rule:, detector_result:)
    return unless detector_result

    type = rule['type']
    context, sentinel_suffix = resolve_overrides(rule['context'].to_s, detector_result)
    return if context.empty?

    if type == 'block_once' || (type == 'warn' && rule['once_per_session'] == true)
      sentinel = sentinel_path(name, sentinel_suffix)
      return if File.exist?(sentinel)

      @sentinels << sentinel
    end

    message = "[#{name}] #{context}"
    case type
    when 'block', 'block_once' then @blocks << message
    else @warns << message
    end
  end

  # Emits final JSON, touches sentinels, and exits the script.
  def emit!
    touch_sentinels if @blocks.any? || @warns.any?

    if @blocks.any?
      reason = (@blocks + @warns).join("\n\n")
      puts JSON.generate(
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: reason,
        },
      )
      exit 2
    elsif @warns.any?
      puts JSON.generate(
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          additionalContext: @warns.join("\n\n"),
        },
      )
    end
    exit 0
  end

  private

  def touch_sentinels
    @sentinels.each do |sentinel|
      FileUtils.mkdir_p(File.dirname(sentinel))
      FileUtils.touch(sentinel)
    end
  end

  def resolve_overrides(static_context, result)
    return [static_context, nil] unless result.is_a?(Hash)

    override = result[:context].to_s
    context = override.empty? ? static_context : override
    [context, result[:sentinel_suffix]]
  end

  def sentinel_path(name, suffix)
    key = suffix && !suffix.to_s.empty? ? "#{name}-#{suffix}" : name
    File.join(@session_dir, key)
  end
end
