---
description: Install a rulekit preset into this project's .claude/rules/
argument-hint: [preset]
---

Install the rulekit preset named **$1** into the current project.

Steps:

1. If no preset name was given in `$1`, list the available presets by running
   `ls "${CLAUDE_PLUGIN_ROOT}/presets"` and ask which one to install. Stop here.
2. Confirm the preset exists: `ls "${CLAUDE_PLUGIN_ROOT}/presets/$1"`. If it does
   not, list what is available and stop.
3. Create `.claude/rules/` in the project root if it does not exist.
4. Copy the preset in without clobbering local edits:
   `cp -rn "${CLAUDE_PLUGIN_ROOT}/presets/$1/." .claude/rules/`
   (`-n` skips files that already exist, so re-running is safe.)
   Tool rules were called read rules: if the project already has
   `.claude/rules/read.yml` and had no `tools.yml` before the copy, remove the
   `tools.yml` just copied in and say so. `tools.yml` replaces `read.yml` once
   it exists, which would switch the user's own rules off; they can rename
   `read.yml` to `tools.yml` when they are ready.
5. Read the copied `.claude/rules/write.yml` and `.claude/rules/tools.yml` and give
   the user a short summary: how many rules were installed, which are `block` vs
   `warn`, and a one-line reminder that every rule's `context` message is meant to
   be edited to match this project's actual conventions.
6. Remind the user that rulekit's hooks only fire when this plugin is enabled, and
   that they can run `/rules-test` to smoke-test the install.

Do not edit any application code. This command only copies rule files.
