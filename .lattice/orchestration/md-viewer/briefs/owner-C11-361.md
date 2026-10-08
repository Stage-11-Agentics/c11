# Owner brief: C11-361 (R4, agent CLI + skill)

- Ticket **C11-361** (`lattice show C11-361`; parent C11-336). Actor `agent:codex-md-r4`. Panel title `R4 Markdown CLI`.
- Worktree `/Users/atin/Projects/Stage11/code/c11-worktrees/md-r4-cli`, branch `md-viewer/C11-361-agent-cli`.
- Depends on C11-359 (native panel + state model + bridge host); runs in parallel with C11-360. Starts on GO after C11-359 merges.

## What you build
The ticket description: `c11 markdown scroll|visible [--watch]|theme|typeface|font|open-external`, all with `--panel`, backed by `markdown.*` socket methods. Queries run off-main; only the web-view hop runs on main; non-focus commands never change macOS focus, the operator's visible workspace or in-app focus. Register the feature in the capability registry the way other versioned features are. Update `skills/c11-markdown/SKILL.md` and `references/commands.md` (and `skills/c11` if anything there changes) in the same PR, in the exact shape of the CLI that ships. Behavioural tests through the CLI/socket seam. `CLI/c11.swift` is a hot file: keep your edits in a contained block.

## Proof
Atlas tagged build (`--tag md-361`): each command driven from a terminal against a markdown panel in a background workspace, with observed output, a screenshot of the scroll flash, `visible --watch` streaming while the panel scrolls, and unknown theme/typeface names plus out-of-range scales rejected.

## Review track
Normal: Review 1 Claude Opus, Review 2 Grok.
