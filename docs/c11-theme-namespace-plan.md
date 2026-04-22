# c11 Theme Namespace Plan

Date: 2026-04-22

Status: planned, pre-release cleanup

Supersedes: the CLI namespace decision in `docs/c11-theming-plan.md` section 9.3 that kept the short `themes` verb for Ghostty terminal themes.

## Problem

The current CLI language creates a namespace collision:

- `c11 themes` currently manages the Ghostty terminal theme by writing a managed `theme = ...` block into `~/Library/Application Support/com.stage11.c11/config.ghostty`.
- c11 also has its own chrome theme system for sidebar, title bars, dividers, browser chrome, markdown chrome, and workspace framing.
- Calling the Ghostty terminal theme command `c11 themes` makes it sound like it controls the c11 chrome theme.

This is confusing because "c11 theme" should mean the c11 visual chrome, not terminal-cell rendering.

## Locked Language

These terms are the product vocabulary going forward:

| Term | Meaning |
| --- | --- |
| `c11 theme` | c11 chrome: sidebar, title bar, tab bar, dividers, browser chrome, markdown chrome, workspace frame |
| `terminal theme` | Ghostty-rendered terminal cells: background, foreground, ANSI palette, cursor, selection |
| `Ghostty config` | Terminal behavior and rendering config: scrollback, fonts, shell integration, terminal theme, and other Ghostty-owned settings |

Do not use "theme" by itself in c11 docs or CLI help when referring to terminal themes. Use "terminal theme" or "Ghostty terminal theme".

## Command Namespace

### Canonical c11 Chrome Theme Commands

`c11 themes` is the canonical namespace for c11 chrome themes.

Target surface:

```bash
c11 themes list
c11 themes get [--slot light|dark]
c11 themes set <name> [--slot light|dark|both]
c11 themes clear
c11 themes reload
c11 themes path
c11 themes dump [--json] [--color-scheme light|dark]
c11 themes validate <path>
c11 themes diff <a> <b>
c11 themes inherit <parent> --as <name>
```

Implementation note: the existing `c11 ui themes ...` implementation already talks to the c11 chrome theme socket methods (`theme.list`, `theme.set_active`, etc.). The implementation can route `c11 themes ...` through that path, but product language should not describe this as "moving `c11 themes` from terminal to chrome." The conceptual rule is simpler: `c11 themes` means c11 themes.

`c11 ui themes ...` can remain as a temporary compatibility alias while pre-release automation catches up, but it is not the canonical namespace and should not be featured in top-level help or new docs.

### Canonical Terminal Theme Commands

`c11 terminal-theme` is the explicit namespace for Ghostty terminal themes.

Target surface:

```bash
c11 terminal-theme
c11 terminal-theme list
c11 terminal-theme set <theme>
c11 terminal-theme set --light <theme> [--dark <theme>]
c11 terminal-theme set --dark <theme> [--light <theme>]
c11 terminal-theme clear
```

This command should preserve the current `c11 themes` terminal-theme behavior:

- lists bundled and user Ghostty themes
- can launch the existing interactive Ghostty theme picker when run in a TTY
- writes the managed `theme = ...` block to the c11 app-support Ghostty config
- requests a Ghostty config reload

Do not introduce a broader `c11 ghostty ...` or `c11 terminal config ...` namespace for this release. That would invite scope creep into general Ghostty parameter editing.

## Non-Goals

- No new settings UI.
- No new terminal theme behavior.
- No new c11 chrome theme behavior.
- No migration warning flow for the old `c11 themes` terminal-theme command. This is pre-release software, and the clearer namespace is worth the breaking change.
- No attempt to make c11 chrome themes set Ghostty terminal themes.
- No attempt to make Ghostty terminal themes select c11 chrome themes.

## Coupling Boundary

c11 chrome may read Ghostty-derived values as inputs, for example `$ghosttyBackground`, so chrome can harmonize with the terminal background.

That is one-way visual derivation, not theme selection.

Allowed:

```toml
[chrome.titleBar]
background = "$ghosttyBackground"
```

Not allowed:

- selecting a c11 theme changes the Ghostty terminal theme
- selecting a Ghostty terminal theme changes the active c11 chrome theme
- agent-side socket commands silently alter operator theme preferences unless they are already explicit c11 theme commands

## Implementation Plan

1. Add `terminal-theme` to CLI dispatch.
   - Route to the current terminal-theme implementation currently behind `runThemes(...)`.
   - Rename user-facing help from "themes" to "terminal-theme".
   - Keep output labels explicit: `Terminal light`, `Terminal dark`, `Ghostty config`.

2. Rebind top-level `themes` to c11 chrome themes.
   - Route `c11 themes ...` to the existing `runUiThemes(...)` implementation.
   - Keep `c11 ui themes ...` as an unadvertised alias for now.
   - Update error examples from `c11 ui themes ...` to `c11 themes ...`.

3. Update top-level help.
   - Advertise `themes` as "c11 chrome themes".
   - Advertise `terminal-theme` as "Ghostty terminal themes".
   - Do not advertise `ui themes` in top-level help.

4. Update docs.
   - `Resources/c11-themes/README.md`: use `c11 themes ...` examples.
   - `docs/socket-api-reference.md`: map CLI examples to `c11 themes ...`.
   - `docs/c11-theming-plan.md`: mark the old namespace decision as superseded.
   - Any skill/API docs that mention theme commands should distinguish c11 chrome themes from terminal themes.

5. Verification.
   - `c11 terminal-theme list` prints Ghostty terminal themes and shows the Ghostty config path.
   - `c11 terminal-theme set "Catppuccin Mocha"` writes the managed terminal-theme block and requests reload.
   - `c11 themes list` prints c11 chrome themes such as `stage11`, `phosphor`, and `radical`.
   - `c11 themes set phosphor --slot both` updates c11 chrome theme selection.
   - `c11 themes set "Catppuccin Mocha"` fails as an unknown c11 chrome theme, because that is a terminal theme.
   - `c11 --help` makes the distinction obvious.

## Acceptance Criteria

- A user can infer from command names alone that c11 chrome themes and Ghostty terminal themes are separate.
- There is one canonical command for c11 chrome themes: `c11 themes`.
- There is one canonical command for Ghostty terminal themes: `c11 terminal-theme`.
- Existing terminal-theme functionality survives under the explicit name.
- No new settings surface or behavior expansion lands as part of this cleanup.
