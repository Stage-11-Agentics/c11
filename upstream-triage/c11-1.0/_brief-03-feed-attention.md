# Topic 03: Feed, and replying to agents from notifications

**Report path:** `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/03-feed-attention.md`

Atin said: "Feed. Ooh. Tell me more about Feed. That seems cool. How can I access that?" He also finds attention and automation interesting. He explicitly skipped the automations rule engine, `cmux events` and `cmux current`, so do not scope those.

Cover:

1. **Feed:** one queue of approvals and questions across all agents, with a keyboard TUI (`cmux feed tui|clear`, `cmux hooks feed --source <agent> [--event <event>]`), plus the right-sidebar feed mode. How items get in (which hooks or events), what an item holds, how you act on one (approve, answer, jump to it), and what happens to the agent when you do.
2. **Reply from the macOS notification banner** (#8670, #10511): typing a reply, picking an AskUserQuestion option, or hitting Revise on a plan exit without switching panes. How the reply reaches the agent's PTY.
3. **How Atin could try Feed today** on the installed cmux 0.64.25: concrete steps. Be explicit about what each step writes to his config (for example, whether `cmux hooks setup` edits `~/.claude/settings.json`) and how to undo it. Do not run any of those steps yourself.
4. **c11 today:** flags, suppression, waiting state, the Option-V jump, the menu bar extra, notifications, and the mailbox. c11's attention model is a core thesis, so be careful and specific about where Feed overlaps it and where it adds something.
5. **Proposed c11 1.0 shape:** a c11 Feed that is fed without tenant config writes. Can waiting state plus screen reads (for example, recognising an AskUserQuestion or a permission prompt on screen) populate it? Can a reply go in through c11's existing `send`/paste path? Include a sketch of the UI: where it lives (sidebar mode, its own tab, the menu bar extra), the keyboard flow, and how it interacts with flags.
