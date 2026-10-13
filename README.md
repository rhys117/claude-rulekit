# rulekit

**Just in time, not just in case.**

Coding agents forget the conventions in `CLAUDE.md` long before they stop writing code. Rulekit puts each rule in front of the agent at the moment it applies, and stops the edit before it lands.

```
/plugin marketplace add https://github.com/rhys117/claude-rulekit
/plugin install rulekit@rulekit
/rules-init rails
```

Needs Ruby and `jq` on `PATH`, and a git repo for the checks that read the working tree. No API key.

## What it does

Every rule is decided by the cheapest check that can decide it. Most conventions never need a model.

```
                    decides                           when               cost
  ────────────────────────────────────────────────────────────────────────────────────
  1  glob + regex   "no default_scope in models"      before the edit    free, offline
  2  detector       "NOT NULL column and its          before the edit    free, offline
     (your Ruby)     backfill in one migration"
  3  judge (Jev)    "this comment restates the code"  end of the turn    one request per
                                                                         changed file
```

- **Rungs 1 and 2 are deterministic.** The same edit gets the same answer every time, in milliseconds, with nothing leaving your machine.
- **Rung 3 is optional.** A decision model answers a yes/no question with a probability, for the rules nothing deterministic can decide. Without a key those rules stay silent and the rest carry on.
- **Rules are yours.** They live in `.claude/rules/` as YAML you can read, and [`/rules-compile`](#compiling-rules-from-your-instruction-files) writes them from the `CLAUDE.md` you already have.

## Before the edit, not after it

A check that runs after the edit tells the agent to go back and repair something. A check that runs before it means the mistake is never written.

| Check | Runs | On a violation |
|---|---|---|
| Glob, regex and detector rules | `PreToolUse`, before the edit or command | **A `block` denies the call.** Nothing lands, and the agent gets the reason. A `warn` lets it through with the advice attached |
| [Post-write sweep](#writes-that-bypass-the-write-tools) | `PostToolUse`, after every tool call | A `block` tells the agent to undo it. Catches a heredoc, `sed -i` or script that never went through `Edit` |
| [Judge](#semantic-rules-with-a-judge-optional) | `Stop`, once per turn | The turn is kept open with the finding |

Only the judge waits for the end of the turn, because it may be a paid network call. Everything a deterministic check can decide is decided first.

## Why not ask a model about everything

| | Regex-only hooks | A model on every rule | rulekit |
|---|---|---|---|
| Earliest feedback | Before the edit | After the edit, or at the end of the turn | Before the edit, wherever a deterministic check can decide |
| Same input, same answer | Yes | No, a probability against a threshold | Yes for regex and detector rules |
| Works with no key and no network | Yes | No | Yes, except `judge` rules |
| Rules a regex cannot express | No | Yes | Yes: a detector first, the judge for the rest |
| Writes that bypass `Edit`/`Write` | Missed | Depends on the tool | Caught by the sweep |
| Rules about commands and searches | No | Depends on the tool | Yes, [tool rules](#how-rules-work) |

If your rules are pure globs and regexes, Anthropic's first party **Hookify** plugin already covers them. Rulekit is for what comes after that:

1. **Detectors.** Ruby that runs in your repo, so it can read the file on disk, union it with the incoming edit, and name a real finding ("this migration adds `NOT NULL` on `slug` and backfills it in the same file"). A regex knows what you are typing. A detector knows what is already there.
2. **Escape hatches.** `block_once` denies the first attempt and yields on the retry: "usually wrong, but you are allowed to mean it." `warn` with `once_per_session` says it once and then stays quiet.
3. **Rules the agent cannot route around.** An agent told to prefer `Bash` will write a whole subsystem through heredocs without one `Edit`. Rulekit watches the working tree, so how the write arrived stops mattering.
4. **Tool rules.** The same idea pointed at the request rather than the content: the wrong package manager, a search too broad for the context window, a deprecated file being opened.
5. **A judge, last.** A decision model for what is left, asked once per turn about only the files that changed.

This is the pattern Anthropic calls [just-in-time context](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) and [progressive disclosure](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills), aimed at context rot: the more you put in the window up front, the less any single rule is recalled later.

## Three minutes to the first block

1. Install the plugin (the two `/plugin` lines above). The hooks do nothing in a project with no `.claude/rules/`, so enabling it globally is safe.
2. Run `/rules-init rails` to copy the bundled Rails preset into `.claude/rules/`, or `/rules-compile` to build rules from your own `CLAUDE.md` and `AGENTS.md`.
3. Run `/rules-test`. It feeds synthetic tool calls through the hooks to confirm patterns compile and detectors load.
4. Ask the agent for something a rule forbids, such as a `default_scope` on a model. The edit is denied before it is written, and the agent sees the rule's `context`:

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
 "permissionDecisionReason":"[no_default_scope] default_scope leaks into every query and is hard to undo. Scope explicitly at the call site instead.\n"}}
```

## Commands

| Command | Does |
|---|---|
| `/rules-init <preset>` | Copies a preset into `.claude/rules/` without overwriting what is there |
| `/rules-compile` | Turns the instructions in `CLAUDE.md`, `AGENTS.md` and friends into rules, each in the cheapest shape that decides it |
| `/rules-test` | Smoke-tests every installed rule against the hooks |
| `rules-rubric.rb sources` | Lists the instruction files and whether the compiled rules are out of date with them |
| `rules-rubric.rb validate` | Checks the compiled rules against what the hooks accept. Exits 1 on any issue |

## How rules work

Rules live in your project under `.claude/rules/`. There are two kinds: **write rules** match the content landing in a file, and **tool rules** match what the agent asks a tool to do. Each kind has a file you write by hand and, optionally, one that [`/rules-compile` generates](#compiling-rules-from-your-instruction-files). Both are loaded and have the same format:

| File | Kind | Fires on |
|---|---|---|
| `write.yml`, `write_rubric.yml` | write | `Edit`, `MultiEdit`, `Write` before the write — and, via the [post-write sweep](#writes-that-bypass-the-write-tools), any other write once it lands |
| `tools.yml`, `tools_rubric.yml` | tool | `Bash`, `Grep`, `Glob` before the call, and `Read` when a rule asks for it |

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
| `type` | all | `block` or `warn`. Write rules also take `block_once`. |
| `files` | write, tool | Path globs (`**` supported). On a write rule, the file being edited, and required. On a tool rule, the path the tool touches (the `Read` file, or a `Grep`/`Glob` path); optional, and never matches `Bash`, which has no single path. |
| `exclude` | write, tool | Optional path globs. A path matching one is left alone, for "everywhere except here". |
| `pattern` | write, tool | Optional Ruby regex. On a write rule, matched against the new content. On a tool rule, against what the tool was asked for: the `Bash` command, the `Grep`/`Glob` search pattern, the `Read` path. Omit to fire on the other matches alone. |
| `tools` | tool | Optional list of tool names. Defaults to `[Bash, Grep, Glob]`; add `Read` to fire when the agent opens a file. |
| `judge` | write | Optional. Ask a [model](#semantic-rules-with-a-judge-optional) a yes/no question when the agent finishes its turn, instead of firing on the match alone. |
| `context` | all | The message returned to the agent. A detector may override it. |
| `enabled` | all | Optional. `false` switches the rule off without deleting it. See [switching a rule off](#switching-a-rule-off). |
| `once_per_session` | warn | When `true`, the rule fires at most once per session. |

What each kind supports:

| | Write rules | Tool rules |
|---|---|---|
| Matches | the content being written | the request: a command, a search, a path |
| Decided | before the edit, after a write that bypassed the edit tools, and on `Stop` for `judge` | before the tool call |
| `block`, `warn`, `once_per_session` | yes | yes |
| `block_once` | yes | no |
| `pattern`, `exclude`, [detectors](#detectors) | yes | yes |
| `files` | required | optional |
| `tools` | no | yes |
| [`judge`](#semantic-rules-with-a-judge-optional) | yes | no |

A tool rule that carries `judge:` is skipped, not fired on the bare match. A tool rule is decided before the call with no model in the loop; use a detector there instead.

Tool rules were called read rules. `read.yml` and `read_rubric.yml` still load when `tools.yml` and `tools_rubric.yml` are absent, so rename them when convenient; once the new file exists the old one is ignored.

### Switching a rule off

Add `enabled: false` to a rule and no hook sees it:

```yaml
# .claude/rules/write_rubric.yml
no_default_scope:
  enabled: false
  type: block
  ...
```

- **It survives a recompile.** `/rules-compile` rewrites the rubric files, so deleting a generated rule only lasts until the next run. The flag is carried forward for as long as the instruction still compiles to that rule.
- **It works in all four files**, hand-written or generated.
- **`rules-rubric.rb validate` counts them**, so a switched-off rule is not forgotten, and reports a value that is not `true` or `false`.

Rule names must be unique across all four files; they share one per session sentinel namespace. If a generated rule and a hand-written one share a name, the hand-written one runs.

Set `CLAUDE_RULES_DIR` to point the engine at a different directory if you do not want `.claude/rules/`.

## Compiling rules from your instruction files

Most projects already state their conventions in prose, in `CLAUDE.md` or `AGENTS.md`. `/rules-compile` has the agent read those files and write each instruction as a rulekit rule, into two generated files that load beside your own:

```
CLAUDE.md, AGENTS.md, nested ones,          .claude/rules/
.cursorrules, CONTRIBUTING.md                 ├── write.yml          yours
        │                                     ├── tools.yml          yours
        ▼                                     ├── write_rubric.yml   generated
  /rules-compile ─────────────────────────►   ├── tools_rubric.yml   generated
  every instructing sentence, in the          └── detectors/         yours + generated
  cheapest shape that decides it
```

Each instruction is given the first shape that can decide it:

| The instruction is about | Becomes |
|---|---|
| What the agent runs, searches or opens ("use pnpm, never npm") | a tool rule: `tools` + `pattern` and/or `files` |
| A place rather than particular code ("never edit `db/schema.rb`") | a write rule on `files` alone |
| Something a regex decides exactly ("no `default_scope`") | a write rule with `pattern` |
| Counting, measuring, or a lookup in another file | a rule plus a small generated [detector](#detectors) |
| Something a reviewer could decide from one file's added lines | a write rule with [`judge`](#semantic-rules-with-a-judge-optional) |
| The conversation, the change as a whole, the whole codebase | recorded as skipped, with the reason |

A generated rule is an ordinary rule plus where it came from:

```yaml
# .claude/rules/write_rubric.yml
_rubric:
  compiled_at: "2026-10-13"
  sources:
    - { path: CLAUDE.md, sha256: "9f2c…" }
  skipped:
    - { text: "If uncertain, ask.", source: "CLAUDE.md:12", reason: "about the conversation, not the code" }

no_default_scope:
  type: block
  files: ["app/models/**/*.rb"]
  pattern: '(?<!\w)default_scope(?!\w)'
  context: Default scopes are not allowed. Scope explicitly at the call site.
  text: "We do not allow default scopes."     # the user's words
  source: "CLAUDE.md:41"                      # where they wrote them
```

- **Rules come only from your files.** The command never adds one it thinks you should have, and every rule quotes its line.
- **The rubric files are rewritten on every compile.** Keep hand-written rules in `write.yml` and `tools.yml`. The one edit that is kept is [`enabled: false`](#switching-a-rule-off), for a generated rule you do not want.
- **Read the generated detectors.** They are code that runs in your hooks.
- **`judge` rules need a judge configured**; the rest work offline.

`bin/rules-rubric.rb` is the deterministic half of the command:

| Command | Does |
|---|---|
| `rules-rubric.rb sources` | Lists the instruction files, the glob each applies to, its sha256, and whether the rubric is out of date with it |
| `rules-rubric.rb validate` | Checks both rubric files against what the hooks accept: types, globs, regexes that compile, detectors that load, unique names, sources that still match. Exits 1 on any issue |

Nothing tells you when a source has changed since the last compile; run `rules-rubric.rb sources` to check, and `/rules-compile` again to refresh.

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

A write detector receives `file_path:`, `relative_path:`, `new_content:`, and `session_id:`. A tool detector receives `tool:`, `tool_input:`, and `session_id:`. Both also receive `rule:`, the rule's own YAML hash, so a detector can read extra configuration declared alongside the rule. Always accept `**` for forward compatibility.

That `rule:` hash is how a detector stays stack agnostic instead of hard coding one framework's layout. The bundled `broad_search_advisory` reads a `roots:` list from its rule (`roots: [app, lib, spec, config]` in the Rails preset, with a generic fallback), so the same code flags broad searches in a Node or Go repo once you point `roots:` at `src`, `cmd`, or `internal`.

Return:

- `false` or `nil` to pass silently.
- `true` to fire with the rule's YAML `context`.
- a `Hash` to fire with overrides: `:context` replaces the message for this fire, and `:sentinel_suffix` namespaces the session sentinel (so a `once_per_session` rule can fire once per target, for example once per model, rather than once globally).

Detectors being Ruby is the point. A detector runs in the repo and can read the project's own files, so it can name a real finding rather than guess from a string match.

## Semantic rules with a judge (optional)

Some conventions are easy to state and hard to regex. A write rule can hand the match to a decision model, the judge. It answers a yes/no question with a probability, and the rule fires when that probability clears the threshold.

The rule names no model. The default judge is [Jev](https://typesafe.ai), TypeSafe's hosted decision model, and which one answers is set by environment variable, so swapping it never touches `write.yml`.

```yaml
migration_backfill_semantic:
  type: block
  files: ["db/migrate/**/*"]
  pattern: 'update_all|find_each|update!'   # optional prefilter, runs first    
  judge:
    question: "Does this migration backfill data in the same file that adds a NOT NULL column?"
    threshold: 0.8                            # default 0.7
  context: Split the backfill into its own migration.
```

A question can say more than that:

| `judge:` key | Does |
|---|---|
| `criteria` | For a yes/no question, a `true` and a `false` example sent with it |
| `flag` | A second, lower bar. A score from `flag` up to `threshold` goes to you as a `systemMessage`; the agent is not told. Unset, anything under `threshold` is silent |
| `type: choice` | Asks which of the options in `criteria` (a map of name to description) applies. `violating` lists the ones that break the rule |
| `type: score` | Asks where on the ordered levels in `criteria` (a list, best first, at most 10) the change sits. `violating_from` is the index of the first level that breaks the rule |

For `choice` and `score` the probability held against `threshold` is the weight the judge put on the violating answers:

```yaml
comment_restates_code:
  type: warn
  files: ["app/**/*.rb"]
  pattern: '#'
  judge:
    type: score
    question: "How much does a comment added here restate the code beside it?"
    criteria: ["not at all", "in passing", "line for line"]
    violating_from: 2
    flag: 0.5
  context: Say why, not what.
```

The judge may be a paid network call, so a `judge:` rule is skipped on every edit and judged once, on `Stop`, over what the turn changed:

```
PreToolUse / PostToolUse                Stop
────────────────────────────────        ──────────────────────────────────────────
glob, pattern, detector rules           `judge:` rules only
`judge:` rules skipped, nothing sent    files changed since the prompt
                                          └─ per file, one request with every
                                             matching `judge:` rule as a question
                                               ├─ p ≥ threshold ─► turn stays open
                                               ├─ p < threshold ─► silent
                                               └─ unset / down  ─► silent
```

| Type | At `Stop` |
|---|---|
| `block` | `decision: block`. The agent is sent back with the finding. |
| `block_once` | Same, the first time this session. |
| `warn` | `additionalContext`. The agent still sees it and the turn continues, but as hook feedback rather than an error. Honours `once_per_session`. |

- **One turn is kept open at most twice**: the first finding, then one re-check of whatever the agent changed in response. Anything after that goes to you as a `systemMessage` and the turn ends.
- **A finding the agent leaves alone does not come back.** Only files that moved since the last `Stop` are asked about.
- **Your own edits between turns are not judged.** The working tree is recorded again on every prompt.
- **Write rules only.** `judge:` on a tool rule is skipped; see [what each kind supports](#how-rules-work).
- **A detector file still wins.** A rule with one is decided before the write as usual and never sent to the judge.
- **It is opt in and fails open.** With no key and no URL set, nothing is sent. If the judge is unreachable, `judge:` rules stay silent.

It needs a git repo, like the post-write sweep, and it stays silent when more than 25 files changed in one turn. A `/compact` in the middle of a turn resets the record, so edits made before it in that turn are not judged.

| Env | Default | |
|---|---|---|
| `RULEKIT_JUDGE_API_KEY` | unset | Bearer token. Falls back to `TYPESAFE_AI_API_KEY` |
| `RULEKIT_JUDGE_URL` | `https://api.typesafe.ai/v1` | API base. Falls back to `TYPESAFE_AI_BASE_URL` |
| `RULEKIT_JUDGE_MODEL` | `jev-latest` | Model id |
| `RULEKIT_JUDGE_TIMEOUT` | `10.0` | Read timeout, seconds. Anything that is not a positive number falls back to the default |

The judge is on once either the key or the URL is set. For Jev that means a key. Any server that speaks the same `POST {url}/systemone` protocol works as a drop-in: set the URL and model, and a key only if it wants one.

What is sent, and what happens when the judge is down, is under [Cost, privacy, safety](#cost-privacy-safety).

`spec/judge_spec.rb` exercises all of this against a fake server, so it runs without a key.

### Abide rubrics (optional)

[Abide](https://github.com/coldteadotai/abide) compiles the same instruction files into `.abide/rubric.json`, where every model-checked rule is a question for the same judge. Set one variable and the Stop hook asks those questions too, beside your own `judge:` rules and in the same request per file:

```
export RULEKIT_ABIDE_RUBRIC=1
```

| `RULEKIT_ABIDE_RUBRIC` | Reads |
|---|---|
| unset, empty, `0`, `false`, `no`, `off` | nothing. This is the default |
| `1`, `true`, `yes`, `on` | `<project>/.abide/rubric.json` |
| anything else | that path, absolute or relative to the project |

Each rule is read as a `block` rule with a `judge:` block:

| Abide | Becomes |
|---|---|
| `id` | the rule's name |
| `scope`, or every file when absent | `files` |
| `check.question`: `boolean`, `choice` or `score`, with its `criteria` | `judge.question`, `type` and `criteria` |
| `violating`, `violatingFrom` | `judge.violating`, `violating_from` |
| `thresholds.act`, 0.8 by default | `judge.threshold` |
| `thresholds.flag`, 0.5 by default | `judge.flag` |
| `text` and `source` | `context`, as `<text> (<path>:<line>)` |

- **Only the Stop hook reads it.** The per-edit hooks and the sweep never see these rules, and rulekit never writes to the rubric. Compiling, calibrating and tuning it stay Abide's job.
- **It uses rulekit's judge settings**, so it needs the key or URL [above](#semantic-rules-with-a-judge-optional). `TYPESAFE_AI_API_KEY` in the environment is enough; Abide's `~/.abide/.env` and its global rubric are not read.
- **Some rules are left out:** `lint`, `deferred` and `unenforceable` checks, and any rule whose `status` is not `active`.
- **Banded like Abide.** At `thresholds.act` and above the agent is sent back. From `flag` up to `act` you get a note and the agent does not. Below `flag`, nothing.
- **`when` is ignored.** An `edit` rule and a `turn` rule are both asked once per changed file, about the lines the turn added to it. A `turn` rule that needs the whole diff or the prompt ("did this add more than was asked") is answering with less than Abide gives it.
- **Globs are Ruby's, not picomatch's.** `**/*.ts` means the same in both; a brace set like `*.{ts,tsx}` or a `!` negation does not match here.
- **A `write.yml` rule of the same name wins**, and a missing, malformed or other-version rubric is ignored.
- **Switching one off.** Abide's own `status` is respected: anything but `active` is skipped. To switch a rule off from rulekit's side without touching the rubric, add its `id` to `write.yml` with only `enabled: false`. `enabled` inside `rubric.json` is not read, since Abide would drop it on the next compile.

Running Abide's own hooks as well would ask each question twice. Use this instead of `abide init`, not on top of it.

`spec/abide_rubric_spec.rb` covers it against the same fake server.

## block, warn, and block_once

| Type | Behaviour |
|---|---|
| `block` | Denies the tool call every time (`permissionDecision: deny`, exit 2). |
| `warn` | Injects an advisory as `additionalContext` and allows the call. Honours `once_per_session`. |
| `block_once` | Denies the first attempt this session, then yields silently on the retry. The escape hatch for "usually wrong, occasionally meant." |

`block_once` and `once_per_session` are tracked with sentinel files under `tmp/.claude-advisory/<session_id>/`. The bundled `SessionStart` hook clears the current session's sentinels at the start of each session (startup, resume, `/clear`, `/compact`), so "once" means once per working session, not once forever.

## Writes that bypass the write tools

A rule matched on `Edit|MultiEdit|Write` guards a tool, not a codebase. Everything below writes code without tripping one:

```bash
cat > app/services/thing.rb <<'EOF'   # heredoc
sed -i '' 's/foo/bar/' app/models/x.rb
python3 -c "pathlib.Path('app/x.rb').write_text(...)"
```

That is not a hypothetical. Claude Code's auto mode explicitly tells the agent to prefer `Bash` for file edits, and a whole service layer can land through heredocs with every rule silent.

So `post-write-sweep.rb` runs on `PostToolUse` for **every** tool and replays the same `write.yml` rules over what actually changed on disk. Nothing about the rules changes; only when they are evaluated does.

```
PreToolUse(Edit|Write)  →  rules see the content about to be written
PostToolUse(*)          →  rules see the lines that did get written
```

**How it decides what is new.** `git status` supplies the candidate set — cheap, and it honours `.gitignore`. Content comes from a per session snapshot of each file's last seen state under `tmp/.claude-advisory/<session_id>/snapshots/`, so `new_content` is the lines that one tool call added: not the whole file, and not the whole branch diff. A tracked file with no snapshot yet falls back to its `HEAD` version, so a one line `sed` into a committed file does not re-flag everything already in it. Writing the snapshot back is also what stops a rule re-firing on every later tool call — once swept, a file shows no delta until it changes again. A snapshot is dropped once git stops calling its file dirty, because it was deleted, committed or reverted, so the same lines written again are checked again.

**What it deliberately ignores.**

| Ignored | Why |
|---|---|
| The file an `Edit`/`MultiEdit`/`Write`/`NotebookEdit` just wrote | The `PreToolUse` hook already checked that content; re-checking would warn twice |
| `git checkout`, `rebase`, `stash`, `reset`, … | That is history arriving, not the agent authoring code |
| More than 25 files moving in one tool call | Same reason, for whatever the command list misses. Counted against what changed since the last sweep, not against everything the branch has dirty, so a big working tree does not switch the sweep off |
| The first sweep of a session | It only records the starting state, so a dirty branch does not flood the first tool call |
| Files over 512KB, and binaries | Generated or vendored, not hand written |

**Types behave the same, except `block`.** A write that has already landed cannot be denied, so a post-write block comes back as `decision: "block"` with a reason telling the agent to revert it, rather than `permissionDecision: "deny"`.

| Type | `PreToolUse` | post-write sweep |
|---|---|---|
| `block` | Denies the call | `decision: block` — "this landed, undo it" |
| `block_once` | Denies once, yields on retry | Same, and the retry is a no-op write with no delta |
| `warn` | `additionalContext` | `additionalContext` |

The sweep is not a substitute for the pre-write hooks; catching a write before it happens is strictly better. It is the backstop for when the agent takes a route the matchers do not cover.

## Cost, privacy, safety

- **Deterministic rules send nothing anywhere.** Glob, regex and detector rules run locally and need no key.
- **The judge is opt in.** With no key and no URL set, nothing is sent and `judge:` rules stay silent.
- **What the judge sees:** the file path and the lines the turn added to that file, cut at 8000 characters, and only for files a `judge:` rule covers. With `RULEKIT_ABIDE_RUBRIC` on, an unscoped Abide rule covers every file. Never the conversation. Leave `judge:` off rules that cover files you would not send to a third party.
- **What it costs:** one request per changed file per turn, carrying every matching `judge:` rule as a question. A rule's `pattern` runs first, so the judge is only asked when it could matter.
- **It fails open.** An unreachable judge, a timeout or a bad response leaves `judge:` rules silent, and the judge is marked down for 60 seconds so an outage costs one attempt, not one per file.
- **The model is yours to choose.** The default is [Jev](https://typesafe.ai), TypeSafe's hosted decision model. Any server that speaks the same protocol works by setting `RULEKIT_JUDGE_URL`.

## How it hooks in

| Event | Runs | Does |
|---|---|---|
| `PreToolUse` on `Edit`, `MultiEdit`, `Write` | `write-rules-check.rb` | Write rules against the content about to be written |
| `PreToolUse` on `Bash`, `Grep`, `Glob`, `Read` | `tool-rules-check.rb` | Tool rules against the command, search or path |
| `PostToolUse` on every tool | `post-write-sweep.rb` | The same write rules against what changed on disk |
| `UserPromptSubmit` | `stop-rules-check.rb --record` | Records the working tree, so your own edits between turns are not judged |
| `Stop` | `stop-rules-check.rb` | `judge:` rules against what the turn added, and an [Abide rubric](#abide-rubrics-optional) when switched on |
| `SessionStart` | cleanup, then both recorders | Clears the session's "once" sentinels and records the starting state |

## Also in this marketplace: exhalekit

Rulekit guards the inhale: it keeps conventions in view at the moment the agent writes code. [**exhalekit**](plugins/exhalekit/README.md) guards the exhale: a `PostToolUse` hook that fires after every non-refactor commit and makes the agent review what it just built for duplication and design drift, backed by a diff-scoped rubycritic run so the review has evidence behind it.

```
/plugin install exhalekit@rulekit
```

The two are independent; install either, or both. Exhalekit needs **`jq`**; its `/exhale-init` additionally assumes a Ruby project with Bundler, since the `diff-quality` script it installs shells out to `bundle exec rubycritic`. The hook itself is language agnostic and degrades to a plain reminder where that script is absent.

## Repo layout

This repo is a marketplace, not a plugin. Rulekit's manifest is at `plugins/rulekit/.claude-plugin/plugin.json` and the marketplace metadata at `.claude-plugin/marketplace.json`. The root holds only marketplace metadata and docs; every plugin lives under `plugins/<name>/`, matching the convention Anthropic's own marketplace uses.

Inside a plugin, the `hooks/`, `commands/`, and `skills/` directories are discovered automatically. A plugin manifest must **not** name them — doing so registers them twice and the loader rejects the plugin outright.

```
claude-rulekit/
├── .claude-plugin/
│   └── marketplace.json                      # lists both plugins and their paths
├── LICENSE
├── README.md                                 # you are here
│
└── plugins/
    ├── rulekit/
    │   ├── .claude-plugin/
    │   │   └── plugin.json                   # name, version, keywords only
    │   ├── hooks/
    │   │   └── hooks.json                    # PreToolUse (write + tool), PostToolUse, Stop, UserPromptSubmit, SessionStart
    │   ├── bin/
    │   │   ├── write-rules-check.rb          # Edit/MultiEdit/Write engine
    │   │   ├── tool-rules-check.rb           # Bash/Grep/Glob/Read engine
    │   │   ├── post-write-sweep.rb           # replays write.yml over writes that bypassed the tools
    │   │   ├── stop-rules-check.rb           # judges `judge:` rules over the turn's changes on Stop
    │   │   ├── rules-rubric.rb               # sources + validate for /rules-compile
    │   │   └── clear-advisory-sentinels.sh   # SessionStart sentinel cleanup
    │   ├── lib/
    │   │   ├── rules_runner.rb               # shared matching, sentinels, output
    │   │   ├── working_tree.rb               # what changed on disk, for the sweep and the Stop hook
    │   │   ├── judge_client.rb               # optional `judge:` rules; the model backend lives here
    │   │   └── abide_rubric.rb               # optional: an Abide rubric read as `judge:` rules on Stop
    │   ├── commands/
    │   │   ├── rules-init.md                 # /rules-init <preset>
    │   │   ├── rules-compile.md              # /rules-compile
    │   │   └── rules-test.md                 # /rules-test
    │   ├── Gemfile                           # rspec, for the suite only; the hooks need no gems
    │   ├── spec/                             # bundle exec rspec
    │   │   ├── judge_spec.rb                 # `judge:` rules and the Stop hook against a fake server
    │   │   ├── abide_rubric_spec.rb          # an Abide rubric judged on Stop
    │   │   ├── rubric_spec.rb                # generated rubric files, sources and validate
    │   │   ├── presets/
    │   │   │   └── rails_spec.rb             # every preset rule fires/stays silent, and the sweep
    │   │   └── support/                      # throwaway project, hook runner, fake judge
    │   ├── skills/
    │   │   └── sorbet-inline-rbs/
    │   │       └── SKILL.md                  # invoked by the dormant Sorbet rule
    │   └── presets/
    │       └── rails/                        # copied in by /rules-init rails
    │           ├── write.yml                 # 15 rules
    │           ├── tools.yml                 # 1 rule
    │           ├── detectors/
    │           │   ├── broad_search_advisory.rb
    │           │   ├── migration_backfill.rb
    │           │   ├── migration_missing_fk_index.rb
    │           │   ├── missing_http_timeout.rb
    │           │   ├── model_wrapper_delegation.rb
    │           │   ├── sorbet_inline_rbs_advisory.rb   # ready, rule ships commented out
    │           │   └── validates_uniqueness_no_index.rb
    │           └── README.md                 # per-rule table and the opinions encoded
    │
    └── exhalekit/                            # see its own README for detail
        ├── .claude-plugin/
        │   └── plugin.json
        ├── hooks/
        │   ├── hooks.json                    # PostToolUse on Bash
        │   └── exhale-reminder.sh            # fires after a non-refactor commit
        ├── commands/
        │   ├── exhale-init.md                # /exhale-init [base-branch]
        │   └── simplify-with-analysis.md     # /simplify-with-analysis [base-branch]
        ├── templates/
        │   └── diff-quality                  # installed into your repo as bin/diff-quality
        └── README.md
```

Only `presets/` is ever copied into your project. Everything else stays in the plugin and runs from there via `${CLAUDE_PLUGIN_ROOT}`, so plugins can be relocated without touching a single hook or command path.

Rulekit's tests are RSpec, and drive the hooks the way Claude Code does: a JSON event on stdin, stdout and the exit code back.

```
cd plugins/rulekit
bundle install
bundle exec rspec
```

Adding a third plugin means a new directory under `plugins/` and one more entry in `marketplace.json`. Nothing at the root changes.

## Presets

`plugins/rulekit/presets/rails/` is a portable set of opinionated Rails conventions generalized from a real production app: fifteen write rules (no `default_scope`, the service object DDD check, the migration safety checklist, `NOT NULL` + backfill in one migration, unindexed foreign keys, `.all.map` instead of SQL, model queries in views, fat model nudges, heavy spec setup, SQL-injection interpolation, bare `rescue`, model references in migrations, missing HTTP timeouts, and uniqueness-without-index) and one tool rule that narrows broad repo searches. See [`plugins/rulekit/presets/rails/README.md`](plugins/rulekit/presets/rails/README.md) for the full table and the opinions each rule encodes.

Presets for other stacks are welcome. A preset is just a `write.yml`, a `tools.yml`, and an optional `detectors/` directory.

## Credit

- **Hookify** (Anthropic) for the declarative block/warn-on-edit model rulekit builds past.
- Anthropic's writing on **just-in-time context** and **progressive disclosure**, and the **context rot** failure mode they describe.

## License

MIT. See [LICENSE](LICENSE).
