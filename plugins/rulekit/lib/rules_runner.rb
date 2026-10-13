require 'fileutils'
require 'json'
require 'yaml'
require_relative 'judge_client'

# Shared engine for write-rules-check.rb, tool-rules-check.rb,
# post-write-sweep.rb and stop-rules-check.rb.
#
# The tool hook handles its own tool-name gating and calls `record` directly.
# The two write-side hooks share `apply_write_rules`, which does the glob /
# pattern / detector matching for one (path, content) pair — the pre-write hook
# supplies content from the tool call, the sweep supplies it from the diff.
# The Stop hook uses `apply_stop_rules` for the `judge:` rules those two defer.
# Every hook finishes with `emit!`.
class RulesRunner
  # Appended to every block_once denial so the agent knows the block is soft:
  # re-issuing the same edit in this session will be allowed through. Authors
  # write the convention; the engine supplies the escape hatch.
  BLOCK_ONCE_AFFORDANCE = 'This rule blocks once per session; make the same edit again and it will go through.'
  STOP_BLOCK_ONCE_AFFORDANCE = 'This rule blocks once per session; if the change is intended, finish again ' \
                               'and it will go through.'

  # Prefixed to a PostToolUse block. By then the write is already on disk, so
  # "denied" would be a lie — the agent has to undo it instead.
  POST_WRITE_PREAMBLE = 'A write that bypassed the pre-write hooks has already landed on disk and broke a rule. ' \
                        'Revert or correct it now, and use Edit/Write for source files so rules apply before the write.'

  # Prefixed to a Stop block. `judge:` rules are judged by a model once the turn
  # is over, so the finding is a probability about code already on disk.
  STOP_PREAMBLE = 'Before finishing: a model review of what this turn changed found likely rule violations. ' \
                  'Correct each one, or leave it and say why if the finding is wrong.'

  FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH

  RULE_TYPES = %w[block block_once warn].freeze

  # Resolves the rules directory. Defaults to <project>/.claude/rules, but
  # CLAUDE_RULES_DIR overrides it (useful for tests or non-standard layouts).
  def self.rules_dir(project_dir)
    override = ENV['CLAUDE_RULES_DIR'].to_s
    override.empty? ? File.join(project_dir, '.claude', 'rules') : override
  end

  # The rules for one side ('write' or 'tools'): the hand-written <kind>.yml and
  # the <kind>_rubric.yml that /rules-compile generates from the project's
  # instruction files, as one hash. On a name clash the hand-written rule wins.
  # Entries that are not rules (the rubric's `_rubric` metadata) ride along and
  # are skipped by every hook, as anything without a known `type` is.
  #
  # A rule with `enabled: false` is left out, so no hook sees it. That is how
  # a generated rule is switched off: /rules-compile keeps the flag when it
  # rewrites the rubric.
  def self.load_rules(project_dir, kind)
    enabled(all_rules(project_dir, kind))
  end

  # The same hash with the switched-off rules still in it, for a caller that
  # lays these rules over others before dropping them.
  def self.all_rules(project_dir, kind)
    ['_rubric', ''].each_with_object({}) do |suffix, merged|
      path = rules_file(project_dir, kind, suffix)
      next if path.nil?

      loaded = YAML.safe_load_file(path)
      merged.merge!(loaded) if loaded.is_a?(Hash)
    end
  end

  def self.enabled(rules)
    rules.reject { |_, rule| disabled?(rule) }
  end

  def self.disabled?(rule)
    rule.is_a?(Hash) && rule['enabled'] == false
  end

  # Tool rules were called read rules, in read.yml and read_rubric.yml. A
  # project that still has those keeps working until it renames them.
  LEGACY_KINDS = { 'tools' => 'read' }.freeze

  # Path of <kind><suffix>.yml, or of its legacy name when only that exists.
  # nil when neither does.
  def self.rules_file(project_dir, kind, suffix = '')
    [kind, LEGACY_KINDS[kind]].compact
                              .map { |name| File.join(rules_dir(project_dir), "#{name}#{suffix}.yml") }
                              .find { |path| File.exist?(path) }
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
    @notices = []
    @sentinels = []
  end

  # Matches one (path, content) pair against every rule in a write.yml hash,
  # recording each rule that fires. `new_content` is whatever the caller counts
  # as newly written: the tool's new_string/content before the write, or the
  # lines a write added once it has landed.
  #
  # Decision order once glob + pattern match: a detector file wins; otherwise a
  # `judge:` block defers the rule to the Stop hook; otherwise the rule fires.
  def apply_write_rules(rules, file_path:, relative_path:, new_content:, session_id:)
    rules.each do |name, rule|
      next unless rule.is_a?(Hash)
      next unless RULE_TYPES.include?(rule['type'])
      next unless applies_to?(rule, relative_path, file_path)
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
               elsif rule['judge'].is_a?(Hash)
                 nil # judged at Stop by apply_stop_rules
               else
                 true
               end

      record(name: name, rule: rule, detector_result: result)
    end
  end

  # Asks the judge about one changed file, in a single request carrying every `judge:`
  # rule whose glob + pattern match it, and records the ones that fire.
  # `new_content` is the lines the turn added to the file. A rule with a
  # detector file is not asked about: the detector already decided pre-write.
  def apply_stop_rules(rules, file_path:, relative_path:, new_content:)
    pending = stop_rules(rules).select do |name, rule|
      applies_to?(rule, relative_path, file_path) && matches_pattern?(rule, name, new_content)
    end
    return if pending.empty?

    fired = judge.fired(pending.transform_values { |rule| rule['judge'] },
                      relative_path: relative_path, new_content: new_content)
    fired.each do |name|
      rule = pending[name]
      record(name: name, rule: rule, detector_result: { context: "#{relative_path}: #{rule['context']}" })
    end
  end

  # The rules the Stop hook owns: a `judge:` block and no detector file.
  def stop_rules(rules)
    rules.select do |name, rule|
      rule.is_a?(Hash) && RULE_TYPES.include?(rule['type']) && rule['judge'].is_a?(Hash) &&
        !File.exist?(File.join(@detector_dir, "#{name}.rb"))
    end
  end

  def judge_configured?
    judge.configured?
  end

  # True once any rule has fired in a way that reaches the agent.
  def pending?
    @blocks.any? || @warns.any?
  end

  # Turns everything pending into a note for the user. The Stop hook calls
  # this once it has kept the turn open as often as one turn allows.
  def demote_to_notice!
    @notices = @blocks + @warns
    @blocks = []
    @warns = []
  end

  # True when the path is inside the rule's `files` and outside its `exclude`.
  def applies_to?(rule, relative_path, file_path)
    matches_globs?(Array(rule['files']), relative_path, file_path) &&
      !matches_globs?(Array(rule['exclude']), relative_path, file_path)
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

  # True when the rule has no `pattern`, or its regex matches `content`: the
  # new code for a write rule, what the tool was asked for on a tool rule.
  def matches_pattern?(rule, name, content)
    pattern = rule['pattern'].to_s
    return true if pattern.empty?

    begin
      regex = Regexp.new(pattern)
    rescue RegexpError
      warn "[#{@script_name}] invalid regex for rule '#{name}': #{pattern}"
      return false
    end

    regex.match?(content)
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
    when 'block_once' then @blocks << "#{text} #{stop? ? STOP_BLOCK_ONCE_AFFORDANCE : BLOCK_ONCE_AFFORDANCE}"
    when 'block'      then @blocks << text
    else @warns << text
    end
  end

  # Emits final JSON, touches sentinels, and exits the script.
  def emit!
    touch_sentinels if @blocks.any? || @warns.any? || @notices.any?

    if @blocks.any?
      puts JSON.generate(block_payload)
      exit(pre_tool_use? ? 2 : 0)
    elsif @warns.any?
      puts JSON.generate(hookSpecificOutput: { hookEventName: @event, additionalContext: @warns.join("\n\n") })
    elsif @notices.any?
      puts JSON.generate(systemMessage: "rulekit: left unresolved this turn\n\n#{@notices.join("\n\n")}")
    end
    exit 0
  end

  private

  # Built on first use, and only ever by the Stop hook.
  def judge
    @judge ||= JudgeClient.from_env(session_dir: @session_dir)
  end

  def pre_tool_use?
    @event == 'PreToolUse'
  end

  def stop?
    @event == 'Stop'
  end

  # A pre-write block denies the call outright. A post-write block cannot —
  # the write already happened — so it comes back as a `decision: block`, which
  # surfaces the reason to the agent and makes it respond. At Stop the same
  # `decision: block` keeps the turn open.
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
      { decision: 'block', reason: "#{stop? ? STOP_PREAMBLE : POST_WRITE_PREAMBLE}\n\n#{reason}" }
    end
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
