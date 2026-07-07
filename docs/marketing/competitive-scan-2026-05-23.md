# c11 Competitive Scan — Six Peer Tools

**Date:** 2026-05-23
**Scope:** cmux (manaflow-ai), Superset, aTerm, Emdash, Tmux-IDE, Rmux
**Purpose:** Launch positioning input — README differentiation, Show HN framing, comparison talking points.

---

## 1. cmux (manaflow-ai) — c11's upstream parent

### Description
cmux is a native macOS terminal app built in Swift/AppKit on top of libghostty, pitched as "a Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents." It reads existing `~/.config/ghostty/config` and adds a sidebar of vertical tabs (with git branch, PR status, cwd, listening ports, latest notification text per workspace), an in-app browser with a scriptable accessibility-tree API, a notification system that picks up OSC 9/99/777 sequences and a `cmux notify` CLI for agent hooks, SSH workspaces with browser routing, Claude Code Teams integration, and a CLI/socket API for creating workspaces, splitting panes, sending keystrokes, and driving the browser. Session state persists across quits. (Sources: [README](https://github.com/manaflow-ai/cmux), [HN 47079718](https://news.ycombinator.com/item?id=47079718).)

### Target audience
Engineers running "multiple Claude Code and Codex sessions in parallel" on macOS, explicitly "not Electron/Tauri." The README name-checks Claude Code, Codex, OpenCode, Grok, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy, Factory, Qoder — the multi-coding-agent operator persona, same one c11 targets.

### Differentiating features
Vertical tabs in a sidebar with live per-workspace metadata; notification rings/panel keyed off escape sequences plus `cmux notify`; in-app browser with scriptable accessibility API; scriptable CLI + socket for workspace/pane/keystroke/browser automation; Ghostty config interop; SSH workspaces with browser routed through remote network; native macOS / GPU-accelerated.

### Tech stack / platform
Swift 80.9% / Python 10.7% / TypeScript 3.8%, AppKit, libghostty for rendering. macOS-only native app.

### OSS status
- **Dual-licensed:** GPL-3.0-or-later open source plus a proprietary commercial license sold by Manaflow, Inc.
- **~17.7k stars** as of 2026-05-23.
- Very active. Two primary committers (`lawrencecchen`, `austinywang`) shipping multiple point releases per week (v0.64.5 → v0.64.9 between May 13–22).
- Effectively 2-person team with AI co-authoring and YC-style commercial backing.

### Overlap with c11
c11 inherits a lot from cmux: native macOS, Swift/AppKit, libghostty rendering, Ghostty config interop, vertical-tab sidebar workspace model, in-app browser as a first-class non-terminal surface, CLI + socket API, session persistence, OSC-driven notification capture. cmux v0.64.7 (May 19, 2026) shipped "Markdown file preview panels" — so even markdown previewing is no longer c11-exclusive (though c11's markdown surfaces are addressable peers, not preview panels). The embedded-browser substrate, the addressable CLI/socket shape, and the vertical-tab sidebar are upstream contributions; c11 should not claim to have invented them.

### Gap c11 fills (what c11 added since the fork)
- **Agent self-identity as a first-class sidebar primitive.** Agents declare role/status/progress/log into per-workspace sidebar telemetry; cmux's notification panel is reactive (it surfaces OSC pings), not an identity layer.
- **Skill system** (`skills/c11/SKILL.md` plus peers) that teaches agents to drive the workspace from inside.
- **Per-workspace mailbox** for agent-to-agent messaging.
- **Surface manifests / metadata layer** as an open JSON seam agents read and write.
- **Markdown surfaces as a peer surface type** — not a preview panel; fully addressable scriptable surfaces.
- **Workspace blueprints / 2×3 new-workspace launcher** (v0.49–0.50).
- **Explicit agent-orchestration primitives** (`c11 default-agent launch`, env-var/CLI split).

### Show HN reception
[HN item 47079718](https://news.ycombinator.com/item?id=47079718), Feb 19 2026, **198 points / 77 comments.** Broadly warm. Praise for native vertical tabs ("a great idea for ghostty"), intuitive first-run, native-not-Electron performance. Objections clustered around tab-drag UX, zoom semantics, auto-reordering of workspaces, squished splits, and "IDE feature creep" warnings. At post time the repo was *private* and the OP wasn't committing to OSS — it has since gone GPL-3.0/commercial.

### What cmux has that c11 doesn't
- **Mind-share and distribution.** ~17.7k stars vs c11's ~24.
- **Cloud VM workspaces.** Recent cmux releases iterate on Cloud VM SSH attach and remote PTY.
- **Browser breadth.** Cookie/history import from 20+ browsers, mature accessibility-tree-based scriptable browser API.
- **Claude Code Teams native integration.**
- **Velocity and team support.** Two committers, commercial license, multiple releases/week.
- **Notification ecosystem maturity.**

The honest framing: **c11 is upstream cmux plus a layer of agent-native infrastructure** (identity, mailbox, skills, surface manifests, orchestration primitives). cmux is still the broader product with more cloud, more browser, and vastly more users.

---

## 2. Superset

### Description
Superset is an Electron desktop app pitched as "The Code Editor for AI Agents" — a wrapper that spins up many isolated git worktrees, drops a CLI coding agent (Claude Code, Codex, Cursor Agent, Gemini CLI, OpenCode) into each, and gives the operator a unified view. The pitch is parallelism through worktree isolation plus glue: one-click worktree creation with automatic environment setup, push notifications, built-in diff viewer, one-click editor handoff. Creators (Avi, Kiet, Satya) describe it as "an open-source terminal made for managing a bunch of coding agents… in parallel" and claim it "more than doubles our productivity." ([HN 46368739](https://news.ycombinator.com/item?id=46368739), [superset.sh](https://superset.sh/), [GitHub](https://github.com/superset-sh/superset))

### Target audience
Engineering teams already pushing CLI coding agents to their limit — devs who feel single-agent flow is the bottleneck. Logos cited include Amazon, Google, ServiceNow, Microsoft, OpenAI, Vercel, Cloudflare, plus YC startups (Mastra, Cadra, Trainloop).

### Differentiating features
Git worktree per agent as the core isolation primitive; automatic environment setup per worktree (setup/teardown scripts, Neon/Supabase branch hooks, Docker); notifications for agent-done/agent-stuck; built-in Kaleidoscope-style diff viewer; agent-agnostic; one-click editor handoff to VS Code/Cursor/Xcode/JetBrains.

### Tech stack / platform
Electron + React + TailwindCSS v4 frontend, Bun runtime, Turborepo, tRPC for IPC, Drizzle ORM + Neon Postgres + better-sqlite3, Ink for terminal UI. 94.9% TypeScript. macOS primary; Windows/Linux noted as "untested." Notable: in the Dec 2025 HN thread, hoakiet98 (team) referenced xterm.js performance ceilings and said they were exploring Ghostty-backed alternatives — same engine c11 already runs on.

### OSS status (a positioning trap)
Sources disagree. Third-party writeups say **Apache 2.0**, but the GitHub repo page itself reads **Elastic License 2.0 (ELv2)** — source available, not OSI-open-source. ELv2 forbids hosted/SaaS competitors. **~11,000 GitHub stars** as of 2026-05-23, ~2,894 commits on main, three named maintainers (Avi Peltz, Kiet Hoang, Satya). Free download, no public pricing page. **This is a real differentiator for c11** — c11 is genuine OSS; Superset is source-available.

### Overlap with c11
Parallel CLI agents in one host app; per-agent isolation (Superset = worktrees, c11 = workspaces/surfaces); agent-agnostic; notifications when agents finish; diff/review surface adjacent to agent; macOS primary.

### Gap c11 fills
- **License.** c11 is real OSS; Superset is ELv2.
- **Programmable surface handles** (`workspace:N`, `surface:M`).
- **Agent-to-agent mailbox.**
- **Agents declare their own identity/status/progress.**
- **Markdown + browser as first-class surface types.**
- **Skill system.**
- **Native Ghostty embed** (Superset is Electron + xterm.js — already hitting perf ceilings per the team's own HN comment).
- **CLI / socket scriptability.**

### Show HN reception
**"Show HN: Superset – Terminal to run 10 parallel coding agents"** (`avipeltz`, 2025-12-23, **96 points**, [HN 46368739](https://news.ycombinator.com/item?id=46368739)). This was their **second** Show HN — first attempt was 24 points on 2025-12-01, same product. Relaunch worked.

Objections: review-bottleneck ("how does this handle databases and stateful services across parallel worktrees?", "Doesn't human review time become a bottleneck?"), worktree-vs-shared-state tradeoff ("file reservations" instead), and skepticism about whether parallel agent work is actually productive.

### Framing lessons for c11's Show HN
1. **Numerical anchor in the title.** "10 parallel coding agents" is concrete and scannable.
2. **Lead with the pain, not the philosophy.** Superset's OP is one sentence. No manifesto.
3. **"We use Superset to build Superset"** — dogfooding signal.
4. **Quantified productivity claim, hedged.** "More than doubles our productivity" — specific enough to be credible, vague enough to be unfalsifiable.
5. **Pre-empt objections.** Review bottleneck, stateful-services multiplication, "is this just worktrees + a UI?"
6. **Show HN relaunches work** — same product, second post, 4× the score.

---

## 3. aTerm

### Description
aTerm is a macOS-only terminal workspace by solo developer Saad Naveed (`saadnvd1`), pitched as "a terminal workspace built for AI coding workflows." It bundles xterm.js terminals with a Monaco editor, a built-in git panel, project-based workspaces, task worktrees, and predefined layouts ("AI + Shell," "AI + Dev + Shell," "AI + Git"). A single-window project switcher (`Cmd+1-9`), **not a multiplexer in the tmux sense** — no socket, no scripting interface, no addressable handle for an external agent to drive the window. ([Show HN OP](https://news.ycombinator.com/item?id=46863804), [README](https://github.com/saadnvd1/aTerm))

### Target audience
A solo developer doing AI-assisted coding facing friction from "too many terminal tabs and split windows." One human driving one agent at a time across a few panes. **No mention of parallel agents, agent identity, or telemetry** — completely different mental model from c11/Emdash/Superset.

### Differentiating features
Predefined agentic layouts; project workspaces with persistent terminals; git-backed task worktrees; built-in Monaco editor; built-in git panel with inline diff/edit; per-project markdown scratch notes; keyboard-first navigation. The pitch is "IDE-shaped terminal for AI coding."

### Tech stack / platform
Tauri 2 (Rust) backend with portable-pty, React 18 + TypeScript + Tailwind + shadcn/ui frontend, xterm.js terminals, Monaco editor. macOS-only, signed/notarized .dmg. TypeScript 86.7%, Rust 10.2%. Tauri (webview) desktop app, **not native** in the AppKit/SwiftUI/Ghostty-renderer sense.

### OSS status
Open source, MIT. **16 stars** as of 2026-05-23. 4 forks, 174 commits, 1 contributor. No commits since 2026-04-24 — a quiet solo project. Note: `aterm.ai` exists as a polished landing page but does not link to the GitHub repo — possibly a separate product reusing the name, worth flagging to avoid conflating.

### Overlap with c11
macOS app; pitches itself as terminal workspace for AI coding agents; multiple AI CLIs (Claude Code, Aider, OpenCode, Cursor) in adjacent panes; project-level workspaces; split panes, themes, keyboard navigation; both MIT-ish OSS.

### Gap c11 fills
The whole operator-orchestrating-many-agents stack: agent self-identity and sidebar telemetry, programmable surface handles, mailbox, skill system, markdown+browser as first-class peers, native Ghostty renderer. aTerm has no socket, no CLI, no external scripting surface — every layout change is a human keyboard shortcut.

### Show HN reception
[Item 46863804](https://news.ycombinator.com/item?id=46863804), 2026-02-02 by `saadn92`. **Landed flat: 1 point, 0 comments.** No public discourse to position against. aTerm is a quiet solo project the HN audience didn't engage with — c11 is not entering a crowded loud space, but it isn't replacing aTerm either.

---

## 4. Emdash — the headline competitor

### Description
Emdash (YC W26) is an Electron-based desktop app that lets a developer run many coding-agent CLIs (Claude Code, Codex, Gemini, Cursor, Devin, Amp, Goose, plus ~20 more) in parallel, with each agent isolated in its own git worktree, locally or over SSH. Founders (Raban von Spiegel, Arne Strickmann) call the category an "Agentic Development Environment" (ADE). Ships built-in ticket integrations (Linear, GitHub, Jira, GitLab, Asana, Forgejo, Plain), diff review, PR creation, CI status, and merge — the whole shell around the agent. ([github.com/generalaction/emdash](https://github.com/generalaction/emdash))

### Target audience
Working developers who already use one or more coding-agent CLIs and want a single GUI to dispatch and supervise many — explicitly *not* the tmux/terminal power user. Thread supporters emphasized "way more demand for a UI than a CLI." Lives-in-Linear/Jira-tickets, click-driven dispatch-and-review loop.

### Differentiating features

**The 27 agents.** Show HN claimed 21; README as of today lists 27: Amp, Auggie, Autohand Code, Charm, Claude Code, Cline, Codebuff, Codex, Continue, Cursor, Devin, Droid, Gemini, GitHub Copilot, Goose, Hermes Agent, Jules, Junie, Kilocode, Kimi, Kiro (AWS), Letta, Mistral Vibe, OpenCode, Pi, Qwen Code, Rovo Dev. Architecture "built to add CLIs quickly." 27 logos in one screenshot is the single biggest reason it scored 206 — HN rewards neutrality.

**"Provider-agnostic"** — *not* a unified API surface, *not* a model fallback. Emdash shells out to whichever agent CLI you point it at. Abstraction is at the *task* level (ticket, worktree, agent, status), not at the prompt or tool-call level. Strategic claim: *"the multi-agent future is heterogeneous."*

**SSH remote.** Real SSH/SFTP with SSH-agent and key auth, credentials in macOS keychain. Workflow: thin laptop dispatches agents that run on a beefy remote box against codebases on the remote. The differentiator OP leaned on hardest when asked "how is this different from Conductor?" — Conductor is local-only.

Other emphasized features: worktree pooling for 500–1000ms task startup, `.emdash.json` config with setup/run/teardown scripts and `$EMDASH_PORT` injection, ticket → agent flow, diff/PR/CI/merge in-app, 60K+ downloads.

### Tech stack / platform
Electron, TypeScript (98.6%). SQLite local-first store. **macOS (Apple Silicon + Intel), Windows x64, Linux x64** — fully cross-platform, unlike c11. v1.1.24 shipped 2026-05-22, 5,910 commits on main.

### OSS status
- **Apache 2.0.** Real OSS.
- **~4.6K GitHub stars** as of 2026-05-23.
- YC W26 — funded startup, not side project. Business model: "bundled coding agent subscription" + enterprise features TBD; core stays open.

### Overlap with c11
Parallel agents, one per worktree (c11's Lattice orchestrator effectively does the same thing); first-class support for many coding-agent CLIs; cross-agent task dispatch; both open source; both reject single-provider lock-in.

### Gap c11 fills (sharp and honest)
**Emdash is a task dispatcher. c11 is a workspace.** The difference matters:

1. **Programmable surface handles.** Emdash has no concept of addressable panes from outside.
2. **Agent-declared self-identity.** Emdash *infers* status from process state and git diffs. c11 lets the agent *write* its own status into the sidebar via the skill.
3. **Agent-to-agent mailbox.** Emdash has no inter-agent communication primitive.
4. **Markdown and browser as first-class surface types.** Emdash is terminal-only inside its panes.
5. **Skill system.** Emdash teaches the *operator* how to use Emdash. c11 teaches the *agent* how to use c11.
6. **Composable per-pane terminals, not a managed task list.** Emdash is a Kanban over agents-in-worktrees; c11 is a multiplexer where the agent flow is one frequent use case.
7. **Ghostty renderer.** Emdash is Electron/xterm-class; c11 renders through Ghostty.

Cleanest framing: *Emdash is what you reach for if your unit of work is "the ticket." c11 is what you reach for if your unit of work is "the operator:agent pair, composing a workspace."*

### Show HN reception
**"Show HN: Emdash – Open-source agentic development environment"**, ~2026-02-26, **206 points, 71 comments** ([HN 47140322](https://news.ycombinator.com/item?id=47140322)).

Top comments:
1. **Bishonen88 (skeptical, top):** *"Custom AI tools like these have an uphill battle to fight ... I can just split my terminal effortlessly."*
2. **mccoyb (existential):** *"If agents continue to get better with RL, what is future proof about this environment or UI?"*
3. **haimau (positive):** *"Been driving my agents (CC, currently testing Pi) for a couple of weeks via Emdash ... shipping fast."*
4. **solomatov (competitive):** *"Could you compare it to Codex App, Conductor?"*
5. **nerder92 (workflow realism):** *"20 to 30% of tasks ... other 70% will have diminishing returns."*

### Objections c11 must pre-empt
- *"I already have tmux + Claude Code, why do I need this?"* — Hit Emdash hardest. c11's answer can't be "we're a better wrapper"; must be "the agent itself drives c11."
- *"If RL makes one agent able to coordinate N agents, your UI is redundant."* — c11's counter: even when the meta-agent exists, *it still needs surfaces*.
- *"How is this different from Conductor / Crystal / Container Use?"* — c11 must have a one-liner ready.
- *"What's your business model?"* — Emdash punted to "TBD" and it cost them.

### What Emdash did right that c11 should study
1. **Headline number.** "21 coding agents" is graspable.
2. **Crisp comparison one-liners.** OP had Conductor/Codex/Crystal differentiation rehearsed.
3. **Show-don't-tell screenshot.** 27 logos do the strategic framing for them.
4. **YC + open-source combo** defused "is this a side project?" skepticism.
5. **Concrete latency claim** (500–1000ms task startup).
6. **OP parked on HN for 24 hours.**

---

## 5. Tmux-IDE

### Description
Tmux-IDE (`wavyrai/tmux-ide`) is a Node.js CLI that turns any project into a tmux-powered terminal IDE driven by an `ide.yml` config. `tmux-ide init` auto-detects the stack and scaffolds YAML describing rows/panes/commands; `tmux-ide` materializes it into a tmux session. Nine built-in templates (default, Next.js, Convex, Vite, Python, Go, plus three `agent-team*` variants) and a "mission-driven" multi-agent layer orchestrating Claude Code / Codex teammates with milestones, validation contracts, skill-based dispatch, stall detection, heartbeat telemetry, and a localhost:6060 browser dashboard. ([tmux-ide.com](https://www.tmux-ide.com/), [README](https://github.com/wavyrai/tmux-ide))

### Target audience
Developers who want a per-project, declarative, reproducible terminal layout (Node/monorepo/Convex/Next.js teams), and increasingly teams running Claude Code agent teams. "OSS agent-first terminal IDE."

### Differentiating features
- **"Declarative"** = `ide.yml` with `name`, `before:` hook, `rows`, per-pane `command`/`dir`/`focus`/`env`, theme. Declarative for *layout*, not runtime behavior.
- **"Scriptable"** = rich `--json`-friendly CLI: `init`, `start`, `stop`, `restart`, `attach`, `ls`, `status`, `inspect`, `doctor`, `validate`, `detect`, `config`, plus mutators `config set`, `add-pane`, `remove-pane`, `add-row`, `enable-team`. Author on HN: *"Currently leaning towards a CLI first approach so that Claude/Cursor can configure and control the IDE."* It does not expose per-pane addressable-handle send APIs — that remains tmux's job.

### Tech stack / platform
TypeScript (~83%), Node.js ≥18, pnpm workspace + turbo monorepo. Installed via `npm i -g tmux-ide`. Runs on top of system tmux ≥3.0 — a *tmux wrapper*, not a from-scratch alternative. Cross-platform anywhere tmux runs: macOS, Linux, WSL, SSH boxes.

### OSS status
Open source, **MIT**. **475 stars**, 27 forks, 633 commits on main, last push 2026-05-22. **30 commits in last 30 days.** Solo maintainer (`wavyrai` / Thijs Verreck). Active CI on Node 18/20/22 + stress-test harness.

### Overlap with c11
Both target operator-running-many-agents; both treat per-project workspace as the unit; both expose CLI for external/agent control; both ship Claude Code-aware orchestration; both have a browser/dashboard surface; both are MIT-ish OSS, agent-first, 2026-vintage.

### Gap c11 fills
- **Native macOS app vs tmux wrapper.** c11 is Swift/AppKit + Ghostty + custom tab bar; Tmux-IDE shells out to system tmux and you live in whatever terminal emulator you opened.
- **First-class non-terminal surfaces.** c11 has addressable markdown and browser surfaces. HN already pushed back on Tmux-IDE: *"why are we eschewing high-DPI graphical displays, icons, true-color, images, and everything else in favour of a 1980s terminal?"*
- **Agent self-identity + sidebar reporting.** Tmux-IDE collects heartbeat/metrics for lead-coordinated teams, but no per-agent self-reporting primitive in the README — agents are seats in templates, not addressable identities.
- **Mailbox primitive.**
- **Broader skill system.** Tmux-IDE installs one bundled Claude Code skill; c11 ships a registry.
- **Addressable surface handles.** Tmux-IDE addresses the *session* and mutates YAML; runtime per-pane control is tmux's job.

### Show HN reception
**88 points, 38 comments** ([HN 47428868](https://news.ycombinator.com/item?id=47428868)), March 2026. Mixed-positive.

- **ekropotin:** *"So basically tmuxinator?"* — load-bearing comparison.
- **bwestergard:** *"I find it really important to avoid the temptation to multi-task by running multiple agents. For quite varied tasks, productivity gains from multi-tasking have proven to be illusory."* — direct shot at the multi-agent thesis c11 also sells.
- **mikestorrent:** *"why are we eschewing high-DPI graphical displays, icons, true-color, images... in favour of a 1980s terminal?"* — the gap c11 actually fills.

### Direct comparison: scriptability axis
Tmux-IDE's scriptability is **YAML-shaped and lifecycle-shaped** (edit `ide.yml`, restart). c11's is **runtime-shaped and handle-shaped** (`workspace:N`, `surface:M`, `c11 send`, no restart). Scriptable in different idioms: Tmux-IDE for workspace *shape*, c11 for workspace *operation*. They could reasonably coexist — an operator could run Tmux-IDE inside a c11 pane.

---

## 6. Rmux

### Description
Rmux is a tmux-compatible terminal multiplexer rewritten from scratch in Rust, with a typed async Rust SDK on the same daemon. Author (`shideneyu`/Helvesec) frames it as a reaction to scraping tmux output with grep and sleeps: *"Two surfaces: a tmux-compatible CLI (~90 commands, your keybindings just work), and a typed async Rust SDK on the same daemon — stable pane IDs, structured snapshots, locator-style waits. The idea is Playwright-style automation, but for terminals."* Runs natively on Linux, macOS, Windows (real ConPTY). **Headless infrastructure — no GUI, no window chrome, no tab bar.** ([Show HN 48219918](https://news.ycombinator.com/item?id=48219918), [rmux.io](https://rmux.io/), [github.com/Helvesec/rmux](https://github.com/Helvesec/rmux))

### Target audience
**Developers building automation against terminal programs, not interactive shell users.** Landing tagline: *"The multiplexer engine for Agents... keeps your shell alive, scriptable, and fully inspectable."* The persona is someone already writing `tmux send-keys` + `capture-pane` + `sleep` glue who wants a typed library — agent-runner authors, CI/integration-test authors for TUIs, DevOps engineers wiring AI agents into long-running shells.

### Differentiating features
1. **Dual surfaces on one daemon** — tmux-compat CLI for humans, typed Rust SDK for machines.
2. **Structured snapshots and locator-style waits** instead of regex-scraping `capture-pane`.
3. **Stable `PaneId`s** that survive index recompression.
4. **True cross-platform** via ConPTY on Windows.

**"Playwright-style SDK" — example code** (from [rmux.io/docs/get-started/](https://rmux.io/docs/get-started/)):

```rust
let pane = rmux.find_panes().title("agent:claude").one().await?;
pane.get_by_text("Ready").wait_for().await?;
pane.keyboard().type_text("printf 'test\n'").await?;
pane.keyboard().press("Enter").await?;

let agents = PaneSet::new(discovered.into_iter().map(|p| p.pane));
agents.keyboard().type_text("Explain rmux in one sentence.").await?;
```

Recognizable Playwright shape: `find_*().filter().one()`, `get_by_text(...).wait_for()`, `keyboard().type_text()`, plus a `PaneSet` for broadcast.

### Tech stack / platform
Rust (98.9%), Tokio, Ratatui for optional embeddable widget, custom PTY backends per platform (Unix PTY, ConPTY). IPC: Unix sockets / Named Pipes. **SDK bindings are Rust-only** — no Python, no TypeScript/Node.

### OSS status
Open source, **dual MIT / Apache-2.0**. **728 stars, 697 commits, latest v0.2.5 on 2026-05-22.** One-maintainer on a hot streak.

### Overlap with c11
- **Addressable panes** — c11's `workspace:N`/`surface:M` vs Rmux's stable `PaneId` + locators.
- **Wait-for-text semantics.**
- **Multi-pane broadcast.**
- **Daemon-backed sessions that survive client disconnects.**
- **Lineage rhetoric** — both pitch themselves as "tmux for the agentic era."

### Gap c11 fills
- **No GUI.** Rmux has no native window, no tab bar, no sidebar; you attach via CLI like tmux.
- **No first-class non-terminal surfaces.** Rmux panes are PTYs, full stop.
- **No agent self-identity / sidebar telemetry.** Rmux locates panes by title; c11 lets agents declare role/status/progress.
- **No mailbox.**
- **No skill system.** Rmux's audience is "you, writing Rust against the SDK." c11's audience is "the agent, taught to drive the workspace from inside."
- **Workspace as the unit of work.** Rmux's hierarchy stops at session/window/pane.
- **Rust-only bindings.** Most agent runtimes are Python or TypeScript; c11's socket/CLI is language-agnostic.

### Show HN reception
**182 points** ([HN 48219918](https://news.ycombinator.com/item?id=48219918)), May 2026. Three clear buckets:

1. **"Why not just tmux?"** — loudest objection. The author's repeated answer: tmux is for humans, rmux is for humans AND machines, with typed snapshots instead of grep-and-sleep.
2. **"Made by Claude" landing-page critique.** Top-rated comment was Sirental: *"The website is a little too obviously made by Claude. The first thing I noticed is the classic 'pill with pulsing green dot.'"*
3. **Genuinely curious agent-orchestrator users.** Most signal here: **cultofmetatron** explicitly named-checked cmux: *"a week ago I was using cmux but its osx only and doesn't work on remote terminals... is there a cli that lets me control the panel layout via a skill file and allow my opencode session to target and send data to other panes?"* — that's almost a description of c11.

### Direct comparison: programmability axis (Rmux SDK vs c11 CLI)
**Rmux goes deeper on typed-API depth. c11 goes deeper on embodied-workspace.**

Rmux is a **library**: import `rmux-sdk`, get typed Rust objects, await locator resolution. Strongly typed at compile time, async-native, Playwright-shaped vocabulary. More ergonomic than `c11 send` if you're writing a Rust orchestrator.

c11 is a **socket + CLI + skill**: every surface has a handle, every command is one shell line, and **agents — not just orchestrator code — drive the workspace through the same interface a human would**. Shallower in API-design terms; broader: any language reaches it, any agent can be taught via the skill, surfaces extend past PTYs.

**Philosophical difference:** Rmux says "rebuild tmux as a backend for agent code." c11 says "the operator:agent pair is the unit of work, and the workspace is its body." Rmux is the better pure backend. c11 is the only one that's also a place you sit and work.

---

# Synthesis

## Where c11 genuinely leads

Five capabilities are genuinely c11-exclusive across this field. These are the launch headline:

1. **Agent self-identity in the sidebar.** Across all six tools, only c11 lets agents *declare* their own role, status, progress, and identity into the workspace. cmux, Superset, and Emdash *infer* status from process state, OSC pings, or git diffs. The c11 agent writes its own telemetry through the skill; the operator sees a sidebar of named, self-reporting agents instead of a tab strip of opaque processes.

2. **Per-workspace agent-to-agent mailbox.** Not a single other tool in this scan has an inter-agent messaging primitive. cmux has notifications (one-way, OSC-driven). Emdash has none. Tmux-IDE has heartbeat telemetry to a coordinator. Rmux's SDK is consumer-to-multiplexer only. c11's mailbox is a structurally distinct primitive.

3. **Skill system that teaches agents to drive the workspace.** The dominant pattern in this space is "human points and clicks; agent runs in a pane." c11 inverts it: the skill loads into the agent's context window, the agent drives c11 from inside. cmux has no skill layer. Emdash teaches the operator. Tmux-IDE ships one Claude Code skill. Rmux teaches Rust developers. **The c11 skill is the steering wheel for the agent itself** — and it's the load-bearing answer to "I already have tmux + Claude Code, why c11?"

4. **Addressable markdown surfaces as peers to terminals.** cmux shipped *markdown preview panels* in v0.64.7 (May 19, 2026) — read-only previews. No other tool has addressable markdown surfaces that an agent can script via the same `surface:N` handle as a terminal. Emdash, Superset, Tmux-IDE, Rmux, aTerm are all terminal-only inside their panes.

5. **Workspace as a primitive above session/window/pane.** Rmux's hierarchy stops at tmux's. Tmux-IDE inherits tmux's. cmux has workspaces (shared origin), but only c11 makes the workspace the unit that carries sidebar identity, mailbox, blueprints, and skill scope together.

## Where c11 is at parity (don't put these in the launch copy)

Table stakes everyone in this space has — featuring them as differentiators reads as either ignorance or padding:

- **Parallel agents in one host app.** Superset, Emdash, Tmux-IDE, cmux — everyone.
- **Worktree isolation.** Superset and Emdash treat it as core; c11's Lattice orchestrator pattern is the same idea.
- **Per-pane CLI/socket scriptability.** cmux, Rmux, Tmux-IDE, Emdash.
- **macOS-first / macOS-native.** cmux, aTerm.
- **Multiple coding agent CLIs supported.** Emdash leads with 27 named; cmux name-checks 13; Superset works with "any CLI"; c11 likewise.
- **Diff review / PR creation surface** — Emdash and Superset have these built in; c11 currently relies on `gh` in a pane.
- **Open source.** Emdash, cmux, aTerm, Tmux-IDE, Rmux, c11 — all OSI-licensed. (Superset is ELv2, the lone exception.)
- **Ghostty rendering** — shared with cmux upstream. **Do not claim "we use Ghostty" as if it's distinguishing** — cmux did it first.

## Where c11 is behind (be honest)

These will come up on Show HN. The README should have answers ready.

- **Mind share.** ~24 stars vs cmux 17.7K, Superset 11K, Emdash 4.6K, Rmux 728, Tmux-IDE 475. c11 is the smallest by 1–3 orders of magnitude. The launch has to do real work to overcome this.
- **Cross-platform.** cmux, Emdash, Tmux-IDE, and Rmux all run on Linux/Windows. c11 is macOS-only and likely to stay so given the AppKit+Ghostty stack.
- **Cloud VM workspaces.** cmux ships them; Emdash has SSH remote. c11 has no comparable cloud-host story.
- **Provider breadth as a marketing surface.** Emdash's "27 logos in one screenshot" does enormous strategic-framing work. c11 supports the same agents but doesn't lead with the list.
- **In-app diff / PR creation / ticket integrations.** Emdash leads (Linear/Jira/GitHub/Asana/Forgejo/Plain). c11 has no first-class diff UI.
- **Velocity.** cmux ships multiple releases per week with two committers and a commercial license. Emdash is YC-backed with 5,910 commits. c11 is fork-level with a smaller active surface area.
- **Notification ecosystem maturity.** cmux's OSC 9/99/777 plumbing is more polished than c11's equivalent.
- **Browser breadth.** cmux ships cookie/history import from 20+ browsers and a mature accessibility-tree API. c11's WKWebView surface is behind.

## The "isn't this just cmux?" paragraph

**Draft for c11's README, 3–4 sentences:**

> c11 is a fork of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) that adds a layer of agent-native infrastructure on top of cmux's terminal substrate. Where cmux gave the operator a fast native Ghostty-backed multiplexer with a scriptable browser and CLI, c11 adds a *surface manifest* where agents declare their own role, status, and progress into a per-workspace sidebar; a *per-workspace mailbox* for agent-to-agent messaging; a *skill system* that loads into the agent's context window and teaches it how to drive c11 from inside; and *addressable markdown surfaces* as peers to terminals and browsers. cmux remains the broader product with cloud VMs, deeper browser support, and orders of magnitude more users — credit and gratitude both. c11 is the narrower bet on the operator:agent pair as the unit of work, and the workspace as its body.

## Show HN title candidates

Patterns from this scan: Superset and Emdash both scored high with concrete framing + numerical anchor. Rmux led with a metaphor ("Playwright for terminals"). Tmux-IDE led abstractly and capped at 88. **Concrete > abstract. Number > no number.**

Three candidates the parent can choose between:

1. **"Show HN: c11 – A macOS multiplexer where AI agents declare their own status in the sidebar"** — leads with the most distinguishing primitive (self-reported telemetry), explicit macOS scope, no over-claim. Concrete.

2. **"Show HN: c11 – Open-source Ghostty-based multiplexer with addressable panes and an agent mailbox"** — leads with substrate (Ghostty signals the cmux audience) + the two primitives Emdash/Superset/Rmux don't have. Strongest for the technical HN reader.

3. **"Show HN: c11 – Terminal where 10+ AI agents drive their own panes via a skill file"** — copies Superset/Emdash's numerical-anchor formula, foregrounds the skill (the load-bearing differentiator from Emdash). Best for HN-first-impression.

Recommendation: **#3 for the post itself, #1 as backup if #3 reads as too marketing.** Avoid "operator:agent pair is the unit of work" in the title — true, but lands cold; save for paragraph 2.

## Top 3 objections to pre-empt

These are drawn from the actual Show HN threads of Emdash (206 pts), Superset (96 pts), Rmux (182 pts), and Tmux-IDE (88 pts). They will come up on c11's launch.

1. **"Isn't this just cmux?"** — the lineage question. Address head-on in the README first paragraph (draft above). Generous credit to cmux; specific list of what c11 added; no defensiveness.

2. **"I already have tmux + Claude Code, why do I need a wrapper?"** — Bishonen88 (top comment on Emdash, 206 pts) and the entire "Why not just tmux?" cluster on Rmux. Standard "wrappers fail" objection. c11's answer **cannot be "we're a nicer GUI"** — it must be: *"tmux's API was built for humans driving shells. c11's primitives — surface handles, the mailbox, the sidebar manifest, the skill that loads into the agent's context — are built for the agent to drive the workspace. The skill is the steering wheel; tmux doesn't have one."* Specifically point at the skill file in the README.

3. **"How is this different from Emdash / Superset / Conductor / Crystal / Container Use?"** — solomatov and straydusk asked this of Emdash; c11 will get the same. **Have crisp one-liners ready:**
   - *vs cmux:* "cmux is the substrate; c11 adds the agent-native layer."
   - *vs Emdash:* "Emdash dispatches agents into worktrees. c11 is the workspace those agents compose from inside."
   - *vs Superset:* "Superset is a worktree manager with an Electron diff viewer. c11 is a native Ghostty multiplexer with addressable per-pane handles and an agent mailbox."
   - *vs Rmux:* "Rmux is a Rust SDK for orchestrator code. c11 is a workspace for the operator:agent pair, language-agnostic."
   - *vs Tmux-IDE:* "Tmux-IDE declares your layout in YAML. c11 lets agents reshape the workspace at runtime."

**Honorable mentions** (will come up but lower-priority to pre-empt):
- *"Multi-agent productivity is illusory"* (bwestergard on Tmux-IDE; nerder92 on Emdash). Counter: "for code review and parallel exploration, not for serialized refactoring." Honest hedge.
- *"If RL gives us meta-agents, your UI is redundant"* (mccoyb on Emdash). Counter: "the meta-agent still needs surfaces. c11 is the substrate it drives."
- *"Stateful services across worktrees?"* (101008, reactordev on Superset). Counter: surface c11's per-workspace env scoping.

---

**End of report. Sources cited inline above. Total tools researched: 6. Total Show HN threads pulled: 5 (aTerm thread had 0 comments).**
