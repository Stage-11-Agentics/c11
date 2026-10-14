# Adversarial Plan Review — C11-193

- **Plan ID:** c11-193-plan
- **Model:** Claude
- **Timestamp:** 20260806-1226
- **Plan under review:** `.lattice/plans/task_01KZAV2VHK2TPFPXE8C7S1YNQ8.md`
- **Ticket:** "launch-agent: refuse to start an agent in another agent's linked worktree"

---

## Executive Summary

**Concern level: high. Do not hand this to an implementer as written.**

This is a 5-line plan for a change that alters the default behavior of the primary agent-spawning primitive in a repo with **38 live linked worktrees** and a house workflow (`lattice-orchestrator`) whose defining move is *one worktree per delegator*. The plan is not wrong in spirit; it is under-specified in exactly the places where the cost lands.

Three findings dominate, in order of severity:

1. **The plan proposes building something that already exists.** Step 2 says "Add a testable linked-worktree probe that compares `git rev-parse --git-dir` with `--git-common-dir` and captures the branch name." That is a verbatim description of `GitContextResolver.resolveOuter` in `Sources/Metadata/GitContextResolver.swift:322-363`, which already returns `.linkedWorktree(basename:absolutePath:branch:)`, already has an injectable `GitRunner` seam for deterministic tests, already runs in `c11LogicTests`, and already handles submodules, bare clones, detached HEAD, and the `.stale` "sibling ran `git worktree remove`" case. A fresh probe will re-derive the easy half and silently drop the hard half. The plan never mentions this file.

2. **The "existing launch-agent cwd resolution seam" the plan opens with does not exist for the inherited case.** In `v2AgentLaunch` (`Sources/SocketHandlers/SocketDispatch.swift:994+`), when `--cwd` is omitted, `cwdOverride` is `nil` and is passed as `workingDirectory: nil` straight into `addWorkspace` / `newTerminalSurface`. The inherited path is resolved much deeper (parent panel cwd → workspace cwd → `$HOME`) and the handler **never materializes it as a string**. There is nothing at that layer to inspect and reject. Step 1 will send an implementer hunting for a seam that isn't there, and the actual work — making the inherited cwd knowable at the guard point — is unbudgeted and unmentioned.

3. **The guard as specified fires on the correct, everyday case.** A delegator working in its own worktree launching its own reviewer/translator/validator is the dominant launch shape in this repo, and it is *legitimate* — same agent lineage, same tree, intentional. The plan refuses it. The signal that actually separates "my tree" from "another agent's tree" is not "is this a linked worktree"; it's "does another live surface already occupy this tree" — and **c11 already knows that**, per-surface, in `SurfaceMetadataStore` under `MetadataKey.worktree` (written by `TabManager.applyDerivedWorktreeBranchMetadata`, `Sources/TabManager.swift:2481`). The plan adopts the ticket's admitted proxy ("*likely* another agent's active tree") without ever evaluating the direct signal sitting one store away.

The single biggest issue, if you only fix one thing: **the plan discards the ticket's own justification for choosing a guard over a default.** The ticket argues a guard beats a better default because "it also holds when someone passes `--cwd` explicitly, which a default cannot." The plan's step 3 then explicitly permits `--cwd` into a worktree with a one-time acknowledgement. Strip that argument out and what remains is a noisy default — which is precisely what the sibling ticket C11-194 delivers. The plan needs to either restore the explicit-case enforcement or state plainly that it is building a loud default and that C11-194 may subsume it.

---

## How Plans Like This Fail

Guard/validation features have a small, well-known set of failure modes. This plan is exposed to most of them.

**The guard fires on the common case and gets disabled.** The classic arc: ship a safety check, it misfires on the dominant workflow, humans learn a reflex to bypass it, the bypass becomes muscle memory, and the guard now only catches the cases nobody was going to hit anyway. Here the reflex is "always pass `--cwd`" — and because `--cwd` is *also* the sanctioned override, every agent that learns it learns to bypass the guard permanently and invisibly. Within a week the skill files, the orchestrator SKILL.md, and every delegator prompt will carry `--cwd` unconditionally, and the guard will never fire again. **The plan has no mechanism to detect that it has been trained around.**

**Fail-open vs fail-closed is left undecided, and both answers are bad.** The probe shells out to `git`. `ProcessGitRunner` carries a 5s timeout; `resolveOuter` via the full `resolve()` path issues roughly six `rev-parse` subprocesses. If git is missing, slow, or the app-process PATH is too poor to find it (the launch-agent reference *explicitly* warns "the app-process PATH is poorer than the login-shell PATH a pane actually gets"), then: fail-closed breaks every launch; fail-open restores exactly the silent failure the ticket exists to eliminate. The plan says nothing about which. This is the fork that decides whether the feature is a nuisance or a placebo, and it isn't in the document.

**The predicate gets tested; the refusal does not.** Step 4's four tests are all pure-logic assertions about a boolean and a message string. That proves the probe classifies directories. It does not prove a launch is actually refused, that the error reaches the calling agent legibly, or that the message renders in a pane a human reads. CLAUDE.md's own "Green Tests ≠ Working Product" section and the `feedback_delegator_escape_forward` discipline both say this is not enough for a behavior change at a user-facing launch site. There is no tagged build, no real `c11 launch-agent` invocation from a real worktree, no screenshot.

**Partial coverage of an invariant stated as absolute.** The ticket declares the invariant "NO TWO AGENTS MUTATE THE SAME TREE." The guard lands in `v2AgentLaunch`, which covers `c11 launch-agent` and `config launch` (`Sources/SocketHandlers/ConfigHandlers.swift` delegates to it). It does **not** cover the A button or `default-agent launch`, which run a separate path at `Sources/TerminalController.swift:8989+` and call `tab.launchAgentSurface(...)` directly. So the programmatic path agents use gets guarded and the human path stays wide open — arguably backwards, since the operator clicking A in a worktree pane is the higher-frequency event. It also doesn't cover `new-pane` / `new-split` / `new-workspace`, all of which inherit cwd and can drop a shell into a contested tree. Scoping to `launch-agent` is defensible; leaving it undeclared is not.

**Two in-flight tickets editing the same lines with no stated merge order.** C11-194's plan step 4 says "Centralize and test cwd precedence: explicit `--cwd`, workspace root, then launching-surface cwd." C11-193's steps 1 and 3 modify the same resolution. Both plan files were authored in the same batch; both tasks are live in `.lattice/`. Neither names the other as a dependency or fixes an order. Whichever lands second eats a conflict in code neither author read.

---

## Assumption Audit

### Load-bearing, and shaky

**A1. "There is an existing launch-agent cwd resolution seam." — FALSE for the inherited case.**
`v2ResolveCwdParam` / `CwdParamResolution` (`Sources/TerminalController.swift:22, 2768`) handles the **explicit** param only. Absent `--cwd`, resolution returns `.inherit`, `cwdOverride` stays `nil`, and inheritance happens downstream of the handler. The one case the guard targets is the one case the existing seam is blind to. The plan collapses without this assumption and its entire step ordering rests on it.

**A2. "The inherited cwd is one well-defined thing." — FALSE. There are three, and they diverge.**
- (a) the **CLI caller's shell cwd** — where the agent typed the command. The CLI *never sends this*: `cli/c11.swift:2328` sets `params["cwd"]` only when `--cwd` is passed.
- (b) the **target pane's parent-surface cwd** — what the new PTY actually inherits. This is what the ticket means ("resolves the child's working directory from the LAUNCHING SURFACE's cwd").
- (c) the **app process cwd** — which `v2AgentLaunch` already uses today for project-config lookup: `let lookupCwd = cwdOverride ?? FileManager.default.currentDirectoryPath` (SocketDispatch.swift:1069). For a GUI app this is likely `/`, which is a pre-existing incoherence nobody has noticed.

In the Acetate repro (a) and (b) coincided, because the orchestrator launched into its own pane. Under `--pane <other>`, `--workspace <other>`, or `--new-workspace` they do not. The plan says "inherited cwd" as though the ambiguity doesn't exist. **Which one does the guard read?** is the first question an implementer will hit and the plan cannot answer it.

**A3. "Linked worktree ⟹ another agent's tree."** The ticket hedges ("*likely*"); the plan hardens the hedge into a refusal. In this repo the inference is usually **wrong**: 38 worktrees exist precisely so each delegator has its own, and a delegator launching a helper into its own worktree is the sanctioned pattern. The false-positive rate on the repo's own primary workflow is close to 100%.

**A4. "A one-time acknowledgement on the explicit path is a meaningful signal."** The ticket's entire diagnosis is that *the failure is silent*. A warning appended to a `--json` warnings array — the existing mechanism, per the launch-agent reference's binary-not-found precedent — is read by the calling program only if the calling program bothers. Most callers shell out and ignore stdout. The acknowledgement reproduces the silence it was designed to break. Load-bearing for the plan's claim to address the ticket; unlikely to hold.

**A5. "`git` is reachable and fast from the guard's execution context."** Unstated, entirely load-bearing. `ProcessGitRunner` uses `/usr/bin/env git`. Sidebar chips already live with this and degrade to "no chips" — an acceptable degradation for decoration, an unacceptable one for a safety guard.

**A6. "Capturing the branch name is straightforward."** Verified false in the field: `git rev-parse --abbrev-ref HEAD` returns the literal string `HEAD` in a detached worktree, and **four of the 38 live worktrees are detached** (`c11-183-autosave`, `c11-183-staging-main`, `c11-188-rereview-94aeb59c`, `acb-05-persistence`). The ticket's specified message becomes `cwd is a linked git worktree on 'HEAD'` — actively confusing. `GitContextResolver` already models this correctly as `.detached(shortSHA:)` / `.noBranch`; a fresh probe that "captures the branch name" ships the bug. This is a concrete, testable defect that step 4's stated test list would not catch.

### Cosmetic / safe

- Non-goal "not mutating tenant git state" — nobody proposed it; it costs nothing but adds nothing.
- Non-goal "not changing launch focus behavior" — correct and consistent with the socket focus policy.
- "Explicit `--cwd` is an intentional override" — reasonable as a principle, though it guts the ticket's rationale (below).

---

## Blind Spots

**No error code.** `docs/launch-agent-reference.md` maintains a structured error table (`unknown_agent_type`, `model_flag_unsupported`, `invalid_params`, `not_found`, …). A new refusal needs a new code (`cwd_is_linked_worktree` or similar) and a table row. The plan mentions "actionable branch/error text" and never names a code. Callers cannot branch on prose.

**No documentation or skill deliverable — against an explicit hard rule.** CLAUDE.md: "every change to the CLI, socket protocol, metadata schema, or surface model is incomplete until the skill is updated to match," plus the HARD RULE that editing a skill source requires running `scripts/sync-installed-skills.sh`. This change alters `launch-agent` behavior for every agent that reads `skills/c11/`. The plan lists neither `docs/launch-agent-reference.md` nor any skill file nor the sync step. **The sibling plan C11-194 remembers all of this** ("update the c11 skill contract for any CLI/socket changes... sync installed skills if edited"). C11-193 forgot it. That asymmetry is the tell that this plan was written faster than its sibling.

**No escape hatch — and the repo already has the idiom.** The only override is `--cwd`, which *changes where the agent runs*. There is no way to say "yes, this inherited worktree, I know, proceed." Eleven lines above the `launch-agent` case in `cli/c11.swift` sits `pane.create`'s `--allow-undersized` / `--force` (line 2218) — the codebase's established pattern for exactly this shape of guard. The plan ignores its own repo's precedent and offers no `--allow-worktree`, no env var, no setting.

**No rollout thought for 38 live worktrees.** This flips behavior for every in-flight delegator on the machine the moment it ships. No staged warn-then-refuse phase, no telemetry on how often it would have fired, no way to measure the false-positive rate before committing to a refusal. `AgentLaunchStatsStore` already exists and records every launch — a two-line "would have blocked" counter would have produced real numbers within a day. Nobody asked.

**`--new-workspace` is never mentioned.** With `--new-workspace` and no `--cwd`, `addWorkspace(workingDirectory: nil)` decides. Is that "inherited"? Does the guard apply? Unspecified, and it is plausibly the exact shape of the Acetate incident.

**The direct signal is never considered.** c11 stores `MetadataKey.worktree` per surface (`Sources/TabManager.swift:2481-2542`) and exposes cwd through `c11 tree`. "Is another *live surface* already sitting in this worktree, and is it not me?" is answerable in-process, with no subprocess, no timeout, no PATH dependency, and near-zero false positives. It is strictly better than the git proxy on every axis the plan cares about, and it enforces the ticket's actual stated invariant rather than a correlate of it. The plan does not mention it, does not reject it, does not know it exists.

**Nested worktrees.** Six worktrees live *inside* the main checkout at `code/c11/c11-worktrees/*`. Not a probe-correctness issue, but the remedy the error message implies ("pass `--cwd` pointing at the project root") is ambiguous when the root contains worktrees, and a naive "just use the repo root" reflex will drop agents into the wrong tree from the other direction.

**`--cwd inherit` is silently broken on this command.** `new-pane` and `new-split` both accept the literal `inherit` keyword (`cli/c11.swift:2117, 2215`). `launch-agent` does not: line 2328 is a bare `resolvePath(v)`, so `--cwd inherit` resolves to `<cwd>/inherit` and errors `not_found`. Pre-existing, out of scope, but this plan is about to make `--cwd` the load-bearing escape hatch on a command whose `--cwd` handling is the least consistent of the three. Fix it while you're here.

---

## Challenged Decisions

**Refuse on inherited, allow on explicit.** This is the plan's central choice and it is the one the ticket argues against. The ticket's stated reason for preferring a guard to a default is that a guard "also holds when someone passes `--cwd` explicitly, which a default cannot." Permit the explicit case and the guard's only advantage over C11-194's default evaporates. Two coherent positions exist — (a) enforce on both paths with a real `--allow-worktree` override, or (b) admit this is a loud default and fold it into C11-194. The plan picks neither; it picks the shape that maximizes friction on the common case while retaining none of the strictness that justified the ticket. **Looks like a default, not a decision.**

**Build a new probe instead of reusing `GitContextResolver`.** Counterargument is overwhelming: reuse gets submodule handling (verified: `git-dir == git-common-dir` inside `ghostty/`, so a submodule correctly classifies as *not* a linked worktree — a fresh probe might get this right by luck, or might not), bare-clone handling, `.stale` handling for `git worktree remove` races, detached-HEAD modeling, a bounded timeout, and an existing `GitRunner` test double. A new probe gets a one-line comparison and four new tests. If there is a reason not to reuse — a layering constraint between the `c11` target and wherever the guard lands — the plan must say so, because from outside it reads as not having looked.

**Server-side placement (implied, never stated).** CLI-side has real advantages the plan never weighs: the CLI runs *in the agent's actual shell with the actual caller cwd*, no PATH problem, no socket-threading concern, and a refusal prints to a terminal a human and an agent both read. Its weakness is that it can't see the target pane's cwd under `--pane`/`--workspace`. Server-side has the opposite profile. This choice determines the answer to A2 and cascades into everything else, and the plan doesn't make it.

**Four pure-logic tests as the entire gate.** For a change whose value is *behavior at a launch site*, testing the predicate is testing the wrong thing. And step 5's instruction to "run the narrowed `c11-logic` test slice" locally cuts directly against the operator-reinforced rule in this repo's memory (`feedback_no_local_xcodebuild_test`, hardened after C11-181 when the operator interrupted a `c11-logic` run): defer **all** local c11 `xcodebuild` to CI. The plan's final step instructs the implementer to do the thing the operator has explicitly stopped an agent from doing before.

**Refusal rather than a confirmation surface.** c11 has a UI. A worktree collision is exactly the kind of thing that could raise a sidebar flag or an attention marker on the launching surface rather than hard-failing a socket call. Not obviously better — but it's the option a product-minded reviewer would raise, and it isn't in the document.

---

## Hindsight Preview

**"We should have known the guard would fire on our own workflow."** 38 worktrees were visible from a single `git worktree list`. The `lattice-orchestrator` skill — shipped in this repo — mandates one worktree per delegator. Nobody ran the command before writing the plan.

**"Why didn't we just reuse `GitContextResolver`?"** Six months out, two implementations of `--git-dir` vs `--git-common-dir` will have drifted, one will handle submodules and one won't, and a bug will be fixed in the wrong one. C11-104 and C11-106 already paid for the hard cases; this plan proposes to not collect.

**"Why didn't we just measure first?"** `AgentLaunchStatsStore` records every launch. A one-week warn-only telemetry pass would have produced the false-positive rate as a number instead of an argument. Cheap, and it would have settled the refuse-vs-warn question empirically.

**"The `--cwd` reflex ate the guard."** The most likely two-year retrospective. Every prompt template acquires `--cwd`, the guard's fire rate goes to zero, and nobody notices because a guard that never fires looks identical to a guard that works.

### Early warning signs the plan has no mechanism to detect

- `--cwd` appearing unconditionally in orchestrator/delegator prompt templates.
- Zero refusals logged over a period where worktree launches are known to have happened.
- Any agent or human filing "launch-agent is broken in worktrees."
- Launch latency creeping up (the git probe on the launch path).
- Refusals concentrated in one workflow — the signature of a misfire, not a catch.

None of these are observable, because the plan adds no counter, no log line, and no metric.

---

## Reality Stress Test

Three likely disruptions, hitting together:

**1. C11-194 lands first.** Cwd precedence is now centralized as explicit → workspace root → surface cwd. The guard's binary (explicit vs inherited) has no slot for **configured**. An operator who deliberately set a workspace root to a worktree gets refused for a choice as intentional as `--cwd`. The implementer, working from a 5-line plan that doesn't mention C11-194's existence, will either guess or ship a guard that punishes deliberate configuration. Conversely if C11-193 lands first, C11-194's "centralize" step rewrites the guard's insertion point and the merge conflict is in logic neither author read.

**2. A delegator fleet is mid-run when this ships.** Delegators sit in worktrees. Each spawns reviewers and validators. Every one of those launches now refuses. The failure mode is a delegator that reports "launch failed" and stalls, or — worse, given how these prompts are written — one that improvises `--cwd` and lands somewhere unintended. The blast radius is the whole fleet, simultaneously, and the plan has no kill switch.

**3. `git` is slow or absent in the app process.** Xcode CLT reinstall, a network-mounted repo, an index lock held by a sibling agent's build. Every launch now waits up to 5 seconds. Whether it then refuses or proceeds is undefined by the plan. Under (2) simultaneously, a fleet of delegators each stalls 5 seconds per sub-agent launch and then does something the plan never specified.

**Combined:** a half-migrated cwd-precedence model, a running fleet, and a degraded git. The guard cannot distinguish "another agent's tree" from "my own tree" from "git didn't answer." The plan provides no override, no telemetry, and no staged rollout, so the only recovery is a code change and a rebuild.

---

## The Uncomfortable Truths

**The plan removes its own reason to exist.** The ticket's case for a guard over a better default is one sentence: it holds even on explicit `--cwd`. The plan permits explicit `--cwd`. What's left is a default that shouts, which is C11-194's job. Someone should say out loud: *if we're allowing `--cwd`, is this ticket still separate from 194?*

**The triggering incident had zero damage, in a different repo, with a different proximate cause.** Read the ticket's own account: nothing was damaged, one agent only read files, the parent committed before re-briefing, and two of the three agents were derailed by a **Codex version-update prompt swallowing their briefs** — a failure this guard does not touch. The cwd inheritance was real and worth fixing; the severity is being carried by a near-miss narrative rather than by observed cost. That's exactly the emotional state in which teams over-build guards that later get bypassed.

**c11 cannot actually enforce "no two agents mutate the same tree" from one launch site.** An agent can `cd` after launch. The operator can open a shell anywhere. The A button bypasses this entirely (different code path). `--cwd` bypasses it by design. The guard covers one entry point out of many while imposing friction on all of them. Selling it as enforcing an invariant oversells it; it's a speed bump on one road.

**The plan is thin in a way that transfers risk to the implementer.** Five imperative lines, no file paths, no error code, no threading note, no timeout policy, no fail-open/fail-closed call, no doc deliverable. Every one of the hard questions above gets decided by whoever implements it, in the moment, without the context to decide well. Compare the sibling C11-194 plan — same length, but it names the surfaces to trace, remembers the skill contract, and remembers the sync step. The gap between the two is not style; it is how much thinking was done before the writing stopped.

**Somebody already solved the hard part and this plan doesn't know it.** `GitContextResolver` (C11-104, refined by C11-106) is a careful, tested, injectable implementation of exactly this probe including cases the plan hasn't thought of. Proposing to "add a testable linked-worktree probe" in a repo that already has one is the clearest available evidence that the codebase wasn't read before the plan was written. Everything else in this review follows from that.

---

## Hard Questions for the Plan Author

1. **`GitContextResolver.resolveOuter` already performs the exact `--git-dir` vs `--git-common-dir` comparison, returns the branch, has an injectable `GitRunner`, and runs in `c11LogicTests`. Why is step 2 building a new probe?** If there's a layering reason the guard can't reach it, name it. *(Currently unanswered; the plan gives no sign of knowing the file exists.)*

2. **Which cwd does the guard read: the CLI caller's shell cwd, the target pane's parent-surface cwd, or the app-process cwd?** They diverge under `--pane`, `--workspace`, and `--new-workspace`. Note that the CLI never transmits (a) and the server already conflates (c) into project-config lookup at `SocketDispatch.swift:1069`. *(Unanswered — and unanswerable from the plan as written.)*

3. **What exactly is "the existing launch-agent cwd resolution seam" in step 1?** `v2ResolveCwdParam` only sees the explicit param; when `--cwd` is absent, `cwdOverride` is `nil` and inheritance happens downstream of the handler. **Where will the inherited cwd be materialized, and is that work in scope?** *(The plan assumes a seam that does not exist for the case it targets. This must be resolved before implementation starts.)*

4. **This repo has 38 live worktrees and a house workflow that gives every delegator its own. A delegator launching its own reviewer from its own worktree is legitimate and common. Why should that be refused?** What is the expected false-positive rate, and did anyone measure it? *(We don't know — and we could have, cheaply, via `AgentLaunchStatsStore`.)*

5. **Why the git proxy instead of the direct signal?** c11 stores `MetadataKey.worktree` per surface (`TabManager.swift:2481`) and knows every live surface's cwd. "Is another live surface already in this tree, and is it not me?" needs no subprocess, no timeout, no PATH, and answers the ticket's actual invariant. Was this considered and rejected, or not considered?

6. **When the git probe times out or `git` isn't on the app-process PATH, does the launch proceed or fail?** Fail-open reinstates the silent failure the ticket is about; fail-closed breaks all launches. *(Unaddressed. This is the single most important undecided behavior in the plan.)*

7. **What is the new structured error code**, and where does it go in `docs/launch-agent-reference.md`'s error table? *(Unnamed.)*

8. **Where is the documentation and skill deliverable?** CLAUDE.md makes it a hard rule that CLI/socket changes are incomplete until the skill is updated *and* `scripts/sync-installed-skills.sh` is run. C11-194's plan remembers this; C11-193's does not. Is the omission deliberate?

9. **What is the override?** `--cwd` isn't one — it changes where the agent runs. The repo already ships the idiom (`--allow-undersized` / `--force` on `pane.create`, `cli/c11.swift:2218`). Why is there no `--allow-worktree`?

10. **Four of the 38 live worktrees are on detached HEAD, where `rev-parse --abbrev-ref HEAD` returns the literal string `HEAD`.** What does the "actionable" message say then? `GitContextResolver` already models this as `.detached(shortSHA:)`. *(Step 4's stated tests would not catch this.)*

11. **Does the guard apply to `--new-workspace` with no `--cwd`?** *(Never mentioned. Plausibly the exact shape of the triggering incident.)*

12. **The A button and `default-agent launch` run a different code path (`TerminalController.swift:8989+`) and will remain unguarded.** Is it intentional that the invariant binds programmatic launches but not the operator clicking A in a worktree pane? Should it be a declared non-goal?

13. **`config launch` delegates to `v2AgentLaunch` and will inherit this guard silently.** Was that considered? Saved configs may legitimately encode worktree launches.

14. **C11-193 and C11-194 modify the same resolution and neither plan names the other.** What is the merge order, and which one owns the final precedence chain? *(No dependency declared on either side; both are in flight now.)*

15. **After C11-194, a workspace root is as deliberate as `--cwd`. Does the guard fire on a workspace root pointing at a worktree?** The plan's explicit/inherited binary has no slot for "configured."

16. **Step 5 instructs a local `c11-logic` run, which cuts against this repo's operator-reinforced rule to defer all local `xcodebuild` to CI (hardened after C11-181).** Is that deliberate, or carried over unexamined?

17. **What validates the refusal end-to-end?** Step 4 tests a predicate. CLAUDE.md's "Green Tests ≠ Working Product" and the escape-forward discipline both want a tagged build and a real `c11 launch-agent` from a real worktree. Is any runtime validation planned?

18. **What is the added launch latency, and is it acceptable?** `resolveOuter` via the full `resolve()` path issues roughly six `rev-parse` subprocesses with a 5s ceiling each, on the launch path.

19. **How will we know if the guard is being trained around?** If every prompt template acquires `--cwd`, the fire rate goes to zero and a working guard is indistinguishable from a dead one. What counter or log line makes that visible? *(None planned.)*

20. **Given the plan permits explicit `--cwd`, what does C11-193 deliver that C11-194's loud default does not?** *(This is the question that should be answered before any code is written. If the honest answer is "not much," the two tickets should merge.)*
