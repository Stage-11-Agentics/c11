Backfill close-out. PR #31 merged 2026-04-20 (user themes + hot reload + Settings picker overload + CLI + socket).

M3 + M4 all delivered and verified on main:
- Sources/Theme/ThemeDirectoryWatcher.swift, ThemeCanonicalizer.swift present.
- Resources/c11-themes/ ships stage11.toml + phosphor.toml + radical.toml + README.md.
- c11 themes CLI is live: list / get / set / clear / reload / path / dump / validate / diff. Two-slot light/dark binding via --slot flag.
- ThemeSocketMethods.swift exposes read-only theme socket access per §12 #13.
- Subsequent polish landed: PR #35 (Radical theme + force-dark in picker), upstream-pull picks for theme-picker search and Enter-apply (theme picker search regression test, theme-from-picker apply).

Operator-facing surface is complete: users can drop .toml in the user themes dir, hot reload picks them up, Settings picker drives them, CLI drives them. M5 (stretch) intentionally not pursued per ticket scope.