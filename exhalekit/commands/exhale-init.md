---
description: Install exhalekit's bin/diff-quality into this Ruby project and wire up the gems it needs.
---

Set this project up so the exhale pass has something to measure. Only do this for a Ruby project — if there is no `Gemfile`, say so and stop.

1. Copy the diff-quality script into the project and make it executable:
   ```
   cp "${CLAUDE_PLUGIN_ROOT}/templates/diff-quality" bin/diff-quality
   chmod +x bin/diff-quality
   ```
   If `bin/diff-quality` already exists, diff the two and report what differs rather than overwriting — the project's copy may have been customised on purpose. Only replace it if the user asks.

2. Check the `Gemfile` for `rubycritic`. If it is missing, add it to the development/test group and tell the user to run `bundle install`. Do not run `bundle install` yourself.

3. Check the `Gemfile` for `undercover`. It is optional — `/simplify-with-analysis` skips the coverage step when it is absent. Mention it as an option; only add it if the user says yes, since it also needs `simplecov` wired to `SimpleCov::Formatter::Undercover` in `spec/spec_helper.rb`.

4. Verify the script runs:
   ```
   bin/diff-quality --last-commit --no-browser
   ```
   "No Ruby files changed against last commit" is a valid, passing result when the last commit touched no Ruby. `--last-commit` is how `/simplify-with-analysis` invokes it; omit the flag (or pass a base branch) to scope to the whole branch instead.

5. Tell the user what you changed in two or three lines, and remind them that `/simplify-with-analysis` is the command that uses it. Do not commit — leave that to the user.
