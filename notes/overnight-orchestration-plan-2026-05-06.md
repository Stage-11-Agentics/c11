# Overnight Lattice Orchestration — Plan & Resume Runbook

**Drafted:** 2026-05-06 ~18:36 UTC by meta-orchestrator agent (Claude Opus 4.7).
**Updated:** 2026-05-06 evening — operator-confirmed policies, queue bumped to 4, framing updated.
**Operator:** Atin (going to bed; operator returns later).
**Operating context:** This runbook is executed by the same Claude session that drafted it (and any successor session that picks up via `state.json`). The meta-orchestrator runs inside the **main `/Applications/c11.app` instance** — the production c11 build, socket `~/Library/Application Support/c11mux/c11.sock`. All surface/pane/workspace IDs in this file from earlier drafts are stale; the orchestrator creates fresh ones at launch and records them in `notes/overnight-meta/state.json`.

---

## What you're being asked to do

Run a meta-orchestration: keep **four Lattice delegations in flight at a time** through the night, picking up the next ticket from a fixed queue as each finishes, until the queue is empty or the operator is back.

Each delegation runs the full `lattice-delegate` skill pattern: isolated git worktree, dedicated delegator pane, plan/impl/review/validate/handoff phases as sibling surfaces (tabs in the delegator's pane). You play the orchestrator role inline for each ticket — there is no separate per-ticket orchestrator pane. You are the one meta-orchestrator surface watching all of them via `ScheduleWakeup` polling.

Skills to load before you do anything:
- `c11`
- `lattice-delegate` (at `/Users/atin/Projects/Stage11/.claude/skills/lattice-delegate/SKILL.md`) — primary contract
- `lattice` (general task tracker patterns)
- Project `CLAUDE.md` at `/Users/atin/Projects/Stage11/code/c11/CLAUDE.md` — typing-latency, localization, testing, validation. Authoritative.

---

## Operator-confirmed policies

These were settled in dialogue. Do not relitigate.

| Policy | Setting |
|---|---|
| Queue size | **4 in flight at a time.** |
| PR merge | **Stack PRs for operator review when operator returns. Do NOT merge anything.** Delegators stop at `status=review` with PR open. |
| Validation bar | **Hybrid.** Heavy (Codex computer-use validator on a tagged build) for UI-visible bug fixes and feature work. Light (build-green + unit tests + delegator self-check) for chores and the audit ticket. Per-ticket designation in the queue table below. |
| C11-1 handling | **Research-only.** Read the audit notes + ticket trail, write a markdown summary of "open decisions and recommended path" for the operator. No code changes, no Lattice writes. Lives in its own sibling pane (not a delegation slot). |
| Token / rate limits | None. No budget cap. Keep working through tickets until queue is empty. |
| Translator phase | **One translator surface per delegation that introduces new strings. Single agent walks all 6 locales sequentially. No parallel locale spawn.** Only C11-30 is expected to need this overnight. |
| Submodule serialization | Queue order enforces this: C11-19 only starts after C11-18 reaches `status=review` or `needs_human`. No runtime lock-detection protocol. If a *different* delegation unexpectedly needs a `ghostty` or `vendor/bonsplit` pointer change, the delegator should park at `needs_human` with a comment and the orchestrator surfaces to operator. |
| Rework cap | 3 cycles per ticket → escalate to `needs_human`. Parked tickets are fine — keep going. |
| Stop conditions | Halt new spawns only if **CI on `main` goes red** (see "CI gate" below). Accumulating `needs_human` tickets is acceptable; do not idle the queue on that signal alone. |

---

## The queue (in order)

Run **C11-17, C11-30, C11-24, C11-16** as the first wave (4 in flight). C11-1 research kicks off in a sibling pane in parallel — it is not a delegation slot. As each delegation lands at `status=review`, drop in the next ticket from the wait list in order: **C11-18 → C11-19 → C11-4**. C11-19 holds if C11-18 is mid-flight (both touch the portal/bonsplit area; serialize via queue order, not a runtime lock).

> **2026-05-07 ~02:42Z operator update:** Stop adding new tickets after the currently-in-flight set. C11-19 is **deferred** — do NOT promote it to in-flight. C11-4 (already promoted) finishes naturally. Run is done when C11-30/24/18/4 reach `status=review` with PRs open or are at-rest.

| # | ULID | Short title | Priority | Validation | Notes |
|---|---|---|---|---|---|
| C11-17 | `task_01KQ2JERH58TBYH5R5K5QT52EE` | Refactor cleanup: dead installer code | medium chore | **Light** | Pure deletion (~2,300 LoC in `CLI/c11.swift`, lines ~13906–16252). Preserve `Resources/bin/claude` (deliberate exception). Update `docs/c11mux-module-4-integration-installers-spec.md` as historical. Pass-1 only; Pass-2 exploration is out of scope overnight. |
| C11-30 | `task_01KQXEJPEGPC7D3Y4Q7RPYGSP9` | Close-workspace confirmation overlay | medium | **Heavy** | Workspace-scoped black scrim + centered card. Mirror `PaneInteractionOverlayHost.swift` pattern. AppKit portal layer (per CLAUDE.md "Terminal find layering contract"). Esc cancels, Return confirms. Fade 120-180ms. Six trigger sites to rewire. New strings → Translator phase for ja/uk/ko/zh-Hans/zh-Hant/ru. |
| C11-24 | `task_01KQTP0S2VV52K1FX3F5837YDH` | Right-click manifest viewer | medium | **Heavy** | New context-menu entry "Show surface manifest…" → read-only JSON viewer. Works on terminal/browser/markdown surfaces. v1 = no editing, no live subscribe. Stretch: `--sources`-style provenance + copy-to-clipboard. |
| C11-16 | `task_01KPYD5M5KV52QSTNEJ6A1ZDGV` | FDA runtime detect + auto-continue TCC primer | medium | **Heavy** | Probe protected file on backoff timer; detect grant; auto-advance the primer. Don't hammer FS, don't block main, don't steal focus from "Continue without it" path. Follow-up to shipped C11-15. |
| C11-18 | `task_01KQ3Y77ATG09X67AKMNA2W2JV` | Ghostty surface duplicates above pane bounds | high bug | **Heavy** | Diagnose-first delegator. Suspected portal-sync race during rapid split→close→reset. Investigation paths in ticket: `WindowTerminalPortal`, `entriesByHostedId`, `synchronizeAllHostedViews`, `attachPaneInteraction`, `.transaction` animation residue. May land at `needs_human` if root cause is speculative. |
| C11-19 | `task_01KQ3YS5WSAHAJF2Z6933QCBA2` | Pane X button residual unresponsive | high bug | **Heavy** | Holds if C11-18 is in flight. Residual after PR #81's `.overlay → .background` fix. Bisect: temporarily disable `paneCloseInteractionRuntime`; if Xs work → issue is in overlay path; if not → likely portal-related (related to C11-18). |
| C11-4 | `task_01KPQ7YJW64PG7J5H4JVM0N2B9` | Resolve Audit Findings | high | **Light** | Three audit items, one PR with three commits: (1) fix `c11`/`cmux` CLI resolution + welcome doc, (2) remove sync main-thread work from hot socket telemetry paths (status/progress/log metadata), (3) write a security threat-model doc covering entitlement/URL handler/browser/Apple Events/camera-mic/JIT/socket-control surfaces + release checklist. **Out of scope:** Audit finding 2 (remote daemon CLI parity) — explicitly excluded by ticket. |

### Tickets explicitly held for operator (do not run)

- **C11-1** — research/recommend only (see "C11-1 research" below).
- **C11-5, C11-9, C11-14, C11-23, C11-26, C11-27, C11-29** — design-heavy or destabilizing; need operator dialogue.
- **C11-20, C11-21, C11-22** — likely already shipped (PRs #84/#86/#87 against them); status hasn't been bumped. Triage rather than impl. Ignore tonight.
- **C11-11** — Linux companion spike, not implementation.
- **C11-34** — already in flight in a separate session elsewhere as of run-start. Do NOT add to the queue. Do NOT spawn a delegation. If polling shows new activity (comments, status transitions, PR opens) on C11-34, that's the other session, not yours — log it in `digest.md` as an FYI but take no action.

---

## Worktrees

All four wave-1 worktrees are pre-created. C11-17/30/24 were created against `origin/main` HEAD `6e4046da1` ("C11-6: App Chrome UI Scale (#123)"). C11-16 was added later against `40e9ee1dc` ("Fix Release-config build (unblocks v0.46.0) (#131)"). All four should be re-fetched and rebased onto fresh `origin/main` at launch (see collision-handling protocol below).

| Ticket | Worktree | Branch |
|---|---|---|
| C11-17 | `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-17-overnight-installer-purge` | `c11-17-overnight-installer-purge` |
| C11-30 | `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-30-overnight-close-overlay` | `c11-30-overnight-close-overlay` |
| C11-24 | `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-24-overnight-manifest-viewer` | `c11-24-overnight-manifest-viewer` |
| C11-16 | `/Users/atin/Projects/Stage11/code/c11-worktrees/c11-16-overnight-fda-detect` | `c11-16-overnight-fda-detect` |

Wait-list ticket worktrees are **not yet created** — make them when you spin up that delegation. Recommended slugs:

- C11-18 → `c11-18-overnight-portal-overdraw`
- C11-19 → `c11-19-overnight-pane-x-residual`
- C11-4  → `c11-4-overnight-audit-findings`

### Collision handling for existing worktrees

The repo has 30+ existing worktrees including stale `c11-24-*` and `c11-26-*` from previous short-ID assignments. The pre-created overnight worktrees (C11-17, C11-30, C11-24) may have been touched in earlier sessions. Apply this protocol per worktree:

```bash
WT=/Users/atin/Projects/Stage11/code/c11-worktrees/<slug>
BR=<branch>

# 1. Fetch fresh main from origin
git -C /Users/atin/Projects/Stage11/code/c11 fetch origin main

# 2. Does the worktree directory exist?
if [ -d "$WT" ]; then
  STATUS=$(git -C "$WT" status --porcelain)
  CURRENT_BR=$(git -C "$WT" rev-parse --abbrev-ref HEAD)
  if [ -z "$STATUS" ] && [ "$CURRENT_BR" = "$BR" ]; then
    # Clean and on the right branch — rebase onto fresh main
    git -C "$WT" rebase origin/main
  else
    # Dirty or wrong branch — surface to operator state file, skip this ticket for now
    echo "{\"ticket\":\"<ULID>\",\"reason\":\"worktree dirty or wrong branch\",\"current_branch\":\"$CURRENT_BR\"}" >> notes/overnight-meta/worktree-conflicts.jsonl
    # Do NOT auto-recreate. Move to next ticket.
  fi
else
  # Worktree dir missing. Branch may still exist locally — clean up and recreate.
  git -C /Users/atin/Projects/Stage11/code/c11 worktree prune
  git -C /Users/atin/Projects/Stage11/code/c11 branch -D "$BR" 2>/dev/null || true
  git -C /Users/atin/Projects/Stage11/code/c11 worktree add -b "$BR" "$WT" origin/main
fi
```

For never-before-used wait-list slugs, the simpler form suffices:

```bash
git -C /Users/atin/Projects/Stage11/code/c11 fetch origin main
git -C /Users/atin/Projects/Stage11/code/c11 worktree add -b <slug> ../c11-worktrees/<slug> origin/main
```

> Always use ULIDs (not short IDs) in delegator prompts and lattice commands. Short IDs renumber on rebase.

---

## Delegator prompts

All four delegator prompts are pre-staged and ready. Each contains `{{WS}}`, `{{DELEG_PANE}}`, `{{DELEG_SURF}}`, `{{ORCH_SURF}}` placeholders that the orchestrator substitutes after layout creation.

| Ticket | Prompt path |
|---|---|
| C11-17 | `c11-worktrees/c11-17-overnight-installer-purge/.lattice/prompts/c11-17-delegator.md` |
| C11-30 | `c11-worktrees/c11-30-overnight-close-overlay/.lattice/prompts/c11-30-delegator.md` |
| C11-24 | `c11-worktrees/c11-24-overnight-manifest-viewer/.lattice/prompts/c11-24-delegator.md` |
| C11-16 | `c11-worktrees/c11-16-overnight-fda-detect/.lattice/prompts/c11-16-delegator.md` |

After creating the Overnight Run workspace + 5-pane layout, run a single sed-style substitution per prompt:

```bash
for TICKET in 17 30 24 16; do
  WT=/Users/atin/Projects/Stage11/code/c11-worktrees/c11-${TICKET}-overnight-*
  PROMPT="$(ls $WT/.lattice/prompts/c11-${TICKET}-delegator.md)"
  # Substitute placeholders. DELEG_PANE/DELEG_SURF differ per ticket — read state.json.
  DELEG_PANE=$(jq -r ".in_flight[\"C11-${TICKET}\"].deleg_pane // empty" $STATE)
  DELEG_SURF=$(jq -r ".in_flight[\"C11-${TICKET}\"].deleg_surf // empty" $STATE)
  WS=$(jq -r ".overnight_workspace" $STATE)
  ORCH_SURF=$(jq -r ".orchestrator_surface" $STATE)
  sed -i '' \
    -e "s|{{DELEG_PANE}}|${DELEG_PANE}|g" \
    -e "s|{{DELEG_SURF}}|${DELEG_SURF}|g" \
    -e "s|{{WS}}|${WS}|g" \
    -e "s|{{ORCH_SURF}}|${ORCH_SURF}|g" \
    "$PROMPT"
done
```

Per-ticket scope summary (already encoded in the prompts themselves):

- **C11-17 (installer purge, light):** pure deletion of ~2,300 lines in `CLI/c11.swift` + historical-banner on `docs/c11mux-module-4-integration-installers-spec.md`. Preserves `Resources/bin/claude`. No translator phase.
- **C11-30 (close-overlay, heavy + translator):** workspace-scoped black scrim + centered card mirroring `PaneInteractionOverlayHost.swift` on the AppKit portal layer; 6 trigger sites; new strings → translator phase walks all 6 locales sequentially.
- **C11-24 (manifest viewer, heavy):** right-click context-menu entry "Show surface manifest…" → read-only JSON viewer for terminal/browser/markdown surfaces; v1 = no editing, no live subscribe; stretch (provenance, copy-to-clipboard) absorbed only if ≤2 extra commits.
- **C11-16 (FDA detect, heavy):** off-main backoff probe of a protected path; auto-advance the TCC primer when grant lands; no main-thread blocking, no focus steal, "Continue without it" path preserved. Follow-up to C11-15.

---

## Layout

The meta-orchestrator (this surface) stays where it is. Create a new workspace, "Overnight Run", to host the 4 delegators + the C11-1 research pane (5 panes total).

```bash
c11 new-workspace                                            # → capture $WS
c11 set-metadata --workspace $WS --key title --value "Overnight Run"

# Discover initial pane via c11 tree --workspace $WS --no-layout → $P_INITIAL

# Build the 5-pane layout: left column 2 panes, right column 3 panes
c11 new-split right --workspace $WS --pane $P_INITIAL        # split into left + right
c11 focus-pane      --workspace $WS --pane $P_INITIAL
c11 new-split down  --workspace $WS                           # left → top + bottom
c11 focus-pane      --workspace $WS --pane <right-pane>
c11 new-split down  --workspace $WS                           # right → top + bottom
c11 new-split down  --workspace $WS                           # right-bottom → middle + bottom (3 panes right)
```

Result: 2 panes left, 3 panes right. Assign:

| Pane | Role |
|---|---|
| left-top | C11-17 delegator |
| left-bottom | C11-30 delegator |
| right-top | C11-24 delegator |
| right-middle | C11-16 delegator |
| right-bottom | C11-1 research (single-pass research agent) |

When wait-list tickets drop in (C11-18 → C11-19 → C11-4), reuse the pane vacated by the completing delegation — rename the tab, swap the cwd, launch a fresh delegator on the new ticket. Do NOT pile multiple finished-delegator surfaces in one pane; the pane's tabs are reserved for the ACTIVE delegation's plan/impl/review/etc. siblings.

When C11-1 research finishes (single-pass write-and-stop), leave the pane idle until a wait-list ticket needs it (it can be repurposed for C11-18/C11-19/C11-4 if needed).

---

## Meta-orchestrator self-setup (do this first at launch)

```bash
# In the meta-orchestrator surface (this current surface):
c11 identify
c11 set-agent       --surface "$CMUX_SURFACE_ID" --type claude-code --model claude-opus-4-7
c11 rename-tab      --surface "$CMUX_SURFACE_ID" "Overnight Meta"
c11 set-metadata    --surface "$CMUX_SURFACE_ID" --key role   --value "meta-orchestrator"
c11 set-metadata    --surface "$CMUX_SURFACE_ID" --key status --value "preflight"
c11 set-description --surface "$CMUX_SURFACE_ID" "Overnight queue: C11-17, C11-30, C11-24, C11-16 (wave 1) + C11-18, C11-19, C11-4 (wait list). C11-1 research in sibling pane. Stack PRs for operator review."

mkdir -p /Users/atin/Projects/Stage11/code/c11/notes/overnight-meta
date -u +%FT%TZ > /Users/atin/Projects/Stage11/code/c11/notes/overnight-meta/started-at.txt
```

Persistent state file across `ScheduleWakeup` ticks lives at `/Users/atin/Projects/Stage11/code/c11/notes/overnight-meta/state.json`. Schema:

```json
{
  "started_at": "ISO-8601",
  "orchestrator_surface": "surface:NN",
  "overnight_workspace": "workspace:MM",
  "in_flight": {
    "C11-17": { "ulid": "...", "wt_dir": "...", "branch": "...", "deleg_surf": "surface:NN", "ws": "workspace:MM", "validation": "light", "last_status": "...", "last_comment_count": 0, "last_check_at": "ISO-8601", "rework_cycles": 0 },
    "C11-30": { ... },
    "C11-24": { ... },
    "C11-16": { ... }
  },
  "wait_list": ["C11-18", "C11-19", "C11-4"],
  "completed": [],
  "parked_needs_human": [],
  "stop_reason": null,
  "last_heartbeat_at": "ISO-8601"
}
```

Auxiliary files alongside `state.json`:
- `started-at.txt` — initial start timestamp
- `worktree-conflicts.jsonl` — append-only log of worktree-collision skips (see Worktrees section)
- `c11-1-research-prompt.md` — pre-staged research prompt (see C11-1 research section)
- `digest.md` — running summary updated every 2-hour heartbeat; this is what operator reads first when returning

---

## C11-1 research (sibling pane, not a delegation)

ULID: `task_01KPP7QBZ3NJMXS4C9NA2XW01X` ("c11mux → c11 rebrand pass").

Status: `needs_human`. Task: read the audit notes (`notes/c11-audit-2026-04-21.md` and the C11-1 worktrees `c11-1-completion-audit`, `c11-1-rebrand-cleanup` — verified on disk), then write a markdown summary at `/Users/atin/Projects/Stage11/code/c11/notes/c11-1-recommendation-2026-05-06.md` containing:

1. **Current state** — what's done, what's not, what the audit found.
2. **Open decisions** — explicit list of operator-judgment items (anything the audit flagged as "needs human" or that requires taste).
3. **Recommended resolution per item** — what you'd do if it were yours, with rationale.
4. **Suggested next steps** — proposed sequence to land C11-1.

No code changes. No Lattice writes (do not transition C11-1's status). The deliverable is the markdown file. When done, post a one-line note in the meta-orchestrator pane noting the file path.

### Pre-staged research prompt

The orchestrator writes the research prompt at `notes/overnight-meta/c11-1-research-prompt.md` as part of the resume checklist (step 4). The prompt body should be roughly:

```
Read the following sources, then write a markdown recommendation file:

1. Lattice ticket: `lattice show task_01KPP7QBZ3NJMXS4C9NA2XW01X --json`
   (read `description`, `events`, `comments` — focus on what's been tried,
   what's blocked, and what's flagged needs-human.)
2. `notes/c11-audit-2026-04-21.md` — the audit notes referenced by the ticket.
3. The two C11-1 worktrees on disk:
   - /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-completion-audit
   - /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1-rebrand-cleanup
   Use `git -C <wt> log --oneline -50` and `git -C <wt> diff origin/main --stat`
   to see what's been attempted and what's pending.
4. The full project CLAUDE.md and the cmux→c11 naming feedback memory at
   /Users/atin/.claude/projects/-Users-atin-Projects-Stage11-code-c11/memory/feedback_cmux_to_c11_naming.md

Then write `/Users/atin/Projects/Stage11/code/c11/notes/c11-1-recommendation-2026-05-06.md`
with these sections:

1. Current state — what's done, what's not, what the audit found.
2. Open decisions — operator-judgment items the audit flagged.
3. Recommended resolution per item — what you'd do, with rationale.
4. Suggested next steps — sequence to land C11-1.

No code changes. No Lattice writes. Do not transition the ticket's status.
When done, write the file path to `/Users/atin/Projects/Stage11/code/c11/notes/overnight-meta/c11-1-research-done.txt`
and stop.
```

Launch: dedicated `claude --dangerously-skip-permissions --model opus` session in the right-bottom pane of the Overnight Run workspace, prompt = `Read /Users/atin/Projects/Stage11/code/c11/notes/overnight-meta/c11-1-research-prompt.md and follow the instructions.`

---

## Polling pattern (do this every wake)

Cadence: **600s default** (10 min) when nothing is hot. **270s** when a delegation is expected to transition imminently (e.g., you saw a "Plan complete" comment 5 min ago and Impl was about to start). After 8 hours of no transition anywhere, surface "no progress detected" to operator regardless. (Operator updated the default from 1500s → 600s at run-time on 2026-05-06.)

Always emit a **2-hour heartbeat** to `notes/overnight-meta/digest.md` regardless of activity, so the operator returning to a quiet workspace can see the run is alive and where things stand.

On each wake:

```bash
REPO_ROOT=/Users/atin/Projects/Stage11/code/c11
STATE=$REPO_ROOT/notes/overnight-meta/state.json

for ticket in $(jq -r '.in_flight | keys[]' $STATE); do
  ULID=$(jq -r ".in_flight[\"$ticket\"].ulid" $STATE)
  # IMPORTANT: pipe through jq with explicit field selection — lattice show --json
  # returns ~60KB per ticket (events array dominates). Always filter.
  JSON=$(cd $REPO_ROOT && lattice show $ULID --json)
  STATUS=$(echo "$JSON" | jq -r '.data.status')
  COMMENTS=$(echo "$JSON" | jq '.data.comment_count // 0')
  # Compare to last_status / last_comment_count in state file.
  # If status crossed into review/needs_human/done/blocked OR new comment carries
  # signal phrase ("Plan complete", "Impl complete", "PR opened", "BLOCKED",
  # "escalat", "needs decision"), update state and decide whether to surface.
done

# Poll delegator surface liveness
c11 get-metadata --workspace $WS --surface $DELEG_SURF --key status

# CI gate (see "CI gate" below)
# Heartbeat (every 2 hours of wall time)
# Then: ScheduleWakeup with appropriate delaySeconds
```

### CI gate

Before spawning any new delegation, verify `main` CI is green. "Red" is defined narrowly to avoid false positives from unrelated workflows:

```bash
# Most-recent completed run on main for each blocking workflow.
# Blocking workflows: build, compat-tests, workflow-guard-tests
# Non-blocking (informational only): build-ghosttykit (only fires on submodule bumps),
# nightly release workflows, scheduled lints.

for WF in build compat-tests workflow-guard-tests; do
  CONCLUSION=$(gh run list --branch main --workflow "$WF" --limit 1 --json conclusion,status | jq -r '.[0] | select(.status=="completed") | .conclusion')
  # If empty (still in-progress) → not blocking; continue.
  # If "success" → green for this workflow.
  # If "failure" or "cancelled" or "timed_out" → CI is red; halt new spawns and surface.
done
```

Halt new spawns and surface to operator if any of those three return non-success. In-flight delegations continue (they're on feature branches, not `main`).

### Surface-to-operator policy

**Surface** only on:
- Transitions to `needs_human`, `blocked`, `done` (each in-flight ticket once per transition)
- Signal-phrase comments
- CI red on `main`
- 8-hour no-transition timeout
- Worktree collisions logged to `worktree-conflicts.jsonl`

**Don't surface** on:
- `status=review` transitions (operator wanted PRs stacked, not alerts)
- Routine plan/impl/translate/validate phase comments
- 2-hour heartbeats (those go to `digest.md`, not the surface)

When a delegation hits `status=review`: update state, drop the next wait-list ticket into the freed pane, schedule next wake.

### Kickoff comment template

When a delegation comes online, post this Lattice comment on the ticket for audit-trail:

```
[Overnight Meta] Delegation online at {ISO-8601-UTC}.
Worktree: {wt_dir}
Branch: {branch}
Delegator surface: {deleg_surf}
Validation tier: {heavy|light}
Will stop at status=review with PR open. Operator returns later for review.
```

---

## Resume checklist (start here at launch)

**Pre-staged at draft time (already on disk; verify, don't recreate):**
- All 4 wave-1 worktrees exist (C11-17/30/24/16) with their `.lattice/prompts/` populated.
- All 4 delegator prompts contain `{{WS}}`, `{{DELEG_PANE}}`, `{{DELEG_SURF}}`, `{{ORCH_SURF}}` placeholders awaiting substitution.
- `notes/overnight-meta/c11-1-research-prompt.md` is staged with hardcoded paths (no placeholders).

**Launch sequence:**

1. Read this file in full. Confirm the operator hasn't added new instructions in the conversation since this was written.
2. Load skills: `c11`, `lattice-delegate` (at `/Users/atin/Projects/Stage11/.claude/skills/lattice-delegate/SKILL.md`), `lattice`, project `CLAUDE.md`.
3. Verify pre-staged artifacts:
   ```bash
   ls -d /Users/atin/Projects/Stage11/code/c11-worktrees/c11-{17,30,24,16}-overnight-*
   ls /Users/atin/Projects/Stage11/code/c11-worktrees/c11-{17,30,24,16}-overnight-*/.lattice/prompts/c11-*-delegator.md
   ls /Users/atin/Projects/Stage11/code/c11/notes/overnight-meta/c11-1-research-prompt.md
   ```
4. Apply collision-handling protocol per worktree (re-fetch origin/main, rebase if clean, log conflict if dirty/wrong-branch).
5. Run meta-orchestrator self-setup (rename tab, set metadata, `mkdir -p notes/overnight-meta` if missing, init `started-at.txt`, write `state.json` skeleton).
6. Create the "Overnight Run" workspace + 5-pane layout per the Layout section. Capture all pane/surface refs into `state.json`.
7. Substitute placeholders in all 4 delegator prompts via the sed loop in the Delegator prompts section. Verify with `grep -l '{{' c11-worktrees/c11-*-overnight-*/.lattice/prompts/c11-*-delegator.md` (should be empty).
8. Launch the four delegators using the c11 skill's one-shot pattern (one per pane):
   ```bash
   c11 send --workspace $WS --surface $DELEG_SURF "cd $WT_DIR && claude --dangerously-skip-permissions --model opus \"Read .lattice/prompts/<ticket>-delegator.md and follow the instructions.\""
   c11 send-key --workspace $WS --surface $DELEG_SURF enter
   ```
   Watch for the "Do you trust this folder?" prompt on first launch in each new worktree (read-screen + send-key 1 to dismiss; the lattice-delegate skill covers this).
9. Launch the C11-1 research agent in the right-bottom pane:
   ```bash
   c11 send --workspace $WS --surface $RESEARCH_SURF "cd /Users/atin/Projects/Stage11/code/c11 && claude --dangerously-skip-permissions --model opus \"Read /Users/atin/Projects/Stage11/code/c11/notes/overnight-meta/c11-1-research-prompt.md and follow the instructions.\""
   c11 send-key --workspace $WS --surface $RESEARCH_SURF enter
   ```
10. Finalize `state.json` with all four in-flight tickets, ULIDs, worktree dirs, branches, surface refs, validation tiers, wait-list, timestamps.
11. Post the kickoff Lattice comment template (see Polling pattern → Kickoff comment template) on each of the four in-flight tickets.
12. Initialize `digest.md` with a "Run started at {ts}" header.
13. `ScheduleWakeup` with `delaySeconds=600` (10-min default; updated from 1500s by operator at run-time), prompt = re-read this file + `state.json` and continue the polling loop. Return.

---

## Stop / handoff when operator returns

When the operator returns:
- Surface the latest `digest.md` (already updated continuously) — per ticket: status, PR URL, validation artifact, any `needs_human` notes.
- Show a glance-readable table of who's where in the lifecycle.
- C11-1 recommendation file path.
- Worktree-conflicts log (`worktree-conflicts.jsonl`) if non-empty.
- Any stop-condition hits with reason.
- Leave every delegation pane open (default per lattice-delegate skill) so the operator can scrub.

---

## Things deliberately decided (so a successor session doesn't relitigate)

- **Queue size = 4.** Confirmed by operator. Prior draft had 3.
- **Translator: one per delegation that introduces strings.** Single agent walks all 6 locales sequentially. No parallel locale spawn. Only C11-30 expected to need this overnight. Confirmed by operator.
- **No token / rate limit logic.** Operator confirmed no budget cap. Just keep working until the queue empties.
- **No `needs_human` accumulation cap.** Tickets parking at `needs_human` is acceptable; do not idle the queue. Confirmed by operator.
- **Submodule serialization is queue-order, not runtime.** C11-19 holds for C11-18 by wait-list position. No comment-protocol or runtime lock. If a *different* delegation unexpectedly needs a submodule pointer change, it parks at `needs_human` and surfaces.
- **No per-ticket orchestrator panes.** Only one meta-orchestrator (this surface). Reduces the tower from 3 levels to 2. Rationale: parallelizing across tickets needs one cross-cutting watcher; the per-ticket orchestrator role from the lattice-delegate skill is collapsed into the meta.
- **Meta-orchestrator runs in production c11.** This Claude session, inside `/Applications/c11.app`, socket `~/Library/Application Support/c11mux/c11.sock`. No bootstrap/handoff to a different session is required.
- **State and artifacts live in the repo.** `notes/overnight-meta/state.json`, `digest.md`, `worktree-conflicts.jsonl`, `c11-1-research-prompt.md`. Inside the working tree so it travels with git, not `/tmp` (which can be wiped).
- **PR target: `main` on `origin` (Stage-11-Agentics/c11).** Never push to `manaflow-ai`.
- **Tagged builds for heavy validation.** Use `./scripts/reload.sh --tag <ticket>-overnight`. Never launch an untagged `c11 DEV.app`.
- **Codex for computer-use validation, not Claude.** Codex inside a c11 surface uses `codex --yolo` (interactive TUI), then a file-backed prompt sent into the live PTY. Never `codex exec` for watched validation.
- **Ticket-prefixed prompt filenames.** `c11-17-delegator.md`, `c11-17-plan.md`, etc. — never bare `delegator.md` / `plan.md` (collision risk across parallel delegations).
- **CI gate is narrow.** Only `build`, `compat-tests`, `workflow-guard-tests` count for "main red." Other workflows (build-ghosttykit, scheduled, nightly) are informational.

---

## Open questions a successor session can punt on (don't block)

- Whether to repurpose the C11-1 research pane after the recommendation file lands — default: reuse for the next wait-list ticket if one needs a slot, else leave idle as a log tail.
- Whether to land C11-17 and C11-4 on the same PR (both are deletion/cleanup-flavored). Default: **no**, separate PRs, separate audit trails. Cohesion principle in the skill applies *within* a ticket, not across tickets.

---

*End of runbook. The orchestrator runs from this Claude session, in production c11. State persists in `notes/overnight-meta/`. Everything needed to launch is above.*
