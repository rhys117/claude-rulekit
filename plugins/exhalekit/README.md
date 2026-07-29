# exhalekit

The exhale half of Kent Beck's inhale/exhale rhythm, as a Claude Code plugin.

An agent is very good at the inhale — write a failing test, make it pass, commit.
It is much worse at the exhale, because nothing forces it. Left alone it keeps
adding, and design quality erodes one reasonable-looking commit at a time. This
plugin makes the exhale arrive on its own, and gives it evidence to work from.

Where [rulekit](../README.md) fires *before* an edit to keep conventions in view,
exhalekit fires *after* a commit to keep the design honest.

---

## What's in it

| Component | Type | Fires / runs when |
|---|---|---|
| `exhale-reminder` | `PostToolUse` hook on `Bash` | A `git commit` succeeds and the message does **not** look like a refactor pass. Injects a reminder to review the change for duplication, coupling, and drifted naming. |
| `/exhale-init` | command | You run it. Installs `bin/diff-quality` into the project and makes sure `rubycritic` is in the `Gemfile`. |
| `/simplify-with-analysis` | command | You run it. Runs the built-in `/simplify` review, then checks the branch for rubycritic regressions and undercover coverage gaps. |

The hook stays quiet when the commit message contains `refactor`, `simplify`, or
`exhale` — that commit *is* the exhale, so nudging again would loop.

---

## Install

```
/plugin marketplace add rhys117/claude-rulekit
/plugin install exhalekit@rulekit
```

Then, once per project:

```
/exhale-init
```

That drops `bin/diff-quality` in the repo and adds `rubycritic` to the `Gemfile` if
it isn't already there. Pass a base branch if the project's default isn't `main`:
`/exhale-init develop`.

Until you run it, the hook still fires — it just points you at `/exhale-init`
instead of at a script that isn't there.

---

## bin/diff-quality

The script the whole plugin is built around. It answers "did this branch make the
code worse?" without the noise of a whole-repo sweep:

- Diffs `*.rb` against the base branch, excluding `spec/`, `db/schema.rb`, and
  `config/routes.rb`.
- Maps each changed `app/` file to its likely spec, plus the request spec for
  controllers, and lists them.
- Runs `bundle exec rubycritic` scoped to just those changed files.

```
bin/diff-quality                 # vs main, opens the HTML report
bin/diff-quality --no-browser    # console only — use this in agent sessions
bin/diff-quality develop         # vs another base branch
```

Always pass `--no-browser` in an agent session. Without it rubycritic tries to open
a browser and the call hangs.

It is a plain script in your repo once installed, not something the plugin owns.
Edit it freely; `/exhale-init` will not overwrite a version you've changed.

---

## Ruby only

`diff-quality` shells out to `bundle exec rubycritic`, and the spec-mapping assumes
`app/` → `spec/`. The hook itself is language-agnostic — if you want the exhale
nudge on a non-Ruby project, enable the plugin and skip `/exhale-init`. You'll get
the reminder without the evidence.

---

## Opting out

Enabling the plugin in a shared project `.claude/settings.json` opts in the whole
team. To back out for yourself, disable it in the gitignored
`.claude/settings.local.json` — local settings override project settings:

```json
{ "enabledPlugins": { "exhalekit@rulekit": false } }
```

That removes the hook and both commands together. Claude Code has no way to disable
one plugin's hooks while keeping the plugin, so this is all-or-nothing by design —
one switch, in a file you own, rather than a second mechanism to remember.

---

## Opinions you may not share

- **The exhale is not optional.** The hook fires on every feature commit, not on
  request. There's no dial between "on" and "off" — if you disagree, turn the plugin
  off for yourself (see [Opting out](#opting-out)).
  Where the plugin is enabled in a shared project `settings.json`, a developer who
  doesn't want the nudge can opt out for themselves with `EXHALEKIT_DISABLED=1`
  (see [Opting out](#opting-out)) rather than unenrolling the team.
- **Review the diff, not the repo.** A whole-repo critic run buries a regression
  your branch introduced under a hundred pre-existing ones.
- **Ignores beat refactors for false positives.** When a smell contradicts a design
  decision you've already assessed against Beck's four rules, put it in `.reek.yml`
  or `.rubycritic.yml`. Refactoring against your own judgment to please a tool is
  how the score goes up and the code gets worse.
- **Feature and refactor commits stay separate.** The hook's skip-on-`refactor`
  behaviour assumes you're keeping them apart.
