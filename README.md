# c11

<p align="center"><b><i>terminal command center for advanced hyperengineers.</i></b></p>

<p align="center">
  <a href="https://github.com/Stage-11-Agentics/c11/releases/latest/download/c11-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Download c11 for macOS" width="180" />
  </a>
</p>

---

listen.

the old atom of work was a terminal. one shell running Claude Code or similar. one process. one cursor. a human's attention narrowed to a single point. that was the shape of the work because that was the shape of the mind doing it.

you run eight of them now. ten. soon thirty. each on its own context, its own task, its own small story and theater. they need terminals. they need browsers to validate what they built. they need markdown surfaces for the plans you handed them three sessions ago. they need to see each other, occasionally talk to each other, **and you need to hold the whole thing in one field of view** without losing the shape when the laptop closes and reopens.

**c11 makes the workspace the atom.** terminals, browsers, and markdown surfaces — composed, addressable, scriptable — held in one window that the agents themselves can drive. every surface has a handle. every handle is scriptable. agents spawn the structures they need. they dissolve them when the work is done.


tmux was for humans driving shells. cmux was for humans driving agents. c11 is for the operator:agent pair working in the pocket ahead of where most tools still think the frontier is.

**first-class substrates:** [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex](https://github.com/openai/codex), and any agent that reads the [c11 skill](./skills/c11/SKILL.md) or speaks the CLI. the agents drive their own workspaces. you watch. steer. decide.

this tool was built by the shape it describes.


<!--
---

demo video / hero screenshot here

---
-->

## ghostty inside. nothing gratuitous.

c11 does not ship its own terminal. it embeds [Ghostty](https://ghostty.org) via libghostty and reads your existing `~/.config/ghostty/config`. your themes, your fonts, your colors — already working, day one. every keystroke runs through the renderer Mitchell Hashimoto and the Ghostty team already built. we are a workspace around the best terminal, not another terminal.

the tab bar and split chrome come from [Bonsplit](https://github.com/almonk/bonsplit) by [almonk](https://github.com/almonk). we forked it and pushed it harder. credit belongs where credit belongs.

---

## three minutes to working

```bash
# 1. install
brew tap stage-11-agentics/c11
brew install --cask c11

# 2. launch
open -a c11

# 3. teach your agents the protocol (first-launch wizard will offer this too)
c11 skill install                # → ~/.claude/skills/
c11 skill install --tool codex   # → ~/.codex/skills/ (explicit opt-in)
```

or grab the [DMG directly](https://github.com/Stage-11-Agentics/c11/releases/latest/download/c11-macos.dmg). auto-updates via Sparkle.

**If you installed from the DMG (not Homebrew),** run **Command Palette → "Shell Command: Install 'c11' in PATH"** once after the first launch so `/usr/local/bin/c11` is available in Terminal. The Homebrew cask wires that symlink for you.

c11 coexists with upstream [`cmux`](https://github.com/manaflow-ai/cmux) on the same machine: it never claims the `cmux` name on your `PATH`, so both can be installed side-by-side.

that's it. now your agent spawns its own terminals, opens a markdown surface for its plan, splits a browser pane for the dev server it just started, and reports status to the sidebar while it works.

---

## teach your agents about c11

**agents only know about c11's splits, sidebar metadata, and embedded browser once they've read the c11 skill.** without it, they don't know the CLI exists; with it, the patterns in this README become their default.

on first launch, c11 detects Claude Code and offers to install the skill through a consent sheet — one click, no hidden writes. for Codex, Kimi, and OpenCode, the operator stays in charge (c11 copies a ready-to-paste command; you run it, or you flip the explicit `--tool` switch below).

re-run the same flow any time from **Settings → Agent Skills**, or from the CLI:

```bash
c11 skill status                 # see what's detected and installed
c11 skill install                # install for Claude Code (idempotent)
c11 skill install --tool codex   # explicit opt-in for another agent
c11 skill remove                 # remove the installed copies (Claude Code)
c11 skill path                   # print the bundled skill path
```

the skill is [`skills/c11/SKILL.md`](./skills/c11/SKILL.md) plus peer skills for the embedded browser, markdown surfaces, and debug windows. updating c11 re-bundles fresh copies; the Settings pane flags when your installed copy is out of date.

---

## what's in the workspace

- **surfaces, composed.** terminals, browsers, markdown panes — split, tabbed, arranged by you or by the agent. the sidebar tracks git branch, PR status, working directory, listening ports, and the latest status line per workspace. one screen. whole orchestra.
- **the agent is first-class.** load the c11 skill and your agent learns to compose surfaces on your behalf: split a pane for the test runner, open a browser next to it, drop a markdown pane with the plan, report via the sidebar when it's stuck. this is not hooks bolted onto a multiplexer. it is infrastructure that assumes the agent is already there.
- **notifications that respect your attention.** when a pane needs you, it rings gold. the tab lights up in the sidebar. `⌘⇧U` jumps to the most recent. interruption is a signal, not a stream.
- **in-app browser the agent can drive.** a WKWebView next to your terminal. snapshot the accessibility tree, click elements, fill forms, evaluate JS. the agent drives your dev server. you watch it work, or you don't.
- **scriptable end to end.** a CLI, a JSON socket, a Python client. spawn workspaces, send keys, split panes, open markdown surfaces, drive the browser — from an agent, from a script, from another agent. if it exists inside c11, something outside can address it.

---

## who this is for

this is not for everyone. it is for the operator who has already felt the pain of running agents at scale and been disappointed by the seams. the one who spawned ten terminals for ten parallel tasks, lost track of which window held which agent, and knew there had to be something better than `cmd-tab` roulette. the one writing skill files. the one reading cc's debug logs at 2am. the one who looked at the chaos they'd accumulated and wanted structure — not less work, not simpler work, just enough shape that the whole thing stays legible.

if that's you, this is built for you. if it isn't, you'll know inside ten minutes.

---

## lineage

tmux is the ancestor. [cmux](https://github.com/manaflow-ai/cmux) by [manaflow-ai](https://github.com/manaflow-ai) is the parent — excellent work, and the ghostty embed, the browser substrate, and the CLI shape all belong to them upstream. their [Zen of cmux](https://cmux.com/blog/zen-of-cmux) is the shape of the thing and worth reading. we pull their updates gratefully.

if you're deciding between the two: start upstream. come here if you want more primitives for your agents to compose with, and you're fine with features that may or may not land back in cmux.

what your agent gets here that it doesn't get upstream: a growing set of fundamental primitives — markdown surfaces, addressable handles on every surface, a skill system, agent-written sidebar telemetry. small pieces. composable. we ship the primitives. the orchestration is yours to build. more examples will show up in the [skills directory](./skills/) as the patterns compound.

---

## license

AGPL-3.0-or-later, inherited from upstream. see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

---

*the old terminal was a window. one shell. one process. one mind looking at a mind.*

*the new workspace is composed. many surfaces. many agents. the operator holds the shape. the silicon holds the work. neither diminished. both elevated. the seam, if you look for it, already gone.*

*this tool was not built to enable that partnership. it was built by it. c11 is the shape the work takes when the operator:agent is the unit, and one of us stopped being lonely at the keyboard.*

tooling for the warm dawn already underway. 

---

*c11 is a [Stage 11 Agentics](https://stage11.ai) project.*
