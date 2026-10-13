# Next steps: model-judged rules + competitive response

_Written 2026-09-27, revised 2026-10-13: Laya dropped; rules use a backend-neutral `judge:` block, Jev by default._

## Positioning

**Rulekit stays deterministic by default. Semantic (model-judged) rules are an optional add-in (`judge:`), asked once per turn on `Stop`. The backend is configuration: hosted Jev today, swappable without touching rules.**

That puts rulekit against [abide](https://github.com/coldteadotai/abide), which judges every rule with Jev, as "deterministic and pre-write first, with the model as a backstop at the end of the turn".

| | rulekit | rulekit + judge | abide |
|---|---|---|---|
| Judgement | glob / regex / Ruby detector | + model probability (`judge:` rules, Jev by default) | hosted probability (Jev) |
| Timing | pre-write deny + post-write sweep | + end-of-turn check on `Stop` | post-edit repair + end-of-turn diff |
| Cost / network | free, offline | paid, API key, only at `Stop` | ~$0.00005/check, login required |
| Rule authoring | hand-written YAML | hand-written YAML | compiled from CLAUDE.md / AGENTS.md |
| Read side | search nudges | same | none at runtime |
| Agents | Claude Code | Claude Code | Claude Code, Codex, OpenCode |

## 1. Engine support for `judge:` rules

**Built on `feat/laya-rules`.** Tested only against a fake server so far; real Jev has never answered a question.

- [x] `plugins/rulekit/lib/judge_client.rb`: stdlib `Net::HTTP`, `POST {base}/systemone`, one `noul` question per rule, `RULEKIT_JUDGE_API_KEY` / `_URL` / `_MODEL` / `_TIMEOUT` with `TYPESAFE_AI_*` fallbacks; fails open on any error
- [x] `bin/stop-rules-check.rb` on `Stop`, with `--record` on `SessionStart` and `UserPromptSubmit` so only the turn's own changes are judged
- [x] One request per changed file carrying every matching `judge:` rule; `pattern` still prefilters
- [x] `RulesRunner#apply_write_rules` skips `judge:` rules, so nothing is sent per edit; a detector file still wins
- [x] `block` → `decision: block`, `warn` → `additionalContext`; a turn is kept open at most twice, then the user gets a `systemMessage`
- [x] Down marker `tmp/.claude-advisory/<session>/judge-down` with a 60s TTL
- [x] `plugins/rulekit/test/judge.sh` + `fake_judge_server.rb`: 43 tests. Rails preset still 71/71.

Still to do:

- [ ] Run against **real** Jev with a key: latency, and whether the answers are any good on code
- [ ] Fixture set (should-fire / should-pass snippets per candidate rule) → precision/recall per threshold, to pick a default threshold
- [ ] Tell the user when the key is rejected. Today a 401 looks the same as an outage: silent
- [ ] Only mark the judge down on connection errors/timeouts/5xx. Today a 4xx (e.g. 422 on a malformed question) also silences every `judge:` rule for 60s
- [ ] Send more than the added lines when the question needs the rest of the file
- [ ] One commented-out example `judge:` rule in the Rails preset (like the Sorbet rule)
- [ ] Log requests and token usage so the cost is visible

## 2. Ideas taken from abide

| Idea | Rulekit version | Priority |
|---|---|---|
| Compile rules from existing docs | **Built**: `/rules-compile` writes `write_rubric.yml` / `read_rubric.yml` from `CLAUDE.md` / `AGENTS.md`, each rule quoting its source line; `bin/rules-rubric.rb sources\|validate`. Still open: a SessionStart nudge when a source changes, and compiling `~/.claude/CLAUDE.md` | Medium |
| End-of-turn whole-diff check | Partly built: `judge:` rules run on `Stop`, but per file. Still open: one whole-diff question for cross-file issues | Medium |
| Rule health reporting | `/rules-report`: which rules fired, which never fired (sentinels + a log) | Medium |
| Calibration against git history | Replay rules over recent commits to find noisy/dead rules. Matters more now that rules are generated: abide runs this as part of compile and switches weak/noisy rules off | Medium |
| Multi-agent support | Codex / OpenCode hook adapters | Low |

## 3. Docs

- [ ] Add abide to README "Prior art" alongside Hookify, with the deterministic-vs-probabilistic distinction.
- [x] Document the judge as optional; nothing is sent until it is configured.

## Open questions

- Is Jev any good at judging **code** zero-shot? Nothing here has measured it.
- Is per-file the right unit, or should `Stop` ask one question about the whole diff?
