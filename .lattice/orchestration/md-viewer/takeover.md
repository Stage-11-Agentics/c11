# Takeover brief: markdown viewer build (keep current; read run-state.md for the full picture)

**State (2026-10-08 10:10 PDT):**
- **Done:**
  - C11-358 R1: c37ced9d78 (#620).
  - C11-359 R2: a95823705c (#621) plus follow-up fd263426f9 (#622).
- **In repair:**
  - C11-360 R3 (PR #623, panel:108): both reviews FAIL. Briefs `briefs/repair1-C11-360.md` and `repair1b-C11-360.md`. The reviewers stay open to verify: Opus pan:132, Grok pan:136.
  - C11-361 R4 (PR #624, panel:109): Opus Review 1 FAIL, brief `briefs/repair1-C11-361.md`. Grok Review 2 (pan:138) is running; when it posts, send R4 an addendum (or "none"), then R4 pushes once. Opus pan:137 verifies.
- **Pre-warm:** C11-362 N1 (panel:133, Luna Fast Max), brief `briefs/owner-C11-362.md`. Send `GO <sha>` after both C11-360 and C11-361 merge, and PEEK when they hand off repaired heads.
- **Not started:** C11-363 N2 (needs a brief, mirroring owner-C11-362; corpus decisions are in run-state Decisions). Final fresh computer-use Validator (brief to write; acceptance list in the original launch brief: messaging-primitive doc, outline/find/source, all themes and typefaces, size by keyboard and toolbar, 560 and wide, Mermaid including the sequence diagram, open-externally, live reload mid-scroll, 357 link navigation with back/forward; compare to the prototype).
- **Seats:** Merge Captain panel:103 (Codex), mailbox `md-merge-captain`, LAND format in run-state. Workspace workspace:16. My mailbox `md-viewer-orchestrator`.

**Rules learned:**
- Never `mailbox recv --drain >/dev/null`; print the bodies.
- `mailbox send` needs `--body`.
- PR CI is Ubuntu-only, so a Swift PR needs the captain's Atlas exact-head gate.
- The main backstop's BrowserDeveloperToolsVisibilityPersistenceTests failure is pre-existing; ignore it.
- After a Codex `/model` switch, restore `~/.codex/config.toml`.
- Atlas guests: two slots max.

**Closeout:**
- Mint one hardening ticket from run-state's list.
- Final report to md-viewer-scoping and C11-336 (merged PRs and SHAs, validation evidence, memory numbers, decisions, follow-ups).
- Disarm the Atlas watchdog: `rm ~/md-viewer-run/armed`, then remove the crontab line.
- Close the fleet surfaces and prune the worktrees.

**Next three moves:**
1. Route the Grok C11-361 verdict.
2. Send VERIFY to R3's reviewers on its new head.
3. LAND whichever of 360 or 361 passes first.
