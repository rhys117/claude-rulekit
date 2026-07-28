# rulekit Rails preset

A portable set of opinionated Rails conventions generalized from a real production app. Copy it into your project with `/rules-init rails`. Every rule's `context` message ships as an opinion, not law — edit it to reflect what your team actually does.

---

## Write rules

These fire on `Edit`, `MultiEdit`, and `Write` tool calls.

| Rule | Type | Triggers on | Tells the agent |
|---|---|---|---|
| `no_default_scope` | block | Any edit to `app/models/**/*` that contains `default_scope` | Default scopes are banned. Use named scopes (`active`, `inactive`) with enforcement at call sites instead. |
| `service_call_idiom` | block_once | `def call` or `def self.call` in `app/models/**/*.rb` or `app/services/**/*.rb` | Run a DDD check: does this class coordinate across multiple aggregates? If it just wraps `.save`/`.update`/`.create` on one model, push the logic onto the model. `def self.call` that only forwards to `new(...).call` is ceremony. Yields on retry (escape hatch for external callable interfaces). |
| `service_design_advisory` | warn | Any edit inside `app/services/**/*` | Confirm the service belongs here. Services must encapsulate meaningful cross-aggregate domain operations. If it only wraps a single-model mutation, move it to the model or controller. |
| `migration_design_advisory` | warn | Any edit inside `db/migrate/**/*.rb` | Walk through five checks before proceeding: is persistence actually necessary; is boolean the right type; are columns named without table-name prefixes; is array/jsonb the right fit; and is a NOT NULL backfill being combined in one migration. |
| `migration_backfill` | warn | Detector-backed. See below. | A NOT NULL constraint and a data backfill appear in the same migration. Split them: add nullable, backfill separately, then constrain. |
| `migration_missing_fk_index` | warn | Detector-backed. See below. | A foreign-key column is being added without an index. Add `add_index` in the same migration. |
| `ruby_vs_sql` | warn | `.all.map`, `.all.select`, `.all.reject`, or `.all.each` in models or controllers | This loads every row into Ruby before filtering. Push the work into SQL with a scope, `where`/`pluck`, or `find_each` for batched iteration. |
| `view_query_logic` | warn | Any ActiveRecord query call (`where`, `find`, `order`, etc.) directly in an `.erb` file | Views should render data the controller already prepared. Query logic in templates is untestable and hides N+1s. Move the query to the controller, a scope, or a presenter. |
| `model_wrapper_delegation` | warn | Detector-backed. See below. | Heads up that a root model with existing wrapper modules is being edited. Check whether the new logic duplicates a wrapper or signals a new cohesive responsibility to extract. |
| `spec_let_fixture_nudge` | warn | `let` or `let!` in `spec/**/*.rb` | Pause on heavy `let`/`let!` setup. Pull multi-record, cross-model construction into shared setup (a FactoryBot factory or trait, a fixture, a `shared_context`, or a support helper). Reserve `let` for small in-memory values and per-test variation. |
| `sql_injection` | block_once | A `#{…}` interpolation inside a double-quoted string argument to `where`/`order`/`find_by_sql`/`having`/`group`/`joins`/`pluck`/`select`/`exists?` in `app/**/*.rb` or `lib/**/*.rb` | SQL-injection vector. Use bind parameters (`where("name = ?", name)`). Single-quoted strings don't interpolate, so they aren't flagged. Yields on retry for trusted constant interpolation. |
| `bare_rescue` | warn | `rescue` with no exception class, or `rescue nil`, in `app/**/*.rb` or `lib/**/*.rb` | Bare rescue swallows every `StandardError` and hides real failures. Rescue the specific class you expect and let the rest surface. |
| `migration_model_reference` | warn | A model-class query (`User.where`, `Model.find_each`, etc.) inside `db/migrate/**/*.rb` | Migrations load *current* model code; when the model changes the migration breaks. Use raw SQL or an inline throwaway class instead. |
| `missing_http_timeout` | warn | Detector-backed. See below. | An HTTP client (`Net::HTTP`/`Faraday`/`HTTParty`/`RestClient`/`Typhoeus`/`Excon`) is used with no timeout in the file. Set `open_timeout` and `read_timeout` so a hung endpoint can't exhaust the thread pool. |
| `validates_uniqueness_no_index` | warn | Detector-backed. See below. | A model validates uniqueness on a column with no backing `unique: true` index in `db/schema.rb`. The validation races under concurrency; add a DB unique index. |

---

## Read rules

These fire on `Bash`, `Grep`, and `Glob` tool calls.

| Rule | Type | Triggers on | Tells the agent |
|---|---|---|---|
| `broad_search_advisory` | warn | Detector-backed. See below. | Narrow the target before searching broadly. Check `db/schema.rb` for table and column names first. Prefer searches scoped to specific subdirectories over `app/` or `.` alone. |

---

## Detector-backed rules

Six rules delegate their fire/no-fire decision to a Ruby detector in `detectors/`. The detector receives the file path and content (for write rules) or the tool name and input (for read rules).

| Rule | Detector inspects |
|---|---|
| `migration_backfill` | Unions the on-disk file with the incoming edit and checks for both a `null: false` / `change_column_null` pattern and a backfill pattern (`update_all`, `find_each`, `exec_update`, etc.). Skips the warning when the migration also creates the table (no existing rows to lock). |
| `migration_missing_fk_index` | Finds every `add_column :t, :*_id` and `add_reference`/`add_belongs_to index: false` in the full migration content. Fires only for columns that have no matching `add_index` entry. Returns the specific column names in its context override. |
| `model_wrapper_delegation` | Checks whether a root model file (e.g. `app/models/user.rb`) has a matching subdirectory of wrapper modules (e.g. `app/models/user/`). If wrappers exist, fires and names them in the message. Skips `application_record.rb`. Uses a per-model sentinel so it fires at most once per model per session. |
| `missing_http_timeout` | Unions the on-disk file with the incoming edit. Fires when the content references an HTTP client but no timeout token (`open_timeout`, `read_timeout`, `timeout`, `Timeout.timeout`) appears anywhere in the file — so a timeout set elsewhere in the same file silences it. A timeout configured in a separate initializer/wrapper can't be seen, so the message says to ignore it in that case. |
| `validates_uniqueness_no_index` | Parses the uniqueness-validated columns from the model, then scans `db/schema.rb` for every column named in a `unique: true` index. Fires (naming the columns) for any validated column not covered. No table-name inflection — a same-named unique index on another table counts as cover, which under-warns rather than nags. |
| `broad_search_advisory` | Matches broad recursive `grep -r`/`find` commands and unscoped `Grep`/`Glob` paths. The "broad" top-level directories come from the rule's `roots:` list (`app`, `lib`, `spec`, `config` here), so the same detector ports to any stack by changing that list. |

---

## Opinions you may not share

These rules encode specific stances:

- **No `default_scope`** — the block is absolute. The workaround is named scopes.
- **Services must be cross-model** — single-model save wrappers belong on the model, not in `app/services/`.
- **Prefer composition over fat models** — the `model_wrapper_delegation` rule nudges toward extracting wrapper modules rather than growing a root model file.
- **Push filtering into SQL** — the `ruby_vs_sql` rule treats `.all.map` as a smell.

Delete any rule that does not fit your team. Soften `block` to `warn`, or `block_once` to `warn` with `once_per_session: true`, if you want advisories instead of stops. Rules with type `block_once` already yield on retry, so they carry a built-in escape hatch.

---

## Optional: Sorbet inline RBS

`write.yml` ends with a commented-out `sorbet_inline_rbs_advisory` rule. It only fits a project that types Ruby with Sorbet's inline RBS comments (`--enable-experimental-rbs-comments`), and it fires on every `def`, so it ships dormant. Uncomment it to enable.

When it fires, it doesn't dump the type conventions into the agent's context. It tells the agent to hand the typing to a subagent that reads the bundled `/rulekit:sorbet-inline-rbs` skill, signs the methods, and runs `srb tc` to green, so the conventions and the verify loop stay out of the main window. The detector ships ready at `detectors/sorbet_inline_rbs_advisory.rb`, and the skill is available whenever the plugin is enabled (no `/rules-init` needed).

---

## Add your own rule

A rule is a YAML entry keyed by a unique name. Put edit-time rules in `write.yml` and search-time rules in `read.yml`:

```yaml
no_raw_execute:
  type: warn                   # warn, block, or block_once
  files: ["app/models/**/*.rb"]
  pattern: '\.execute\('        # optional Ruby regex on the new content
  context: "Prefer a scope or Arel over a raw connection.execute in a model."
```

The `files` glob and optional `pattern` decide when it fires. `context` is the message the agent sees. `warn` lets the edit through with the note, `block` refuses it, and `block_once` refuses the first attempt then yields on a retry.

When a regex is not enough, add a detector at `detectors/<rule_name>.rb`. It reads project state and decides:

```ruby
module Detectors
  module NoRawExecute
    def self.call(file_path:, new_content:, **)
      return false unless new_content.match?(/\.execute\(/)
      true   # false to stay silent, true to use the YAML context above,
             # or { context: "custom message" } to override it
    end
  end
end
```

The module name is the CamelCase of the rule name. The full field list, the detector return contract, and the read-side `roots:` style config are documented in the [top-level README](../../README.md#how-rules-work).

---

## Testing

`./test.sh` smoke-tests this preset against the rulekit engine. It pipes synthetic `PreToolUse` events through `bin/write-rules-check.rb` and `bin/read-rules-check.rb` with `CLAUDE_RULES_DIR` pointed here, and asserts each rule fires (or stays silent) as intended, including the detector-backed rules, the `block_once` retry, `once_per_session`, and the read-side `roots:` config. Run it after editing any rule or detector. It builds a throwaway project with `mktemp` and cleans up after itself, so it touches no repo state.
