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

    def forget(relative_path)
      FileUtils.rm_f(path_for(relative_path))
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

  # One dirty file that has moved since its snapshot.
  Change = Struct.new(:code, :repo_path, :absolute, :relative)

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

  # Everything git calls dirty, narrowed to what has actually moved since
  # `snapshots` last saw it. A long-lived branch is dirty in dozens of files;
  # only the handful touched since then are worth reading. Returns nil outside
  # a git repo. Snapshots of files that have since vanished are dropped.
  def moved_files(project_dir, snapshots)
    repo_root = git(project_dir, 'rev-parse', '--show-toplevel')&.strip
    return nil if repo_root.nil? || repo_root.empty?

    entries = changed_entries(project_dir)
    return nil if entries.nil?

    project_root = real_path(project_dir)
    scratch_root = File.join(project_root, 'tmp', '.claude-advisory')

    entries.filter_map do |code, repo_path|
      absolute = File.expand_path(File.join(repo_root, repo_path))
      next unless absolute.start_with?("#{project_root}/")
      next if absolute.start_with?("#{scratch_root}/") # the hooks' own snapshots

      relative = absolute[(project_root.length + 1)..]

      unless File.file?(absolute)
        snapshots.forget(relative)
        next
      end
      next if File.size(absolute) > MAX_BYTES
      next unless snapshots.stale?(relative, absolute)

      Change.new(code, repo_path, absolute, relative)
    end
  end

  # What `change` looked like when `snapshots` last saw it. With no snapshot
  # yet, an untracked file is new in full and a tracked one is new since HEAD.
  def baseline(project_dir, snapshots, change)
    snapshots.read(change.relative) ||
      (change.code.start_with?('?') ? '' : git(project_dir, 'show', "HEAD:#{change.repo_path}").to_s)
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
