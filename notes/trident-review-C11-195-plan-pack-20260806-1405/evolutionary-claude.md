# Evolutionary Plan Review — C11-195-plan (Claude) — 20260806-1405

Plan reviewed: `.lattice/plans/task_01KZBZY4WBCMG252XSJPJC1CPA.md`
Read-only review. No files outside this one were touched.

---

## Executive Summary

On paper this is a five-line bug fix: stop feeding the GUI process's arbitrary cwd
into `DefaultAgentProjectConfig.find(from:)`. Most of it is already implemented on
`fix/C11-193-launch-agent-cwd` (`SocketDispatch.swift` now passes
`cwdResolution.path`, and the response already carries `cwd` + `cwd_source`).

The opportunity is that C11-195 is the **third consumer** of C11-194's resolver, and
the third consumer is where you find out whether you built a seam or just patched
three sites. Right now it is three sites. There are **five** places in the tree that
independently answer "where is this agent's project config," with **three different
fallbacks** (process cwd, `$HOME`, focused-panel directory), and the branch fixes
exactly one of them. C11-195's real job — the version worth doing — is to convert
"resolved launch cwd" from a local variable into a **type that is the only way to ask
the question**, and to make the answer *visible in the launch response*. Do that and
this bug class ends permanently. Do the literal plan and you fix one call site,
leave a second one named in the ticket ambiguously scoped, and newly diverge the
A button from the CLI.

There is also one finding that is not evolutionary at all and needs a decision before
implementation: **changing where the walk starts changes which ancestors it can
reach**, and one of the reachable ancestors is `~/.c11/agents.json` — the exact file
behind the historical A-button pin bug. The plan does not name a stop point.

---

## What's Really Being Built

Not "a cwd fix." Three layers deep, in order of durability:

1. **Stated deliverable:** project `.c11/agents.json` is applied on the default
   launch path.
2. **Actual deliverable:** the launch pipeline gains a single authoritative
   *launch context* — a resolved path plus its provenance — and every downstream
   decision (child cwd, git-worktree policy, project config lookup) reads from that
   one value instead of re-deriving it. C11-193 consumes it for warning policy,
   C11-195 for config lookup. The plan's step 2 ("pass that same resolved path into
   surface creation so configuration lookup and the child cwd cannot diverge") is the
   thesis of the whole three-ticket arc, stated once and then under-invested in.
3. **Latent deliverable nobody has named:** once workspaces carry stable roots
   (C11-194) and launches resolve against them, c11 has for the first time a
   machine-readable notion of **"the project this workspace is working on."**
   `.c11/agents.json` is the first tenant of that namespace. `WorkspaceBlueprintStore`
   already walks the same tree with the same pattern. Port ranges, blueprints, skill
   pins, sidebar defaults, launch policy — all of them want the same anchor. This
   ticket is quietly the first client of a **project-profile resolver** that does not
   exist yet.

Name layer 3 out loud in the plan. It changes what "shared helper reuse" means in the
non-goals line from an afterthought into the deliverable.

---

## How It Could Be Better

### 1. The call-site inventory is incomplete, and the plan's non-goal makes it ambiguous

`DefaultAgentProjectConfig.find(from:)` has five production callers:

| Site | Starting path | Fallback |
|---|---|---|
| `SocketDispatch.swift:1075` (`v2AgentLaunch`) | `cwdResolution.path` (fixed on branch) | process cwd |
| `TerminalController.swift:9076` (`defaultAgentLaunch`) | `cwdArg` | **process cwd — untouched on branch** |
| `Workspace.swift:12448` (`launchAgentSurface`, the A button) | `resolverCwdForAgentLaunch()` | panel dir → workspace `currentDirectory` → process cwd |
| `AppDelegate.swift:6764` (workspace-creation launch) | `workingDirectory` | none |
| `GhosttyTerminalView.swift:3557` (`C11_DEFAULT_AGENT_LAUNCH` env stamp) | `workingDirectory` | `$HOME` |

Two problems the plan should resolve explicitly:

- The ticket text names `defaultAgentLaunch` as carrying the same bug, but the plan's
  non-goal says "not changing … the A-button/default-agent entry point beyond shared
  helper reuse." An implementer can read that as *excluding* site 2. It is still
  broken on the branch. Either scope it in (it is the same one-line change plus a
  caller-surface plumb) or say in one sentence why it is deliberately deferred and
  file the follow-up. Ambiguity here is how a ticket ships half-fixed.
- Site 3 (the A button) will **newly diverge** from site 1 after C11-194 lands.
  `resolverCwdForAgentLaunch()` reads the focused panel's directory and never consults
  `workspace.rootDirectory`. So after this arc, a workspace with an explicit root
  resolves project config from the *root* when launched via CLI and from the *shell's
  wandered cwd* when launched via the A button. That is a new inconsistency
  introduced by this arc, in exactly the surface the operator uses most. It deserves
  at minimum a named decision, ideally one line: `resolverCwdForAgentLaunch()` gains
  `rootDirectory` at the front of its ladder.

### 2. The walk's *stop* point is now a live question

`find(from:)` walks up to 64 levels toward `/`. Changing the start point changes the
reachable ancestor set. Two concrete hazards:

- Under `~/Projects/Stage11/code/c11/…` the walk passes `~/Projects/Stage11/code/`,
  `~/Projects/Stage11/`, and `~/`. `~/.c11/agents.json` is a real file on this machine
  and is precisely the artifact behind the documented A-button pin bug — the decoder
  at `DefaultAgentConfig.swift:305` exists specifically to reject its legacy shape.
  A start-point change can newly *reach* it (or a valid-shaped sibling) for launches
  that previously started from an unrelated process cwd and found nothing.
- Once workspaces have roots, the natural semantic is **clamp the walk at the
  workspace root** — a project's config should not be inherited from its parent
  directory tree by accident.

The plan's non-goal says it will not change "project-config precedence," but the walk
bound is not precedence, and it is being changed implicitly. Make it explicit: either
"walk semantics unchanged, ancestor reachability shift is accepted" (with a test that
pins it) or "walk clamps at workspace root when one exists." Silent is the one
unacceptable answer.

### 3. The test as specified does not bind the bug

Step 3 proposes a scratch-backed test with `.c11/agents.json` under the resolved path
and a different process fallback, asserting the config is found from the resolved
path. But `c11Tests/DefaultAgentConfigTests.swift:343-383` **already** proves
`find(from:)` locates a scratch-dir config and walks upward. Re-proving the walker
does not prove the *wiring*, and the wiring is the entire bug. Per the repo's test
quality policy, this is close to a test that asserts shape rather than behavior.

What actually binds it is a pure seam: a function that takes the resolution and
returns `(config, sourcePath)`, with the launch paths calling nothing else. Then the
test is "given resolution X, the launch planner's config comes from X's tree, not the
process cwd" — and it fails if a future refactor reintroduces the process fallback.

Two more concrete notes on the test:
- The existing tests live in `c11Tests` (**host-required**, ~35s + DEV.app launch).
  The plan says "logic test." Put it in `c11LogicTests` — which forces the seam to be
  host-free, which is the good outcome. The right test target and the right
  architecture are the same decision here.
- Add a **negative** test: process cwd contains a valid `.c11/agents.json`, resolved
  path's tree does not. Assert the process-cwd config is *not* applied. That is the
  assertion that would have caught the original bug; the positive test would have
  passed under the buggy code whenever the two paths happened to coincide.

### 4. Validation (step 4) has no oracle

"Validate in the tagged app that an inherited/root launch reports the expected cwd and
uses the project-level agent configuration" — the first half is checkable
(`cwd`/`cwd_source` are already in the response). The second half is inferred from the
launch command string, which is fragile and sometimes indistinguishable from the user
default. See the `config_source` suggestion below; it makes step 4 a one-line
assertion instead of a squint.

---

## Mutations and Wild Ideas

**M1 — Make the raw-string call unrepresentable.**
Rename to `DefaultAgentProjectConfig.find(for: AgentLaunchWorkingDirectoryResolution)`
and delete the `String?` overload from the module's reachable surface. Site #6 then
costs a compile error instead of a bug report. This is the cheapest permanent fix in
the whole arc and it is a mechanical refactor of five call sites.

**M2 — `config_source` in the launch response.** *(highest leverage per line of code)*
The response already carries `cwd` and `cwd_source`. Add
`"config_source": "/abs/path/.c11/agents.json" | null`. The bug's defining property
was *silence*; this converts the entire class into a one-command diagnosis, forever,
for operators and agents alike. It also gives step 4 its oracle and gives the
integration test a stable assertion target.

**M3 — `c11 explain-launch [--cwd X] [--workspace W]`.**
A dry-run that prints the full ladder without launching anything: explicit → workspace
root → launching surface → process, which rung won, which `.c11/agents.json` files
were probed, which one matched, and the final resolved command. This ticket exists
because a resolution chain was invisible; the durable answer to an invisible chain is
a command that prints it. Cheap — every input is already a pure function.

**M4 — Promote the walk into a `ProjectProfileResolver`.**
`DefaultAgentProjectConfig` and `WorkspaceBlueprintStore` already do the same
bounded upward walk against the same `.c11/` directory. One resolver, one walk, one
clamp rule, one cache keyed on workspace root. Immediately halves the filesystem
work per launch and gives every future project-scoped setting a home that is already
correct.

**M5 — Watch `<root>/.c11/` and hot-apply.**
Once discovery is root-anchored, an FSEvents watch is trivial. Editing
`.c11/agents.json` and having the next A-button click reflect it (with a sidebar
toast) is a genuinely delightful loop, and it is a ~30-line follow-on to M4 rather
than a project.

**M6 — Stamp provenance into the launched surface.**
Export `C11_LAUNCH_CWD_SOURCE` and `C11_PROJECT_CONFIG_PATH` into the child env
(`GhosttyTerminalView.swift:3557` already stamps agent env at spawn). The agent then
*knows* where it was launched from and can say so in its sidebar report. Turns
provenance from a debug field into something an agent can act on — for example, a
delegator that notices it inherited a linked-worktree cwd and says so in its first
line.

**M7 — Negative-space telemetry.**
Record, off-main and cheaply, when a project config *would* have been found under a
different rung of the ladder than the one that won. That single counter would have
surfaced this bug the first week it existed instead of during a plan review. It is
the general shape of catching silent-resolution defects in the field.

**Anti-mutation, named so it gets rejected on purpose:** falling back to the git
toplevel of the resolved path when no `.c11/` is found. Tempting, plausible, and a
precedence change that would silently alter behavior for every existing user. The
plan's non-goal correctly forbids it. Keep it forbidden.

---

## What It Unlocks

- **Project-scoped agent policy becomes real.** Today `.c11/agents.json` works only if
  you pass `--cwd`, so effectively nobody relies on it. After this, a repo can pin its
  harness/model/effort and every launch in that workspace obeys — which makes
  "check in your `.c11/agents.json`" a legitimate team convention rather than a trap.
- **A namespace with a resolver.** `.c11/` under a workspace root becomes the obvious
  home for blueprints, port policy, launch defaults, sidebar config. That is a
  platform seam, not a setting.
- **Launch responses become auditable.** With `cwd` + `cwd_source` + `config_source`,
  every launch is self-describing. That is the substrate for launch-stats questions
  nobody can answer today ("how many launches inherited their cwd?", "how many
  workspaces have roots?").
- **The lattice-orchestrator fleet gets safer by default.** Delegator worktrees are the
  canonical linked-worktree case; roots + provenance are what let a delegator's agent
  land in the right tree without the operator thinking about it.

---

## Sequencing and Compounding

The plan's headline sequencing claim ("C11-194 must land first") is right and already
reality on the branch. But the plan's *internal* order is backwards relative to where
the branch actually is.

**Current state:** steps 1 and 2 are effectively done for the socket path
(`SocketDispatch.swift` passes `cwdResolution.path`, and
`addWorkspace(workingDirectory: cwdResolution.path, establishRootFromWorkingDirectory:)`
already ties lookup and child cwd together). The plan reads as if none of this exists.
Rebase the plan against the branch or an implementer will re-litigate landed work.

**Better order for the remaining work:**

1. **Seam first.** Introduce the resolution-typed lookup (M1) plus the pure
   `(config, sourcePath)` return. Everything after is a one-liner.
2. **Both call sites fall out.** Sites 1 and 2 become trivial; sites 3–5 become
   *visible* decisions rather than things nobody looked at.
3. **`config_source` in the response** (M2) — do this *before* validation, not after.
   It is what makes step 4 checkable.
4. **Logic tests in `c11LogicTests`**, positive + negative, against the seam.
5. **Then** tagged-app validation, now oracle-driven.
6. Docs + skill sync.

**Sequencing hazard worth flagging loudly:** the branch's
`AgentLaunchWorkingDirectoryResolver.decision` still returns `.reject(...)` for an
inherited linked-worktree cwd, while C11-193 rev 3 is a *binding operator decision* to
warn and proceed. In `v2AgentLaunch` the decision is evaluated **before** the config
lookup, so under the current branch code an inherited launch inside a linked worktree
errors out and never reaches C11-195's code path at all. Since every
lattice-orchestrator delegator lives in a linked worktree, C11-195's step-4 validation
cannot pass in the delegator's own environment until C11-193's warn-only change lands.
Either C11-193's flip lands first, or step 4 must specify a non-worktree validation
environment. This is not hypothetical; it is the current state of the shared branch.

---

## The Flywheel

There is no self-reinforcing loop in the plan as written. There is an obvious one
adjacent to it, and it is cheap to engineer:

> **Type forces correctness → response field makes it observable → `explain-launch`
> makes it diagnosable → the next project-scoped setting rides the same rail for free.**

Each turn lowers the cost of the next. Today the loop runs the wrong way: every new
launch entry point costs a fresh bug (five sites, three fallbacks, two of them wrong),
each found by a human reading code during a plan review. Flip it and every new entry
point costs a compile error caught in seconds.

The accelerant is M1 + M2 together — roughly a day of work, and they are the two
pieces that make every subsequent project-scoped feature cheap instead of risky.

---

## Concrete Suggestions

1. **Amend step 1** to enumerate all five call sites with an explicit disposition for
   each (fix / defer with ticket / verified correct). Silence about a site is how
   `defaultAgentLaunch` stays broken while its ticket closes green.
2. **Add a step 1b:** change the lookup signature to take the resolution type and drop
   the raw-`String?` entry point. Five mechanical edits; permanent.
3. **Add `config_source` to the `agent.launch` response** next to the existing `cwd`
   and `cwd_source`. Update `docs/socket-api-reference.md`,
   `docs/launch-agent-reference.md`, and `skills/c11/references/api.md`, then run
   `scripts/sync-installed-skills.sh c11` per the repo's hard rule.
4. **Rewrite step 3's test spec:** positive *and* negative case, against the pure
   seam, in `c11LogicTests` — not a second copy of the existing walker test in
   `c11Tests`.
5. **Decide the walk's stop point in one sentence** in the plan (clamp at workspace
   root vs. unchanged-with-accepted-reachability-shift), and pin whichever you pick
   with a test. Reference the `~/.c11/agents.json` legacy file explicitly so the
   reviewer knows the hazard was considered, not missed.
6. **Add one line to `resolverCwdForAgentLaunch()`** putting `rootDirectory` at the
   front of its ladder, so the A button and the CLI cannot disagree about which
   project a workspace belongs to. If this is genuinely out of scope, file it before
   merging — it is a regression this arc creates.
7. **Sharpen step 4's acceptance:** name the exact assertion
   (`config_source == <tmp>/.c11/agents.json` and the resolved command matches the
   project entry, with the process cwd deliberately seeded with a *different* config).
   Name a validation environment that is not a linked worktree, or gate on C11-193's
   warn-only flip landing first.
8. **File M3/M4/M5 as one follow-up ticket** ("project profile resolver + explain-launch")
   rather than letting them evaporate. The whole point of noticing layer 3 is that it
   gets written down.

---

## Questions for the Plan Author

1. Is `defaultAgentLaunch` (`TerminalController.swift:9076`) in scope? The ticket names
   it; the non-goal line can be read as excluding it; the branch does not fix it. One
   of those three needs to change.
2. Should the upward walk **clamp at the workspace root** when one exists? This is the
   highest-consequence unstated decision in the plan, and it is a behavior change
   either way once the start point moves.
3. Should the A button (`resolverCwdForAgentLaunch()`) consult `rootDirectory`? If not,
   is CLI/A-button divergence in a rooted workspace an accepted outcome of this arc?
4. Will you add `config_source` to the launch response? If yes, this ticket carries a
   documented API addition and a skill sync; if no, how does step 4's validation
   distinguish "project config applied" from "user default happened to match"?
5. Where does the new test live — `c11LogicTests` (fast, requires the seam) or
   `c11Tests` (host-bound, matches the existing file)? The repo's testing policy
   points at the first; the plan says "logic test" but the existing coverage is in
   the second.
6. What is the validation environment for step 4, given the branch currently *rejects*
   inherited linked-worktree launches and every delegator runs inside one? Does
   C11-193's warn-only flip land before C11-195's validation?
7. Is there appetite for the resolution-typed lookup (M1) in this ticket, or should it
   be a follow-up? It is the difference between fixing this bug and ending this bug
   class, and it is cheaper now than after site #6 exists.
8. Longer arc: do you want `.c11/` to become the general project-profile namespace
   (agents + blueprints + ports + launch policy) with one resolver? If yes, this
   ticket should be built as its first client rather than as a standalone patch — that
   is a small change to how step 1 is written and a large change to what it is worth.
