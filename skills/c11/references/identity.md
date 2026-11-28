# Orientation, title and description, the report

Print this page with `c11 guide identity`. The full orientation steps, Codex's runtime capture, the title and description contract, and the report format. A link to `<page>.md` names another page: `c11 guide <page>`.

## Orientation

**Codex: capture your exact thread before other orientation work.** From one of your own tool subprocesses, run `c11 conversation capture-runtime` with no arguments. It reads `CODEX_THREAD_ID`, the agreeing `C11_PANEL_ID` value, and the subprocess's actual cwd itself. Never expand, copy, relay, or add those values as flags; an orchestrator cannot truthfully capture a child agent's runtime identity on its behalf.

The bundled Codex wrapper separately marks each interactive process boundary. Its internal `--expected-resume-id` claim intent preserves an existing exact ref only for the same explicit `codex resume <uuid>`; plain launches and mismatches invalidate the prior lifecycle until this target performs runtime capture. Agents and orchestrators must not call that internal option or treat argv as causal identity.

c11 stamps your sidebar identity itself: the agent-type/model chip and a placeholder **"Awaiting first task"** title are set the moment you launch. Apart from Codex's conversation capture above, there is no mechanical identity ritual to spend the operator's time on.

**You'll usually load this skill because a task arrived** that touches the workspace (a split, a status report, a browser check). When that happens, orient in place and keep moving — at minimal effort, no per-command deliberation:

- Refine the placeholder into your real role: `c11 rename-panel --panel "$C11_PANEL_ID" "<2–4 word role>"`. The sidebar is the operator's only view into a room of parallel agents, so a working agent must not sit under "Awaiting first task".
- Say why it's open right now: `c11 set-description --panel "$C11_PANEL_ID" "<current context>"` — this is your live subtitle, the line the operator reads under your name (contract below).
- If your model chip is blank (an unpinned launch c11 couldn't label), set it: `c11 set-agent --panel "$C11_PANEL_ID" --type "$C11_AGENT_TYPE" --model "$C11_AGENT_MODEL"` — substitute your own known type/model if those vars are empty.
- Reach for `c11 tree` / `c11 identify --json` only when you actually need layout or your refs (footgun below).
- Read a reference (map below) only for the capability you're using — not preemptively.
- **Declare mailbox identity during orientation, before peers need to reach you**: `c11 set-metadata --panel "$C11_PANEL_ID" --key mailbox.address --value "<stable-handle>" --type string`. Mail push is on by default for an interactive agent a c11 wrapper launched; `mailbox.delivery=off` (or `mailbox.doorbell=off`) opts out. Titles are mutable; the address survives renames. c11 pushes only to a real agent-owned interactive terminal, never a plain shell or one-shot command. (Depth → [docs/c11-mailbox-guide.md](../../../docs/c11-mailbox-guide.md).)

**Launched with only a hydrate message and no task yet?** An operator can configure a "load the skill" launch prompt, so your first turn may carry no real task. Don't invent a title — leave the placeholder, reply in one line that you're ready, and set your real title/description from the next real message, as your first action that turn.

### Title vs description: identity and the live subtitle

- **Title = stable identity.** 2–3 words, role-first, DISTINCT from siblings — make the first word differ; the leading characters are all that survive sidebar truncation. A ticket ID is welcome (`C11-184 Attention`). No `Parent :: Child` chains, no shared prefixes. Rename only when your role or mission changes; check `c11 get-titlebar-state` first.
- **Description = your live subtitle.** The operator reads it in three places: in the bar under the panels (the bar shows the description, and on a terminal a fixed chip naming the machine), as the subtitle row in the panel sheet, and flattened to one truncated line in the sidebar. First sentence carries what you are doing *now* and the next meaningful gate, present tense: `"Auditing retry admission against the shipped tests; next, verify cancellation."` — not "Reviewing the code."
- **Plain English always.** A ticket number may appear in the subtitle, never *as* the subtitle — the operator should not need a tracker lookup to know what a panel is doing.
- **Refresh at transitions** (task start, phase change, blocker hit or cleared, handoff) — not after every command. A working agent must not sit under a stale subtitle; same register as panel naming.
- **The operator sees its age.** Beside the description, the panel bar and the summary card show `edited 12 min ago` (a narrow panel bar shows `12m`) and the sidebar card shows `12m`. Only a change of text moves the age: rewriting the same text leaves it, so a re-set never makes a stale subtitle look fresh. `get-titlebar-state --json`, `tree --json` and `sidebar-state --json` report `description_updated_at` (local time) and `description_age_seconds`.
- **Icon + color = optional at-a-glance marker.** `c11 set-panel-icon --panel "$C11_PANEL_ID" "🧪"` pins a glyph left of the panel's close X; `c11 set-panel-color --panel "$C11_PANEL_ID" teal` fills its tab with that color, full on the visible panel and dimmed on the others (`--clear` removes either; the operator sets the same color from the panel's right-click Panel Color menu). Use them to mark a set or a role family across panels, not as status.
- **Lineage is the LAST line**: `Lineage: <parent> → <role>`. Arrow, never `::`. Ancestry is static; the line that survives truncation must be the live one. Preserve it on every update.

### The report: what the operator reads on arrival

The operator reaches your panel cold, from another agent's panel, often through Feed, and reads your last message to decide whether to act. Write it for that reader.

- **First line says whether they must act.** `Needs you: nothing`, or numbered questions, each with one line on what hangs on the answer and your recommendation.
- **Aim under 100 words.** A target, not a rule: a report they asked for, or a decision with real options, can run longer. "Needs you: nothing" ends the message within a few lines.
- **State, not story.** A change made is one line. The reasoning lives in the file, ticket or run-state, and the message points there.
- **Never restate what another panel, PR or doc already holds.** Point at it.
- The long version is one ask away; the transcript holds it.
