# C11-1: c11mux → c11 rebrand pass (fork-level, upstream-compatible)

Rename the Stage 11 fork's product brand from c11mux to c11. Scope is fork-level only — upstream manaflow-ai/cmux untouched.

**Heuristic: user sees it → rename; compiler/daemon sees it → don't.**

Rename: product brand in prose, README, CLAUDE.md, PHILOSOPHY.md, CHANGELOG.md, C11MUX_TODO.md → C11_TODO.md, docs/ active plans, skills/ directory names and content, Resources/welcome.md, Resources/Localizable.xcstrings values.

Do NOT rename: CLI binary cmux, env vars (CMUX_*), socket paths, bundle IDs, Xcode targets/schemes, cmuxd daemon, Swift/Zig source identifiers, historical spec/review-pack docs, GhosttyTabs.xcodeproj/.

Execution: 4 parallel agents on disjoint file trees. Briefs at notes/c11-rebrand/. B3 (skills/) runs last to avoid mid-session skill-load conflicts.

Follow-ups: C11-2 (landing + demo video), C11-3 (installer / skill-copy UX), separate ticket for runtime c11 CLI symlink.

Acceptance:
- rg -i c11mux returns only whitelisted historical docs and intentional identifiers
- cmux binary still works; skill still auto-loads under skills/c11/
- Dry-run upstream merge from manaflow-ai/cmux has zero conflicts in Sources/, cmuxd/, Xcode project
- ./scripts/reload.sh --tag c11-rebrand smoke test passes
