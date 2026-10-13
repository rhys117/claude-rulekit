require 'digest'

# The generated rubric files and bin/rules-rubric.rb.
#
# Covers: write_rubric.yml and tools_rubric.yml are loaded by all four hooks
# beside the hand-written files, a hand-written rule wins a name clash, the
# `_rubric` metadata is never treated as a rule, tool rules honour `pattern`,
# `exclude` carves a path out of a rule on both sides, the legacy read.yml
# names still load, `sources` finds instruction files and reports staleness,
# and `validate` accepts a good rubric and names what is wrong with a bad one.

RSpec.describe 'rubric files' do
  before(:context) { @judge = FakeJudge.new }
  after(:context) { @judge.stop }

  let(:project) { Project.new(env: { 'RULEKIT_JUDGE_URL' => @judge.url }) }

  before do
    project.write('CLAUDE.md', "# Project\n\nWe do not allow default scopes.\nAlways use pnpm.\n")
    project.write('apps/web/AGENTS.md', "Never show a user a raw error.\n")
    project.write('CONTRIBUTING.md', "Open a pull request.\n")
    project.write('node_modules/pkg/CLAUDE.md', "not ours\n")
    project.git_init
  end

  after { project.cleanup }

  def sha(relative)
    Digest::SHA256.file(project.path(relative)).hexdigest
  end

  def write_rubrics
    project.rules('write_rubric.yml', <<~YAML)
      _rubric:
        compiled_at: "2026-10-13"
        sources:
          - { path: CLAUDE.md, sha256: "#{sha('CLAUDE.md')}" }
          - { path: apps/web/AGENTS.md, sha256: "#{sha('apps/web/AGENTS.md')}" }
        skipped:
          - { text: "Ask when unsure.", source: "CLAUDE.md:9", reason: "about the conversation" }

      no_default_scope:
        type: block
        files: ["app/models/**/*.rb"]
        exclude: ["app/models/legacy/**/*"]
        pattern: '(?<!\\w)default_scope(?!\\w)'
        context: Default scopes are not allowed.
        text: "We do not allow default scopes."
        source: "CLAUDE.md:3"

      semantic_backfill:
        type: warn
        files: ["db/migrate/**/*"]
        judge:
          question: "Does this migration backfill data?"
        context: Split the backfill out.
        text: "Never show a user a raw error."
        source: "apps/web/AGENTS.md:1"

      shadowed:
        type: block
        files: ["lib/**/*"]
        context: rubric version
        text: "x"
        source: "CLAUDE.md:3"
    YAML
    project.rules('tools_rubric.yml', <<~YAML)
      _rubric:
        compiled_at: "2026-10-13"
        sources:
          - { path: CLAUDE.md, sha256: "#{sha('CLAUDE.md')}" }
          - { path: apps/web/AGENTS.md, sha256: "#{sha('apps/web/AGENTS.md')}" }

      use_pnpm:
        type: block
        tools: [Bash]
        pattern: '(?<![\\w-])npm\\s+install\\b'
        context: This repo uses pnpm.
        text: "Always use pnpm."
        source: "CLAUDE.md:4"
    YAML
  end

  def hand_written_shadow
    project.rules('write.yml', <<~YAML)
      shadowed:
        type: warn
        files: ["lib/**/*"]
        context: hand-written version
    YAML
  end

  def write(relative, content)
    project.write_hook(project.write_event(project.path(relative), content))
  end

  describe 'before compiling' do
    it 'lists the instruction files as new, from the working directory' do
      out = project.rubric('sources', chdir: project.root, env: { 'CLAUDE_PROJECT_DIR' => nil }).stdout

      expect(out).to include("CLAUDE.md  scope **/*  sha256 #{sha('CLAUDE.md')}  [new]")
      expect(out).to include('apps/web/AGENTS.md  scope apps/web/**/*'), 'nested file scoped to its directory'
      expect(out).to include("CONTRIBUTING.md  scope **/*  sha256 #{sha('CONTRIBUTING.md')}  [new]  (optional")
      expect(out).not_to include('node_modules'), 'vendored files are not sources'
      expect(out).to include('status: not compiled yet')
    end

    it 'has nothing to validate' do
      out = project.rubric('validate')

      expect(out.stdout).to include('Run /rules-compile')
      expect(out.exit_code).to eq(1)
    end
  end

  describe 'the hooks' do
    before do
      write_rubrics
      hand_written_shadow
    end

    it 'apply write_rubric rules before a write' do
      out = write('app/models/x.rb', 'default_scope { }')
      expect(out).to fire('no_default_scope')
      expect(out.exit_code).to eq(2)

      expect(write('app/models/x.rb', 'scope :active')).to be_silent, 'pattern miss stays silent'
      expect(write('app/models/x.rb', 'default_scope').stdout).not_to include('_rubric'), 'metadata is never a rule'
      expect(write('app/models/legacy/x.rb', 'default_scope { }')).to be_silent, 'exclude carves a path out'
    end

    it 'let a hand-written rule win a name clash' do
      out = write('lib/x.rb', 'anything')

      expect(out.stdout).to include('hand-written version')
      expect(out.stdout).not_to include('rubric version'), 'shadowed rubric rule does not run'
      expect(out.exit_code).to eq(0), 'hand-written warn does not block'
    end

    it 'apply tools_rubric rules before a tool call' do
      out = project.tool_hook(project.bash('npm install left-pad'))
      expect(out).to fire('use_pnpm')
      expect(out.exit_code).to eq(2)

      expect(project.tool_hook(project.bash('pnpm install left-pad'))).to be_silent, 'pattern miss stays silent'
      expect(project.tool_hook(project.grep('npm install', 'docs'))).to be_silent, 'tool rule keeps to its tools'
    end

    it 'replay write_rubric rules in the post-write sweep' do
      project.sweep({ session_id: 's' }, '--bootstrap')
      project.write('app/models/y.rb', "default_scope { where(x: 1) }\n")

      expect(project.sweep(project.bash('true'))).to fire('no_default_scope')
    end

    it 'judge write_rubric judge rules on Stop' do
      project.record('s')
      project.write('db/migrate/001_x.rb', "User.find_each { backfill }\n")

      expect(project.stop('s').stdout).to include('[semantic_backfill] db/migrate/001_x.rb')
    end
  end

  describe 'tool rules' do
    it 'fire inside their files and leave an excluded path alone' do
      project.rules('tools.yml', <<~YAML)
        no_legacy:
          type: warn
          tools: [Read]
          files: ["legacy/**/*"]
          exclude: ["legacy/README.md"]
          context: legacy is deprecated
      YAML

      expect(project.tool_hook(project.read(project.path('legacy/a.rb')))).to fire('no_legacy')
      expect(project.tool_hook(project.read(project.path('legacy/README.md')))).to be_silent
    end

    it 'are skipped, and reported, when they carry a judge' do
      project.rules('tools.yml', <<~YAML)
        judged_search:
          type: warn
          pattern: "left-pad"
          judge: { question: "Is this a bad idea?" }
          context: judged
      YAML

      out = project.tool_hook(project.bash('echo left-pad'))

      expect(out).not_to fire('judged_search')
      expect(out.stderr).to include('judge is not supported on tool rules')
    end
  end

  describe 'the legacy read.yml and read_rubric.yml' do
    before do
      write_rubrics
      project.rename_rules('tools_rubric.yml', 'read_rubric.yml')
    end

    it 'still load when the new names are absent' do
      expect(project.tool_hook(project.bash('npm install left-pad'))).to fire('use_pnpm')
      expect(project.rubric('validate').stdout).to include('read_rubric.yml: 1 rules')

      project.rules('read.yml', "old_name:\n  type: warn\n  pattern: \"left-pad\"\n  context: from read.yml\n")
      expect(project.tool_hook(project.bash('echo left-pad')).stdout).to include('from read.yml')
    end

    it 'give way to tools.yml once it exists, without being merged in' do
      project.rules('read.yml', "old_name:\n  type: warn\n  pattern: \"left-pad\"\n  context: from read.yml\n")
      project.rules('tools.yml', "new_name:\n  type: warn\n  pattern: \"left-pad\"\n  context: from tools.yml\n")

      out = project.tool_hook(project.bash('echo left-pad')).stdout

      expect(out).to include('from tools.yml')
      expect(out).not_to include('from read.yml')
    end
  end

  describe 'validate' do
    before do
      write_rubrics
      # Files for the rubric's globs to reach, so only `shadowed` reaches nothing.
      project.write('app/models/y.rb', "class Y; end\n")
      project.write('db/migrate/001_x.rb', "# migration\n")
    end

    it 'reports a name clash with a hand-written rule' do
      hand_written_shadow

      out = project.rubric('validate')

      expect(out.stdout).to include('shadowed: name is already used in write.yml')
      expect(out.exit_code).to eq(1)
    end

    it 'accepts a good rubric, summarises it, and notes what looks unintended' do
      out = project.rubric('validate')

      expect(out.stdout).to include('valid')
      expect(out.exit_code).to eq(0)
      expect(out.stdout).to include('write_rubric.yml: 3 rules (1 pattern, 1 judge, 0 detector, 1 match only), 1 skipped')
      expect(out.stdout).to include('tools_rubric.yml: 1 rules (1 pattern')
      expect(out.stdout).to include('note:  write_rubric.yml: shadowed: blocks every edit')
      expect(out.stdout).to include('shadowed: files (lib/**/*) match nothing in the repo yet')
      expect(out.stdout).not_to include('no_default_scope: files'), 'glob that matches a file is not noted'
    end

    it 'names everything wrong with a bad rubric' do
      project.rules('write_rubric.yml', <<~YAML)
        _rubric:
          sources:
            - { path: CLAUDE.md, sha256: "#{sha('CLAUDE.md')}" }
            - { path: gone.md, sha256: "abc" }
          skipped:
            - { text: "no reason given" }

        Bad-Name:
          type: block
          files: ["**/*"]
          context: x
          text: x
          source: "CLAUDE.md:1"

        no_files:
          type: warn
          pattern: '(unclosed'
          judge: { threshold: 3 }
          context: x
          text: x
          source: "elsewhere.md:1"

        no_provenance:
          type: deny
          files: ["**/*"]
          exclude: "lib/**/*"

        bad_detector:
          type: warn
          files: ["**/*"]
          context: x
          text: x
          source: "CLAUDE.md:1"

        wide_judge:
          type: warn
          files: ["**/*"]
          judge: { question: "q" }
          context: x
          text: x
          source: "CLAUDE.md:1"
      YAML
      project.rules('detectors/bad_detector.rb', "module Detectors; module Wrong; end; end\n")
      project.rules('tools_rubric.yml', <<~YAML)
        _rubric:
          sources:
            - { path: CLAUDE.md, sha256: "#{sha('CLAUDE.md')}" }
        judged_tool:
          type: block_once
          tools: [Bash, Edit]
          judge: { question: "q" }
          context: x
          text: x
          source: "CLAUDE.md:1"
        no_files:
          type: warn
          context: x
          text: x
          source: "CLAUDE.md:1"
      YAML

      out = project.rubric('validate')

      expect(out.exit_code).to eq(1)
      [
        'source gone.md does not exist',
        'skipped[0] needs text, source and reason',
        'Bad-Name: name must be snake_case',
        'wide_judge: asks the judge about every changed file',
        'no_files: files is empty',
        'no_files: pattern is not a valid Ruby regex',
        'no_files: judge.question is empty',
        'no_files: judge.threshold must be a number between 0 and 1',
        'no_files: source elsewhere.md is not listed',
        'no_provenance: type must be one of block, block_once, warn',
        'no_provenance: text is missing',
        'no_provenance: context is empty',
        'no_provenance: exclude must be a list of globs',
        'bad_detector: detectors/bad_detector.rb does not load or does not define Detectors::BadDetector.call',
        'tools_rubric.yml: judged_tool: type must be one of block, warn',
        'judged_tool: judge is not supported on tool rules',
        'judged_tool: tools has unknown names: Edit',
        'tools_rubric.yml: no_files: name is already used in write_rubric.yml',
      ].each { |issue| expect(out.stdout).to include(issue) }
    end

    it 'reports a rubric that does not parse' do
      project.rules('tools_rubric.yml', "not: [valid\n")

      expect(project.rubric('validate').stdout).to include('tools_rubric.yml: does not parse')
    end
  end

  describe 'sources, once compiled' do
    before { write_rubrics }

    it 'reports an up to date rubric' do
      out = project.rubric('sources').stdout

      expect(out).to include("CLAUDE.md  scope **/*  sha256 #{sha('CLAUDE.md')}  [unchanged]")
      expect(out).to include('[not compiled (optional)]'), 'optional source left out is not stale'
      expect(out).to include('status: up to date')
    end

    it 'reports a source edited since, and validate catches it too' do
      project.append('CLAUDE.md', "A new rule.\n")

      expect(project.rubric('sources').stdout).to include('status: out of date')
      expect(project.rubric('validate').stdout).to include('source CLAUDE.md has sha256')
    end
  end
end
