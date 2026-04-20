# c11 TODO

c11-specific work. Upstream cmux backlog lives in `TODO.md`.

## CI
- [ ] **P0** Fix CI — legacy from upstream has never run green on this repo; audit workflows, cull/retarget ones that don't apply, and get a successful run on `main`

## M9 TextBox — known regressions / follow-ups
- [ ] **TextBox Up/Down cursor movement** — in a multi-line TextBox with content, Left/Right move the cursor character-by-character as expected, but Up/Down silently do nothing. Evidence captured in `/tmp/c11mux-debug-m9-textbox.log` via dlog instrumentation during the M9 session (2026-04-18): `moveUp:` selector **never arrives** at `InputTextView.doCommand`, despite the text view being first responder and `moveLeft:` / `moveRight:` arriving fine. The asymmetry rules out our routing layer — the issue is upstream of `doCommand`, probably in `keyDown` → `interpretKeyEvents` → responder-chain interception. Suspects: a parent SwiftUI / AppKit view (NSScrollView, GhosttySurfaceScrollView portal layer, the Bonsplit split-pane host) is eating the arrow event. Next session should re-instrument `keyDown` to confirm moveUp keyCode=126 arrives (or doesn't) at the NSTextView and, if it doesn't, walk up the responder chain until you find who ate it. ~1h estimate. Low user-visibility since Shift+Return lets users insert blank lines and Left/Right still navigate within each line; not worth blocking M9 on.
