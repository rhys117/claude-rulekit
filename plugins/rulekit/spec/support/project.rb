require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'

# A throwaway project for the hooks to run against, and the hooks themselves.
class Project
  PLUGIN_ROOT = File.expand_path('../..', __dir__)
  BIN = File.join(PLUGIN_ROOT, 'bin')

  # Variables a developer's shell may carry that would change what a hook does.
  CLEARED = %w[CLAUDE_RULES_DIR RULEKIT_JUDGE_URL RULEKIT_JUDGE_API_KEY RULEKIT_JUDGE_MODEL RULEKIT_JUDGE_TIMEOUT
               RULEKIT_ABIDE_RUBRIC TYPESAFE_AI_API_KEY TYPESAFE_AI_BASE_URL].to_h { |name| [name, nil] }.freeze

  # Snapshots go by mtime. Filesystems that keep whole seconds need a pause
  # before each write for a change to register; set this to 1.1 there.
  SETTLE = Float(ENV.fetch('RULEKIT_SPEC_SETTLE', '0'))

  attr_reader :root, :env

  # `env` is applied to every hook run; a run's own `env:` is laid over it.
  def initialize(env: {})
    @root = Dir.mktmpdir('rulekit-spec')
    @env = env
    FileUtils.mkdir_p(File.join(rules_dir, 'detectors'))
  end

  def cleanup
    FileUtils.remove_entry(@root)
  end

  def rules_dir
    File.join(@root, '.claude', 'rules')
  end

  def path(relative)
    File.join(@root, relative)
  end

  # Writes a file under .claude/rules, e.g. rules('write.yml', yaml).
  def rules(name, content)
    File.write(File.join(rules_dir, name), content)
  end

  def rename_rules(from, to)
    File.rename(File.join(rules_dir, from), File.join(rules_dir, to))
  end

  def write(relative, content)
    sleep SETTLE if SETTLE.positive?
    FileUtils.mkdir_p(File.dirname(path(relative)))
    File.write(path(relative), content)
  end

  def append(relative, content)
    write(relative, (File.exist?(path(relative)) ? File.read(path(relative)) : '') + content)
  end

  def git_init
    git('init', '-q')
    git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'init')
  end

  def git_commit_all(message)
    git('add', '-A')
    git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', message)
  end

  def git(*args)
    system('git', '-C', @root, *args, out: File::NULL, err: File::NULL, exception: true)
  end

  def session_dir(session)
    path(File.join('tmp', '.claude-advisory', session))
  end

  # ---- the hooks ----

  def write_hook(payload, **options)
    run('write-rules-check.rb', payload, **options)
  end

  def tool_hook(payload, **options)
    run('tool-rules-check.rb', payload, **options)
  end

  def sweep(payload, *args, **options)
    run('post-write-sweep.rb', payload, *args, **options)
  end

  # stop-rules-check.rb --record, as on SessionStart and UserPromptSubmit.
  def record(session, **options)
    run('stop-rules-check.rb', { session_id: session }, '--record', **options)
  end

  def stop(session, **options)
    run('stop-rules-check.rb', { session_id: session, hook_event_name: 'Stop' }, **options)
  end

  def rubric(command, **options)
    run('rules-rubric.rb', nil, command, **options)
  end

  # ---- events ----

  def edit(file_path, new_string, session: 's')
    { tool_name: 'Edit', session_id: session, tool_input: { file_path: file_path, new_string: new_string } }
  end

  def write_event(file_path, content, session: 's')
    { tool_name: 'Write', session_id: session, tool_input: { file_path: file_path, content: content } }
  end

  def bash(command, session: 's')
    { tool_name: 'Bash', session_id: session, tool_input: { command: command } }
  end

  def grep(pattern, path, session: 's')
    { tool_name: 'Grep', session_id: session, tool_input: { pattern: pattern, path: path } }
  end

  def read(file_path, session: 's')
    { tool_name: 'Read', session_id: session, tool_input: { file_path: file_path } }
  end

  private

  def run(script, payload, *args, env: {}, chdir: nil)
    environment = CLEARED.merge('CLAUDE_PROJECT_DIR' => @root).merge(@env).merge(env)
    options = { stdin_data: payload.nil? ? '' : JSON.generate(payload) }
    options[:chdir] = chdir if chdir
    stdout, stderr, status = Open3.capture3(environment, File.join(BIN, script), *args, **options)
    HookResult.new(stdout, stderr, status.exitstatus)
  end
end
