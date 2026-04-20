# C11-3: c11 installer / skill-copy UX

Polish the first-run installer and skill-copy UX so that new operators land with skills/c11/ copied to the right tool config locations (cc ~/.claude/skills/, codex equivalent, etc.).

Principle reminder: c11 does NOT write to user tool configs. The installer only copies the skill file; the operator decides whether their TUI loads it.

Depends on: C11-1 (skill directory must be skills/c11/ before installer copies it).

Related: CMUX-40 already shipped the Agent Skills pane + CLI + first-launch wizard. This ticket is follow-up polish on post-rebrand naming.
