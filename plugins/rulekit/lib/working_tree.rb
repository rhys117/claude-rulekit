require 'digest'
require 'fileutils'

# What changed on disk, for the hooks that guard the working tree rather than a
# tool call (post-write-sweep.rb and stop-rules-check.rb).
#
# `git status` supplies the candidate set (cheap, and it respects .gitignore).
# Content comes from a per-session snapshot of each file's last-seen state, so
# the lines handed to a rule are the ones added since the caller last looked —
# not the whole file, and not the whole branch diff. Each caller keeps its own
# Snapshots, because each has its own idea of "last looked".
module WorkingTree
  # Skip anything bigger; it is generated or vendored, not hand-written.
  MAX_BYTES = 512 * 1024

  # Above this many files moving at once, callers record and stay silent: that
  # is history arriving, not code being authored. Counted against what moved
  # since the caller last looked, not against everything the branch has dirty,
  # so a big working tree does not switch a hook off.
  MAX_FILES = 25

  # Record of each changed file's last-seen content. The diff against it is
  # what gets evaluated; writing it back is what keeps a rule from re-firing
  # until the file changes again.
  class Snapshots
    def initialize(dir)
      @dir = dir
    end

    def initialized?
      File.exist?(marker)
    end

    def initialize!
      FileUtils.mkdir_p(@dir)
      FileUtils.touch(marker)
    end

    def read(relative_path)
      path = path_for(relative_path)
      File.exist?(path) ? scrub(File.read(path, mode: 'r:UTF-8')) : nil
    end

    # A cheap "has this moved since we last looked?" so a pass only reads the
    # files that were touched. The snapshot is written straight after the
    # source is read, so an untouched file's snapshot is never older than it.
    def stale?(relative_path, source_path)
      snapshot = path_for(relative_path)
      return true unless File.exist?(snapshot)

      File.mtime(source_path) > File.mtime(snapshot)
    end

    def write(relative_path, content)
      FileUtils.mkdir_p(@dir)
      File.write(path_for(relative_path), content, mode: 'w:UTF-8')
    end

    # Drops every snapshot but those of `relative_paths`. A file git no longer
    # calls dirty is either gone or back at HEAD, and its old snapshot would
    # hide the same lines if they were written again.
    def keep_only(relative_paths)
      kept = relative_paths.map { |relative_path| path_for(relative_path) }
      FileUtils.rm_f(Dir.glob(File.join(@dir, '*')) - kept)
    end

    private

    def marker
      File.join(@dir, '.initialized')
    end

    # Hashed so a path's separators and length cannot escape the snapshot dir.
    def path_for(relative_path)
      File.join(@dir, Digest::SHA256.hexdigest(relative_path))
    end

    def scrub(text)
      text.valid_encoding? ? text : text.scrub
    end
  end

  # One changed file. `base` is the revision its unsnapshotted content is
  # measured against: HEAD for a dirty tracked file, the caller's `since` for
  # one a commit since then touched, nil for a file with no committed past.
  Change = Struct.new(:base, :repo_path, :absolute, :relative)

  module_function

  def git(project_dir, *args)
    output = IO.popen(['git', '-C', project_dir, *args], err: File::NULL, &:read)
    return nil unless $?.success?

    output.force_encoding('UTF-8').scrub
  end

  # [[status_code, repo_relative_path], ...]. NUL-delimited so paths with spaces
  # survive; rename and copy entries carry a trailing source path to consume.
  def changed_entries(project_dir)
    raw = git(project_dir, 'status', '--porcelain', '--untracked-files=all', '-z')
    return nil if raw.nil?

    fields = raw.split("\0")
    entries = []

    until fields.empty?
      field = fields.shift
      next if field.nil? || field.length < 4

      code = field[0, 2]
      entries << [code, field[3..]]
      fields.shift if code.start_with?('R', 'C')
    end

    entries
  end

  # Repo paths touched by the commits made on this branch since `since`,
  # leaving out merges: a merge brings in other people's history, not code
  # written here. Empty when HEAD no longer descends from `since` (a reset or
  # a branch switch), since the commits between them are not this branch's.
  def committed_paths(project_dir, since)
    return [] if since.nil? || git(project_dir, 'merge-base', '--is-ancestor', since, 'HEAD').nil?

    git(project_dir, '-c', 'core.quotePath=false', 'log', '--first-parent', '--no-merges',
        '--format=', '--name-only', "#{since}..HEAD").to_s.lines(chomp: true).reject(&:empty?).uniq
  end

  # Everything git calls dirty, plus everything committed since `since` when
  # given, narrowed to what has actually moved since `snapshots` last saw it.
  # A long-lived branch is dirty in dozens of files; only the handful touched
  # since then are worth reading. Returns nil outside a git repo. Snapshots of
  # files outside that set are dropped: a deleted untracked file leaves
  # `git status` altogether, as does a tracked one that was reverted.
  def moved_files(project_dir, snapshots, since: nil)
    repo_root = git(project_dir, 'rev-parse', '--show-toplevel')&.strip
    return nil if repo_root.nil? || repo_root.empty?

    entries = changed_entries(project_dir)
    return nil if entries.nil?

    committed = committed_paths(project_dir, since)
    bases = entries.to_h { |code, repo_path| [repo_path, code.start_with?('?') ? nil : 'HEAD'] }
    committed.each { |repo_path| bases[repo_path] = since }

    project_root = real_path(project_dir)
    scratch_root = File.join(project_root, 'tmp', '.claude-advisory')

    changed = bases.filter_map do |repo_path, base|
      absolute = File.expand_path(File.join(repo_root, repo_path))
      next unless absolute.start_with?("#{project_root}/")
      next if absolute.start_with?("#{scratch_root}/") # the hooks' own snapshots
      next unless File.file?(absolute)

      Change.new(base, repo_path, absolute, absolute[(project_root.length + 1)..])
    end
    snapshots.keep_only(changed.map(&:relative))

    changed.select do |change|
      File.size(change.absolute) <= MAX_BYTES && snapshots.stale?(change.relative, change.absolute)
    end
  end

  # What `change` looked like when `snapshots` last saw it, or failing that, at
  # its base revision. A file absent there is new in full.
  def baseline(project_dir, snapshots, change)
    snapshots.read(change.relative) ||
      (change.base ? git(project_dir, 'show', "#{change.base}:#{change.repo_path}").to_s : '')
  end

  # Records the current state of each change in `snapshots` and yields it with
  # the lines added since the previous snapshot, skipping files that are
  # binary or gained nothing.
  def each_addition(project_dir, snapshots, changes)
    changes.each do |change|
      content = read_source(change.absolute)
      next if content.nil?

      added = added_lines(baseline(project_dir, snapshots, change), content)
      snapshots.write(change.relative, content)
      yield change, added unless added.strip.empty?
    end
  end

  # Lines present in `current` that `baseline` does not account for, in order.
  # A multiset difference rather than a real LCS diff: rules match by regex, so
  # what matters is that unchanged lines stay out of the content being scanned.
  def added_lines(baseline, current)
    return current if baseline.nil? || baseline.empty?

    remaining = Hash.new(0)
    baseline.each_line { |line| remaining[line] += 1 }

    added = current.each_line.reject do |line|
      next false if remaining[line].zero?

      remaining[line] -= 1
      true
    end

    added.join
  end

  def read_source(path)
    content = File.read(path, mode: 'r:UTF-8')
    content = content.scrub unless content.valid_encoding?
    content.include?("\0") ? nil : content
  end

  # git reports real paths, but CLAUDE_PROJECT_DIR and tool arguments can arrive
  # through a symlink (/var vs /private/var on macOS). Compare resolved paths or
  # nothing inside the project looks like it is inside the project.
  def real_path(path)
    File.realpath(path)
  rescue Errno::ENOENT
    File.expand_path(path)
  end
end
