# An Abide rubric judged on Stop, against a fake judge server.
#
# Covers: off unless RULEKIT_ABIDE_RUBRIC is set, a model-checked rule is
# asked about and blocks, choice and score questions, scope and its every-file
# default, the rubric's own thresholds and the flag band between them, the
# rules left out (not model-checked, not active),
# a path in the variable, a write.yml rule of the same name winning or
# switching it off, the
# per-edit hooks never seeing these rules, and failing open on a bad rubric.

RSpec.describe 'an Abide rubric' do
  before(:context) { @judge = FakeJudge.new }
  after(:context) { @judge.stop }

  let(:judge) { @judge }
  let(:judge_env) { { 'RULEKIT_JUDGE_URL' => judge.url, 'RULEKIT_JUDGE_API_KEY' => 'test-key' } }
  let(:project) { Project.new(env: judge_env.merge('RULEKIT_ABIDE_RUBRIC' => '1')) }

  def model_rule(id, **extra)
    {
      id: id,
      text: "Rule #{id} as written.",
      source: { path: 'AGENTS.md', line: 7 },
      when: 'edit',
      check: { type: 'model', question: { type: 'boolean', instructions: "Does this break #{id}?" } },
      status: 'active',
    }.merge(extra)
  end

  def rubric(rules, **extra)
    JSON.generate({ version: 1, compiledAt: '2026-09-20T00:00:00.000Z', sources: [], rules: rules }.merge(extra))
  end

  let(:rules) do
    [
      model_rule('no-backfill-in-migration', scope: ['db/migrate/**/*.rb'], check: {
                   type: 'model',
                   question: {
                     type: 'boolean',
                     instructions: 'Does this migration move data?',
                     criteria: { true: 'User.find_each', false: 'add_index' },
                   },
                 }),
      model_rule('everywhere'),
      model_rule('switched-off', status: 'disabled'),
      model_rule('weak', status: 'weak'),
      model_rule('a-choice', scope: ['app/**/*'], check: {
                   type: 'model',
                   question: {
                     type: 'choice',
                     instructions: 'Where does it log?',
                     criteria: { stdout: 'puts', logger: 'Rails.logger' },
                     violating: ['stdout'],
                   },
                 }),
      model_rule('a-score', scope: ['app/**/*'], check: {
                   type: 'model',
                   question: {
                     type: 'score',
                     instructions: 'How much does this restate the code?',
                     criteria: ['not at all', 'in passing', 'line for line'],
                     violatingFrom: 2,
                   },
                 }),
      { id: 'for-the-linter', text: 'No var.', source: { path: 'AGENTS.md' }, check: { type: 'lint', how: 'no-var' } },
    ]
  end

  before do
    judge.requests.clear
    project.write('.abide/rubric.json', rubric(rules))
    project.git_init
  end

  after { project.cleanup }

  def changed(relative, line, session: 's')
    project.record(session)
    project.append(relative, "#{line}\n")
    project.stop(session)
  end

  it 'is not read unless the variable is set' do
    [nil, '', '0', 'false', 'off'].each_with_index do |value, index|
      env = { 'RULEKIT_ABIDE_RUBRIC' => value }
      project.record("off-#{index}", env: env)
      project.append("db/migrate/00#{index}_x.rb", "User.find_each { backfill }\n")

      expect(project.stop("off-#{index}", env: env)).to be_silent, "#{value.inspect} leaves it off"
    end
    expect(judge.requests).to be_empty, 'nothing is sent'
  end

  it 'judges a model-checked rule and blocks with the rule as written' do
    out = changed('db/migrate/001_x.rb', 'User.find_each { backfill }')

    expect(out.stdout).to include('"decision":"block"')
    expect(out).to fire('no-backfill-in-migration')
    expect(out.stdout).to include('db/migrate/001_x.rb: Rule no-backfill-in-migration as written. (AGENTS.md:7)')

    expect(judge.requests.last.questions.fetch('no-backfill-in-migration')).to eq(
      'type' => 'noul',
      'instructions' => 'Does this migration move data?',
      'criteria' => { 'true' => 'User.find_each', 'false' => 'add_index' },
    )
  end

  it 'asks choice and score questions and fires on the weight of the violating answers' do
    out = changed('app/x.rb', 'backfill')

    expect(out).to fire('a-choice')
    expect(out).to fire('a-score')
    questions = judge.requests.last.questions
    expect(questions.fetch('a-choice')).to eq(
      'type' => 'choice',
      'instructions' => 'Where does it log?',
      'criteria' => { 'stdout' => 'puts', 'logger' => 'Rails.logger' },
    )
    expect(questions.fetch('a-score')).to eq(
      'type' => 'score',
      'instructions' => 'How much does this restate the code?',
      'criteria' => ['not at all', 'in passing', 'line for line'],
    )

    out = changed('app/y.rb', 'nothing to see')
    expect(out).to be_silent, 'weight on the compliant answers does not fire'
  end

  it 'tells the user, not the agent, about a score in the flag band' do
    out = changed('app/x.rb', 'borderline')

    expect(out.stdout).to include('"systemMessage"')
    expect(out.stdout).to include('[a-choice] app/x.rb: Rule a-choice as written. (AGENTS.md:7) (scored 0.6)')
    expect(out.stdout).not_to include('"decision"')
    expect(out.stdout).not_to include('additionalContext')

    project.write('.abide/rubric.json', rubric(rules, thresholds: { act: 0.8, flag: 0.7 }))
    expect(changed('app/y.rb', 'borderline')).to be_silent, "below the rubric's own flag threshold nothing is said"
  end

  it 'leaves out rules that are not model-checked or not active' do
    changed('db/migrate/001_x.rb', 'User.find_each { backfill }')

    expect(judge.requests.last.questions.keys).to contain_exactly('no-backfill-in-migration', 'everywhere')

    changed('app/x.rb', 'backfill')
    expect(judge.requests.last.questions.keys).to contain_exactly('everywhere', 'a-choice', 'a-score')
  end

  it 'applies a rule with no scope to every file, and a scoped one only inside it' do
    out = changed('lib/anything.rb', 'backfill')

    expect(out).to fire('everywhere')
    expect(out).not_to fire('no-backfill-in-migration')
    expect(judge.requests.last.questions.keys).to eq(['everywhere'])
  end

  it 'does not judge the rubric itself' do
    project.record('s')
    project.write('.abide/rubric.json', rubric(rules, compiledBy: 'backfill'))

    expect(project.stop('s')).to be_silent
    expect(judge.requests).to be_empty
  end

  it "fires at the rubric's act threshold, 0.8 by default" do
    project.write('.abide/rubric.json', rubric(rules, thresholds: { act: 0.95, flag: 0.5 }))

    out = changed('lib/x.rb', 'backfill')

    expect(out.stdout).not_to include('"decision"'), 'the fake judge answers 0.9'
    expect(out.stdout).to include('"systemMessage"'), '0.9 is now in the flag band'
    expect(judge.requests.size).to eq(1)
  end

  it 'reads the rubric from a path in the variable' do
    project.write('rules/other.json', rubric([model_rule('from-elsewhere')]))
    project.record('s')
    project.append('lib/x.rb', "backfill\n")

    expect(project.stop('s', env: { 'RULEKIT_ABIDE_RUBRIC' => 'rules/other.json' })).to fire('from-elsewhere')
    project.append('lib/x.rb', "backfill again\n")
    expect(project.stop('s', env: { 'RULEKIT_ABIDE_RUBRIC' => project.path('rules/other.json') }))
      .to fire('from-elsewhere'), 'an absolute path works too'
  end

  it 'runs beside write.yml judge rules, which win a name clash' do
    project.rules('write.yml', <<~YAML)
      everywhere:
        type: warn
        files: ["lib/**/*"]
        judge:
          question: "Hand-written?"
        context: hand-written wins
      own_rule:
        type: warn
        files: ["lib/**/*"]
        judge:
          question: "Own?"
        context: own rule
    YAML

    out = changed('lib/x.rb', 'backfill')

    expect(out.stdout).to include('hand-written wins')
    expect(out).to fire('own_rule')
    expect(out.stdout).not_to include('Rule everywhere as written')
    expect(judge.requests.size).to eq(1), 'both kinds share one request per file'
  end

  it 'is switched off by enabled: false under the same name in write.yml' do
    project.rules('write.yml', <<~YAML)
      everywhere:
        enabled: false
    YAML

    out = changed('db/migrate/001_x.rb', 'User.find_each { backfill }')

    expect(out).to fire('no-backfill-in-migration')
    expect(out).not_to fire('everywhere')
    expect(judge.requests.last.questions.keys).to eq(['no-backfill-in-migration'])
  end

  it 'is never seen by the per-edit hooks' do
    expect(project.write_hook(project.write_event(project.path('lib/x.rb'), 'backfill'))).to be_silent
    project.sweep({ session_id: 's' }, '--bootstrap')
    project.append('lib/x.rb', "backfill\n")
    expect(project.sweep(project.bash('true'))).to be_silent
    expect(judge.requests).to be_empty
  end

  it 'fails open on a rubric that is missing, malformed, or another version' do
    wrong_shape = [
      rubric([{ id: 'x', check: 'model' }]),
      rubric([model_rule('x', check: { type: 'model', question: 'is it?' })]),
      rubric([model_rule('x', check: { type: 'model', question: { type: 'choice', instructions: 'Which?' } })]),
    ]
    [nil, '{ not json', '[]', rubric(rules, version: 2), *wrong_shape].each_with_index do |content, index|
      content.nil? ? FileUtils.rm(project.path('.abide/rubric.json')) : project.write('.abide/rubric.json', content)

      out = changed("lib/x#{index}.rb", 'backfill', session: "bad-#{index}")

      expect(out).to be_silent
      expect(out.exit_code).to eq(0)
    end
    expect(judge.requests).to be_empty
  end
end
