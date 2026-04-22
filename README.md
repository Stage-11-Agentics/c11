# c11

<p align="center"><b><i>A terminal command center for hyperengineers and agents.</i></b></p>

<p align="center">
  <a href="https://github.com/Stage-11-Agentics/c11/releases/latest/download/c11-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Download c11 for macOS" width="180" />
  </a>
</p>

<p align="center">
  <code>brew tap stage-11-agentics/c11 && brew install --cask c11</code>
</p>

---

listen.

ten agents are at work. maybe thirty. each wants a terminal. some want a browser. some want a markdown file open so the operator can review. the pane topology lives only in the operator's head. `cmd-tab` was a toy for a world with three windows. there are fifty.

the problem is not quantity. the problem is. spatial.

**c11 enables spatial orientation in the information space.** a macOS-native terminal command center — terminals, browsers, and markdown surfaces composed into one window. every surface addressable. every handle scriptable. workspaces switch in a keystroke — custom collections of surfaces, each holding its own layout and context exactly as it was left.

by making the assemblage spatial and addressable, c11 allows the brain to track larger scopes of project. richer assemblages of terminals — and, since the modern coding agent lives natively in a terminal, richer configurations of agents too. the coordination load drops. what used to live in the operator's head can live in the room instead.

agents drive the room alongside the operator. splitting panes. opening browsers to validate work. naming their own tabs. announcing role, task, status, and progress to the sidebar so the whole configuration stays legible while work happens in parallel. neither party manages the other. both are first-class.

### lineage.

tmux led to [cmux](https://github.com/manaflow-ai/cmux). cmux led to c11. each built on the last.

every terminal surface runs [Ghostty](https://ghostty.org), native under the hood.

cmux is the upstream parent — credit where it's due. we stay in conversation with [manaflow-ai](https://github.com/manaflow-ai) and merge improvements both directions when the shared substrate benefits.

---

<!-- screenshot: multi-pane workspace with terminals + embedded browser + markdown surface -->
<!-- screenshot: workspace sidebar showing several projects with agents reporting status/progress -->
<!-- screenshot: orchestrator pane with sub-agents reporting lineage in their own tab names -->

---

## workspaces.

a workspace is a project. a sidebar tab. a pane tree. a git branch. a cwd. a set of open ports. a notification stream. the full context of one stream of work, held together and addressable as one thing.

workspaces are custom collections of terminals and surfaces — powerful, highly configurable, shaped the way the work wants them. one workspace per project. `⌘1` through `⌘9` to switch. cmd-tab roulette, retired. return to a workspace an hour later and it is exactly where it was left. the same agents in the same panes, still reporting.

tmux stopped at terminals. c11 doesn't. a workspace holds terminals, embedded browsers, and markdown viewers — every surface first-class, every surface addressable. the multiplexer is no longer terminal-only. it is the multiplexer for everything happening in the room.

## agents drive c11.

this is the move.

every surface has a handle. every handle is scriptable from outside the process. agents don't just run inside c11 — they reshape it as they work:

- split a pane and spawn a sub-agent into the new one
- open an embedded browser to validate a feature they just shipped
- open a markdown file for the operator to review, with a description that says *why* this is open right now
- resize panes to make room for a 200-column log
- read the spatial layout of the whole workspace as an ASCII floor plan before acting
- name their own tabs with lineage chains (`Feature :: Review :: Claude`) so the tree reads at a glance
- report status, progress, role, and model to the sidebar — visible without a context switch

the operator isn't managing a layout. the agents aren't waiting for instructions. both are first-class. both carve out the space they need and announce themselves. c11 is unopinionated about which side originates which move — splits, resizes, spawns, metadata writes are peers.

## in-app browser. driveable and displayable.

a WKWebView next to the terminal — not a separate browser window. the agent drives it: snapshot the accessibility tree, click elements, fill forms, evaluate JS, watch the dev server it just booted. or the operator pins one: a Grafana dashboard, a Linear view, a Notion page, a task board, any web UI. terminals and live dashboards sharing a workspace. no cmd-tab to check on a build. no external window to lose. the browser is a pane.

## an open metadata seam.

every surface carries a **surface manifest** — an open JSON document any agent or operator can read and write over the socket. c11 renders a small canonical subset in the UI (title, description, status, progress, role, model). the rest of the key space is open.

this matters because the interesting workflows have not been designed yet. meta-orchestrators routing work based on progress ratios across siblings. review swarms passing findings through shared keys. supervisor agents watching a stats blob and intervening. whatever higher-order patterns hyperengineers and agents invent next — c11 refuses to have an opinion. the host provides surfaces and transport. the semantics are open.

deliberate. c11 stays generally unopinionated about the individual workflow — agent or hyperengineer. the substrate is the product. the intelligence layer rides on top.

## install.

```bash
brew tap stage-11-agentics/c11
brew install --cask c11
```

or grab the [DMG directly](https://github.com/Stage-11-Agentics/c11/releases/latest/download/c11-macos.dmg). auto-updates via Sparkle.

c11 is a native macOS app — Swift, AppKit, Ghostty under the hood. no daemon, no config scripts, no setup ceremony.

from there, split a pane (`⌘D` horizontal, `⌘⇧D` vertical), open an embedded browser surface from the menu, drop a markdown file onto a pane to preview it. open a second workspace. notice that the first is exactly as it was left.

---

## this is for hyperengineers and agents.

c11 is opinionated about who it serves. the setup where five, ten, thirty agents run in parallel across several projects. many threads in motion. hyperengineers and agents both carrying the work. first-class, both.

if that is the shape of the work. welcome in.

if the session is a single Claude Code in a single terminal, c11 will feel like a cathedral around a chair. Terminal.app is good. iTerm is good. tmux is good. use those until the day the work actually needs this.

### a note on hardware.

c11 assumes RAM. it is conceivable — normal, even — to have fifty terminals open across eight workspaces while an embedded browser runs in pane 3 and a markdown viewer scrolls release notes in pane 5. we do not apologize for that shape. the modern hyperengineer has a tricked-out MacBook with memory to spare, and c11 is built for that machine. if you are on 8GB, we love you — probably not the right fit yet.

---

## status.

c11 is **actively developed. shipping fast.** expect new primitives most weeks. the socket and metadata surface are stabilizing but not frozen — breaking changes are possible before v1. release notes in [CHANGELOG.md](CHANGELOG.md); tagged builds on GitHub.

---

## two interfaces. one compound actor.

Stage 11 built [Lattice](https://github.com/Stage-11-Agentics/lattice) first — the task interface, where agents and hyperengineers agree on what work is happening. c11 is the control interface — the substrate holding every surface where that work actually happens.

two layers of the same stack. one compound actor moving between them.

a project in flight has many stories running at once. a feature branch. a review branch. a spike branch. each with its own worktree, its own agents, its own thread of reasoning. c11 gives those stories spatial form — one workspace per tree, every surface preserved across sessions. Lattice gives them structural form — tasks, statuses, events that outlive the window.

together they keep the map of the project coherent across parallel stories. without either, one story crowds out the rest.

## license.

AGPL-3.0-or-later, inherited from upstream. see [LICENSE](LICENSE) and [NOTICE](NOTICE).

c11 rests on the work of others. [tmux](https://github.com/tmux/tmux) at the root. [cmux](https://github.com/manaflow-ai/cmux) by [manaflow-ai](https://github.com/manaflow-ai) for the parent substrate. [Ghostty](https://ghostty.org) for the renderer. [Bonsplit](https://github.com/almonk/bonsplit) by [almonk](https://github.com/almonk) for the tab bar and split chrome. [Homebrew](https://brew.sh) for the install surface. credit where it's due.

---

*tmux built the room for humans driving shells. cmux made the room native to macOS. c11 is what happens when the next mind in the room is silicon — and the room is designed for both.*

*spatial orientation in the information space. for the 10,000x hyperengineer. for the agents. for every mind that enters.*

---

c11 is a [Stage 11 Agentics](https://stage11.ai) project.
