---
name: c11-markdown
version: 1
description: Open markdown files in a c11 markdown panel (formerly a tab) with live reload. Use when you need to display plans, documentation, or notes alongside terminals and browser panels with rich rendering (headings, code blocks, tables, lists, Mermaid diagrams). Prefer this over external viewers when c11 is running.
---

# c11 Markdown Panels

Use this skill to display markdown files in a c11 markdown panel — a first-class panel type that lives alongside terminal and browser panels in the same workspace, driven from the same `c11` CLI. The binary is `c11`.

Rich rendering (headings, code blocks, tables, lists, Mermaid) with live file watching — the panel auto-updates when the file changes on disk.

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

# Open splitting from a specific panel
c11 markdown open plan.md --panel panel:5

# Open in a specific window
c11 markdown open plan.md --window window:1
```

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

Local raster images are limited to the document directory and its subdirectories;
symlinks outside that tree and remote images are blocked. Document HTML and
scripts never execute. Relative markdown links open another markdown panel;
web links follow c11's browser routing settings. Anchors stay in the document.
Live reload preserves the reading position, with no separate change-tracking UI.
Visible readers stay live. c11 retains four recently hidden readers across the
app and releases older web views. Reopening a panel restores its source line and
offset, read/source mode, find query, and native reading preferences. Reading raw
content remains available while a panel's web view is released.
