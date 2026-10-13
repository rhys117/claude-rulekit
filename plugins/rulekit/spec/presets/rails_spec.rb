# The Rails preset, against the rulekit engine.
#
# CLAUDE_RULES_DIR points the hooks at presets/rails, so these are the rules
# and detectors a project gets from `/rules-init rails`. Every rule has a case
# that fires and, where it matters, one that stays silent. The last group
# drives the post-write sweep against a real git repo, since it reads the
# working tree rather than the tool call.

RSpec.describe 'the Rails preset' do
  let(:project) { Project.new(env: { 'CLAUDE_RULES_DIR' => File.join(Project::PLUGIN_ROOT, 'presets', 'rails') }) }

  after { project.cleanup }

  def edit(file_path, new_string)
    project.write_hook(project.edit(file_path, new_string))
  end

  def write(file_path, content)
    project.write_hook(project.write_event(file_path, content))
  end

  def migration(body)
    "class X < ActiveRecord::Migration[8.0]\n#{body}\nend"
  end

  describe 'tools.yml' do
    describe 'broad_search_advisory' do
      it 'fires once per session on a recursive grep over a source root' do
        event = project.bash('grep -r foo app/')

        out = project.tool_hook(event)
        expect(out).to fire('broad_search_advisory')
        expect(out.exit_code).to eq(0)

        expect(project.tool_hook(event)).to be_silent, 'second broad grep silenced (once_per_session)'
      end

      it 'fires on a Grep over a source root' do
        expect(project.tool_hook(project.grep('foo', 'app'))).to fire('broad_search_advisory')
      end

      it 'stays silent on a narrow path' do
        expect(project.tool_hook(project.grep('foo', 'app/models/order.rb'))).to be_silent
      end

      it 'stays silent on a directory that is not one of its roots' do
        expect(project.tool_hook(project.grep('foo', 'src'))).to be_silent
      end

      it 'stays silent on a tool it does not list' do
        out = project.tool_hook(project.read('x'))

        expect(out).to be_silent
        expect(out.exit_code).to eq(0)
      end
    end
  end

  describe 'write.yml' do
    describe 'no_default_scope' do
      it 'blocks a default_scope in a model' do
        out = edit('app/models/post.rb', "class Post\n  default_scope { where(active: true) }\nend")

        expect(out).to fire('no_default_scope')
        expect(out.stdout).to include('permissionDecision')
        expect(out.exit_code).to eq(2)
      end

      it 'leaves a plain model edit alone' do
        expect(edit('app/models/post.rb', "class Post\nend")).not_to fire('no_default_scope')
      end
    end

    describe 'ruby_vs_sql' do
      it 'warns on all.map' do
        out = edit('app/models/post.rb', '  names = Comment.all.map(&:name)')

        expect(out).to fire('ruby_vs_sql')
        expect(out.exit_code).to eq(0)
      end
    end

    describe 'view_query_logic' do
      it 'fires on a model query in a view' do
        out = edit('app/views/posts/index.html.erb', '<%= Post.where(active: true).count %>')

        expect(out).to fire('view_query_logic')
      end

      it 'stays silent on plain markup' do
        expect(edit('app/views/posts/index.html.erb', '<div>hello</div>')).to be_silent
      end
    end

    describe 'spec_let_fixture_nudge' do
      it 'fires on a let in a spec' do
        expect(edit('spec/models/post_spec.rb', '  let(:post) { build(:post) }')).to fire('spec_let_fixture_nudge')
      end

      it 'stays silent on a spec edit without one' do
        expect(edit('spec/models/post_spec.rb', '  before { sign_in user }')).to be_silent
      end
    end

    describe 'service_call_idiom (block_once)' do
      it 'blocks a def call the first time and yields on the retry' do
        first = edit('app/services/charge.rb', "  def call\n    do_thing\n  end")
        expect(first).to fire('service_call_idiom')
        expect(first.exit_code).to eq(2)

        retried = edit('app/services/charge.rb', "  def call\n    do_thing\n  end")
        expect(retried).not_to fire('service_call_idiom')
        expect(retried.exit_code).to eq(0)
      end

      it 'does not fire on a method that only starts with call' do
        expect(edit('app/models/widget.rb', "  def caller_id\n    1\n  end")).not_to fire('service_call_idiom')
      end
    end

    describe 'service_design_advisory' do
      it 'fires on an edit to a service file' do
        out = edit('app/services/report.rb', "  def perform\n    build_report\n  end")

        expect(out).to fire('service_design_advisory')
        expect(out.exit_code).to eq(0)
      end
    end

    describe 'migration_backfill (detector)' do
      it 'fires on a NOT NULL column backfilled in the same migration' do
        out = write('db/migrate/20260101000000_x.rb', migration(<<~RUBY.chomp))
          def up
            add_column :posts, :slug, :string, null: false
            Post.find_each { |p| p.update!(slug: p.title.parameterize) }
          end
        RUBY

        expect(out).to fire('migration_backfill')
        expect(out).to fire('migration_design_advisory')
        expect(out.exit_code).to eq(0)
      end

      it 'does not fire on a fresh table' do
        out = write('db/migrate/20260101000001_x.rb', migration(<<~RUBY.chomp))
          def change
            create_table :widgets do |t|
              t.string :name, null: false
            end
            Widget.find_each { |w| w.update!(name: "x") }
          end
        RUBY

        expect(out).not_to fire('migration_backfill')
        expect(out).to fire('migration_design_advisory'), 'the migration was still evaluated'
        expect(out.exit_code).to eq(0)
      end
    end

    describe 'migration_missing_fk_index (detector)' do
      it 'fires on a foreign key column without an index, and names the column' do
        out = write('db/migrate/20260101000002_x.rb', migration(<<~RUBY.chomp))
          def change
            add_column :posts, :author_id, :bigint
          end
        RUBY

        expect(out).to fire('migration_missing_fk_index')
        expect(out.stdout).to include('author_id')
      end

      it 'does not fire when the index is added too' do
        out = write('db/migrate/20260101000003_x.rb', migration(<<~RUBY.chomp))
          def change
            add_column :posts, :author_id, :bigint
            add_index :posts, :author_id
          end
        RUBY

        expect(out).not_to fire('migration_missing_fk_index')
      end
    end

    describe 'model_wrapper_delegation (detector)' do
      it 'fires on a model with extracted siblings on disk, and names the sibling' do
        project.write('app/models/order.rb', "class Order < ApplicationRecord; end\n")
        project.write('app/models/order/line_item.rb', "class Order::LineItem; end\n")

        out = edit(project.path('app/models/order.rb'), "  def total\n    1\n  end")

        expect(out).to fire('model_wrapper_delegation')
        expect(out.stdout).to include('line_item')
        expect(out.exit_code).to eq(0)
      end
    end

    describe 'sql_injection (block_once)' do
      it 'blocks an interpolated where the first time and yields on the retry' do
        interpolated = %q(  scope :by_name, ->(q) { where("name = '#{q}'") })

        first = edit('app/models/post.rb', interpolated)
        expect(first).to fire('sql_injection')
        expect(first.exit_code).to eq(2)

        retried = edit('app/models/post.rb', interpolated)
        expect(retried).not_to fire('sql_injection')
        expect(retried.exit_code).to eq(0)
      end

      it 'does not fire on a parameterized where' do
        out = edit('app/models/post.rb', '  scope :by_name, ->(q) { where("name = ?", q) }')

        expect(out).not_to fire('sql_injection')
      end
    end

    describe 'bare_rescue' do
      it 'fires on a rescue with no class' do
        out = edit('app/clients/sync.rb', "    do_work\n  rescue => e\n    nil\n  end")

        expect(out).to fire('bare_rescue')
        expect(out.exit_code).to eq(0)
      end

      it 'does not fire on a rescue that names its class' do
        out = edit('app/clients/sync.rb', "    do_work\n  rescue Net::ReadTimeout => e\n    retry\n  end")

        expect(out).not_to fire('bare_rescue')
      end
    end

    describe 'migration_model_reference' do
      it 'fires on a model referenced in a migration' do
        out = write('db/migrate/20260101000010_x.rb', migration(<<~RUBY.chomp))
          def up
            User.where(active: true).find_each { |u| u.touch }
          end
        RUBY

        expect(out).to fire('migration_model_reference')
        expect(out.exit_code).to eq(0)
      end

      it 'does not fire on a plain add_column' do
        out = write('db/migrate/20260101000011_x.rb', migration(<<~RUBY.chomp))
          def change
            add_column :posts, :title, :string
          end
        RUBY

        expect(out).not_to fire('migration_model_reference')
      end
    end

    describe 'missing_http_timeout (detector)' do
      it 'fires on an HTTP call with no timeout' do
        out = edit('app/clients/payment_client.rb', "  def fetch\n    Net::HTTP.get(URI(url))\n  end")

        expect(out).to fire('missing_http_timeout')
        expect(out.exit_code).to eq(0)
      end

      it 'does not fire when a timeout is set' do
        out = edit('app/clients/payment_client.rb',
                   "  def fetch\n    Net::HTTP.start(host, port, open_timeout: 5, read_timeout: 5)\n  end")

        expect(out).not_to fire('missing_http_timeout')
      end
    end

    describe 'validates_uniqueness_no_index (detector)' do
      # A schema with a unique index on email but none on username.
      before do
        project.write('db/schema.rb', <<~RUBY)
          add_index "users", ["email"], name: "idx_users_email", unique: true
          add_index "users", ["company_id"], name: "idx_users_company"
        RUBY
      end

      it 'fires on a uniqueness validation with no unique index, and names the column' do
        out = edit(project.path('app/models/account.rb'), '  validates :username, uniqueness: true')

        expect(out).to fire('validates_uniqueness_no_index')
        expect(out.stdout).to include('username')
        expect(out.exit_code).to eq(0)
      end

      it 'does not fire when the column has a unique index' do
        out = edit(project.path('app/models/account.rb'), '  validates :email, uniqueness: true')

        expect(out).not_to fire('validates_uniqueness_no_index')
      end
    end

    describe 'sorbet_inline_rbs_advisory (detector)' do
      it 'fires on a def with no signature' do
        out = edit('app/jobs/cleanup_job.rb', "  def perform\n    1\n  end")

        expect(out).to fire('sorbet_inline_rbs_advisory')
        expect(out.exit_code).to eq(0)
      end

      it 'stays silent on a signed def in a typed file' do
        out = edit('app/jobs/cleanup_job.rb', "# typed: true\n  #: -> Integer\n  def perform\n    1\n  end")

        expect(out).to be_silent
      end
    end
  end

  describe 'the post-write sweep, for writes that bypass Edit and Write' do
    let(:tool_call) { project.bash('true') }

    before do
      project.git_init
      project.write('.gitignore', "tmp/\n")
      project.write('app/models/order.rb', <<~RUBY)
        class Order < ApplicationRecord
          def legacy
            risky
          rescue
            nil
          end
        end
      RUBY
      project.git_commit_all('base')
      @bootstrap = project.sweep({ session_id: 's' }, '--bootstrap')
    end

    def sweep
      project.sweep(tool_call)
    end

    it 'only records the starting state on bootstrap' do
      expect(@bootstrap).to be_silent
    end

    it 'catches a default_scope after the fact, as a block rather than a deny, and only once' do
      project.write('app/models/post.rb', "class Post < ApplicationRecord\n  default_scope { where(active: true) }\nend\n")

      out = sweep
      expect(out).to fire('no_default_scope')
      expect(out.stdout).to include('"decision":"block"')
      expect(out.stdout).not_to include('permissionDecision'), 'a write that landed cannot be denied'
      expect(out.exit_code).to eq(0)

      expect(sweep).to be_silent, 'unchanged tree re-sweeps silently'
    end

    it 'scans only the lines added, so what a touched file already had stays quiet' do
      project.append('app/models/order.rb', "\n# harmless trailing comment\n")
      expect(sweep).to be_silent

      project.append('app/models/order.rb', "\ndef fresh\n  thing rescue nil\nend\n")
      expect(sweep).to fire('bare_rescue')
    end

    it 'does not re-check a Write the pre-write hook already saw' do
      project.write('app/services/thing.rb', "class Thing\n  def self.call\n    1\n  end\nend\n")

      out = project.sweep(project.write_event(project.path('app/services/thing.rb'), nil))

      expect(out).to be_silent
    end

    it 'records a git state move without evaluating it, then or later' do
      project.write('app/models/widget.rb', "class Widget\n  default_scope { all }\nend\n")

      expect(project.sweep(project.bash('git checkout -- .'))).to be_silent
      expect(sweep).to be_silent, 'files recorded by a git state move do not fire later'
    end

    # A branch can sit dirty in far more files than one tool call ever touches.
    # The cap has to count what moved since the last sweep, or a big working
    # tree turns the sweep off for the rest of the session.
    it 'only records when 40 files move at once, and still fires on the next single file' do
      (1..40).each { |i| project.write("app/models/noise_#{i}.rb", "class Noise#{i}\n  default_scope { all }\nend\n") }
      expect(sweep).to be_silent, '40 files at once exceeds the cap, whatever is in them'

      project.write('app/models/late.rb', "class Late < ApplicationRecord\n  default_scope { all }\nend\n")
      expect(sweep).to fire('no_default_scope')
    end
  end
end
