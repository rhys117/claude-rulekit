---
description: Install bin/diff-quality so the exhale review has evidence behind it
argument-hint: [base-branch]
---

Set up `bin/diff-quality` in the current project. This is the script the exhale hook
and `/simplify-with-analysis` both call: it scopes rubycritic to the files changed
against a base branch and lists the specs related to those files, so the exhale
review runs on the diff instead of the whole repo.

Steps:

1. Confirm this is a Ruby project with a `Gemfile` at the root. If there is no
   `Gemfile`, say so and stop — `diff-quality` shells out to `bundle exec rubycritic`
   and is useless without Bundler.

2. Work out the base branch. Use `$1` if given; otherwise read the repo's default:
   ```
   git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'
   ```
   Note the `sed` — that command prints `origin/main`, and you want the local branch
   name. Fall back to `main` if it prints nothing. Tell the user which one you
   settled on.

3. Install the script, without clobbering a local version:
   ```
   mkdir -p bin
   cp -n "${CLAUDE_PLUGIN_ROOT}/templates/diff-quality" bin/diff-quality
   chmod +x bin/diff-quality
   ```
   If `bin/diff-quality` already existed, `cp -n` leaves it alone. Diff it against
   the template and tell the user what differs rather than overwriting their edits.

4. If the base branch from step 2 is not `main`, update the `BASE_BRANCH` default in
   `bin/diff-quality` to match.

5. Check the `Gemfile` for `rubycritic`. If it is missing, add it to the development
   or test group as `gem 'rubycritic', require: false` and run `bundle install`.
   If it is already there, do nothing.

6. Verify the install by running `bin/diff-quality --no-browser` against the base
   branch. On a branch with no Ruby changes it should print
   `No Ruby files changed against <base>` and exit 0 — that is a pass. If it errors,
   fix the cause before reporting success.

7. Tell the user what happened in a few lines: which base branch, whether the script
   was installed or already present, whether `rubycritic` was added. Mention that
   the exhale hook will now point at `bin/diff-quality` after every non-refactor
   commit, and that `/simplify-with-analysis` runs the deeper review on demand.

Notes:

- Do not edit application code. This command touches `bin/diff-quality` and, only if
  `rubycritic` is absent, the `Gemfile` and `Gemfile.lock`.
- Do not commit anything. Leave the changes in the working tree for the user.
- If the project also has `undercover` and `simplecov` installed,
  `/simplify-with-analysis` will use them for diff coverage. Absent, it skips that
  step. Do not install them here.
