# A path relative to the git checkout that contains it, for glob matching.
#
# Claude Code keeps CLAUDE_PROJECT_DIR on the checkout a session started in,
# even after the session moves into a worktree. Stripping only that prefix
# leaves a worktree file absolute, and a repo-relative glob never matches it.
# The checkout root is the directory holding `.git` (a directory in the main
# checkout, a file in a worktree), walked up from the file — or from the
# nearest existing parent when the file is not on disk yet.
module CheckoutPath
  module_function

  # Repo-relative form of an absolute `path`. An already-relative path is
  # returned as given. With no checkout around the file, `project_dir` is
  # stripped instead, and a path outside that too is left unchanged.
  def relative(path, project_dir)
    text = path.to_s
    return text if text.empty? || !text.start_with?('/')

    root = root_for(text)
    root = project_dir.to_s if root.nil? || root.empty?
    return text if root.empty?

    strip(text, root) || text
  end

  # Checkout to run git in. The session's `cwd` when it sits in a different
  # checkout than `project_dir`; `project_dir` when it does not, or when `cwd`
  # is not inside a checkout at all.
  def git_dir(cwd, project_dir)
    cwd_root = root_for(cwd.to_s)
    return project_dir if cwd_root.nil?

    project_root = root_for(project_dir.to_s)
    return cwd_root if project_root.nil?
    return project_dir if real(cwd_root) == real(project_root)

    cwd_root
  end

  # Directory holding `.git`, or nil when `path` is not inside a checkout.
  def root_for(path)
    text = path.to_s
    return nil if text.empty?

    dir = existing_ancestor(File.expand_path(text))
    return nil if dir.nil?

    until File.exist?(File.join(dir, '.git'))
      parent = File.dirname(dir)
      return nil if parent == dir

      dir = parent
    end

    dir
  end

  def existing_ancestor(path)
    current = path
    until File.exist?(current)
      parent = File.dirname(current)
      return nil if parent == current

      current = parent
    end

    File.file?(current) ? File.dirname(current) : current
  end

  def strip(path, root)
    head, rest = split_existing(File.expand_path(path))
    base = real(root)
    return nil unless head == base || head.start_with?("#{base}/")

    relative = head == base ? '' : head[(base.length + 1)..]
    [relative, rest].reject(&:empty?).join('/')
  end

  # [realpath of the existing prefix, the not-yet-created suffix]
  def split_existing(path)
    current = path
    missing = []

    until File.exist?(current)
      missing.unshift(File.basename(current))
      parent = File.dirname(current)
      break if parent == current

      current = parent
    end

    if File.file?(current)
      missing.unshift(File.basename(current))
      current = File.dirname(current)
    end

    [real(current), missing.join('/')]
  end

  def real(path)
    File.realpath(path)
  rescue Errno::ENOENT
    File.expand_path(path)
  end

  class << self
    private :existing_ancestor, :strip, :split_existing, :real
  end
end
