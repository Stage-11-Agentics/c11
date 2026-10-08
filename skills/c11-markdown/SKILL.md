---
name: c11-markdown
version: 1
description: Open markdown files in a c11 markdown panel (formerly a tab) with live reload. Use when you need to display plans, documentation, or notes alongside terminals and browser panels with rich rendering (headings, code blocks, tables, lists, Mermaid diagrams). Prefer this over external viewers when c11 is running.
---

# c11 Markdown Panels

Use this skill to display markdown files in a c11 markdown panel — a first-class panel type that lives alongside terminal and browser panels in the same workspace, driven from the same `c11` CLI. The binary is `c11`.

Rich rendering (headings, code blocks, tables, lists, Mermaid) with live file watching — the panel auto-updates when the file changes on disk.

## Corpus Navigation

- Press **⌘K** in a Markdown panel to search Markdown file names and headings in the containing Git repository. If the file is outside a Git repository, c11 searches its containing directory.
- Open the panel outline and select **Referenced by** to see links to the current document and current section. Selecting a result navigates within the same panel and adds to its history.
- The index skips .git, node_modules, DerivedData, build, dist, and .build; indexing is bounded, incremental and local to the open panel.
- C11-123 references show a title/status card only when the indexed repository has a matching local .lattice board entry. The lookup is read-only; unmatched IDs stay plain text.

Agent command:

~~~bash
c11 markdown backlinks --panel <id|ref> --json
~~~

It returns bounded references for the selected Markdown panel's current file
without changing panel or workspace selection.

## Core Workflow

1. Write your plan or notes to a `.md` file.
2. Open it in a markdown panel.
3. The panel auto-updates when the file changes on disk.

```bash
# Open a markdown file as a split next to the current terminal
c11 markdown open plan.md

# Absolute path
c11 markdown open /path/to/PLAN.md

# Target a specific workspace
c11 markdown open design.md --workspace workspace:2
```

## When to Use

- Displaying an agent plan or task list alongside the terminal
- Showing documentation, changelogs, or READMEs while working
- Reviewing notes that update in real-time (e.g., a plan file being written by another process)

## Producing artifacts the operator will return to

When you are creating **more than one** markdown artifact across a session — a map, a proposal, an audit, a status report — present them as **one navigable document**, not multiple disconnected areas. The hyperengineer is already running many agents in many workspaces; your session should not become another navigation problem for them to solve when they come back from lunch.

Two patterns, in priority order:

### Default: one consolidated file with sections

Write to a single `/tmp/<task>-trail.md` and append as the work progresses. The operator scrolls one document instead of switching panels; the most current section sits on top so it is what they see first when they return.

```bash
# At the start of a multi-artifact piece of work, open the trail file once
c11 new-area --type markdown --file /tmp/voice-trail.md
# → OK panel:35 area:9 workspace:1

# Then write to that file as the work evolves — live-reload renders it.
# When new sections supersede earlier ones, put the new section at the top
# so the operator's first read is current truth, not stale context.
```

This is the right default unless the operator explicitly asks for separate files.

### When you need multiple distinct files: panels of the *same* area

If the artifacts genuinely need to be separate files (different audiences, different lifetimes, downstream tooling reads them as units), add the second and subsequent ones as **panels of the existing markdown area**, not as new areas:

```bash
# Capture the area ref from the first open
c11 new-area --type markdown --file /tmp/voice-map.md
# → OK panel:35 area:9 workspace:1

# Add subsequent files as panels of area:9 — NOT new areas
c11 new-panel --type markdown --file /tmp/voice-wave-1.md --area area:9
c11 new-panel --type markdown --file /tmp/voice-audit.md --area area:9
```

The operator sees one markdown area; the artifacts navigate as panels of that area. This is materially different from three `c11 new-area` calls, which produce three sibling areas the operator has to context-switch between.

### Always: title + description per panel

Whether it is one consolidated file or an area holding several panels, set `c11 set-title` and `c11 set-description` on every markdown panel immediately after opening it. The operator should know what they are looking at without opening it. See the top-level c11 skill's "Title and description" section for the conventions.

### Close stale artifacts at session-end

If an early-session map document is superseded by a final audit, close the early panel (`c11 close-panel --panel <ref>`) so the operator's primary view shows the current truth. Leaving five panels open across a session because they were once useful is unkind to the next look.

## Live File Watching

The panel automatically re-renders when the file changes on disk. This works with:

- Direct writes (`echo "..." >> plan.md`)
- Editor saves (vim, nano, VS Code)
- Atomic file replacement (write to temp, rename over original)
- Agent-generated plan files that are updated progressively

If the file is deleted, the panel shows a "file unavailable" state. During atomic replace, the panel attempts automatic reconnection within its short retry window. If the file returns later, close and reopen the panel.

## Agent Integration

### Opening a plan file

Write your plan to a file, then open it:

```bash
cat > plan.md << 'EOF'
# Task Plan

## Steps
1. Analyze the codebase
2. Implement the feature
3. Write tests
4. Verify the build
EOF

c11 markdown open plan.md
```

### Updating a plan in real-time

The panel live-reloads, so simply overwrite the file as work progresses:

```bash
# The markdown panel updates automatically when the file changes
echo "## Step 1: Complete" >> plan.md
```

### Recommended AGENTS.md instruction

Add this to your project's `AGENTS.md` to instruct coding agents to use the markdown viewer:

```markdown
## Plan Display

When creating a plan or task list, write it to a `.md` file and open it in c11:

    c11 markdown open plan.md

The panel renders markdown with rich formatting and auto-updates when the file changes.
```

## Routing

```bash
# Open in the caller's workspace (default — uses C11_WORKSPACE_ID)
c11 markdown open plan.md

# Open in a specific workspace
c11 markdown open plan.md --workspace workspace:2

# Navigate an existing Markdown panel in place
c11 markdown open plan.md --panel panel:5

# Open in a specific window
c11 markdown open plan.md --window window:1
```

Without `--panel`, an optional `#fragment` selects a heading in the new panel.
With a stable `--panel` target, `c11 markdown open <path>#<fragment> --panel
panel:8` navigates that existing Markdown panel in place. This does not change
the visible workspace or focus. The panel validates the target and records
back/forward history.

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Full command syntax and options |
| [references/live-reload.md](references/live-reload.md) | File watching behavior, atomic writes, edge cases |

## Rendering Support

The markdown panel renders:

- Headings (h1-h6) with dividers on h1/h2
- Fenced code blocks with monospaced font
- Inline code with highlighted background
- Tables with alternating row colors
- Ordered and unordered lists (nested)
- Blockquotes with left border
- Bold, italic, strikethrough
- Links (clickable)
- Horizontal rules
- Images (inline)

The offline WKWebView renderer bundles Mermaid, syntax highlighting, math,
footnotes, task lists and callouts. No external Mermaid CLI is required.

Text scale (50–300% in 10% steps), theme (`system`, `light`, `dark`), typeface
(`theme`, `serif`, `sans`, `mono`) and the outline choice belong to each panel
and survive session restore. The last setting changed becomes the default for
new panels. Invalid saved values fall back independently to their defaults.
⌘= / ⌘− / ⌘0 change text scale through c11's focused-panel shortcuts.
⌘F opens the focused Markdown panel's in-page find popover; Return and ⇧Return
move between matches. ⇧⌘O toggles the page-rendered outline through the
customizable shortcut registry. The outline docks when the effective width
fits, otherwise it overlays the page; click a heading to jump without closing
it, type to filter, and press Escape to clear the filter before closing it.
System theme follows c11's effective appearance, which follows the OS when c11
appearance is set to System. Typing in page controls keeps the web view as first
responder only when C11-359's panel focus policy allows it.

Document links navigate in the same panel by default. The toolbar's default
link-destination toggle switches ordinary relative links to a new markdown
panel; Cmd-click uses the opposite destination. Same-document anchors always
stay in the current panel, including Cmd-click, and participate in panel
history. Use ⌘[ / ⌘] or the toolbar arrows to move through that panel's history.
A broken anchor offers the closest headings.
Hovering a relative link briefly previews the target section after native path
validation. Automatic document, palette and backlink navigation stays inside
the source document's repository (or its directory when it has no repository).

## Agent Reading Controls

These commands target an explicit markdown panel. They do not select its
workspace or change c11's in-app focus. Discover the `markdown.agent_cli`
feature, version 1, through `c11 capabilities` before relying on the socket
methods. Use a stable `panel:<n>` reference or UUID; bare panel indices are
rejected because they are scoped to the selected or caller workspace.

```bash
c11 markdown scroll --panel panel:8 --heading "Installation"
c11 markdown visible --panel panel:8 --json
c11 markdown visible --panel panel:8 --json --watch
c11 markdown theme --panel panel:8 --list
c11 markdown theme --panel panel:8 --set dark
c11 markdown typeface --panel panel:8 --list
c11 markdown typeface --panel panel:8 --set mono
c11 markdown font --panel panel:8 --scale 1.2
c11 markdown open-external --panel panel:8
c11 markdown open /path/to/guide.md#installation --panel panel:8
c11 markdown history --panel panel:8 --json
c11 markdown links --panel panel:8 --broken --json
```

`visible` reports the current heading path, visible source-line range, reading
progress, theme, typeface, text scale, pane size, find state and bounded text
selection. `scroll`, `visible`, and `visible --watch` create a hidden reader
when needed and wait up to eight seconds for its first rendered state. A
`not_ready` or `timeout` response means the reader did not become ready in that
window; selecting the workspace is not an agent recovery path, so report the
error instead. A scroll against a hidden panel takes effect in its reader; the
gold flash appears when the panel is next shown.

`visible --watch` emits one JSON object per line for the initial state and later
changes. It follows renderer state events rather than polling, remains attached
to the panel model while WebKit is evicted, streams presentation changes, and
resumes rendered state when the reader is recreated or shown. It ends when the
panel closes (for example, `c11 close-panel --panel panel:8`), the client
disconnects, c11 stops the CLI listener, or the peer sends more bytes or
half-closes its request side.
`scroll --heading` prefers an exact slug or exact case-insensitive heading text.
If only broader matches exist, it chooses a unique prefix before considering a
unique substring; multiple matches at that tier return `ambiguous` with heading
examples instead of silently scrolling to the first one.
`open --panel` uses the panel navigation API with origin `agentCLI`; it accepts
an absolute or caller-relative file path and optional `#fragment`, and returns
the navigation outcome without selecting the panel's workspace. `history`
returns the bounded back/forward stack and captured reading positions. `links
--broken` reports relative Markdown links whose target file or heading is
missing, outside the source scope, or unreadable.
Theme and typeface names come from the panel's registered options. Font scale
must be between 0.5 and 3.0 and is stored at the panel's 0.1-step precision.
`open-external` opens the panel's bound file in the macOS default application
behind c11.

Local raster images are limited to the document directory and its subdirectories;
symlinks outside that tree and remote images are blocked. Document HTML and
scripts never execute. Relative Markdown links navigate in the same panel by
default; the toolbar toggle changes that default, and Cmd-click uses the
opposite destination. Same-document anchors stay in the current panel. Web links
follow c11's browser routing settings.
Validated `mailto:` links accept recipients, cc, bcc, subject and body only;
hosts, ports, fragments and control characters are refused. They open through
`NSWorkspace` only after an operator clicks.
Live reload preserves the reading position, with no separate change-tracking UI.
Visible readers stay live. c11 retains four recently hidden readers across the
app and releases older web views. Reopening a panel restores its source line and
offset, read/source mode, find query, and native reading preferences. Reading raw
content remains available while a panel's web view is released. If the original
anchored block no longer exists, restoration falls back to the captured line.
