# C11-344: Markdown viewer: edit markdown in a source pane beside the live preview

Atin (2026-10-06): editing split out of C11-336 (markdown viewer upgrade). Depends on C11-336's WKWebView renderer.

Recommended shape: a source editor (CodeMirror 6) beside the live preview, Cmd+S to save. Not WYSIWYG edit-in-place: round-tripping rendered content back to markdown reformats files agents wrote and makes every save a noisy diff.

The real work is not the editor:
- Concurrent writes: agents write these files while the operator edits. Detect a disk change under a dirty buffer and offer reload / keep mine / diff, never silently clobber either side.
- Dirty state: tab indicator, unsaved buffers survive c11 restart via the session snapshot.
- Close with unsaved changes: a sheet, never runModal (see CLAUDE.md pitfalls).
- Keyboard: editor shortcuts must not collide with c11 bindings; focus handoff between editor and terminal.
- Agent-native: CLI/socket reports dirty state so an agent does not overwrite an operator's in-progress edit.

Estimate: medium complexity, after C11-336 lands.
