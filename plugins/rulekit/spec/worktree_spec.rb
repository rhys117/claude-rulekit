# CLAUDE_PROJECT_DIR stays on the checkout a session started in, even after the
# session moves into a git worktree. Paths are matched relative to the checkout
# that holds the file, and the sweep reads that checkout.

RSpec.describe 'a git worktree session' do
  let(:project) { Project.new }

  after { project.cleanup }

  before do
    project.git_init
    project.write('app/services/kept.rb', "class Kept\nend\n")
    project.git_commit_all('base')
    project.rules('write.yml', <<~YAML)
      no_default_scope:
        type: block
        files: ["app/services/**/*"]
        pattern: 'default_scope'
        context: Scope at the call site.
    YAML
  end

  def worktree_path(relative)
    File.join(project.worktree, relative)
  end

  it 'blocks an edit to a matching file in the worktree' do
    out = project.write_hook(project.edit(worktree_path('app/services/fresh.rb'), 'default_scope { all }'))

    expect(out).to fire('no_default_scope')
    expect(out.exit_code).to eq(2)
  end

  it 'leaves a clean edit in the worktree alone' do
    out = project.write_hook(project.edit(worktree_path('app/services/kept.rb'), "def fine\n  1\nend"))

    expect(out).to be_silent
    expect(out.exit_code).to eq(0)
  end

  it 'fires a tool rule on a Read of a matching file in the worktree' do
    project.rules('tools.yml', <<~YAML)
      no_service_reads:
        type: block
        tools: [Read]
        files: ["app/services/**/*"]
        context: Do not open service files.
    YAML

    out = project.tool_hook(project.read(worktree_path('app/services/kept.rb')))

    expect(out).to fire('no_service_reads')
    expect(out.exit_code).to eq(2)
  end

  it 'catches a shell write in the worktree' do
    project.sweep({ session_id: 's', cwd: project.worktree }, '--bootstrap')
    File.write(worktree_path('app/services/sneaky.rb'), "class Sneaky\n  default_scope { all }\nend\n")

    out = project.sweep(project.bash('cat > app/services/sneaky.rb').merge(cwd: project.worktree))

    expect(out).to fire('no_default_scope')
    expect(out.stdout).to include('"decision":"block"')
    expect(out.exit_code).to eq(0)
  end
end
