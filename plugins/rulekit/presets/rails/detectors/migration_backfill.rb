module Detectors
  # Fires when a migration both adds a NOT NULL constraint and backfills data in
  # the same file. Reads the on-disk file (the pre-edit state) and unions it with
  # the incoming content so the check works for Write (whole file) and Edit
  # (fragment) alike.
  module MigrationBackfill
    NOT_NULL = /(add_column|add_reference|add_belongs_to)\b[^\n]*null:\s*false|change_column_null\([^)]*,\s*false/
    BACKFILL = /\b(update_all|find_each|find_in_batches|in_batches|exec_update|exec_query)\b|\.update!?\(|reset_column_information/
    CREATE_TABLE = /\bcreate_table\b/

    def self.call(file_path:, new_content:, **)
      existing = File.exist?(file_path) ? File.read(file_path) : ''
      content = "#{existing}\n#{new_content}"

      return false unless NOT_NULL.match?(content)
      return false unless BACKFILL.match?(content)
      # A migration that also creates the table is operating on a fresh table —
      # the existing-table hazard does not apply.
      return false if CREATE_TABLE.match?(content)

      true
    end
  end
end
