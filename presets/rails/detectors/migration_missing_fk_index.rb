module Detectors
  # Fires when a migration adds a foreign-key column without an index — an
  # `add_column :t, :*_id` with no matching `add_index`, or an `add_reference`
  # explicitly opting out with `index: false`. Reads the on-disk file unioned
  # with the incoming content so Write and Edit both see the whole migration.
  module MigrationMissingFkIndex
    ADD_FK_COLUMN = /add_column\s+:\w+,\s*:(\w+_id)\b/
    REFERENCE_NO_INDEX = /add_(?:reference|belongs_to)\b[^\n]*\bindex:\s*false/

    def self.call(file_path:, new_content:, **)
      existing = File.exist?(file_path) ? File.read(file_path) : ''
      content = "#{existing}\n#{new_content}"

      return true if REFERENCE_NO_INDEX.match?(content)

      fk_columns = content.scan(ADD_FK_COLUMN).flatten.uniq
      return false if fk_columns.empty?

      unindexed = fk_columns.reject do |col|
        escaped = Regexp.escape(col)
        content.match?(/add_index\s+:\w+,\s*(?::#{escaped}\b|\[[^\]]*:#{escaped}\b)/)
      end
      return false if unindexed.empty?

      {context: "This migration adds foreign-key column(s) #{unindexed.join(', ')} without " \
         'an index. Unindexed FKs make joins and association lookups slow and cause ' \
         "lock contention on delete. Add add_index for #{unindexed.join(', ')} in " \
         'this migration.'}
    end
  end
end
