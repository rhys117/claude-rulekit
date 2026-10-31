# `judge:` rules and the Stop hook, against a fake judge server.
#
# Covers: the per-edit hooks leave `judge:` rules alone, Stop judges what the
# turn changed in one request per file, thresholds and the `pattern` prefilter,
# criteria, choice and score questions, the flag band,
# block vs warn output, an unchanged tree is not asked about twice, edits made
# between turns are not judged, the per-turn continuation cap, the env names
# and their TypeSafe fallbacks, and failing open when unconfigured or
# unreachable.

RSpec.describe 'judge rules' do
  before(:context) { @judge = FakeJudge.new }
  after(:context) { @judge.stop }

  let(:judge) { @judge }
  let(:project) { Project.new(env: { 'RULEKIT_JUDGE_URL' => judge.url, 'RULEKIT_JUDGE_API_KEY' => 'test-key' }) }

  before do
    judge.requests.clear
    project.rules('write.yml', <<~YAML)
      semantic_backfill:
        type: block
        files: ["db/migrate/**/*"]
        judge:
          question: "Does this migration backfill data?"
          threshold: 0.8
        context: Split the backfill into its own migration.

      strict_backfill:
        type: block
        files: ["db/migrate/**/*"]
        judge:
          question: "Is this certainly a backfill?"
          threshold: 0.95
        context: should never fire

      advisory:
        type: warn
        files: ["app/**/*"]
        judge:
          question: "Does this backfill?"
        context: Keep backfills out of app code.

      prefiltered:
        type: warn
        files: ["app/**/*"]
        pattern: 'never_matches_this'
        judge:
          question: "Anything?"
        context: should never fire

      detector_wins:
        type: warn
        files: ["lib/**/*"]
        judge:
          question: "Anything?"
        context: detector wins
    YAML
    project.rules('detectors/detector_wins.rb', <<~RUBY)
      module Detectors
        module DetectorWins
          def self.call(**) = true
        end
      end
    RUBY
    project.git_init
  end

  after { project.cleanup }

  def add(relative, line)
    project.append(relative, "#{line}\n")
  end

  describe 'the per-edit hooks' do
    it 'leave judge rules to Stop' do
      out = project.write_hook(project.write_event(project.path('db/migrate/001_x.rb'), 'User.find_each { backfill }'))
      expect(out).to be_silent, 'pre-write hook skips judge rules'
      expect(out.exit_code).to eq(0)

      project.sweep({ session_id: 's' }, '--bootstrap')
      add 'db/migrate/001_x.rb', 'User.find_each { backfill slug }'
      expect(project.sweep(project.bash('true'))).to be_silent, 'post-write sweep skips judge rules'

      expect(judge.requests).to be_empty, 'per-edit hooks make no request'
    end

    it 'still let a detector file decide before the write' do
      expect(project.write_hook(project.write_event(project.path('lib/x.rb'), 'anything'))).to fire('detector_wins')
    end
  end

  describe 'Stop' do
    it 'only records on the first pass of a session' do
      add 'db/migrate/001_x.rb', 'User.find_each { backfill slug }'

      expect(project.stop('s1')).to be_silent
      expect(judge.requests).to be_empty
    end

    it 'is silent on a record pass' do
      expect(project.record('s2')).to be_silent
    end

    it 'judges what the turn changed, one request per matching file' do
      add 'db/migrate/001_x.rb', 'User.find_each { backfill slug }'
      project.record('s2')
      add 'db/migrate/002_x.rb', 'User.find_each { backfill slug }'
      add 'db/migrate/003_x.rb', 'add_index :users, :email'
      add 'lib/y.rb', 'backfill'

      out = project.stop('s2')

      expect(out.stdout).to include('"decision":"block"'), 'block rule holds the turn open'
      expect(out).to fire('semantic_backfill')
      expect(out.stdout).to include('db/migrate/002_x.rb: Split the backfill'), 'finding names the file'
      expect(out.stdout).not_to include('strict_backfill'), 'below its threshold a rule stays silent'
      expect(out.stdout).not_to include('003_x.rb'), 'file below threshold is not named'
      expect(out.stdout).not_to include('detector_wins'), 'detector-backed rule is not asked about'
      expect(out.exit_code).to eq(0)

      expect(judge.requests.size).to eq(2), 'one request per matching file'
      request = judge.requests.find { |r| r.state.include?('002_x') }
      expect(request.questions.dig('strict_backfill', 'type')).to eq('noul'), 'request carries every matching rule'
      expect(request.authorization).to eq('Bearer test-key')
      expect(request.body['model']).to eq('jev-latest')
      expect(judge.requests.map(&:state).join).not_to include('001_x'), 'files changed before the turn are not judged'
    end

    it 'does not judge an unchanged tree twice' do
      project.record('s2')
      add 'db/migrate/002_x.rb', 'User.find_each { backfill slug }'
      project.stop('s2')

      expect { expect(project.stop('s2')).to be_silent }.not_to(change { judge.requests.size })
    end

    it 'judges a deleted file again when the same content is written back' do
      project.record('s2')
      add 'db/migrate/002_x.rb', 'User.find_each { backfill slug }'
      expect(project.stop('s2')).to fire('semantic_backfill')

      FileUtils.rm(project.path('db/migrate/002_x.rb'))
      project.record('s2')
      add 'db/migrate/002_x.rb', 'User.find_each { backfill slug }'

      expect { expect(project.stop('s2')).to fire('semantic_backfill') }.to change { judge.requests.size }.by(1)
    end

    it 'judges a reverted tracked file again when the same change is made again' do
      project.write('db/migrate/002_x.rb', "add_index :users, :email\n")
      project.git_commit_all('migration')
      project.record('s2')
      add 'db/migrate/002_x.rb', 'User.find_each { backfill slug }'
      expect(project.stop('s2')).to fire('semantic_backfill')

      project.write('db/migrate/002_x.rb', "add_index :users, :email\n")
      project.record('s2')
      add 'db/migrate/002_x.rb', 'User.find_each { backfill slug }'

      expect(project.stop('s2')).to fire('semantic_backfill')
      expect(judge.requests.last.state).not_to include('add_index'), 'only the lines added since HEAD are sent'
    end

    it 'judges what the turn committed, against the commit the turn started from' do
      project.write('db/migrate/002_x.rb', "add_index :users, :email\n")
      project.git_commit_all('before the turn')
      project.record('s2')
      add 'db/migrate/002_x.rb', 'User.find_each { backfill slug }'
      project.git_commit_all('during the turn')

      expect(project.stop('s2')).to fire('semantic_backfill')
      expect(judge.requests.size).to eq(1)
      expect(judge.requests.last.state).not_to include('add_index'), 'lines from before the turn are not sent'
    end

    it 'judges only what the turn added to a file that was already dirty, once committed' do
      project.write('db/migrate/002_x.rb', "add_index :users, :email\n")
      project.git_commit_all('before the turn')
      add 'db/migrate/002_x.rb', 'remove_index :users, :name'
      project.record('s2')
      add 'db/migrate/002_x.rb', 'User.find_each { backfill slug }'
      project.git_commit_all('during the turn')

      expect(project.stop('s2')).to fire('semantic_backfill')
      expect(judge.requests.last.state).not_to include('remove_index'), 'edits made before the turn are not sent'
    end

    it 'leaves what a merge brought in to the branch that wrote it' do
      project.git_commit_all('rules')
      project.git('checkout', '-q', '-b', 'side')
      add 'db/migrate/005_x.rb', 'User.find_each { backfill slug }'
      project.git_commit_all('on side')
      project.git('checkout', '-q', '-')
      project.record('s2')
      project.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'merge', '-q', '--no-ff', '-m', 'merge side', 'side')

      expect(project.stop('s2')).to be_silent
      expect(judge.requests).to be_empty
    end

    it 'returns a warn rule as feedback, skips a pattern miss, and ignores edits made between turns' do
      project.record('s2')
      add 'db/migrate/004_user_edit.rb', 'backfill by hand'
      project.record('s2')
      add 'app/models/x.rb', 'def backfill; end'

      out = project.stop('s2')

      expect(out.stdout).to include('"additionalContext":"[advisory] app/models/x.rb'), 'warn rule comes back as feedback'
      expect(out.stdout).to include('"hookEventName":"Stop"')
      expect(out.stdout).not_to include('"decision"'), 'warn rule does not block'
      expect(judge.requests.size).to eq(1), 'edits made between turns are not judged'
      expect(judge.requests.last.questions).not_to have_key('prefiltered'), 'pattern miss is not asked'
    end

    describe 'beyond a bare yes/no' do
      before do
        project.rules('write.yml', <<~YAML)
          with_criteria:
            type: block
            files: ["lib/**/*"]
            judge:
              question: "Does this backfill?"
              flag: 0.5
              criteria:
                true: "find_each with update"
                false: "add_index"
            context: yes or no

          logs_to_stdout:
            type: warn
            files: ["lib/**/*"]
            judge:
              type: choice
              question: "Where does it log?"
              criteria:
                stdout: "puts or print"
                logger: "Rails.logger"
              violating: [stdout]
            context: Use the logger.

          restates_code:
            type: warn
            files: ["lib/**/*"]
            judge:
              type: score
              question: "How much does this comment restate the code?"
              criteria: ["not at all", "in passing", "line for line"]
              violating_from: 2
            context: Say why, not what.

          half_a_choice:
            type: block
            files: ["lib/**/*"]
            judge:
              type: choice
              question: "Which?"
            context: never asked
        YAML
        project.record('s5')
      end

      it 'sends criteria with the question, and each shape as its own type' do
        add 'lib/x.rb', 'backfill'

        out = project.stop('s5')

        expect(out).to fire('with_criteria')
        expect(out).to fire('logs_to_stdout')
        expect(out).to fire('restates_code')
        questions = judge.requests.last.questions
        expect(questions['with_criteria']).to eq(
          'type' => 'noul', 'instructions' => 'Does this backfill?',
          'criteria' => { 'true' => 'find_each with update', 'false' => 'add_index' }
        )
        expect(questions.dig('logs_to_stdout', 'type')).to eq('choice')
        expect(questions.dig('restates_code', 'criteria')).to eq(['not at all', 'in passing', 'line for line'])
        expect(questions).not_to have_key('half_a_choice'), 'a choice with no options is not asked'
      end

      it 'notes a score between flag and threshold for the user, only on a rule that sets flag' do
        add 'lib/x.rb', 'borderline'

        out = project.stop('s5')

        expect(out.stdout).to include('"systemMessage"')
        expect(out.stdout).to include('[with_criteria] lib/x.rb: yes or no (scored 0.6)')
        expect(out.stdout).not_to include('logs_to_stdout'), 'a rule with no flag stays silent below its threshold'
        expect(out.stdout).not_to include('"decision"')
      end

      it 'sends a flag note alongside a finding' do
        add 'lib/x.rb', 'backfill'
        add 'lib/y.rb', 'borderline'

        out = project.stop('s5')

        expect(out.stdout).to include('"decision":"block"')
        expect(out.stdout).to include('[with_criteria] lib/y.rb: yes or no (scored 0.6)')
      end
    end

    it 'keeps one turn open at most twice, then tells the user instead' do
      project.record('s3')
      add 'db/migrate/010_x.rb', 'backfill one'
      expect(project.stop('s3').stdout).to include('"decision":"block"'), 'first finding blocks'

      add 'db/migrate/010_x.rb', 'backfill two'
      expect(project.stop('s3').stdout).to include('"decision":"block"'), 'the repair is re-checked and can block'

      add 'db/migrate/010_x.rb', 'backfill three'
      out = project.stop('s3')
      expect(out.stdout).to include('"systemMessage"'), 'past the cap the user is told instead'
      expect(out.stdout).not_to include('"decision"'), 'past the cap the turn may end'

      project.record('s3')
      add 'db/migrate/010_x.rb', 'backfill four'
      expect(project.stop('s3').stdout).to include('"decision":"block"'), 'a fresh prompt starts the count again'
    end
  end

  describe 'configuration' do
    before do
      project.record('s4')
      add 'db/migrate/020_x.rb', 'backfill'
    end

    it 'stays silent and sends nothing when neither a key nor a url is set' do
      out = project.stop('s4', env: { 'RULEKIT_JUDGE_URL' => nil, 'RULEKIT_JUDGE_API_KEY' => nil })

      expect(out).to be_silent
      expect(out.exit_code).to eq(0)
      expect(judge.requests).to be_empty
    end

    it 'runs on a url alone, for a keyless backend, with the model from the environment' do
      out = project.stop('s4', env: { 'RULEKIT_JUDGE_API_KEY' => nil, 'RULEKIT_JUDGE_MODEL' => 'english' })

      expect(out.stdout).to include('020_x.rb')
      expect(judge.requests.last.authorization).to be_nil, 'keyless request sends no bearer'
      expect(judge.requests.last.body['model']).to eq('english')
    end

    it 'falls back to the TypeSafe env names' do
      out = project.stop('s4', env: { 'RULEKIT_JUDGE_URL' => nil, 'RULEKIT_JUDGE_API_KEY' => nil,
                                      'TYPESAFE_AI_BASE_URL' => judge.url, 'TYPESAFE_AI_API_KEY' => 'ts-key' })

      expect(out.stdout).to include('020_x.rb')
      expect(judge.requests.last.authorization).to eq('Bearer ts-key')
    end

    it 'falls back to the default timeout when the one given is unusable' do
      out = project.stop('s4', env: { 'RULEKIT_JUDGE_TIMEOUT' => 'soon' })

      expect(out.stdout).to include('020_x.rb')
    end
  end

  it 'fails open when the judge is unreachable, and marks it down' do
    gone = FakeJudge.new
    gone.stop
    project.record('s5')
    add 'db/migrate/030_x.rb', 'backfill'
    add 'db/migrate/031_x.rb', 'backfill'

    out = project.stop('s5', env: { 'RULEKIT_JUDGE_URL' => gone.url })

    expect(out).to be_silent
    expect(out.exit_code).to eq(0)
    expect(File).to exist(File.join(project.session_dir('s5'), 'judge-down'))
  end
end
