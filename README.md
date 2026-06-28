# rulekit

Just in time, not just in case.

Rulekit delivers coding conventions to a Claude Code agent at the moment it acts, instead of front-loading them into `CLAUDE.md` where they compete for attention and quietly stop landing. `PreToolUse` hooks match the file the agent is about to edit (by path glob) and the content it is about to write (by regex), then either **block** the edit or inject a one line advisory right then. A read side hook nudges before broad `Bash`, `Grep`, and `Glob` searches, so junk stays out of the context window in the first place.

This is the pattern Anthropic calls [just-in-time context](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) and [progressive disclosure](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills), aimed at the failure mode they call context rot: the more you put in the window up front, the less any single rule is recalled later.

## Prior art, and where rulekit goes further

Anthropic ships a first party plugin, **Hookify**, that already does the declarative half of this: rules that fire on `Edit`, `Write`, and `MultiEdit`, match file path and content by regex, and choose between block and warn. If your rules are pure globs and regexes, use Hookify.

Rulekit is for when you have outgrown pure declarative rules. It adds three things Hookify does not have:

1. **Pluggable detector modules.** Logic, not just a pattern. A detector is Ruby that runs in your repo, so it can read the file on disk, union it with the incoming edit, and name a real finding back ("this migration adds `NOT NULL` on `slug` and backfills it in the same file"). A regex knows what you are typing. A detector knows what is already there.
2. **Per session escape hatches.** `block_once` denies the first attempt and yields on the retry, which encodes "this is usually wrong, but you are allowed to mean it." `warn` with `once_per_session` fires an advisory once and then stays quiet so it does not become noise.
3. **Read side guardrails.** The same idea pointed upstream. A nudge on `Bash`, `Grep`, and `Glob` to narrow a search before it floods the window.

Think of it as Hookify for power users.

## Install

Rulekit needs **Ruby on `PATH`** (the hooks are Ruby scripts) and **`jq`** (used by the `SessionStart` cleanup hook).

```
/plugin marketplace add https://github.com/rhys117/claude-rulekit
/plugin install rulekit@rulekit
```

The plugin manifest is at `.claude-plugin/plugin.json`; the marketplace metadata at `.claude-plugin/marketplace.json`. The hooks no-op silently in any project that has no `.claude/rules/`, so enabling rulekit globally is safe.

## Quick start

```
/rules-init rails
/rules-test
```

`/rules-init rails` copies the bundled Rails preset from `presets/rails/` into your project's `.claude/rules/`. `/rules-test` feeds synthetic tool calls through the hooks to confirm patterns compile and detectors load.

## How rules work

Rules live in your project under `.claude/rules/`. Two files are loaded, one per side of the agent's work:

| File | Fires on |
|---|---|
| `.claude/rules/write.yml` | `Edit`, `MultiEdit`, `Write` |
| `.claude/rules/read.yml`  | `Bash`, `Grep`, `Glob` |

Each file is a YAML map keyed by rule name:

```yaml
# .claude/rules/write.yml
no_default_scope:
  type: block
  files:
    - "app/models/**/*"
  pattern: '(?<!\w)default_scope(?!\w)'
  context: >
    default_scope leaks into every query and is hard to undo.
    Scope explicitly at the call site instead.
```

| Field | Used by | Description |
|---|---|---|
| `type` | all | `block`, `block_once`, or `warn`. |
| `files` | write, read | Path globs (`**` supported). On write, the file being edited; on read, the path the tool touches (the `Read` file, or a `Grep`/`Glob` path). |
| `pattern` | write | Optional Ruby regex matched against the new content. Omit to fire on the file glob alone. |
| `tools` | read | Optional list of tool names. Defaults to `[Bash, Grep, Glob]`; add `Read` to fire when the agent opens a file. |
| `context` | all | The message returned to the agent. A detector may override it. |
| `once_per_session` | warn | When `true`, the rule fires at most once per session. |

Rule names must be unique across `write.yml` **and** `read.yml`; both share one per session sentinel namespace.

Set `CLAUDE_RULES_DIR` to point the engine at a different directory if you do not want `.claude/rules/`.

## Detectors

When a rule needs more than a regex, add a Ruby file at `.claude/rules/detectors/<rule_name>.rb`. It defines a module under `Detectors` whose name is the CamelCase of the rule name, with a `self.call`:

```ruby
# .claude/rules/detectors/migration_backfill.rb
module Detectors
  module MigrationBackfill
    def self.call(file_path:, new_content:, **)
      # Union the on-disk file with the incoming edit so the check works for
      # a whole-file Write and a one-line Edit alike.
      source = (File.exist?(file_path) ? File.read(file_path) : "") + "\n" + new_content

      return false unless source.match?(/null:\s*false/)
      return false unless source.match?(/update_all|find_each|exec_update/)
      return false if source.match?(/create_table/)   # fresh table, no hazard

      true
    end
  end
end
```

A write detector receives `file_path:`, `relative_path:`, `new_content:`, and `session_id:`. A read detector receives `tool:`, `tool_input:`, and `session_id:`. Both also receive `rule:`, the rule's own YAML hash, so a detector can read extra configuration declared alongside the rule. Always accept `**` for forward compatibility.

That `rule:` hash is how a detector stays stack agnostic instead of hard coding one framework's layout. The bundled `broad_search_advisory` reads a `roots:` list from its rule (`roots: [app, lib, spec, config]` in the Rails preset, with a generic fallback), so the same code flags broad searches in a Node or Go repo once you point `roots:` at `src`, `cmd`, or `internal`.

Return:

- `false` or `nil` to pass silently.
- `true` to fire with the rule's YAML `context`.
- a `Hash` to fire with overrides: `:context` replaces the message for this fire, and `:sentinel_suffix` namespaces the session sentinel (so a `once_per_session` rule can fire once per target, for example once per model, rather than once globally).

Detectors being Ruby is the point. A detector runs in the repo and can read the project's own files, so it can name a real finding rather than guess from a string match.

## block, warn, and block_once

| Type | Behaviour |
|---|---|
| `block` | Denies the tool call every time (`permissionDecision: deny`, exit 2). |
| `warn` | Injects an advisory as `additionalContext` and allows the call. Honours `once_per_session`. |
| `block_once` | Denies the first attempt this session, then yields silently on the retry. The escape hatch for "usually wrong, occasionally meant." |

`block_once` and `once_per_session` are tracked with sentinel files under `tmp/.claude-advisory/<session_id>/`. The bundled `SessionStart` hook clears the current session's sentinels at the start of each session (startup, resume, `/clear`, `/compact`), so "once" means once per working session, not once forever.

## Repo layout

```
rulekit/
├── .claude-plugin/
│   ├── plugin.json            # plugin manifest
│   └── marketplace.json       # marketplace listing
├── hooks/
│   └── hooks.json             # PreToolUse (write + read) and SessionStart
├── bin/
│   ├── write-rules-check.rb   # Edit/MultiEdit/Write engine
│   ├── read-rules-check.rb    # Bash/Grep/Glob engine
│   └── clear-advisory-sentinels.sh  # SessionStart sentinel cleanup
├── lib/
│   └── rules_runner.rb        # shared matching, sentinels, output
├── commands/
│   ├── rules-init.md          # /rules-init <preset>
│   └── rules-test.md          # /rules-test
└── presets/
    └── rails/                 # copy in with /rules-init rails
        ├── write.yml
        ├── read.yml
        ├── detectors/
        ├── test.sh            # asserts every rule fires/stays silent
        └── README.md
```

## Presets

`presets/rails/` is a portable set of opinionated Rails conventions generalized from a real production app: fifteen write rules (no `default_scope`, the service object DDD check, the migration safety checklist, `NOT NULL` + backfill in one migration, unindexed foreign keys, `.all.map` instead of SQL, model queries in views, fat model nudges, heavy spec setup, SQL-injection interpolation, bare `rescue`, model references in migrations, missing HTTP timeouts, and uniqueness-without-index) and one read rule that narrows broad repo searches. See [`presets/rails/README.md`](presets/rails/README.md) for the full table and the opinions each rule encodes.

Presets for other stacks are welcome. A preset is just a `write.yml`, a `read.yml`, and an optional `detectors/` directory.

## Credit

- **Hookify** (Anthropic) for the declarative block/warn-on-edit model rulekit builds past.
- Anthropic's writing on **just-in-time context** and **progressive disclosure**, and the **context rot** failure mode they describe.

## License

MIT. See [LICENSE](LICENSE).
