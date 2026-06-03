# C11-33: c11 new-split / new-pane: --cwd flag to set new shell's cwd at creation

## Problem

Shells spawned by \`c11 new-split\` and \`c11 new-pane\` start in \`\$HOME\`. They do not inherit:
- the parent pane's terminal cwd, or
- the orchestrator's Bash-subprocess cwd (the agent calling the split).

Result: every sub-agent launched into a fresh pane to work on a project must be sent a \`cd /path && claude ...\` prefix in the spawn command. Forgetting it (easy to do during multi-agent orchestration) means the sub-agent boots in \`~\`, fails to find the repo, and either errors out or compensates by cd'ing itself based on prompt context. Both wastes tokens and creates a class of subtle ordering bugs.

Hit live during C11-32 orchestration (Phase 4 + Phase 7 sub-agent spawn) on 2026-05-06.

## Proposed fix

Add \`--cwd <path>\` to:
- \`c11 new-split\`
- \`c11 new-pane\`

Sets the new shell's working directory at creation time, before the PTY is wired up. Optional flag; defaults to current behavior (\$HOME) for backwards compat.

Stretch consideration: also \`--cwd inherit\` to mean "use the parent pane's terminal cwd" via standard TTY foreground-process introspection.

## Relevant files (likely)

Wherever \`new-split\` / \`new-pane\` socket handlers spawn the PTY shell.

## Out of scope

Auto-inheriting cwd by default would be a behavior change with potential blast radius (existing scripts/keybindings rely on \$HOME default). Keep this opt-in via flag.

## Workaround until shipped

Documented in c11 SKILL.md ("\`cd\` to the project before \`claude\` / \`codex\`" callout) and in agent prompts: always prefix \`cd /repo && \` to the launch line.
