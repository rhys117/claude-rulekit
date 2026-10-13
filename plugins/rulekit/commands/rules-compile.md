---
description: Compile this project's instruction files (CLAUDE.md, AGENTS.md, ...) into rulekit rules
---

Turn the rules a person wrote for coding agents into rulekit rules that hooks
enforce at the moment of an edit, a search or a command. The output is two
files beside the hand-written ones, in the same format:

- `.claude/rules/write_rubric.yml` — loaded together with `write.yml`
- `.claude/rules/tools_rubric.yml` — loaded together with `tools.yml`

Tool rules were called read rules. If the project still has `read_rubric.yml`,
write `tools_rubric.yml` and delete the old file; it is ignored once the new
one exists. A hand-written `read.yml` is the user's: read it as you would
`tools.yml` and leave it where it is.

Two facts before you start:

- **Rules come only from the user's own files.** Never add a rule you think
  they should have. If a file holds no enforceable rules, say so.
- **The rubric is committed and read by people.** Every rule must trace to a
  line they can point at, in their wording.

The rubric files belong to this command and are rewritten on every run. Never
edit `write.yml`, `tools.yml` or an existing detector that is not yours.

## Step 1. Find and read the sources

Run `ruby "${CLAUDE_PLUGIN_ROOT}/bin/rules-rubric.rb" sources` from the project
root. It lists each instruction file, the glob its rules apply to, and its
sha256. The tag at the end of each line and the closing `status:` line compare
the file with the last compile (`new`, `changed`, `unchanged`, `gone`); they
are for the person, and you compile every listed file either way. If it finds
no sources, tell the user there is nothing to compile and stop.

Read every listed file in full. Then:

- **Follow pointers.** A file that says "read X" or imports `@path/to/file` is
  pointing at another source. Read it and treat it as a source of its own.
- **Nested files apply only to their directory.** A rule from
  `apps/web/CLAUDE.md` (scope `apps/web/**/*`) gets globs under `apps/web/`.
- Read a file marked optional only for sentences that instruct. How to open a
  pull request is not a rule.
- Read `.claude/rules/write.yml`, `.claude/rules/tools.yml` and the names in
  `.claude/rules/detectors/` if they exist. Rule names are unique across all
  four files, and a rule the user already wrote by hand is not compiled again.

## Step 2. Extract every statement that instructs

Go through each file top to bottom. An instruction is one thing the agent is
told to do or not do, that could be kept or broken on its own.

- Count instructions, not bullets. A bullet that says "never accept the key as
  a flag, and never log it" is two, and both carry the same `source` line.
- One idea said twice is one instruction. Compile it once and quote the
  clearest wording.
- Headings, taglines, rationale and questions to "ask yourself" are not
  instructions. They often say what one is for and belong in its `context`.
- A description is not an instruction. "This is a pnpm monorepo" tells the
  agent nothing to do; "always use pnpm" does. Do not infer the second from the
  first.

For each one capture the user's own words, trimmed to a sentence or two, and
the file and line. Keep any code block beside it: a worked example carries more
signal than the prose.

## Step 3. Give each rule the cheapest shape that decides it

Ask in this order and stop at the first yes. Earlier shapes are exact, free and
act before the write; later ones cost more and know less.

| # | Question | Shape | Lands in |
|---|---|---|---|
| 1 | Is it about what the agent runs, searches for or opens? ("use pnpm, never npm", "no AI attribution in commits", "check schema.rb before searching", "do not read `legacy/`") | tool rule: `tools` + `pattern` and/or `files` | `tools_rubric.yml` |
| 2 | Can a regex over the new code decide it exactly? (`default_scope`, `console.log`, `interface Foo`, `binding.pry`) | write rule with `pattern` | `write_rubric.yml` |
| 3 | Would a few lines of Ruby decide it exactly, where a regex cannot: counting, measuring, or a look at another file in the repo? (line caps, "a uniqueness validation needs a unique index") | write or tool rule + detector | rubric + `detectors/<name>.rb` |
| 4 | Is it about a place rather than about particular code? ("never edit `db/schema.rb` by hand", "services coordinate several models") | write rule on `files` alone | `write_rubric.yml` |
| 5 | Could a reviewer decide it from the lines added to one file and nothing else? (a comment that restates the code, raw error text reaching a user, a hand-rolled retry loop) | write rule with `judge` | `write_rubric.yml` |
| 6 | None of the above. | not a rule | `_rubric.skipped`, with the reason |

What ends up in 6: instructions about the change as a whole (scope creep, an
abstraction with one caller), about the conversation ("ask when unsure", "state
a plan"), ones that need an understanding of the whole codebase, ones that
compare the new code with what was there before, and ones already covered by a
hand-written rule (name it in the reason).

A rule sees only what is being written, never the previous version. A detector
can read the file on disk, which before an edit is still the old content.

Every instruction lands somewhere. Count them: the report at the end is those
counts.

### Choosing `type`

What decides it is how sure the match is, then how firm the wording is:

| The match | `type` |
|---|---|
| Exact, and the wording allows no exception ("never", "must not", a flat "use X, not Y") | `block` |
| Can be legitimate, or the wording is soft ("avoid", "prefer", "usually") | `block_once` (denies once, lets the retry through) |
| A reminder for a place, or anything decided by `judge` | `warn`, with `once_per_session: true` for place reminders |

Tool rules have no `block_once`. A `judge` answer is a probability: keep it to
`warn` unless the user's wording is absolute and the question is narrow.

## Step 4. Write each rule

### `files`

Globs relative to the project root. `**/` crosses directories and `**/*.rb`
also matches a file at the root. There is no brace expansion: write
`["app/**/*.rb", "app/**/*.erb"]`, not `app/**/*.{rb,erb}`.

A write rule **must** have `files`; without one it never matches. Use
`["**/*"]` only when the rule truly applies everywhere, and prefer the
narrowest extension or directory the user's text supports. Scope goes here,
never in the wording of a pattern or question.

### `exclude`

Optional globs, same syntax, for "everywhere except here". "Define
`assertNever` once in the schema package" is a pattern on the definition with
`exclude: ["packages/schema/**/*"]`. Do not write a detector to carve out a
path.

### `pattern`

A **Ruby** regex.

- On a write rule it is matched against the new content only: the replacement
  text of an edit, which may be one line out of the middle of a file. Do not
  rely on anything outside the lines being written. `^` and `$` match at line
  boundaries.
- On a tool rule it is matched against what the tool was asked for: the
  command for `Bash`, the search pattern for `Grep`/`Glob`, the path for
  `Read`.
- Match the offence, not the topic: `(?<!\w)default_scope(?!\w)`, not `scope`.
- Quote it in single quotes in YAML so backslashes survive.
- Test every pattern before you keep it, on one string that must match and one
  that must not:
  `ruby -e 'r = Regexp.new(ARGV[0]); p r.match?(ARGV[1]), r.match?(ARGV[2])' '<pattern>' '<bad>' '<good>'`

### `judge`

```yaml
judge:
  question: "Does this change add a comment that restates what the line below it does?"
  threshold: 0.8    # optional, default 0.7
```

The judge is a small model that answers yes/no with a probability. It runs
when the turn ends, once per changed file, and sees only the file path and the
lines the turn added to that file. A vague question scores in the middle on
everything and never fires, and the user reads that silence as good news.

- One idea per question. Two parts means two rules.
- Ask about the change and name the concrete shape: the identifier, the call,
  the syntax, the position.
- Ask for existence, not a verdict on the whole: "Is there at least one ..."
  fires on the first offending line; "Are the comments appropriate?" never
  leaves the middle.
- Under about 60 words. It is billed every time the file changes.
- Yes must mean the rule is broken.
- Add a `pattern` whenever some token must be present for the rule to be
  broken at all (`rescue` for an error-handling rule, `#` for a comment rule).
  It runs first and costs nothing, so the judge is only asked when it could
  say yes.

The judge is optional for the user. Without one configured these rules stay
silent, so never use `judge` for something a pattern or detector decides.

### Detectors

`.claude/rules/detectors/<rule_name>.rb`, found by the rule's name:

```ruby
# Generated by /rules-compile from CLAUDE.md:88
module Detectors
  module ControllerActionLength          # CamelCase of the rule name
    def self.call(file_path:, new_content:, rule:, **)
      # write rules also get relative_path:, session_id:
      # tool rules get tool:, tool_input:, session_id:, rule:
      new_content.lines.size > rule.fetch('max_lines', 30)
    end
  end
end
```

Return `false`/`nil` to pass, `true` to fire with the rule's `context`, or
`{ context: "..." }` to fire with a message that names the finding. Always
accept `**`. Put thresholds and paths in the rule's YAML as extra keys and read
them from `rule`, so the person can tune them without touching Ruby. `files`
and `pattern` still run first, so use them to keep the detector off unrelated
files.

A detector runs inside the hook on every matching tool call. Keep it short,
side-effect free and fast, and write one only when it decides the rule
exactly. Never overwrite a detector that lacks the "Generated by
/rules-compile" header.

### `context`

What the agent is told when the rule fires. Say what is wrong and what to do
instead, in the user's terms, using their rationale and their example if they
gave one. One to four sentences. It is the only part of the rule the agent
sees.

### `text` and `source`

Every rule carries the instruction it came from and where:

```yaml
text: "We do not allow default scopes."
source: "CLAUDE.md:41"
```

### Names

`snake_case`, saying what the rule catches (`no_default_scope`,
`raw_error_to_user`). Unique across `write.yml`, `tools.yml` and both rubric
files. When recompiling, keep the name a rule already has.

## Step 5. Write the files

```yaml
# .claude/rules/write_rubric.yml
# Generated by /rules-compile from this project's instruction files.
# Do not edit by hand: put hand-written rules in write.yml, which wins on a
# name clash. Re-run /rules-compile after changing a source.

_rubric:
  compiled_at: "2026-10-13"
  sources:
    - { path: CLAUDE.md, sha256: "<from step 1>" }
    - { path: apps/web/CLAUDE.md, sha256: "<from step 1>" }
  skipped:
    - text: "State your assumptions. If uncertain, ask."
      source: "CLAUDE.md:12"
      reason: "about the conversation, not the code"
    - text: "No features beyond what was asked."
      source: "CLAUDE.md:22"
      reason: "about the change as a whole; rules see one file at a time"

no_default_scope:
  type: block
  files: ["app/models/**/*.rb"]
  pattern: '(?<!\w)default_scope(?!\w)'
  context: >
    Default scopes are not allowed. Use explicit scopes such as `active` and
    apply them at the call site.
  text: "We do not allow default scopes."
  source: "CLAUDE.md:41"

schema_is_generated:
  type: block
  files: ["db/schema.rb"]
  context: >
    db/schema.rb is generated. Change it with a migration, never by hand.
  text: "Never edit db/schema.rb directly."
  source: "CLAUDE.md:47"

raw_error_to_user:
  type: warn
  files: ["apps/web/app/controllers/**/*.rb"]
  pattern: 'rescue|\.message'
  judge:
    question: "Does this change put raw exception text (e.message, e.to_s, or an interpolation of them) into a response body or rendered copy?"
    threshold: 0.8
  context: >
    Never show a user a raw error. Log the exception and render a message
    written for a person.
  text: "Never show a user a raw error."
  source: "apps/web/CLAUDE.md:9"
```

```yaml
# .claude/rules/tools_rubric.yml
# Generated by /rules-compile. Do not edit by hand; see write_rubric.yml.

_rubric:
  compiled_at: "2026-10-13"
  sources:
    - { path: CLAUDE.md, sha256: "<from step 1>" }

use_pnpm:
  type: block
  tools: [Bash]
  pattern: '(?<![\w-])(npm|yarn)\s+(install|add|run|i)\b'
  context: >
    This repo uses pnpm. Run the same command with `pnpm`.
  text: "Always use pnpm, never npm or yarn."
  source: "CLAUDE.md:15"

legacy_views_deprecated:
  type: warn
  tools: [Read]
  files: ["app/views/shared/**/*.erb"]
  once_per_session: true
  context: >
    These shared partials are deprecated. New shared UI is a ViewComponent
    under app/components; check there first.
  text: "Shared partials are deprecated; build ViewComponents."
  source: "CLAUDE.md:63"
```

Rules of the files:

- Both files list every source that was read under `_rubric.sources`, with the
  sha256 from step 1, whether or not that file produced a rule there.
- `_rubric.skipped` goes in `write_rubric.yml` only.
- Write a file even when it holds no rules, so its sources are recorded.
  If neither side has a single rule, write nothing and tell the user.
- `tools` defaults to `[Bash, Grep, Glob]`; name `Read` explicitly to fire
  when a file is opened. A tool rule with `files` never matches `Bash`.

## Step 6. Validate, then try the rules

Run `ruby "${CLAUDE_PLUGIN_ROOT}/bin/rules-rubric.rb" validate`. Fix every
`issue:` line and run it again until it prints `valid`. Read each `note:` line
and either act on it or be sure it is what the user's rule means.

Then feed each rule that has a `pattern` or a detector one payload that should
fire and one that should not, with `CLAUDE_PROJECT_DIR` set to the project
root. Give every payload its own `session_id`: `block_once` and
`once_per_session` rules fire once per session and then go quiet.

```bash
echo '{"tool_name":"Write","session_id":"rules-compile-1","tool_input":{"file_path":"'"$PWD"'/app/models/x.rb","content":"default_scope { where(active: true) }"}}' \
  | "${CLAUDE_PLUGIN_ROOT}/bin/write-rules-check.rb"
echo '{"tool_name":"Bash","session_id":"rules-compile-2","tool_input":{"command":"npm install left-pad"}}' \
  | "${CLAUDE_PLUGIN_ROOT}/bin/tool-rules-check.rb"
```

Firing looks like this; passing prints nothing and exits 0:

| `type` | Exit | stdout |
|---|---|---|
| `block`, `block_once` | 2 | JSON with `permissionDecision: "deny"` and the rule's name and `context` |
| `warn` | 0 | JSON with `additionalContext` |

A rule that fires on the good payload or stays silent on the bad one gets
rewritten, or moved to `skipped` if it cannot be made exact. `judge` rules are
not sent anything. Remove `tmp/.claude-advisory/rules-compile*` when done.

## Step 7. Report

Tell the user in a few plain sentences: how many instructions were found; how
many became rules, split by shape (pattern, files only, detector, judge, tool;
`validate` prints files-only rules as "match only");
how many were skipped and the main reasons; whether any detectors were
generated, since those are code they should read; and that `judge` rules only
run once a judge is configured. Do not paste the rubric into the conversation.
