module Detectors
  # Flags broad, unscoped repo searches so the advisory in read.yml can nudge
  # the agent to narrow first.
  #
  # The directories treated as "broad source roots" are read from the rule's
  # `roots:` list in read.yml. That keeps the stack-specific part as data: this
  # preset sets Rails roots (app, lib, spec, config), but a Node or Go preset
  # can set src, cmd, internal, etc. without touching this code. When no roots
  # are configured a generic fallback is used, so the detector is never tied to
  # one framework's layout.
  module BroadSearchAdvisory
    DEFAULT_ROOTS = %w[app lib src spec test tests config].freeze

    def self.call(tool:, tool_input:, rule: {}, **)
      roots = Array(rule && rule['roots'])
      roots = DEFAULT_ROOTS if roots.empty?
      alt = roots.map { |r| Regexp.escape(r) }.join('|')

      # Recursive grep (any path), or find/Grep/Glob rooted at the repo or a
      # whole source root rather than a scoped subdirectory.
      broad_bash = /grep\s+.*-[a-zA-Z]*r|find\s+(\.|#{alt})\/?(\s|$)/
      broad_path = /\A(|\.|#{alt})\/?\z/

      case tool
      when 'Bash'
        broad_bash.match?(tool_input['command'].to_s)
      when 'Grep', 'Glob'
        broad_path.match?(tool_input['path'].to_s)
      else
        false
      end
    end
  end
end
