# c11 Philosophy

Principles that shape what c11 is and, more importantly, what it refuses to be. Operational details live in `CLAUDE.md`; visions and features live in `ROADMAP.md`; this document captures the worldview underneath both.

## c11 is host and primitive, not an intelligence layer

c11 is the room the compound actor works in: terminal, browser, and markdown surfaces; workspaces, panes, tabs; notifications; one CLI and socket API. The opinion about what agents *do* lives upstairs: Lattice, Mycelium, the rest of the Stage 11 stack. c11's job is to be the best possible substrate for that opinion to land on, not to have one of its own.

The test: if a proposed feature requires c11 to know what the agent is working on, it's the wrong shape. c11 should care about *where* the agent is (surface, pane, workspace) and *what kind* of agent it is (terminal type, model, declared role), never what the agent is thinking.

## Observe from outside, never hook into agents

c11 features must not require agent-side cooperation. When a feature needs information about what's happening in a pane (auto-titles, session recaps, activity summaries, stall detection, metadata inference), c11 reads the pane externally (`c11 tree`, pane scrollback, screen content) and processes it, typically via a cheap local model, rather than asking the agent to write to a file, call a CLI, or otherwise play along.

**Why this matters:** c11 has to work identically for Claude Code, Codex, Gemini, Kimi, bash sessions, REPLs, log tails, and anything else in a pane. Requiring agent cooperation couples c11 to specific agents and breaks the neutrality of the substrate. The moment an agent has to be modified to work well in c11, c11 has already lost.

**Concrete example.** When Claude Code shipped the `/recap` feature with no programmatic access, the tempting fix was a SessionStart hook that prompts Claude to emit a recap file. Wrong shape: it would have made c11's recap feature Claude-specific and fragile to Claude's internal changes. The right shape is c11 reading the pane itself and producing its own interpretation. Agent-agnostic by construction.

**How to apply.** When designing any c11 feature that surfaces "what's going on" in a pane, default to external observation plus a small model for interpretation. Only consider agent-side integration when external observation is genuinely insufficient, and when you reach for it, flag it as a philosophical exception worth discussing before building. Exceptions here are load-bearing; they shouldn't accumulate casually.

## Built for the hyperengineer and their agents

The target operator is the compound actor: a human navigating a shifting capability surface as a single entity, often orchestrating extensive terminal-based LLM coding agents in parallel. Everything else is scaffolding.

Design decisions follow from this. A first-time user installing c11 to try multiplexing once is not the target, and their ergonomics don't override the compound actor's. Density over handholding. Sharp edges over safety rails, when the trade-off is between them. The hyperengineer wants to move fast and will accept learning a thing; they don't want surprises.

## Location-agnostic

Terrestrial, orbital, or elsewhere: the interface is the same. This is why c11 is local-first, file-based, and network-optional wherever possible. The Spike doesn't require a data center nearby; the room around it shouldn't either.

## Primitives before policy

If a feature can be built by users composing existing primitives (splits, surfaces, metadata, sockets), that's the preferred path. New primitives land when composition gets painful, not because a specific workflow would be nicer with dedicated syntax. The CLI and socket API are the same surface, deliberately: automation is first-class, not an afterthought.

## Lineage matters

c11 is a macOS-native reinterpretation of tmux rebuilt on Ghostty, forked from the upstream cmux project. That lineage is load-bearing:
- **tmux**: for the ergonomics of panes, splits, persistent sessions, programmatic control.
- **cmux**: for the macOS-native tmux reinterpretation this fork builds on.
- **Ghostty**: for a GPU-accelerated renderer that keeps typing latency honest.
- **macOS-native**: for first-class AppKit surfaces, not a font-pushing TTY widget.

When a design choice forces a trade-off between these three, the question is which property is load-bearing for the compound actor in this moment, usually not all three at once, but none of them can be casually sacrificed.
