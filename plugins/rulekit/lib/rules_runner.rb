require 'fileutils'
require 'json'

# Shared engine for write-rules-check.rb, read-rules-check.rb and
# post-write-sweep.rb.
#
# The read hook handles its own tool-name gating and calls `record` directly.
# The two write-side hooks share `apply_write_rules`, which does the glob /
# pattern / detector matching for one (path, content) pair — the pre-write hook
# supplies content from the tool call, the sweep supplies it from the diff.
# Every hook finishes with `emit!`.
class RulesRunner
  # Appended to every block_once denial so the agent knows the block is soft:
  # re-issuing the same edit in this session will be allowed through. Authors
  # write the convention; the engine supplies the escape hatch.
  BLOCK_ONCE_AFFORDANCE = 'This rule blocks once per session; make the same edit again and it will go through.'

  # Prefixed to a PostToolUse block. By then the write is already on disk, so
  # "denied" would be a lie — the agent has to undo it instead.
  POST_WRITE_PREAMBLE = 'A write that bypassed the pre-write hooks has already landed on disk and broke a rule. ' \
                        'Revert or correct it now, and use Edit/Write for source files so rules apply before the write.'

  FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH

  RULE_TYPES = %w[block block_once warn].freeze

  # Resolves the rules directory. Defaults to <project>/.claude/rules, but
  # CLAUDE_RULES_DIR overrides it (useful for tests or non-standard layouts).
  def self.rules_dir(project_dir)
    override = ENV['CLAUDE_RULES_DIR'].to_s
    override.empty? ? File.join(project_dir, '.claude', 'rules') : override
  end

  # Per-session scratch dir backing sentinels and the sweep's snapshots.
  # Cleared on SessionStart by clear-advisory-sentinels.sh.
  def self.session_dir(project_dir, session_id)
    File.join(project_dir, 'tmp', '.claude-advisory', session_id.to_s.empty? ? 'unknown-session' : session_id)
  end

  def self.from_env(script_name:, project_dir:, session_id:, event: 'PreToolUse')
    new(
      script_name: script_name,
      session_dir: session_dir(project_dir, session_id),
      detector_dir: File.join(rules_dir(project_dir), 'detectors'),
      event: event,
    )
  end

  def initialize(script_name:, session_dir:, detector_dir:, event: 'PreToolUse')
    @script_name = script_name
    @session_dir = session_dir
    @detector_dir = detector_dir
    @event = event
    @blocks = []
    @warns = []
    @sentinels = []
  end

  # Matches one (path, content) pair against every rule in a write.yml hash,
  # recording each rule that fires. `new_content` is whatever the caller counts
  # as newly written: the tool's new_string/content before the write, or the
  # lines a write added once it has landed.
  def apply_write_rules(rules, file_path:, relative_path:, new_content:, session_id:)
    rules.each do |name, rule|
      next unless rule.is_a?(Hash)
      next unless RULE_TYPES.include?(rule['type'])
      next unless matches_globs?(Array(rule['files']), relative_path, file_path)
      next unless matches_pattern?(rule, name, new_content)

      detector = load_detector(name)
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

      record(name: name, rule: rule, detector_result: result)
    end
  end

  # True when any glob matches the path, tried both project-relative and
  # absolute. An empty glob list never matches — a write rule must scope itself.
  def matches_globs?(globs, relative_path, file_path)
    return false if globs.empty?

    globs.any? do |glob|
      File.fnmatch?(glob, relative_path, FNMATCH_FLAGS) ||
        File.fnmatch?(glob, file_path, FNMATCH_FLAGS)
    end
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

    text = "[#{name}] #{context}"
    case type
    when 'block_once' then @blocks << "#{text} #{BLOCK_ONCE_AFFORDANCE}"
    when 'block'      then @blocks << text
    else @warns << text
    end
  end

  # Emits final JSON, touches sentinels, and exits the script.
  def emit!
    touch_sentinels if @blocks.any? || @warns.any?

    if @blocks.any?
      puts JSON.generate(block_payload)
      exit(pre_tool_use? ? 2 : 0)
    elsif @warns.any?
      puts JSON.generate(hookSpecificOutput: { hookEventName: @event, additionalContext: @warns.join("\n\n") })
    end
    exit 0
  end

  private

  def pre_tool_use?
    @event == 'PreToolUse'
  end

  # A pre-write block denies the call outright. A post-write block cannot —
  # the write already happened — so it comes back as a `decision: block`, which
  # surfaces the reason to the agent and makes it respond.
  def block_payload
    reason = (@blocks + @warns).join("\n\n")

    if pre_tool_use?
      {
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason: reason,
        },
      }
    else
      { decision: 'block', reason: "#{POST_WRITE_PREAMBLE}\n\n#{reason}" }
    end
  end

  def matches_pattern?(rule, name, new_content)
    pattern = rule['pattern'].to_s
    return true if pattern.empty?

    begin
      regex = Regexp.new(pattern)
    rescue RegexpError
      warn "[#{@script_name}] invalid regex for rule '#{name}': #{pattern}"
      return false
    end

    regex.match?(new_content)
  end

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
