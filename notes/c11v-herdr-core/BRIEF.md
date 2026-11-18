# Brief: should herdr-core become the basis of every c11 terminal?

You are a Fable seat in c11, launched by the c11 agent that did the first research pass (panel "herdr research"). Atin is driving you directly and reads your panel. He calls this **a potential pivot for c11** and wants a deep, unhurried exploration, not a quick verdict. Take your time. Go wide, then deep.

## The idea in one paragraph

c11's planned daemon (`c11d`, in `docs/c11v-design.md`) would own every terminal's PTY and screen on every host, while the c11 app becomes a pure display. herdr-core (`hc`, Apache-2.0, `github.com/herdrdev/herdr-core`) appears to already be that daemon: a holder process per terminal that outlives the core, an attach stream that sends a first paint and then raw program output, core-to-core federation over SSH, parent and child terminals, versioned documents in the core, an OpenRPC API. The proposal: hc runs all terminals on all hosts; c11 stays the display area: windows, workspaces, areas, terminal, browser and markdown panels, the sidebar and attention model.

## Read first

1. `docs/c11v-herdr-core.md`: the design sketch from the first pass, with what was verified. Treat it as a hypothesis to attack, not a conclusion.
2. `docs/c11v-design.md`: the c11v design, its decisions, the Step 0 results and open questions. The c11d it describes is what hc would replace.
3. Step 0 spike reports: `git show spike/c11v-manual-io:spike/c11v/README.md` and the rest of `spike/c11v/` on that local branch (the manual-IO backend, the stub daemon, `latbench.rs`, the cmux-tui harness, evidence).
4. `CLAUDE.md` in this repo, especially "Host and primitive, never configurator", the socket focus and threading policies, typing-latency hot paths, and the build rules (builds go to the build host through `scripts/remote-build.sh`).
5. `docs/remote-daemon-spec.md` (today's `c11 ssh` and `c11d-remote`), `upstream-triage/c11-1.0/02-ssh-agents.md`, `upstream-triage/c11-1.0/04-ios-companion.md`.
6. The c11 skill (`skills/c11/SKILL.md` and its references): the product surface agents depend on.

## The herdr family (cloned, read freely)

Shallow clones in `/private/tmp/claude-501/-Users-demo-Projects-Stage11-code-c11/724b9223-616b-4ef7-822f-32cd9dd2bd67/scratchpad/src/`: `herdr-core`, `herdr-app`, `herdr` (the TUI), `herdr-browser`, `herdr-layout-examples`, `awesome-herdr`. If that folder is gone, re-clone from `github.com/herdrdev/*`. Deepen history (`git fetch --unshallow`) if velocity or authorship matters.

- **herdr-core** (hc): 24k lines of Rust, first commit 2026-10-23, v0.1.14, mostly one author. Key reads: `schema/README.md`, `schema/hc.openrpc.json`, `docs/security.md`, `docs/machines.md`, `crates/herdr-core/src/{attach,holder,holder_proto,stitch,machines,relay,viewers}.rs`, its `SKILL.md`.
- **herdr-app**: their GPUI + libghostty desktop app on hc, shipped about 2026-10-25. A direct c11 competitor on macOS, Linux and Windows.
- **herdr** (TUI): 46.7k stars, its own server (cell-grid frames, not raw), 22 agent-detection manifests in `src/detect/manifests/`.

## Verified so far (hc 0.1.14 on the laptop, isolated session)

- Attach is raw after the first paint: OSC 7, OSC 8 and 24-bit SGR passed byte for byte.
- Keystroke-to-echo round trip through core and holder to zsh: p50 51 µs, p99 194 µs (6,000 samples, load 7).
- `kill -9` on the core: holder and shell survived; the next `hc` call started a new core that adopted the same pid with the screen intact.
- Terminals report `ghostty 1.3.0-HEAD`; no telemetry code found in the core.

The harness is in `notes/c11v-herdr-core/probe/` (`hcenv.sh` isolates a session; `hcprobe.py raw|lat` speaks the framed protocol). The verified release binary: `https://releases.herdr.dev/core/latest.json` → `macos-aarch64` tarball, check its sha256. Never use the installer script (it writes `~/.local/bin`).

## What to explore

Go beyond this list; it is a floor.

**The shape.** What does c11 look like with hc underneath, concretely, layer by layer? Walk the ~190 `TerminalPanel` / `TerminalSurface` special cases in `Sources/` and say what each becomes. Which c11 features move to hc, which stay in the app, which need a c11 sidecar, which break? Mailbox and doorbell, input guard, `read-screen`, `send`, agent detection, conversation resume and the session-resume wrappers, prompt cache and model detection, events and journal, flags and delegates, lineage, the panel sheet clocks, port scanning, the socket access gate, snapshots and restore, Quit semantics.

**Fidelity.** Ghostty's manual IO fed by hc: first-paint correctness (modes, kitty flags, alternate screen, scrollback, cursor, charsets), IME, bell, OSC 52 read, kitty graphics, resize ordering (the vim-after-resize defect from Step 0), multi-viewer sizing, flow control under heavy output (`yes`, a big `cat`), query answering (the core answers terminal queries itself: does that conflict with Ghostty?).

**Scale and robustness.** 200 terminals: holder RSS and CPU, core CPU, latency under load and under output floods. Core crash, holder crash, sleep and wake, network loss, SSH ControlMaster behavior, federation failure modes, `missed` and resync, state-directory corruption.

**Security and macOS.** hc has no per-client auth: any process under the user's uid can drive every terminal. Compare with c11's descendant-only socket gate and its focus and threading policies. TCC attribution when holders, not c11.app, are the responsible process; `SMAppService` and bundling; code signing and notarization of a bundled hc; per-tag dev isolation.

**Product and users.** c11 has live users. Migration, the exec fallback, snapshot compatibility, opt-in path, and what a user experiences at each step. What does c11 stop being good at, or gain? What does the skill (the agent contract) become?

**Strategy.** herdr-app competes head-on and the core is a week old with a bus factor near one. Dependency risk, fork-ability, protocol stability (its "API only grows" test), version and update coupling, trademark and naming, the interop option (shared session: c11 terminals visible in herdr-app and in third-party clients like Heeler). Alternatives on the same axes: build c11d ourselves (the Step 0 recommendation, a fork of cmux-tui's terminal host), fork hc outright, or a hybrid. If this is a pivot, what does c11 become, and what is its moat when the runtime layer is shared?

## Hands-on is encouraged

- Run hc yourself, always isolated: own `HC_SESSION`, XDG dirs under a scratch folder, socket in a short `/tmp` folder. Stop every core you start and remove its sockets. Never start a core in Atin's default session.
- Remote tests: use a Prime sandbox (`~/src/platform/prime-intellect.md`), not the build host's real environment. Ask before installing anything on the build host.
- c11 builds and tests go to the build host through `scripts/remote-build.sh` with one reused tag (see `CLAUDE.md` and `skills/c11-hotload/SKILL.md`); clicks and launches go to a sandbox guest, never Atin's session. Wiring the spike branch's manual-IO backend to hc's attach stream ("spike 0b") is in scope if you judge it the best use of time; say so first.
- Subagents and other models are fine for parallel reading or a second opinion (Sonnet by default, Opus when it earns it).

## Boundaries

- No pushes, PRs, tags or releases. Spike work stays on local branches.
- Nothing outward-facing: no issues, comments or messages to herdr or anyone else.
- Never write tenant config (`~/.claude/`, `~/.codex/`, shell rc files) or install hc into Atin's PATH.
- Don't touch `docs/c11v-design.md`. You may correct `docs/c11v-herdr-core.md` where you find it wrong; note each correction at the end of your exploration doc.

## Deliverable

`notes/c11v-herdr-core/EXPLORATION.md`, plus any evidence beside it. Open with "Needs you:" and numbered decisions, each with your recommendation and what hangs on it. Then: the architecture as you now see it, the feature-by-feature map, numbered issues ranked by severity (each with evidence or the experiment that would settle it), pros and cons against the alternatives, a strategic read, and a proposed path with steps and kill criteria. Mark every claim as verified (and how) or inferred.

## Working rhythm

- Name your panel and keep your description current at each phase (c11 skill).
- Give Atin steady updates at checkpoints in your panel, in local time, so he never has to ask.
- Raise a c11 flag only if you are blocked on a decision only Atin can make.
- When done, post your report in your panel and send a one-line pointer to the launching agent: `c11 mailbox send --to-parent "<path and headline>"`.
