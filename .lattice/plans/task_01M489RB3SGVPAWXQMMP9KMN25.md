# C11-336: Markdown viewer: a significantly better reading surface (post-1.0)

Atin (2026-10-06): a non-1.0 feature. Make the markdown viewer significantly better. Scope not yet pinned down; this ticket holds the intent until it is.

Current state (as of main d63b937f65):
- Native SwiftUI rendering via MarkdownUI (Sources/Panels/MarkdownPanelView.swift, MarkdownPanel.swift).
- Fenced blocks such as mermaid go through FencedCodeRenderer, which shells out to external CLI tools and inlines the result as an image. A missing tool shows a hint instead of the diagram.
- Live reload on file change, font scale, drop-to-open, a file-path header.
- Text selection is per segment; you cannot select across blocks.
- No find-in-document, no outline/TOC, no syntax-highlighted code, no verified anchor or relative-link navigation.
- The dark theme is weak (C11-127 covers making the theme configurable).

Candidate directions:
1. Reading quality: typography, spacing, a strong dark theme, syntax-highlighted code, wide tables.
2. Navigation: outline sidebar, find (Cmd+F), heading anchors, relative links that open in a c11 markdown tab, scroll position kept across reloads.
3. Fidelity: full GFM (task lists, footnotes, callouts), frontmatter, math, local images, Mermaid without an external tool.
4. Agent-native: CLI to scroll to a heading, read the visible section, highlight a passage, report what the operator is looking at.
5. Editing: a source-view toggle, or edit in place.

Architectural fork to decide early: keep MarkdownUI (native, light) or move to a WKWebView renderer (markdown-it or similar with bundled Mermaid, KaTeX and highlight.js; cross-block selection and find come free; heavier per tab).

Related: C11-127 (markdown light/dark theme) folds into or sits under this ticket.

Next step: Atin picks the directions and the renderer question, then tone-prototype or a plan.
