---
description: Run the /simplify exhale review, then check the last commit for rubycritic regressions and the branch for uncovered lines.
---

Run the standard `/simplify` exhale review, then check for rubycritic regressions and uncovered lines.

Rubycritic is scoped to the **last commit** by default — the exhale follows a commit, so that commit is the work under review. Pass a base branch as `$1` to widen it to the whole branch instead (`main`, or `master` if that is what this repo uses). Coverage is always compared against the base branch.

**Guiding principle: be pragmatic.** Rubycritic and undercover are regression *signals*, not scorecards to chase. Judge every flagged smell against Kent Beck's four rules of simple design: passes the tests → reveals intention → no duplication → fewest elements. Check the project's `CLAUDE.md` for design rules and for any smells it already documents as known false positives, and honour them. Many smells are false positives on deliberate designs — DSL value objects, declarative config data, cohesive domain classes. When a smell contradicts a design decision already assessed against Beck's rules, the right response is to **add it to `.reek.yml` / `.rubycritic.yml` ignores**, not to refactor against your own judgment. Likewise, not every uncovered line warrants a test — trivial getters, defensive branches that can't realistically be hit, and glue code may be fine. Chasing the score degrades the code.

Follow these steps in order:

1. Invoke the bundled `/simplify` skill (via the Skill tool) and let it complete its review and any fixes it proposes. Do not skip this step — `/simplify` is the primary signal; the other checks are regression guards on top of it.

2. After `/simplify` finishes, run the diff-quality script scoped to the last commit:
   ```
   bin/diff-quality --last-commit --no-browser
   ```
   This analyses only the files that commit touched and runs related specs, keeping things fast and avoiding whole-repo noise. If `$1` was given, use `bin/diff-quality $1 --no-browser` instead to scope to the whole branch. If `bin/diff-quality` does not exist, run `/exhale-init` first to install it, then continue.

3. From the console output, identify for each file it reports:
   - Any file now rated **D or F** that was not D/F on the base branch (regression).
   - Any new smell *types* introduced on changed files.
   - Skip anything `CLAUDE.md` documents as a known false positive for this repo.

4. If the project uses undercover (check for it in the `Gemfile`), check diff coverage. It reads the `SimpleCov::Formatter::Undercover` output at `coverage/coverage.json` produced by the test suite:
   ```
   bundle exec undercover --compare main
   ```
   If undercover reports that coverage data is missing or stale, tell the user to re-run the relevant specs and try again — do **not** silently skip this step. If the project does not use undercover, say so in one line and move on.

5. For each undercover warning, classify:
   - **Genuine** — material logic (branches, conditionals, domain methods) on code this branch introduced or meaningfully changed. Add a test.
   - **Acceptable** — trivial or defensive code (simple accessors, logging, unreachable error fallbacks, view helpers verified manually). Note and move on.
   - **Pre-existing** — the uncovered lines weren't introduced by this branch. Don't act.

6. Report rubycritic + undercover findings together as a short list. For rubycritic regressions, say whether the smell is **Genuine**, **False positive** (extend `.reek.yml` / `.rubycritic.yml` ignores), or **Acceptable**.

7. Close the loop on Genuine findings in one follow-up pass:
   - For genuine rubycritic regressions, make the refactor.
   - For genuine undercover warnings, add the test.
   - For false positives, extend the ignore config.
   - Leave the changes uncommitted for now — step 8 needs them in the working tree.

8. Re-run the analysis **once** to confirm, *before* committing the follow-up:
   ```
   bin/diff-quality --last-commit --no-browser
   bundle exec undercover --compare main
   ```
   `--last-commit` diffs the working tree against the reviewed commit's parent, so it covers both that commit and the uncommitted fixes. Committing first would narrow the scope to the fixes alone.
   - If the re-run is clean, commit the follow-up changes separately from `/simplify`'s commit (keep exhale phases distinct per the inhale/exhale rhythm), then stop.
   - If the re-run surfaces *new* genuine findings that weren't in the first pass, **surface them to the user and stop** — do not iterate further. Repeated rounds of "fix → re-analyse → fix" on the same exhale is a sign you're chasing the tools rather than designing.

9. If there were no regressions at step 6, say so in one line and stop without running step 7 or 8.

Rules:
- Do not re-run the full-repo rubycritic sweep — diff mode only.
- Do not silence a smell to make the score go up. Ignores are for design decisions already assessed against Beck's rules, not for convenience.
- Do not write low-value tests just to cover a line. A test that doesn't meaningfully exercise behavior is noise.
- If `/simplify` already addressed a smell or coverage gap the tools flag, don't double-count it.
- At most **one** follow-up pass + **one** re-analysis per invocation. Further work is the user's call.
