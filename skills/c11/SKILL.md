---
name: c11
version: 1
description: c11 is a native macOS terminal multiplexer. Load this skill anytime any of the following attributes are hit: (1) session is inside c11 (`C11_SHELL_INTEGRATION=1`), (2) working with panes, surfaces, workspaces, splits, or tabs, (3) sending text or commands to another surface, (4) launching or orchestrating sub-agents, (5) declaring agent identity, setting title/description, or reporting sidebar status, (6) using the embedded browser or markdown surfaces, (7) any c11-specific command or troubleshooting question. When in doubt, load it.
---

# c11

**c11** is a terminal multiplexer that enables an individual hyperengineer operator to handle many terminals via spatial organization and organization across tabs, many tabs to a given pane, which is like a display area, many panes to a given workspace, and many workspaces to a given window, and potentially even multiple windows per C11 app.

**A workspace is a project.** One workspace per repo, project, or work item — that's the default unit, unless the operator has explicitly set up otherwise. When work needs more room, it goes into the **current workspace** as a new pane (`new-pane`) or a new surface within an existing pane (`new-surface`). New panes are right when the work needs its own spatial slot — a sub-agent for an audit, a terminal tailing logs, a browser pane for validation, a markdown surface for notes. New surfaces are right when a pane wants another tab on the same slot. New workspaces (`new-workspace`) are correct when the operator has named a different project or mission.

Agents are first-class here: every surface declares its own identity, title, and description, and reports status to the sidebar via the `c11` CLI. This skill teaches that operating model.

Browser and markdown are first-class surface types alongside terminals — see the sibling `c11-browser` and `c11-markdown` skills.

## Detect c11

Check `C11_SHELL_INTEGRATION`. If set to `1`, you are inside c11; use native workflows (splits, embedded browser, `c11 set-metadata`) instead of Chrome MCP or plain `open`.

```bash
[ "$C11_SHELL_INTEGRATION" = "1" ] && echo "in c11" || echo "not in c11"
```

Other env vars available to child processes: `C11_WORKSPACE_ID`, `C11_SURFACE_ID`, `C11_TAB_ID`, `C11_SOCKET_PATH`, `C11_SOCKET_PASSWORD`. The spawning shell may also set `C11_AGENT_TYPE`, `C11_AGENT_MODEL`, and `C11_AGENT_TASK` to pre-seed agent declaration — read once at surface start.

## Concepts

- **Window** — top-level macOS window
- **Workspace** — sidebar tab (title, git branch, cwd, ports, notifications)
- **Pane** — split region within a workspace
- **Surface** — terminal, browser, or markdown viewer inside a pane. Panes can hold multiple surfaces as tabs.

Refs accept UUIDs, short refs, or indexes: `window:1`, `workspace:1`, `pane:2`, `surface:3`, `tab:1`.

## Orient first

At session start — always, in this order:

```bash
c11 identify                                                        # Your workspace/surface/pane refs (JSON)
c11 tree                                                            # Spatial layout of the current workspace + hierarchical listing
c11 set-agent --type claude-code --model claude-opus-4-7            # Declare terminal_type + model (mandatory)
c11 rename-tab       --surface "$C11_SURFACE_ID" "<your role>"      # Title — what this surface is (mandatory)
c11 set-description  --surface "$C11_SURFACE_ID" "<why it's open>"  # Description — what you're doing right now (mandatory)
```

> **Binary bug (as of 2026-04-18):** `C11_TAB_ID` is exported equal to the workspace UUID, not the tab UUID. Bare `c11 rename-tab "<role>"` (and any other tab-scoped command that defaults to `C11_TAB_ID`) errors with `not_found: Tab not found`. Always pass `--surface "$C11_SURFACE_ID"` for tab-scoped commands (`rename-tab`, `set-title`, `set-description`) until this is fixed — `C11_SURFACE_ID` itself is correct.

> **Harness footgun: `$C11_SURFACE_ID` may be empty in agent-harness subprocesses.** Some harnesses (notably Claude Code's `Bash` tool) spawn subprocesses without inheriting c11 shell-integration env vars — `$C11_SURFACE_ID`, `$C11_TAB_ID`, and `$C11_WORKSPACE_ID` are empty strings even when `C11_SHELL_INTEGRATION=1` triggered the skill load. The CLI does **not** reject `--surface ""`: it silently defaults to whichever surface is *currently focused* in the workspace, which is usually a peer agent's tab. The `OK` envelope looks identical to a successful write; the only tell is that the response's `tab=` does not match your `caller.tab_ref`.
>
> **Defense:** at session start, capture your refs from `c11 identify --json` once and use the **literal refs** for every surface- or tab-scoped write going forward — `--surface surface:7`, not `--surface "$C11_SURFACE_ID"`.
>
> ```bash
> # Cache once.
> eval "$(c11 identify --json | python3 -c 'import json,sys
> d=json.load(sys.stdin)["caller"]
> print(f"C11_MY_SURFACE={d[\"surface_ref\"]}; C11_MY_WORKSPACE={d[\"workspace_ref\"]}; C11_MY_TAB={d[\"tab_ref\"]}")')"
>
> # Use the cached values.
> c11 rename-tab       --surface "$C11_MY_SURFACE" "<your role>"
> c11 set-description  --surface "$C11_MY_SURFACE" "<why it's open>"
> ```
>
> After the first write, verify with `c11 get-titlebar-state --surface "$C11_MY_SURFACE"` and confirm the title appears on the surface marked `◀ here` in `c11 tree --no-layout`. The same caution applies to `set-metadata`, `set-status`, `set-agent`, `clear-metadata`, `trigger-flash`, and any other surface- or tab-scoped command.

Also populate `role`, `task`, and `status` via `c11 set-metadata` **if known** from the opening message or environment (e.g. the user references a ticket ID, or `C11_AGENT_TASK` is set). Skip when unknown — don't guess.

**Title and description are both mandatory at orientation — not optional, not "if you have time," not "only for orchestrated sub-agents."** Every agent in every pane sets both, every time. The sidebar is the operator's only view into a room full of parallel agents; a surface that doesn't announce what it is *and* why it's open is invisible. The *Title and description* section below covers **what** to write; this section is about **when**: immediately, before touching the work.

Solo-agent orientation looks like this:

```bash
c11 rename-tab       --surface "$C11_SURFACE_ID" "TICKET-42 Plan"
c11 set-description  --surface "$C11_SURFACE_ID" "Planning the migration off the legacy auth middleware. Drafting a stepwise approach; no code changes yet."
```

**An unnamed, undescribed tab is an unidentifiable agent.** Name your tab immediately, even when working solo. Key word first, 2–4 words, under 25 characters (the sidebar truncates from the right): `c11 rename-tab "TICKET-42 Plan"` survives; `"Planning TICKET-42"` truncates to `"Planning TICK…"`.

**Show lineage for downstream tabs.** When a pane is spawned from another — sub-agents under an orchestrator, review agents over a feature's work, follow-ups rooted in earlier output — chain parent to child with `::`, parent first: `Login Button :: MA Review :: Claude`. Multiple rungs chain in order. The sidebar truncates to the parent (grouping siblings visibly); the full chain shows in the title bar. Users may override; lineage is the default whenever a parent exists. Before renaming, check `c11 get-titlebar-state` — if a chain is already present, preserve the prefix and only refine the trailing segment. See [references/orchestration.md#tab-naming-mandatory](references/orchestration.md#tab-naming-mandatory) for the full convention.

**Sibling workers are not downstream.** When the operator sets up peer panes they'll drive directly — e.g., two Claude Code panes for parallel feature work, a standing "Lattice Manager" next to them — skip the `::` chain and use a short positional or role anchor: `Feature Left`, `Feature Right`, `Lattice Manager`. Reserve `::` lineage for true hierarchical orchestration where a parent agent routes work down to sub-agents it will read back from.

**If the user's opening message is absent or ambiguous, ask before orienting.** This aligns with the global "dialogue" norm — don't silently rename a tab `"Explore"` just to have something in the sidebar. A direct request ("fix this bug", "what is X called") is not ambiguous; proceed with the request and run orientation in the same turn.

**If the user's opening message is bootstrap-only, defer titling to the next user message.** A bootstrap-only first message is one whose payload is "hydrate context" rather than "do work." Examples: `"load the c11 skill"`, `"you are running inside c11, load the c11 skill"` (the current launcher style), `"load the c11 and lattice skills"`. The operator's real first query is one turn behind, and the title should reflect that, not the bootstrap directive.

While deferring:

- Run identity orientation immediately. `c11 identify`, `c11 tree`, `c11 set-agent` declare *who* the agent is, independent of work, and are safe to fire now.
- Set a placeholder title and description that honestly reflect the orienting state:

```bash
c11 rename-tab       --surface "$C11_SURFACE_ID" "Awaiting first task"
c11 set-description  --surface "$C11_SURFACE_ID" "c11 skill loaded. Send your first task to name this surface."
```

- **On the next real user message, your very first action is to title the surface, before any other tool call.** The "next real user message" is the first turn from the user that isn't itself another bootstrap directive: another `"load X skill"` keeps you deferring; anything that describes work is what you title from. A stale `"Awaiting first task"` lingering past the first work message is a navigation failure, not a minor cosmetic lapse. If you are in a chat whose only turn so far is `"load the c11 skill"`, you wait. The moment the operator's real query arrives, the title is the first thing you set.

The rule is intentionally narrow. It does **not** cover `"read /path/to/X and follow instructions"` (the work lives in the file; read it, then title) or slash-command first turns (the slash skill takes over and titles for its own work). If a bootstrap clause is bundled with real work in the same message (`"load the c11 skill, then plan ticket LAT-42"`), title from the work clause; the bootstrap is noise. If no follow-up ever arrives, the placeholder persists; the operator handles naming via the Bonsplit tab UI or a direct rename instruction.

**Titling is not a one-shot.** After the first real titling, proactively refresh both fields as the work pivots: new ticket, new file, new sub-task, scope change of any meaningful kind. Don't wait for the operator to ask, and don't batch it for the end of the session. The *Keep them current when scope shifts* section below covers the broader discipline; the deferral case above is just the first moment where it matters.

### Declaring your agent

`c11 set-agent` writes `terminal_type` and `model` to the surface manifest:

```bash
c11 set-agent --type claude-code --model claude-opus-4-7
c11 set-agent --type codex --task lat-412
```

Common types: `claude-code`, `codex`, `kimi`, `opencode`. Any kebab-case string is accepted. Inside Claude Code, `claude.session_id` is populated automatically by the wrapper.

## Targeting

`--workspace` and `--surface` must be passed **together** when targeting a surface you don't live in. Either flag alone fails or misfires.

```bash
# WRONG — errors or hits the wrong surface
c11 send --surface surface:5 "npm test"

# RIGHT — always pass both when remote
c11 send --workspace workspace:2 --surface surface:5 "npm test"
c11 send-key --workspace workspace:2 --surface surface:5 ctrl+c
```

When talking to your own surface, omit both — env vars default them correctly.

**`send` and `send-key` now require explicit surface targeting.** Callers outside a c11 shell integration context must pass `--surface`. The `C11_SURFACE_ID` env var satisfies the requirement for callers already inside a c11 surface. Passing `--window` alone is not sufficient — the command errors rather than falling back to whatever surface happens to be focused in that window.

## Send text to a surface

```bash
c11 send "echo hello"                   # Types text AND submits (synthetic Return at the end)
c11 send --no-submit "cd /tmp/"         # Types text only — no Return; for partial-line construction
c11 send-key enter                      # Send a keypress directly (no text)
```

`c11 send` types the text and dispatches a synthetic Return on the same turn, so the receiving TUI sees one user turn. Pass `--no-submit` when you want to type into the prompt without executing — building a partial line across multiple calls, or staging text before the operator hits Enter manually.

For complex prompts (backticks, code blocks, multi-line), deliver via temp file and tell the receiving agent to `Read /tmp/prompt.md` — shell escaping through `c11 send` is brittle.

**Text is positional, not `--text`.** `c11 send` accepts only `--workspace` and `--surface` flags; the message is the trailing positional argument. Writing `--text "foo"` silently types the literal string `--text` into the terminal because the parser takes `--text` as the positional and `foo` as a stray extra arg. Same shape applies to `c11 set-status`, `c11 log`, and any other CLI that documents text as a positional.

```bash
# WRONG: sends `--text claude ...` as keystrokes
c11 send --workspace $WS --surface $SURF --text "claude --dangerously-skip-permissions"

# RIGHT: positional, no --text
c11 send --workspace $WS --surface $SURF "claude --dangerously-skip-permissions"

# Use -- if the text itself starts with a dash
c11 send --workspace $WS --surface $SURF -- "--help is not a flag here"
```

**PTY-only reach.** `c11 send` / `c11 send-key` write bytes into the target terminal surface's PTY. They do NOT dispatch NSEvents to the AppKit responder chain, so they cannot drive non-terminal UI — the TextBox input, settings panels, sidebar controls, find overlays, and any SwiftUI / AppKit control are all unreachable this way. If a task requires typing into or clicking an AppKit element, the c11 socket CLI is the wrong tool. Working alternatives:

- Ask the human operator to exercise the UI and paste back the result.
- Accessibility automation (`AXUIElement`, `System Events` AppleScript).
- A purpose-built debug socket command in the c11 app itself (e.g. add a `textbox.focus` or `textbox.send-key` handler to the socket).

Surface this constraint up front when planning — don't sink time into PTY-based automation for a target that isn't a terminal.

## Read another surface

```bash
c11 read-screen --workspace $WS --surface $SURF --lines 80
c11 read-screen --scrollback --lines 200        # include scrollback buffer
```

## Create splits, panes, surfaces

```bash
c11 new-split <left|right|up|down>             # Split any pane; the NEW pane is always a terminal
c11 new-pane --type browser --url <url>        # New pane of any surface type; --direction is relative to focus
c11 new-surface --pane <pane-ref>              # Add a tab to an existing pane
c11 new-surface --no-focus                     # Create without stealing focus (safe for background agents)
c11 new-workspace                              # Create a new workspace
c11 new-workspace --layout <path|name>         # Create a workspace from a blueprint plan
```

- **`new-split` clarified.** Source can be a pane of any surface type — terminal, browser, or markdown. Only the *new* pane is constrained to terminal. Use `new-pane` when the new pane should be a browser or markdown viewer.
- **`--no-focus` on `new-surface`.** Pass `--no-focus` to create a terminal, browser, or markdown surface without the workspace switching focus to it. Useful when an agent is building out a layout in the background.
- **`--layout` on `new-workspace`.** Pass a blueprint file path or blueprint name to create a workspace pre-populated with the plan's pane/surface topology. Response includes `workspace_id`, `workspace_ref`, `window_id`, and `window_ref` (same envelope as a plain `new-workspace`), plus a `layout_result` field with apply details.
- **Direction is relative to the focused pane.** `new-pane` has no `--pane` flag; it operates on the currently focused pane. Call `c11 focus-pane --pane <ref> --workspace <ref>` first if you need to target a different one.
- **`new-split` does NOT return the new pane ref** — output is `OK surface:<N> workspace:<M>` only. Follow with `c11 tree --no-layout` (or `--json`) to discover the newly created pane. `new-pane` *does* return the pane ref (`OK surface:<N> pane:<P> workspace:<M>`).
- **Default targets differ.** `new-split` defaults to the **caller's** pane; `new-surface` defaults to the **focused** pane (often different). To add a tab to your own pane, read `caller.pane_ref` from `c11 identify` and pass it via `--pane`.
- **Browsers are tabbed by default.** When you need a browser surface and the workspace **already has a browser pane**, add a new browser tab to that existing pane rather than opening a fresh browser pane — match the universal browser expectation that new pages are tabs, not new windows. Find the existing browser pane in `c11 tree --json` (the pane holding a `surface_type: browser` surface) and call `c11 new-surface --type browser --url <url> --pane <browser-pane-ref>`. Only reach for `c11 new-pane --type browser` when **no** browser pane exists yet, or when the operator explicitly wants a separate pane (e.g. two pages side by side for comparison). Spawning a new browser pane when one already exists is the awkward interaction to avoid.
- **Operator-facing tab bar buttons.** Each pane's tab bar carries surface-spawn buttons: **A** (leftmost — launches the operator's configured agent; default Claude Code, set in Settings → Agents & Automation → Agent Launcher Button), then Terminal, Browser, Markdown. On the right, after the split buttons: **+** (new tab of the focused kind) and **X** (close this entire pane — shows a confirmation dialog). The X button is disabled when only one pane exists. These are UI affordances for the operator; agents continue to use the CLI commands above.

## Resize panes

Binary splits aren't balanced automatically. Two `new-split right` calls give you `[A 50% | B 25% | C 25%]`, not equal thirds. Use `resize-pane` to rebalance.

```bash
c11 resize-pane --pane <ref> --workspace <ref> (-L|-R|-U|-D) --amount <px>
```

- `-R <px>` grows the pane by pushing its **right** border rightward (shrinks the right neighbor).
- `-L <px>` grows the pane by pushing its **left** border leftward (shrinks the left neighbor).
- `-U` / `-D` are the vertical equivalents.
- A direction toward the workspace edge fails with `Pane has no adjacent border in direction <dir>`: the leftmost pane cannot `-L`, the topmost cannot `-U`, etc. Resize from the neighbor instead.

**Compound-split cascade.** When you resize a pane whose nearest matching border belongs to an *outer* split (not the split that directly separates it from its closest sibling), the resize moves the outer boundary; both children of the inner split grow **proportionally**, preserving their existing ratio. Example: given `[A 50%] | [B 25% | C 25%]` (outer horizontal split, right half split again), `resize-pane --pane B -L 500` pulls 500px across the outer boundary — B and C each gain 250px because their inner ratio is 1:1. Resize again across the inner boundary (`-R` on B) to equalize B and C without touching A.

**Recipe: equal thirds from two right-splits.** After `new-split right` twice on a workspace of width `W`, you have `[A W/2 | B W/4 | C W/4]`. One resize lands thirds, because the cascade does the inner redistribution for free:

```bash
# W = workspace content width (read from `c11 tree --json` or the ASCII floor plan header)
c11 resize-pane --workspace $WS --pane $B -L $((W / 6))
# → A shrinks by W/6 to W/3; B and C each grow by W/12 (inner ratio preserved) to W/3 each.
```

## Spatial layout (c11 tree)

`c11 tree` is how an agent sees the room. By default it scopes to your current workspace, renders an ASCII floor plan sized to the real content area, and lists every pane with pixel and percent ranges on the H (horizontal) and V (vertical) axes plus the split path that produced it.

```bash
c11 tree                                # current workspace with floor plan (default)
c11 tree --window                       # all workspaces in current window
c11 tree --all                          # every window
c11 tree --json                         # structured coordinates for layout reasoning
c11 tree --no-layout                    # suppress the floor plan, keep hierarchy
```

Read `c11 tree` before planning layouts — splitting blind leads to cramped panes. For programmatic layout decisions use `--json`: every pane carries its rect in pixels and percent, the workspace content-area dimensions, and its split path.

**`tty` field.** `c11 tree --json` and `c11 surface list` now include a `tty` field on each terminal surface (e.g., `/dev/ttys004`). Use this to correlate a c11 surface with a shell process, process listings, or agent detection — useful for "which surface is running that codex?" lookups.

## Title and description

The title bar on every surface shows a short title plus an optional longer description of what the surface is doing and why. Both are writable by agent or user and live on the surface manifest (canonical `title` / `description` keys).

```bash
c11 set-title "SIG Delegator — reviewing PR #42"
c11 set-description "Running smoke suite across 10 shards; reports to Lattice task lat-412."
c11 set-title --from-file /tmp/title.txt     # for long or special-character titles
c11 get-titlebar-state                       # read caller's own title/description/collapsed state
```

`c11 rename-tab` is a thin alias for `set-title`. The sidebar tab label is a truncated projection of the title; the title bar shows the full string and, when expanded, renders the description as markdown (bold, italic, inline code, lists, headings, blockquotes, links, rules; images/fenced-code/tables are stripped at render; links are styled but not navigable). Content over ~5 lines scrolls internally in a 90pt-capped region. See [references/metadata.md](references/metadata.md#title--description-sugar-m7) for the full subset and payload fields.

### The title + description split

Given the naming rule above (and its sub-agent echo in [orchestration.md](references/orchestration.md#writing-c11-aware-agent-prompts)), the useful further distinction is *what* title and *what* description. They carry different weight:

- **Title = what the surface *is*.** Generic and reusable across sessions. For file-backed surfaces (markdown, browser-on-local-file) the filename alone is usually right: `PHILOSOPHY.md`, `RFC-42.md`, `staging.yaml`. For role-holding terminals, the role in 2–4 words: `Phase 2 agent`, `Log tail`, `gh pr watch`.
- **Description = why this surface is open *right now*.** Context-specific, one to two sentences. The operator glancing at the sidebar and expanding the title bar should understand what prompted this surface and what to pay attention to, without reading the content.

```bash
c11 set-title       --workspace $WS --surface $SURF "PHILOSOPHY.md"
c11 set-description --workspace $WS --surface $SURF "Reviewing after migrating the observe-from-outside principle out of memory into this doc. About to revise the Primitives-before-policy section."
```

The operator is running parallel work and context-switching between surfaces; title + description together make the sidebar a navigable index of in-flight work instead of a list of opaque tabs. A hyperengineer who can see "why is this open" at a glance is strictly more effective than one who has to re-read the content to remember.

**Batch with the open command.** When you `c11 new-pane --type markdown --file …` or `--type browser --url …` for the operator, set title + description as the immediate next calls — don't defer. A surface that lives even briefly without a description is one the operator will have to re-derive context for when they tab over.

**Multiple artifacts in one session → one pane, not many tabs.** If the work produces more than one markdown artifact for the operator to review, consolidate them: either append to a single trail file with sections, or add subsequent files as **tabs of the same pane** with `c11 new-surface --type markdown --file <path> --pane <pane-ref>`. Three top-level markdown tabs make the operator do navigation work c11 is supposed to remove. See the c11-markdown skill's *Producing artifacts the operator will return to* section for the full pattern.

### Keep them current when scope shifts

Title and description are only useful as a navigable index if they reflect what the surface is *right now*. When your work pivots — planning → implementation, one ticket → another, one file → another, one sub-task → another — proactively refresh both fields **at the pivot**, not at the end of the session and not when the operator prompts you to. The operator glancing at the sidebar should never see a stale breadcrumb.

Rough test for "did I drift?": if an operator scanning the sidebar would make a different routing decision based on the new state of the work, the title or description is out of date.

When updating, preserve any lineage prefix on the title and the `Lineage:` line on the description — those are the operator's map for reconstructing why this pane exists (see below). Refine the trailing segment, not the chain.

### Lineage in titles and descriptions

For panes spawned downstream of another — sub-agents, reviews, fixes rooted in earlier output — lineage goes in **both** fields:

- **Title** chains with `::`, parent first (see Orient first above). Each segment stays short so the full chain fits: `Login Button :: MA Review :: Claude`.
- **Description** carries the story up the chain. Lead with a breadcrumb line, then the current context.

```bash
c11 set-title       --workspace $WS --surface $SURF "Login Button :: MA Review :: Claude"
c11 set-description --workspace $WS --surface $SURF "Lineage: Login Button → Multi-Agent Review → Claude reviewer.
Reviewing PR #42 for correctness, style, and edge cases. One of three parallel reviewers; findings merge upstream."
```

When updating the description on task change, preserve the lineage line — don't strip it. It's the operator's map for reconstructing why this pane exists; losing it forces a re-derivation from content.

### Pane-layer lineage

Panes (the split-tree leaves a surface lives in) carry their own free-form JSON manifest alongside the surface manifest. It surfaces the same title/description pair, and the same `::` lineage convention applies — the rules documented above cover panes verbatim, so this section only notes what's pane-specific.

- **Write with `--pane`.** `c11 set-metadata --pane <pane-ref> --key title --value "Parent :: Child"` (or `--json '{...}'`) writes to the pane layer. `--surface` and `--pane` are mutually exclusive on the same call.
- **Read-then-write is the default.** `pane.set_metadata` returns `prior_values` for every key in the incoming partial. Compose from the prior value rather than replacing — chain a new rung onto the existing lineage instead of blowing it away, unless the new task is genuinely unrelated.
- **Same `::` rules as surface titles.** Parent first, short segments, sibling workers skip the chain (see the *Orient first* and *Lineage in titles and descriptions* sections above — don't duplicate conventions across layers). When you `--title "Parent :: Child"` on `c11 new-split` / `new-pane`, the seeded value flows through the same persistence path as an explicit write.
- **On `/clear` (context reset), ask before renaming.** An agent that drops context inherits the pane title it had before the reset. If the next task is unrelated, ask the operator whether to rename the pane rather than silently replacing the breadcrumb — the prior lineage was load-bearing for someone. c11 installs no `/clear` hook; this is guidance, not automation.

## The surface manifest

Every surface carries a **surface manifest** — an open-ended JSON document that declares what the surface is, what it's doing, and anything else agents or tools want to advertise about it. Agents read and write it over the socket via `c11 get-metadata` / `c11 set-metadata`. c11 renders a small set of canonical keys in the sidebar and title bar, and leaves every other field opaque for Lattice, Mycelium, and third-party tools to define their own keyspace on top.

Think of the manifest as the extension point for c11: the host provides the surface and the transport; anyone can stake out their own keys.

```bash
# Write
c11 set-metadata --json '{"role":"reviewer","task":"lat-412","progress":0.4}'
c11 set-metadata --key status --value "running"
c11 set-metadata --key progress --value 0.6 --type number

# Read
c11 get-metadata                        # full blob
c11 get-metadata --key role --key task
c11 get-metadata --sources              # include provenance (who wrote each key, when)

# Clear
c11 clear-metadata --key task
c11 clear-metadata                      # clear everything (explicit source only)
```

> **Always pass `--surface "$C11_SURFACE_ID"` explicitly on surface-write commands** — `set-metadata`, `set-agent`, `set-title`, `set-description`, `rename-tab`, `clear-metadata`, etc. The env-var default is only safe on c11 binaries built after the `fix/set-metadata-env-default` fix; older binaries silently write to whatever surface the *operator* is focused on, which in a multi-surface workspace means you'll stomp a peer agent's metadata instead of your own. Defensive form costs one flag and works on every c11 version.
>
> ```bash
> c11 set-metadata --surface "$C11_SURFACE_ID" --key status --value "running"
> c11 set-title    --surface "$C11_SURFACE_ID" "TICKET-42 :: Impl"
> ```

**Canonical keys** (typed, rendered, size-capped):

| Key | Type | Renders |
|-----|------|---------|
| `role` | string (kebab-case, ≤64) | sidebar label |
| `status` | string (≤32) | sidebar pill |
| `task` | string (≤128) | sidebar monospace tag |
| `model` | string (kebab-case, ≤64) | sidebar chip |
| `progress` | number 0.0–1.0 | sidebar progress bar |
| `terminal_type` | kebab-case string (≤32) | sidebar chip |
| `title` | string (≤256) | title bar + sidebar tab label |
| `description` | markdown subset (≤2048) | title bar expanded region |

Non-canonical keys are free-form — the blob is your app's transport. Per-surface cap is 64 KiB; pull-on-demand only (no subscribe in v1).

**Precedence**: `explicit > declare > osc > heuristic`. `c11 set-metadata` writes as `explicit` and always wins. Heuristic auto-detection never overwrites a declared or explicit value.

## Sidebar reporting

Sidebar metadata commands give fast feedback without touching the JSON blob:

```bash
c11 set-status task "3/5 complete" --icon "play.fill" --color "#00FF00"
c11 set-progress 0.6 --label "3/5 subtasks"
c11 log --source "agent-name" "Finished the data model step"
c11 list-status
c11 clear-status task
```

**Constraint**: these only work from a direct c11 child process. Headless `claude -p` subprocesses are reparented to `launchd` and lose the auth chain — they cannot call any `c11` command. Interactive `claude` keeps the chain intact.

## Surface flash — asynchronous attention

Flash is c11's per-surface attention primitive: a brief or persistent visual pulse on the pane content and the sidebar workspace row. Reach for it when an agent produces something the operator should look at but the agent does not want to steal focus.

```bash
# One-shot pulse on a non-focused surface
c11 trigger-flash --surface <ref>

# Persistent pulse — keeps repeating until dismissed
c11 trigger-flash --surface <ref> --persistent

# Per-call color override (6- or 8-digit sRGB hex; default #F5C518)
c11 trigger-flash --surface <ref> --persistent --color "#FF5C5C"

# Programmatic cancel — clears any in-flight persistent pulse
c11 cancel-flash --surface <ref>
```

**`--persistent`** repeats the pulse until *either* the operator dismisses it (clicking the pane content or the sidebar workspace row) *or* an agent calls `c11 cancel-flash`. Use it for "look at this eventually," not "look right now": the operator may be deep in another workspace, and the recurring pulse is what makes the surface findable later. A `--persistent` call on a surface that is already focused degrades to a one-shot pulse — persisting where the operator is already looking would be noise.

**`--color`** distinguishes signals from different agents on the same workspace. Default is `#F5C518` (Stage 11 warm yellow). Validation accepts `#RRGGBB` or `#RRGGBBAA` (case-insensitive, optional `#`); anything else errors. The override tints the pane ring and the sidebar row pulse; the Bonsplit tab-strip pulse keeps its internal accent.

**`flash_state` metadata key.** When a persistent flash starts, c11 writes `flash_state=persistent` into the surface manifest; cancellation clears it. Other agents can poll the manifest instead of subscribing to per-frame visual state:

```bash
c11 get-metadata --surface <ref> --key flash_state
# → "persistent" if a persistent flash is live; empty otherwise
```

Treat `flash_state` as a forward-compatible enum — future c11 versions may add states. Match the value you care about; don't assume the field is binary. Cancel when the signal is stale: an agent that triggered a persistent flash to wait on a long-running task should call `c11 cancel-flash` if the task completes by another path.

**Flash Duration is operator-tuned.** Settings → Notifications → Flash Duration ranges 500–4000ms (default 1500ms) and scales every channel together (pane ring, sidebar row, persistent ticks). Agents do not need to read it — fire the signal, c11 paces it.

## Launching sub-agents

When you spawn a sub-agent, give it its own c11 surface (`c11 new-split` or `c11 new-pane`) and launch the agent inside that surface. The operator gets full observability through c11 (sidebar status, title and description, screen content), and the sub-agent runs as a full-fledged interactive instance instead of a headless detached process.

**Use `c11 default-agent launch --in-surface <ref>` to do the launch.** It is the canonical programmatic path: c11 owns the per-TUI prompt-delivery contract (claude-code positional, post-ready sendText for codex/opencode/kimi), so the same call works regardless of which agent the operator has configured. No shell interpolation, no per-TUI branching in caller code.

```bash
cat > /tmp/lat-xxx-prompt.md <<'EOF'
[full prompt here]
EOF

# Step 1: create the surface (terminal pane the agent will live in).
c11 new-split right

# Step 2: launch the agent into the new surface with the bootstrap prompt.
# Inspect `c11 tree --no-layout` (or the response from new-pane) to get the
# new surface's ref.
c11 default-agent launch \
    --in-surface surface:5 \
    --cwd /path/to/project \
    --prompt-file /tmp/lat-xxx-prompt.md
```

`--prompt-file` is preferred over `--prompt "..."` for anything non-trivial: c11 reads the file and delivers it as-is, no caller-side shell escaping.

The operator's configured default agent is launched unless `--agent <type>` overrides for this call only. Preference changes (Settings → Default Agent) take effect for the next launch — no shell respawn required.

### Fallback: `$C11_DEFAULT_AGENT_LAUNCH`

For ad-hoc shell composition (not the primary path for orchestrated launches), every c11 shell exports `$C11_DEFAULT_AGENT_LAUNCH` — the bare launcher command for the configured default agent, with no initial prompt baked in. Sibling `$C11_DEFAULT_AGENT_SEED_PROMPT` carries the operator's configured first-message string when set.

```bash
# Launches the agent with no prompt. Submit one yourself if needed.
c11 send --workspace $WS --surface $SURF "cd /path && $C11_DEFAULT_AGENT_LAUNCH"

# Reproduce the A-button's first-message shape (claude-code only — other
# TUIs ignore positional prompts).
c11 send --workspace $WS --surface $SURF \
    "cd /path && $C11_DEFAULT_AGENT_LAUNCH \"$C11_DEFAULT_AGENT_SEED_PROMPT\""
```

Reach for these env vars when the c11 binary's launcher CLI is the wrong fit (e.g., piping the launcher line through another process). For orchestrated sub-agent launches, prefer `c11 default-agent launch` — it works uniformly across all configured agent types and isn't sensitive to which TUI is the default.

### Pin the sub-agent's base

When the sub-agent will work in a worktree, the prompt must name the base
branch or SHA explicitly. Don't say "fresh worktree" — the agent will
inherit whatever HEAD is at spawn time, which may be a working branch you
don't intend to include.

```text
# WRONG — agent inherits caller's branch, transitively pulls in work
# that may not belong in this scope.
"Work in a fresh worktree and ship a PR for X."

# RIGHT — base is explicit; lineage is auditable.
"Branch off origin/main at <SHA from `git rev-parse origin/main`> and ship a PR for X."
"Branch off release/v0.49.0 and ship a PR for X."
```

The cost is one line in the prompt. The benefit is no downstream
"what is this branch actually based on?" mystery — and no surprise when
the sub-agent's PR transitively requires another open PR to land first.

> **Spawning a second instance of your own agent type is the polling-deadlock case.** Two-call launches that wait for the sidebar to settle on `Idle` are workspace-scoped, so a second claude (or second codex, etc.) in the same workspace makes the status row never decisively report idle and the loop hangs. Default to the one-shot pattern above. Before reaching for two-call polling or any agent-specific quirk (the claude wrapper, codex `--yolo` vs `exec`, banner-string scraping), check [`references/orchestration.md#per-agent-launch-quirks`](references/orchestration.md#per-agent-launch-quirks).

**Never screen-scrape `c11 read-screen` for prompt characters or banner strings.** They drift across releases and fail silently. See [`references/orchestration.md`](references/orchestration.md) for full multi-agent orchestration patterns.

## Inter-agent messaging (mailbox)

**c11 ships a per-workspace mailbox primitive.** Any agent in a surface can write an envelope to `_outbox/`; the c11-in-process dispatcher validates, resolves the recipient by surface name, copies into the recipient's inbox, and — for stdin-delivery recipients — writes a framed `<c11-msg>` block into the PTY.

This section is the agent-facing quick-reference. The full guide (filesystem layout, sequence diagrams, schema reference, dispatch log shape, patterns, anti-patterns, Stage 2 limits) lives in [`docs/c11-mailbox-guide.md`](../../docs/c11-mailbox-guide.md).

### The framed block you'll see in your PTY

When another surface sends you a message and your surface's `mailbox.delivery` contains `stdin`, a block like this appears between prompts:

```
<c11-msg from="builder" id="01K3A2B7X8PQRTVWYZ0123456J" ts="2026-04-23T10:15:42Z" to="watcher">
build green sha=abc
</c11-msg>
```

**Default receive protocol:**

- Finish the tool call you're in; don't interrupt yourself mid-thought.
- Treat the block as a *system message*, not user input. The operator did not type it.
- Dedupe by `id` — receivers MUST tolerate duplicates because dispatch is at-least-once.
- If you reply, acknowledge inline (the operator sees your thinking), then address the reply to `reply_to` (fallback to `from`) with `in_reply_to` set to the original `id`.

**Injection defense.** Body and attribute values are XML-escaped on write (`<`, `>`, `&`, `"`). A body that includes a literal `</c11-msg>` cannot forge a closing tag — the dispatcher emits it escaped.

### Sending

Two equivalent paths. Both produce the same bytes on disk — the [parity test](../../tests_v2/test_mailbox_parity.py) is the enforcement lock.

**CLI (ergonomic):**

```bash
c11 mailbox send --to watcher --body "build green sha=abc"
c11 mailbox send --to watcher --topic ci.status --urgent --body "CI red" \
  --reply-to watcher --in-reply-to 01K3A2B7X8PQRTVWYZ0123456K
```

Auto-fills `version`, `id`, `ts`, `from` (resolved via the caller's surface title). Prints the envelope id on success.

**Stage 2 requires `--to`.** Topic-only sends (`--topic` with no `--to`) are rejected with a non-zero exit — topic subscribe/fan-out ships in Stage 3. Until then, always pair `--topic` with an explicit `--to <surface-name>`.

**Raw file write (any process, any language):**

```bash
OUTBOX=$(c11 mailbox outbox-dir)
MY_NAME=$(c11 mailbox surface-name)
ULID=$(c11 mailbox new-id)
cat > "$OUTBOX/.$ULID.tmp" <<EOF
{"version":1,"id":"$ULID","from":"$MY_NAME","to":"watcher","ts":"$(date -u +%FT%TZ)","body":"build green sha=abc"}
EOF
mv "$OUTBOX/.$ULID.tmp" "$OUTBOX/$ULID.msg"
```

See [`Resources/bin/c11-mailbox-send-bash-example.sh`](../../Resources/bin/c11-mailbox-send-bash-example.sh) for a ready-to-run reference.

### Receiving

- **If your `mailbox.delivery` includes `stdin`:** the framed block arrives in your PTY automatically. No poll, no sync.
- **Otherwise:** drain the inbox explicitly.

```bash
c11 mailbox recv --drain    # list + print + unlink (default)
c11 mailbox recv --peek     # list + print only
```

**Opting in to stdin delivery.** Stdin delivery is per-recipient and off by default. Set `mailbox.delivery` on the surface that should auto-receive — it is a **comma-separated string** (not a JSON array), and the only handlers registered today are `stdin` and `silent`:

```bash
c11 set-metadata --surface "$C11_SURFACE_ID" --key mailbox.delivery --value stdin --type string
# multiple handlers run in order on the same envelope:
c11 set-metadata --surface "$C11_SURFACE_ID" --key mailbox.delivery --value stdin,silent --type string
```

Writing the value as JSON (e.g. `--type json --value '["stdin"]'`) is the canonical footgun: the dispatcher splits the stringified blob on commas, doesn't match the literal token `["stdin"]` against `{stdin, silent}`, and silently registers zero handlers — the envelope still lands in the inbox, but the framed block never reaches the PTY. Use `--type string` with the bare token(s) above.

### Debugging

```bash
c11 mailbox trace 01K3A2B7X8PQRTVWYZ0123456J   # pretty-print dispatch events for one id
c11 mailbox tail                                # follow _dispatch.log as it grows
c11 mailbox outbox-dir                          # absolute path of your outbox
c11 mailbox inbox-dir                           # absolute path of your inbox
```

`_dispatch.log` events go `received → resolved → copied → handler → cleaned`. A `rejected` event with an `_rejected/<id>.err` sidecar means the envelope failed validation (wrong version, missing field, oversize body, etc.) — see `spec/mailbox-envelope.v1.schema.json` for the rules.

### Stage 2 limitations (know before you lean on these)

- **No topic fan-out.** `c11 mailbox send` rejects topic-only envelopes (`--topic` without `--to`) with a non-zero exit and `topics_not_implemented`. Pair `--topic` with `--to <surface-name>` to send now; Stage 3 wires `mailbox.subscribe` globs through the dispatcher.
- **No `watch` handler.** `c11 mailbox watch` is unimplemented; use `c11 mailbox tail` to follow the dispatch log.
- **No `c11 mailbox configure` convenience.** Set `mailbox.delivery` / `mailbox.subscribe` / `mailbox.retention_days` via `c11 set-metadata` for now.
- **No `body_ref` read-through.** The schema accepts the field and the dispatcher stores it; reading external bodies is the recipient's job for now.
- **At-least-once is steady-state only.** Envelopes sitting in `_outbox/` when c11 restarts do get picked up on next start. But if c11 is killed *between* moving an envelope into `_processing/` and finishing the inbox copy, the envelope is stranded there until Stage 3 ships the `_processing/` recovery sweep. Callers that care about crash-window durability should pair with reply-chain retries or application-level tracking until then.
- **No per-surface inbox cap.** Stage 3 adds this alongside the crash-recovery sweep.

## Web validation

When in c11, prefer the embedded browser over Chrome MCP (`mcp__claude-in-chrome__*`). It is lighter, integrated into the workspace, and does not create stray Chrome windows.

- Preview: `open <url>` or `open <file>` — reuses the browser surface automatically.
- Interact: `c11 browser click`, `c11 browser snapshot`, `c11 browser fill`, etc.

Reach for Chrome MCP only when **not** in c11 or when a Chrome-specific feature is required. See the `c11-browser` sibling skill for the full automation API.

### Opening a browser pane on a local service

If the browser pane targets a local daemon (e.g. `lattice dashboard`, a dev server), start the daemon **before** creating the browser pane — otherwise the browser loads an error page and won't auto-refresh when the service comes up later. If you do have to open the pane first, reload it once the listener is live:

```bash
c11 browser --surface <surface> reload
```

**Don't pipe daemon launches to `head`, `tail`, or any finite reader.** When the reader exits, the daemon gets SIGPIPE and dies mid-start. Detach cleanly instead:

```bash
nohup lattice dashboard --port 8799 > /tmp/lattice-dashboard.log 2>&1 &
disown
```

## Workspace persistence

c11 can snapshot a workspace to disk and restore it later with the layout, surface titles, metadata (including `mailbox.*` pane metadata), and — when opted-in — resumed Claude Code sessions.

```bash
# Capture the current workspace to ~/.c11-snapshots/<ulid>.json
c11 snapshot

# List what's on disk (newest first)
c11 list-snapshots

# Restore by id (fresh shells)
c11 restore 01KQ0XYZ…

# Restore with cc session resume: each Claude Code surface re-spawns as
# `cc --resume <claude.session_id>` via the Phase 1 restart registry.
C11_SESSION_RESUME=1 c11 restore 01KQ0XYZ…
```

The snapshot wraps a `WorkspaceApplyPlan`; the same shape Blueprints and the debug `c11 workspace apply` use. Explicit `SurfaceSpec.command` always wins over any registry synthesis — the registry only fires when a terminal surface has no command and its metadata declares a known `terminal_type`. See [`references/claude-resume.md`](references/claude-resume.md) for the full wire-up (the SessionStart hook operators paste into `~/.claude/settings.json`, the `C11_SESSION_RESUME` gate, troubleshooting).

## Troubleshooting

If `c11` on your PATH does not resolve to the active bundle's CLI, run `c11 doctor` (`--json` for machine-readable output). It reports the bundled CLI path, how `c11` resolves on PATH, whether the PATH-fix shell hook has been applied, and a `status` of `ok | mismatch | missing | no_bundle`.

## References

- **[references/api.md](references/api.md)** — full command surface: addressing, discovery, workspace/pane/surface management, surface initialization quirks, sidebar metadata, notifications, troubleshooting
- **[references/orchestration.md](references/orchestration.md)** — multi-agent patterns: layout, tab naming, launching Claude Code sub-agents, agent-to-agent communication, sidebar reporting, writing c11-aware prompts
- **[references/metadata.md](references/metadata.md)** — metadata deep dive: socket methods, precedence table, all canonical keys, sidecar sources, consumer patterns
- **[references/claude-resume.md](references/claude-resume.md)** — Claude session resume: operator-installed SessionStart hook and the `C11_SESSION_RESUME` gate
- **[../c11-browser/SKILL.md](../c11-browser/SKILL.md)** — c11 embedded browser automation
- **[../c11-markdown/SKILL.md](../c11-markdown/SKILL.md)** — markdown surface viewer

Working with Lattice tickets inside c11? Also consult the `lattice` skill for Lattice+c11 integration patterns.
