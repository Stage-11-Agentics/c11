Anchor close-out. All three child milestones shipped on main; this parent was just left at planned.

- CMUX-21 (M1 — engine + parser + default theme + surface adoption): done. PR #28.
- CMUX-32 (M2 — workspace color prevalence + frame + dividers): done. PR #30 + C11-8 PR #45 chrome refinement.
- CMUX-35 (M3+M4 — user themes + hot reload + Settings + CLI): done. PR #31 + Radical theme PR #35 + upstream theme-picker polish.

Verified on main:
- Sources/Theme/ holds the full engine (C11muxTheme, ThemeManager, ThemedValueAST/Parser/Evaluator, TomlSubsetParser, ThemeContext, ThemeRoleRegistry, ThemeDirectoryWatcher, ThemeCanonicalizer, ThemeSocketMethods, WorkspaceFrame, ResolvedThemeSnapshot).
- Resources/c11-themes/ ships stage11 + phosphor + radical built-ins plus README.
- c11 themes CLI is live (list/get/set/clear/reload/path/dump/validate/diff).
- Light/dark slot binding via @AppStorage two-slot model, themes mode-agnostic per §12 #12.
- Per-bundle-ID @AppStorage isolation per §12 #14.
- Read-only theme socket methods per §12 #13.

§12 locks honored. M5 (stretch) intentionally not pursued, no re-justification triggered.