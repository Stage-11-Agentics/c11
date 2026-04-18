<h1 align="center">c11mux</h1>
<p align="center">
c11mux is tooling for advanced hyperengineers.
</p>



<p align="center">
  <a href="https://github.com/Stage-11-Agentics/c11mux/releases/latest/download/c11mux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Download c11mux for macOS" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="c11mux screenshot" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Watch the demo</a>
</p>

<p align="center">
  English · <a href="README.ja.md">日本語</a>
  <br/>
  <sub><i>Japanese translation is from the upstream era and will be refreshed as c11mux's fork-specific copy stabilizes.</i></sub>
</p>

## What this is

c11mux is tooling for hyperengineers.

We enable highly complex assemblages of terminals, browsers, and markdown surfaces — agentically spawned, agentically managed, all composed into a single workspace under a single operator. Every pane is addressable. Every surface is scriptable. Agents spawn the structures they need, and they dissolve them when the work is done.

We are building at the forefront of tooling for the operators working ahead of the curve — the ones already running more in parallel than was possible a year ago, already shaping workflows that will be obvious in retrospect. This is not a multiplexer with agent hooks stapled on. It is infrastructure for how the frontier actually works now.

c11mux is a Stage 11 Agentics fork of [**cmux**](https://github.com/manaflow-ai/cmux) by [manaflow-ai](https://github.com/manaflow-ai). They built something badass and they deserve credit for it! Specifically the ghostty terminal, browser, and CLI substrate belongs with them upstream — their [original motivation](https://cmux.com/blog/zen-of-cmux) is the shape of the thing, and it's worth reading. We also happily pull their updates and are honored to be building alongside them! 

*This is not trying to be first-timer-friendly software, if you're primarily running a single Claude Code or are reasonably new to the practice of running many paralelle coding agents, c11mux is probably more complicated than what you is ideal for the usecase*

## Why this exists

The old unit of work was a single terminal. A single shell, a single process, one thing happening at a time. That is not what running agents looks like.

The new unit is a workspace. Many terminals — one per agent, one per task, one per branch — composed into a coherent whole. Tabs for the ones you cycle through, splits for the ones you want in your peripheral vision. A browser pane or three for validating what the agents build. Markdown surfaces for plans, notes, and the context the agents need to read. All held in one window. All addressable by the CLI. All drivable by the agents themselves.

The workspace holds everything at once. You hold the workspace. When you close your laptop, the shape of the work is intact when you open it again.

Other tools treat the terminal as the atom. c11mux treats the workspace as the atom and the terminal as one of many cells inside it. 

## What you get

- **Workspaces composed of many surfaces.** Terminals, browsers, and markdown panes split and tabbed on a single screen.
  - The sidebar shows git branch, PR status, working directory, listening ports, and the latest notification line per workspace.
- **Agent-driven surface composition.** c11mux is particularly powerful in letting your coding agents use the c11mux skill to assemble, edit, manipulate, and communicate between the different surfaces within a workspace. This takes a little thinking to get used to: **your coding agents can start spawning new terminals** and stay aware of where they appear within a given workspace, which yields a substantial increase in operator performance when used effectively.
- **The terminal is Ghostty.** c11mux does not ship its own terminal emulator — it embeds [Ghostty](https://ghostty.org/) via libghostty. Ghostty's GPU-accelerated rendering and performance come with it, and c11mux reads your existing `~/.config/ghostty/config` so your themes, fonts, and colors already work. We are a workspace built around the best terminal, not a new terminal.
- **Agent-aware notifications.** When an agent needs you, its pane rings gold and the tab lights up in the sidebar. `⌘⇧U` jumps to the most recent unread.
- **In-app browser the agents can drive.** A WKWebView you can split next to your terminal. Scriptable — snapshot the accessibility tree, click elements, fill forms, evaluate JS. Agents drive your dev server while you watch.
- **Scriptable end to end.** A CLI and a JSON socket API. Spawn workspaces, send keystrokes, split panes, open markdown surfaces, drive the browser — from an agent, from a script, from another agent.

## Install

**DMG** (auto-updates via Sparkle):

<a href="https://github.com/Stage-11-Agentics/c11mux/releases/latest/download/c11mux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Download c11mux for macOS" width="180" />
</a>

**Homebrew:**

```bash
brew tap stage-11-agentics/c11mux
brew install --cask c11mux
```

**Nightly** — built from `main` on every push, runs alongside stable with its own bundle ID. [Download](https://github.com/Stage-11-Agentics/c11mux/releases/download/nightly/c11mux-nightly-macos.dmg).

The c11mux cask conflicts with the upstream `cmux` cask — Homebrew will ask you to remove one before installing the other. On first launch, macOS may ask you to confirm opening an app from an identified developer.

## Lineage

tmux is the original (the name comes from 'Terminal MUltipleXer'). cmux is a great creation by [manaflow-ai](https://github.com/manaflow-ai/cmux) (open source), and c11mux is the [Stage 11](https://stage11.ai) fork of cmux.

cmux itself is built on two external open-source projects worth naming: [Ghostty](https://ghostty.org/) — the developer-favorite GPU-accelerated terminal by [Mitchell Hashimoto](https://github.com/mitchellh), embedded via libghostty and responsible for every keystroke — and [Bonsplit](https://github.com/almonk/bonsplit) by [almonk](https://github.com/almonk), which provides the tab bar and split-pane chrome. Both carry through into c11mux and both deserve credit.

This fork exists so Stage 11 can push agent-orchestration features past what exists today, and iterate on changes that may or may not land back in cmux.

What changes in the fork: app display name (**c11mux**), bundle ID (`com.stage11.c11mux`), release artifacts, Homebrew tap, and the Sparkle auto-update feed. What stays identical to upstream: the `cmux` CLI binary name, every `CMUX_*` environment variable, socket paths and protocol, shell integration scripts, and every CLI subcommand — so existing scripts, dotfiles, and third-party tools keep working unchanged.

- Upstream: <https://github.com/manaflow-ai/cmux>

## About Stage 11

Stage 11 Agentics builds infrastructure for the advanced hyperengineer: we build [spike](https://stage11.ai/spike.html) infrastructure. Among our projects: [Lattice](https://github.com/Stage-11-Agentics/Lattice), the coordination system that keeps the spike legible across sessions.

More at [stage11.ai](https://stage11.ai).

A good way to impress us at a job intervie is a interesting PR into this repo. If thats you, [build with us](https://stage11.ai/build-with-us).

## License

AGPL-3.0-or-later, inherited from upstream. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE) for the full text and a summary of fork modifications.
