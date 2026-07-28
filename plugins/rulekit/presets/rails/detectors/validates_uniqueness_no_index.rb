module Detectors
  # Fires when a model validates uniqueness on a column that has no matching
  # unique index in db/schema.rb. A uniqueness validation without a DB-level
  # unique index races under concurrency: two requests both pass the SELECT and
  # both INSERT, so a duplicate slips through.
  #
  # Heuristic (no Rails / ActiveSupport loaded in a hook, so no table-name
  # inflection): it collects every column named in a `unique: true` index
  # anywhere in schema.rb and treats a validated column as covered if it appears
  # in any of them. That under-warns (a same-named unique index on a different
  # table counts as cover) rather than nagging on false positives.
  module ValidatesUniquenessNoIndex
    # `validates :a, :b, ... uniqueness ...` — capture the leading symbol list.
    VALIDATES_BLOCK = /validates\s+((?::\w+\s*,\s*)*:\w+)[^\n]*\buniqueness\b/
    VALIDATES_OF = /validates_uniqueness_of\s+((?::\w+\s*,?\s*)+)/
    UNIQUE_INDEX_LINE = /(?:add_index|t\.index|\bindex)\b[^\n]*unique:\s*true/

    def self.call(file_path:, new_content:, **)
      existing = File.exist?(file_path) ? File.read(file_path) : ''
      content = "#{existing}\n#{new_content}"

      validated = scan_validated_columns(content)
      return false if validated.empty?

      schema = find_schema(file_path)
      covered = schema ? indexed_unique_columns(schema) : []

      missing = validated.reject { |col| covered.include?(col) }
      return false if missing.empty?

      hint = schema ? '' : ' (db/schema.rb not found — confirm the migration adds one)'
      {context: "This model validates uniqueness on #{missing.join(', ')} but no matching " \
        "`unique: true` index was found in db/schema.rb#{hint}. A uniqueness validation " \
        'runs a SELECT before INSERT, so two concurrent requests can both pass it and ' \
        'both write — a duplicate slips through. Enforce it at the database with ' \
        "add_index :table, :#{missing.first}, unique: true."}
    end

    def self.scan_validated_columns(content)
      cols = []
      content.scan(VALIDATES_BLOCK) { |m| cols.concat(m[0].scan(/:(\w+)/).flatten) }
      content.scan(VALIDATES_OF) { |m| cols.concat(m[0].scan(/:(\w+)/).flatten) }
      cols.uniq
    end

    def self.indexed_unique_columns(schema)
      cols = []
      schema.each_line do |line|
        next unless UNIQUE_INDEX_LINE.match?(line)

        cols.concat(line.scan(/:(\w+)/).flatten)
        cols.concat(line.scan(/"(\w+)"/).flatten)
      end
      cols.uniq
    end

    # Walk up from the model file to a db/schema.rb, then fall back to
    # CLAUDE_PROJECT_DIR (covers a relative file_path that can't be walked).
    def self.find_schema(file_path)
      dir = File.dirname(File.expand_path(file_path))
      loop do
        candidate = File.join(dir, 'db', 'schema.rb')
        return File.read(candidate) if File.exist?(candidate)

        parent = File.dirname(dir)
        break if parent == dir

        dir = parent
      end

      project = ENV['CLAUDE_PROJECT_DIR'].to_s
      unless project.empty?
        candidate = File.join(project, 'db', 'schema.rb')
        return File.read(candidate) if File.exist?(candidate)
      end

      nil
    end
  end
end
