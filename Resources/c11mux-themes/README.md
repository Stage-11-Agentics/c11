# c11mux themes

Drop a `.toml` file in this folder to add a chrome theme to c11mux. The app watches
this directory and hot-reloads themes within ~1 second of a save.

Two slots exist in Settings → Theme:

- **Light chrome** — theme applied when macOS is in Light appearance.
- **Dark chrome** — theme applied when macOS is in Dark appearance.

Each slot can point at any bundled or user theme independently.

## Schema (v1)

A minimum theme file:

```toml
[identity]
name         = "mytheme"
display_name = "My Theme"
author       = "me"
version      = "0.01.001"
schema       = 1

[palette]
background = "#0A0C0F"
accent     = "#C4A561"

[variables]
background = "$palette.background"
accent     = "$palette.accent"
```

The `name` field must match the filename (`mytheme.toml` ⇢ `name = "mytheme"`).

### Chrome sections

All sections are optional. Unset roles fall back to the bundled `stage11` defaults.

```toml
[chrome.sidebar]
activeTabFill = "$workspaceColor"
badgeFill     = "$accent"

[chrome.titleBar]
background          = "$surface"
foreground          = "$foreground"

[chrome.windowFrame]
color            = "$workspaceColor"
thicknessPt      = 1.5
inactiveOpacity  = 0.25
```

### Variable expressions

- `$palette.name` — reference a palette entry.
- `$variableName` — reference another `[variables]` entry.
- `$workspaceColor` / `$ghosttyBackground` — reserved magic variables.
- `.opacity(0.5)`, `.mix($other, 0.3)`, `.lighten(0.04)`, `.darken(0.04)` — modifiers.

### Debugging

```
cmux ui themes validate path/to/mytheme.toml
cmux ui themes list
cmux ui themes dump --json
```

Malformed themes are retained at their last-known-good contents while a diagnostic
is logged. Fix the file and save — it re-loads automatically.
