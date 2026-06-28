module Detectors
  # Fires when written Ruby content adds a `def` without an inline RBS
  # signature (`#:` / `#|` line immediately above), or creates a new file
  # without a `# typed:` sigil. Sentinel is keyed per-file so the nudge fires
  # once per file per session.
  module SorbetInlineRbsAdvisory
    DEF_LINE = /^\s*def\s/
    SIG_LINE = /\A\s*#(:|\|)/
    TYPED_SIGIL = /^#\s*typed:/

    def self.call(file_path:, relative_path:, new_content:, **)
      lines = new_content.lines
      unsigned_def = lines.each_index.any? do |i|
        lines[i].match?(DEF_LINE) && !(i.positive? && lines[i - 1].match?(SIG_LINE))
      end

      new_file_without_sigil = !File.exist?(file_path) && !new_content.match?(TYPED_SIGIL)

      return false unless unsigned_def || new_file_without_sigil

      {sentinel_suffix: relative_path.tr('/', '-')}
    end
  end
end
