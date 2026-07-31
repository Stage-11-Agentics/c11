# Adversarial Plan Review: C11-184 (flagged and suppressed agents)

- **Plan ID:** c11-184-plan
- **Model:** Claude
- **Timestamp:** 20260728-1726
- **Plan under review:** `.lattice/plans/task_01KYMTXQVWCXCF0TGN5ZWG341E.md`
- **Verified against:** working tree at `09782511b` (the plan's own base gate), plus `docs/c11-flagged-agent-plan.md`, `docs/c11-mark-vocabulary.md`, `docs/c11-attention-model-skill-section.md`, `CLAUDE.md`

---

## Executive Summary

This is a good plan about the wrong unit of work. The engineering judgment inside it is genuinely strong: the raw-vs-signal index split is the right decomposition, the serialized commit boundary is the right instinct, the portal-mounted banner avoids a real PTY-resize bug, and the bypass audit (generic `set_metadata`, replace, restore, launch, transfer, close, prune) is more thorough than most plans of this type ever get. Cycle 1 clearly did real work.

But it is one plan, one branch, and one PR covering seven phases, roughly twenty files including the four largest files in the repository (`ContentView.swift` 15,476 lines, `AppDelegate.swift` 14,654, `Workspace.swift` 12,908, `GhosttyTerminalView.swift` 10,073), a public API change to a vendored submodule, a new socket domain with five methods, four CLI commands, two launch flags, four event types, two mark renderers, a new AppKit overlay with an interactive control, six locales, a skill contract with a manual sync step, an unresolved product policy decision, and a bespoke performance measurement campaign that has no existing instrument. The stated review budget is "one fresh correctness/threading review, one focused fix pass, one terminal re-review." That budget is not real for this diff.

**The single biggest issue is the latency gate.** The plan declares a hard, numeric, pre-merge ship blocker (`feature-on p95 delta <= 1 ms` at 20-agent fleet scale) and then allocates zero work to building the instrument that would produce that number. I checked: there is no latency harness in `scripts/`, none in `tests_v2/`. The only existing instrument is `CmuxTypingTiming` (`Sources/AppDelegate.swift:104`), which is (a) `dlog`-based and therefore **DEBUG-only**, (b) threshold-gated at 6 ms event delay and 1 ms handler duration so it *discards* sub-threshold samples, making a p50 arithmetically impossible to derive from it, and (c) measuring event-delay and handler-duration, not keystroke-to-paint. A 1 ms p95 delta is also inside the noise floor of an unpinned macOS machine running twenty live agent processes emitting terminal output. The predictable outcome is that this gate is either quietly waived or "satisfied" by an unreproducible ad-hoc script, and the plan's most important quality claim becomes theater.

Second biggest: **nothing in this plan measures whether the feature works.** Every gate is mechanism verification. Zero instrumentation exists to answer the only question that matters six weeks out: did flags reduce operator scan cost, or did agents start flagging routinely and kill the tier?

---

## How Plans Like This Fail

Five patterns apply directly.

**1. The "one ticket" that was a program.** Plans of this shape fail by being merged in a rush at 80% because the branch has become unmergeable against a moving `main`. This plan touches the four most-contended files in a repository that runs a parallel lattice-orchestrator fleet by default. The plan pins a base commit but specifies **no rebase cadence and no time estimate anywhere**. The absence of any duration estimate in a seven-phase plan is itself a tell: nobody has priced it, so nobody can notice it running long.

**2. The unmeasurable quality gate.** Covered above. The characteristic failure is not that the gate fails; it is that the gate is never actually run, and everyone remembers it as having passed.

**3. The deferred decision that turns out to be structural.** Phase 3's operator-held question is framed as "one isolated policy branch at one call site." It is not. See Challenged Decisions.

**4. The prerequisite that shipped without validation, so the follow-on rewrites it.** This has already happened here. The seam audit concedes that C11-183's shipped sidebar behavior (flagged working animates with the normal stepped fill; flagged idle/cold static) **contradicts** the binding spec, which requires breathe for every flagged non-waiting state. I verified the shipped code: `Sources/ContentView.swift:11453` reads `guard !suppressed, !staticMarks else { return nil }`, with no `flagged` term, so flagged working does indeed run base motion today. C11-183 merged four commits ago against a spec that was already written. The mechanism that let that happen is still in place.

**5. Correct-in-isolation projections that drift because they are implemented more than once.** Already happening. `Sources/Sidebar/SidebarActivityProjector.swift:55` and `Sources/ContentView.swift:11437` **each independently compute the identical reduction** `suppressed && !flagged && state == .waiting ? .idle : state`. That is the plan's headline reducer, duplicated at HEAD, before this ticket adds `SurfaceLivenessDeriver`, `AttentionModel`, and a Bonsplit presentation path as further consumers. The plan lists "spec precedence implemented differently in two renderers" as a risk with the mitigation "one shared pure presentation value." But the plan's own owned-files list keeps projection logic in `SidebarActivityProjector.swift` *and* `SurfaceLivenessDeriver.swift` *and* the new `AttentionModel.swift`, and says nothing about deleting the duplicate at `ContentView.swift:11437`. The risk is not mitigated; it is pre-existing and about to be doubled.

---

## Assumption Audit

### Load-bearing (plan collapses or ships broken without these)

**A1. "A 1 ms p95 keystroke-to-paint delta is measurable on this codebase."**
False as things stand. No harness exists; the only instrument is DEBUG-only and threshold-truncated. Also note the second-order problem: because `dlog` is DEBUG-gated (and per `CLAUDE.md` an ungated `dlog` breaks the Release build), the measurement necessarily runs on a Debug build whose SwiftUI and render characteristics differ materially from the Release build users get. You would be gating the shipped product on a number from a different product. **Likelihood it holds: very low.**

**A2. "40+ concurrently animating marks is a constructable test configuration."**
The plan's fleet protocol demands "at least 20 active agent surfaces so 40+ marks exist across surface tabs and sidebar cards." But the plan *also* requires (correctly, per the vocabulary doc) that marks unsubscribe when scrolled out of the tab bar, in collapsed panes, in unselected workspaces, or while the app is inactive. Twenty surfaces in one workspace means most tabs are scrolled out of the tab bar and therefore must not animate. Spreading across workspaces means the background workspaces must not animate. **The worst case the gate claims to measure is unreachable by construction under the plan's own correctness requirements.** Either the pause rules are broken (in which case the gate measures a bug) or the gate measures far fewer than 40 marks and the "fleet scale" framing is decorative. Nobody has reconciled these two requirements. **Likelihood it holds as written: low.**

**A3. "The Phase 3 decision is a one-line branch."**
See Challenged Decisions. If the answer is "yes, deliver," the binding spec sentence "Suppressed surfaces deliver no system notification, by definition" becomes false and the spec must be rewritten. A spec edit is not a branch. **Likelihood it holds: moderate at best.**

**A4. "`by: operator | agent` is trustworthy attribution."**
It is not. The socket has no per-caller authentication, and the plan explicitly adds "an explicit socket field for trusted operator-originated actions." Any agent can set that field to `operator`. The spec's entire justification for `by` is that a dismissed agent can distinguish *seen and deferred* from *nobody looked*. A field whose only value is trust, with a caller-settable value, is worse than no field: it is a signal that will silently lie. **Likelihood it holds: it does not hold; it is simply wrong as specified.**

**A5. "The metadata source timestamp is a sound flag-queue epoch."**
Partly verified and mostly sound. `SourceRecord.ts` exists (`SurfaceMetadataStore.swift:637`), is persisted (`PersistedMetadataSource.ts`, `Sources/PersistedMetadata.swift:74`), and round-trips through `restoreFromSnapshot`. Good. But: the store already has a same-source same-value no-op guard (`SurfaceMetadataStore.swift:634`) that returns `false` without touching `ts`, while the *merge* path at `:741` unconditionally writes `sblob[k] = SourceRecord(source: source, ts: ts)`. The plan's requirement that an active-to-active reason revision **preserve** the original epoch is therefore not the store's current behavior on the merge path, and the plan does not name that specific line as a change site. This will be found late.

**A6. "Signal eligibility can be layered onto the existing index builder."**
Structurally yes, semantically under-specified. `NotificationIndexes` is keyed **by tab** (`unreadCountByTabId`, `TerminalNotificationStore.swift:640`) while suppression is **per surface**, and `TerminalNotification.surfaceId` is optional. A tab holding a split with one suppressed surface and one ordinary surface must still tick its tab-level unread; a tab whose only surface is suppressed must not. The plan states the per-notification predicate (`!(suppressed && !flagged)`) but **never states the tab-level aggregation rule**. This is precisely where the plan's own "raw/signal index drift" risk will actually materialize, and it is the one place the plan's mitigation does not reach.

**A7. "The banner is purely additive to focus handling."**
Not verified by the plan, and probably false. `GhosttyTerminalView.swift:8809` (`isSearchOverlayOrDescendant`) walks the responder chain testing `v is NSHostingView<SurfaceSearchOverlay>` and string-matching `"BrowserSearchOverlay"`. Any *interactive* overlay (and the banner has an X button) must be known to this predicate or the focus-clearing path will misclassify it. The plan says "do not touch `hitTest()`" and "restore terminal focus," but never names this function. Note also that the existing code already resorted to string-matching a type name, which tells you the seam is not clean and the third overlay will not be free.

**A8. "The operator will run the skill sync."**
`CLAUDE.md` marks this as a HARD RULE precisely because it has been skipped before ("a fix lands in `skills/c11/SKILL.md`, the commit is green, and agents keep reading the old wording for weeks"). The plan puts it at the very end of Phase 6, the position of maximum schedule pressure, in a plan with no schedule.

### Invisible assumptions

- **That flag rarity self-regulates.** Inherited from the spec, never tested, never instrumented. The spec's own words: "no enforcement mechanism, no soft cap, no rate limit."
- **That an operator can tell a suppressed surface from an ordinary one when they need to.** They cannot; the spec forbids any visual indicator, and the plan adds no bulk query for suppression (see Blind Spots).
- **That flags and suppression are transient.** Both are sticky and persist across relaunch, with no expiry and no bulk clear.
- **That the flag color is legible to everyone.** No color-blindness consideration appears anywhere in the plan (see Blind Spots, most serious item).
- **That `main` will hold still.**
- **That the tagged-build visual pass is a validation, not a design session.** The plan says `#9D8AD9` is a "starting value, dialled in the tagged build." That is a design decision scheduled inside a validation gate.

---

## Blind Spots

**B1. Color-blind operators cannot see a flag in either mark renderer. This is the most serious gap in the plan.**

The prerequisite doc's entire thesis is that shape carries lifecycle so that "color is thereby free for the flagged modifier," and it frames that as an accessibility repair (the old vocabulary's working/waiting pair "was already false for that pair"). The flagged modifier then spends *only* color. For a protanope or deuteranope, flagged-idle and ordinary-idle are the same shape in near-identical values, and flagged-working and ordinary-working likewise. Motion partially covers this, but the plan makes **Reduce Motion a hard override on all flag motion**. So: **Reduce Motion plus color-vision deficiency equals flagged being completely undetectable in both mark renderers.** The sidebar row and banner still carry it, but the marks are the fleet-scan channel, which is the feature's entire stated purpose.

The spec even hands you the fix and then walks past it: *"Opacity is now a completely free channel, unused by lifecycle, flagged, or suppressed. Worth knowing as headroom before anyone spends it."* Spend it, or add a second shape channel, or state the accepted cost explicitly. The plan's accessibility items are entirely VoiceOver labels and Reduce Motion, with no color check at all, in a feature whose prerequisite ticket was justified as an accessibility repair.

**B2. There is no bulk read for suppression, in the feature's own dominant use case.**

The spec names the shape: "an orchestrator dispatches a fleet of workers... suppressing the subagents is what makes that fleet legible." The plan adds `flag.list` with deterministic oldest-first ordering. It adds no equivalent for suppression. Combined with the deliberate no-visual-indicator rule and the accepted cost that a finished suppressed agent and a stalled one both read idle, an orchestrator with thirty suppressed children has **no way to enumerate them, no way to tell finished from stalled, and no per-surface indicator**. Its only recourse is `get-metadata` per surface, one call at a time. The plan does mention "return attention fields in machine-readable launch/list results" as one line in Phase 2, with no acceptance-checklist item and no test. Promote it: `flag.list` should enumerate suppression too, or `list` should carry attention fields as a first-class, tested output.

**B3. No efficacy instrumentation, and therefore no way to ever know if this worked.**

The motivation section makes a concrete, falsifiable claim: scan cost grows linearly with fleet size and flags fix it. The plan ships four event types that would make measurement trivial and then never proposes reading them. Nothing counts flags raised per week, flag lifetime before lower, `by` distribution, or the fraction of agents that ever flag (the spec's stated 9-in-10 target). If agents start flagging routinely, the tier is dead and there will be no data to prove it, only vibes. Add a minimal read: `c11 events tail` already exists as the source. This costs almost nothing and is the difference between a feature you can iterate on and one you can only argue about.

**B4. No lifecycle end for either modifier.**

Both are sticky and survive relaunch, by design. Neither has expiry, bulk clear, or auto-lower (explicitly out of scope). Two accumulation failures follow, and neither is in the plan:

- A surface suppressed for an overnight sweep is **still suppressed the next morning** when the operator starts using it interactively. Nothing signals it, nothing clears it, and there is no indicator to notice it by (B2).
- Stale flags accumulate on dead-ish surfaces. The Flagged Agents row's entire design justification is "zero flags, zero footprint... a new element appearing in the sidebar is a stronger signal than an existing button changing color." Once the row is permanently non-zero, that property is destroyed and the feature has degraded back into the flat waiting tier it was built to escape.

Relatedly, the plan **skips stale/unopenable surfaces in navigation but presumably still counts them** in `flaggedCount`. A row reading "3 flagged" that jumps to only one is a correctness bug that the plan has already written in. Count and navigable set must agree, and that agreement is not in the acceptance checklist.

**B5. Surface close is not handled with the same rigor as the other bypasses.**

`SurfaceMetadataStore.removeSurface` uses `queue.async` (`:579`), fire-and-forget, while writes use `queue.sync`. So closing a flagged surface removes its metadata *asynchronously* relative to any UI update, opening a visible stale-count window. The plan mentions "prune also enters through explicit service hooks" but the acceptance checklist has no item for "flag clears when its surface closes," and the test checklist covers stale flags only in navigation.

**B6. `restoreFromSnapshot` has no validation seam at all.**

Verified: it assigns `metadata[...] = values` and `sources[...] = sources` wholesale, with zero validation (`:566-573`). The only key it special-cases is `flash_state`, dropped at the call site in `Workspace.swift:7606`. So a corrupted or hand-edited session snapshot can inject a multi-kilobyte, multi-line `flag` value that bypasses every validator the plan builds, and it will be rendered in a banner floating over terminal pixels. The plan asserts restore "enters through explicit service hooks"; the actual function has nowhere to hook. Validate on the restore path specifically and truncate defensively at the banner, and add a test with a hostile snapshot.

**B7. No rollback path and no kill switch.**

This feature changes the default attention behavior of the whole application: waiting counts, `⌥V` destination, both mark renderers, the sidebar, and external notification delivery. The regressions that matter (a lost `waiting.entered` edge, a double-counted flag, `⌥V` going somewhere wrong) are **invisible until the operator misses something**, which is the worst possible detection profile. The only remedy on offer is reverting a seven-phase branch. A defaults-backed switch that forces signal-eligibility to equal raw eligibility is cheap insurance, and the `Static marks` user default is a precedent already in the codebase.

**B8. `flaggedCount` scope is ambiguous between two surfaces.**

The plan says the Flagged Agents row "follows that existing scope," which for the notification store is app/window-global. It also adds `WorkspacePulseSummary.flaggedCount`, which is per-workspace. So there are potentially two different flag counts visible at once, in adjacent chrome, and the plan never states whether they should agree or how the operator is meant to read the difference. Name it.

**B9. No time estimate, anywhere.**

Seven phases, twenty files, a submodule API change, a translation stage, and a performance campaign, with no duration on any of it. That is not a scheduling nicety. Without it there is no threshold at which anyone notices this is running long, and no basis for the split decision this plan needs.

---

## Challenged Decisions

**C1. One PR for all of it. Challenge hard.**

Phases 0 through 3 (canonical model, primitives, signal layer) are a self-contained, testable, shippable unit with no visual surface. Phases 4 through 6 (renderers, submodule, banner, localization) are a second. Splitting gives you: a mergeable first half while `main` is still close, a real review budget per half, an isolated Bonsplit submodule change that is not entangled with the notification-store refactor, and an escape from the situation where a failed latency gate blocks the model layer that has nothing to do with latency. The plan's own commit-unit list (six coherent units) already describes the seam. The counterargument is that a half-shipped feature is confusing to agents reading the skill; that is answered by landing the skill section with the second half, which the plan already does.

**C2. Phase 3's held decision is not one branch, and holding it is the wrong call.**

The question ("does a flag on a suppressed surface fire a system notification?") *is* the headline use case. "Do not tell me when you finish, do tell me if you get stuck" describes an overnight sweep, where the operator is by definition **not looking at c11**. If the answer is no, the flagged-plus-suppressed combination, which the binding spec calls "the most valuable one in the feature," has no out-of-app channel at all: the violet mark, the sidebar row, and the banner all reach an operator who is asleep or in another application. The plan is prepared to ship the marquee case delivering nothing and call that faithful to spec.

Worse, the plan's own Phase 4 requirement makes this concrete: mark motion is gated on `scenePhase == .active` (see `WorkspaceContentView.swift:226`). So the alarm flash, "the strongest visual signal c11 has," **stops when the operator switches to another application**, which is exactly the scenario the system notification exists to cover. That interaction is nowhere in the plan and is not covered by "Static marks and Reduce Motion precedence match the spec."

And if the answer turns out to be yes, the spec sentence "Suppressed surfaces deliver no system notification, by definition" is false and must be rewritten. That is a spec change, not a call-site branch. **Resolve this before Phase 1, not after Phase 2.** It is a five-minute conversation with the operator that determines whether the feature's headline claim is true.

**C3. Oldest-first, cross-workspace `⌥V` changes the key's character, and nobody has said so.**

Today `⌥V` goes to the *latest* unread, so its destination is recent and therefore usually contextually close to what the operator was just doing. Flags invert that: oldest-first means the destination is by construction the **least** recent thing, and the flag queue is global, so `⌥V` can now yank the operator out of the workspace they are actively working in, into a different one, for something raised twenty minutes ago, at a moment they chose for a different reason. The spec's justification ("a flag up for twenty minutes is more starved") is a fairness argument about the flag, not an experience argument about the operator. Alternatives worth naming and rejecting deliberately rather than by default: latest-first for flags too; oldest-first within the current workspace before crossing; or a soft preference for the current workspace. This is the most-used key in the sidebar cluster and its feel is changing without discussion.

**C4. "Replace the C11-183 scaffolding behavior" needs a stated reason, not just a spec citation.**

The plan reverses just-shipped behavior on spec authority alone. That may well be right. But the deeper question is why C11-183 shipped a behavior contradicting a spec that already existed, four commits ago, and what prevents the same thing next time. If C11-183's behavior was a considered simplification, the reversal deserves an argument. If it was an oversight, the process gap is worth one sentence.

**C5. Extending Bonsplit's public API on the critical path.**

`Tab` is `public`, `Hashable`, `Sendable`, with an all-`let` memberwise init (`vendor/bonsplit/.../Tab.swift`). Adding an optional presentation value touches the init, the `from tabItem:` bridge, every construction site, controller create/update, transfer, and decode-with-default. Meanwhile `bonsplitActivityAnimationEnabled` is today a **single** environment key folding four conditions (`WorkspaceContentView.swift:225-230`); splitting it into base and explicit motion means finding every consumer inside the package. This is fine work, but it is a submodule API design that has to be right on the first try, because reverting a submodule pointer mid-ticket is genuinely painful and the plan's own submodule discipline (push to `main`, verify ancestry, then commit the parent pointer) makes iteration expensive. Consider landing the Bonsplit seam as its own small submodule PR *before* the c11 work, so the API is settled and pushed before anything depends on it.

**C6. Localization and the skill at Phase 6 is the wrong position.**

The plan's own instruction is "stabilize English keys first," but "first" is scheduled last. User-facing text is produced in Phase 2 (CLI help), Phase 4 (the row), and Phase 5 (the banner). In practice those strings get written inline as they are needed, and Phase 6 becomes a hunt for bare literals rather than a translation pass, which is exactly the failure `CLAUDE.md` warns about. Add the localized keys at the moment each string is written; let Phase 6 be translation only. And the translator subagent stage plus the maintainer-machine skill sync are the last two items in a long chain, which is where anything gets cut.

**C7. "One serialized `SurfaceAttentionService`" needs a stated lock ordering.**

The plan requires one commit boundary covering canonical metadata write, epoch timestamp, projection refresh, signal-index refresh, event emission, and optional direct delivery, with the socket response sent only after the whole thing is observable, and with `DispatchQueue.main.sync` forbidden by policy. That means the service's own serialization calls into `SurfaceMetadataStore`'s serial `queue` (which uses `queue.sync` for writes at `:621` and `:666`, but `queue.async` for `removeSurface`/`removeWorkspace`/`pruneWorkspace`), then hops to main for projection, then completes the request from main's continuation. That is a two-queue-plus-main-actor commit protocol with a mixed sync/async store underneath it. It is implementable with async plus completion, and it is also very easy to write as a rare deadlock or a rare stale response. **There is no sequence, no stated lock ordering, and no acknowledgment of the store's mixed sync/async surface.** Write the ordering down before Phase 1.

**C8. Forbidding all local test execution has an unpriced cost.**

This is the operator's rule and it is not negotiable here. But the plan should price it: every logic assertion for a 4-lifecycle by 2-flag by 2-suppression matrix, plus edge transitions, plus idempotency, round-trips through PR CI. That is a slow inner loop for the most assertion-dense part of the ticket, and the plan's risk section does not mention schedule at all. At minimum, structure the reducer so the entire matrix is a single table-driven test that can be got right in one or two CI rounds rather than discovered one combination at a time.

---

## Hindsight Preview

Two years out, the likely retrospective lines:

**"We should have known the latency gate was never going to run."** The instrument did not exist, and nobody costed building it. The gate reads as rigor and functions as a formality. Early warning sign, available today: nobody can name the command that produces the p95 number.

**"Why didn't we just split it?"** The seam was obvious. The plan's own commit-unit list drew it.

**"The suppression indicator we refused to build."** The no-visual-indicator rule is defensible in isolation and, combined with no bulk query, no expiry, and the accepted finished-versus-stalled ambiguity, produces an operator who has genuinely lost track of what state their fleet is in. The first time someone asks "which of these is suppressed?" the answer is thirty `get-metadata` calls. Early warning sign: the operator asking that question even once.

**"Flags became the new waiting within a month."** No enforcement, no telemetry, no expiry, no auto-lower. The spec explicitly bets on social self-regulation among *agents*, which is a novel bet with no precedent, and ships nothing that would detect losing it. Early warning sign: the Flagged Agents row is non-zero more days than not.

**"The color-blind gap sat in the accessibility-motivated feature for two years."** Because every accessibility item in the plan was about VoiceOver and Reduce Motion.

**"We shipped the headline case with no channel."** If Phase 3 resolves to "no notification," flagged-plus-suppressed reaches an absent operator through nothing at all, and the marks stop animating when the app is inactive anyway.

Early warning mechanisms the plan should add and currently lacks: a reproducible latency command checked into `scripts/`; a flag-rate read off the events stream; a count-versus-navigable-set consistency assertion; and a stale-flag age readout in `flag.list` output.

---

## Reality Stress Test

**Disruption 1: `main` moves.** Another delegator lands in `ContentView.swift` or `AppDelegate.swift`, which in this repo's default workflow is close to certain over a multi-week ticket. The branch rebases across the four largest files in the repo, and every rebase risks silently reverting an attention-path edit. No rebase cadence is specified.

**Disruption 2: the latency gate fails, or cannot be run.** The plan has a pre-registered fallback ladder, which is genuinely good practice. But the ladder assumes the gate produced a number. If the instrument does not exist, the honest options are "build a harness now" (unscoped work, mid-ticket) or "ship the fallback rung by default" (static marks, static violet), which quietly deletes most of the visual design that Phases 4 and 5 were built for. Nobody has decided which of those is the plan.

**Disruption 3: the Phase 3 decision comes back "yes, deliver."** The binding spec sentence becomes false, `docs/c11-flagged-agent-plan.md` needs an edit, the acceptance checklist item changes, the skill section's suppression paragraph arguably needs a qualifier, and the notification-policy test matrix flips a row. Small, but not one line, and it lands after Phase 3 is already built.

**All three together:** a branch that cannot cleanly rebase, whose visual half has been reduced to static fallbacks by an unmeasurable gate, and whose spec is being edited mid-flight. The rational move at that point is to merge the model and primitive layers and defer the rest, which is exactly the split that should have been made at the start, minus several weeks. This is the most likely bad ending, and it is fully preventable today.

---

## The Uncomfortable Truths

**This is a program with a ticket number.** Everyone can see it. The phase count, the file list, the fact that a product policy question is embedded as a placeholder inside it, and the fact that it needs its own performance measurement campaign all say the same thing. The plan is well made; the unit is wrong.

**The hard gate is the softest thing in the document.** A numeric merge blocker with no instrument is a wish. Everything else in this plan is executable. That one is not, and it is the item labeled "hard pre-merge gate."

**Nobody has said out loud that flagged-plus-suppressed may reach the operator through nothing.** The spec calls it the most valuable combination in the feature. The current faithful reading gives it no system notification, and its in-app alarm flash stops when the app is not active. That combination is the feature's headline promise, and as specified today it may not be kept.

**The feature is unfalsifiable as planned.** No counter, no rate, no baseline, no follow-up. Six weeks from now the question "did this help?" will be answered by whoever speaks first.

**The plan is disciplined about process and light about product.** It is meticulous on threading, submodule ancestry, bypass closure, and evidence capture. It is thin on: what the operator does when they lose track of their suppressed fleet; what happens when flags accumulate; whether oldest-first cross-workspace `⌥V` is actually pleasant to use; whether a color-blind operator can see any of this. Those are the questions the operator will ask in week two.

**"Dial in the violet in the tagged build" is a design decision hiding inside a validation gate.** If `#9D8AD9` does not hold at 9pt against `#E8E8E8` on the void, that is discovered at the end of the longest phase chain, and the fix competes with the rest of the visual pass for the same attention.

---

## Hard Questions for the Plan Author

1. **What exact command produces the p95 keystroke-to-paint number?** Name the binary, the script, the output format. There is no harness in `scripts/` or `tests_v2/`, and `CmuxTypingTiming` is DEBUG-only, threshold-gated at 6 ms and 1 ms, and measures event delay and handler duration, not keystroke-to-paint, so p50 cannot be derived from it at all. If the answer is "we will build one," that is unscoped work inside a plan with no schedule. *Currently "we don't know," and that is a problem.*

2. **How do you construct 40+ concurrently animating marks when your own correctness rules require off-screen, collapsed, unselected-workspace, and background marks to unsubscribe?** These two requirements contradict. Which one gives?

3. **You are gating on a Debug build. Why is a Debug-measured 1 ms delta the right proxy for Release behavior?**

4. **Resolve the Phase 3 question now: does a flag on a suppressed surface fire a system notification?** If no, state plainly in the plan that the feature's headline case reaches an absent operator through no channel, and note that its in-app flash also stops when the app is inactive (`WorkspaceContentView.swift:226` gates on `scenePhase == .active`). If yes, say which spec sentence you are rewriting.

5. **How does an orchestrator enumerate its thirty suppressed children?** No visual indicator, no `suppress.list`, no attention column with a test behind it. Per-surface `get-metadata` is not an answer at fleet scale.

6. **How does a color-blind operator see a flag in the mark row?** Shape is spent on lifecycle, motion is killed by Reduce Motion, and opacity is explicitly free and explicitly unspent. Either spend it or write down the accepted cost.

7. **What clears a suppression that has outlived its purpose?** Concretely: the operator suppresses eight subagents at 11pm, the sweep finishes at 3am, and at 9am they start working in those surfaces. What tells them, and what clears it?

8. **When `flaggedCount` includes a stale or unopenable surface that navigation skips, what does the operator see?** A row reading "3" that jumps to one is a bug. Where is the invariant that count equals navigable set, and where is its test?

9. **What is the tab-level aggregation rule for signal eligibility?** Indexes are keyed by tab (`unreadCountByTabId`), suppression is per surface, `surfaceId` is optional, and a tab can hold several surfaces via splits. State the rule for a tab holding one suppressed and one ordinary surface. This is where index drift will actually live.

10. **Which single function owns index rebuild and edge emission?** Today `emitWaitingEdges` derives its delta from state captured inside `notifications.didSet`. You are adding a second rebuild trigger from attention mutations. Two paths that both rebuild `indexes` and both emit edges is a double-emit and lost-edge race. Where is the structural invariant, not the review-checklist item?

11. **Write down the lock ordering for `SurfaceAttentionService`.** It serializes over a store that uses `queue.sync` for writes and `queue.async` for removal and prune, hops to main for projection, and must not respond before the commit is observable, all without `main.sync`. Show the sequence.

12. **How is `by: "operator"` verified?** It is a caller-settable field on an unauthenticated socket, and its entire purpose is trust. Either derive it from the transport (banner X equals operator, socket equals agent, no override) or document it as advisory and stop leaning on it in the skill text.

13. **What validates `flag` on the restore path?** `restoreFromSnapshot` assigns wholesale with zero validation and only the `flash_state` key is special-cased at the call site. A corrupt snapshot puts arbitrary multi-line text into a banner floating over terminal pixels.

14. **What is the merge-time behavior of `SurfaceMetadataStore` line 741** (`sblob[k] = SourceRecord(source: source, ts: ts)`) **relative to your requirement that a reason revision preserve the original epoch?** That line unconditionally overwrites `ts`, and it is not in your owned-change list.

15. **Does the banner's X button ever become first responder?** If yes, `isSearchOverlayOrDescendant` (`GhosttyTerminalView.swift:8809`) must learn about it. If no, say so as a design constraint and test it.

16. **Are there two flag counts on screen at once?** Global footer row versus per-workspace `WorkspacePulseSummary.flaggedCount`. Should they agree? What does the operator read?

17. **Why is oldest-first, cross-workspace the right `⌥V` behavior?** Defend it as operator experience, not as queue fairness. It inverts the key's current recency property and lets it pull the operator across workspaces at a moment they chose for something else.

18. **Why one PR?** State the reason, or split at Phase 3 or 4. Your own commit-unit list already draws the seam.

19. **How long is this?** No estimate appears anywhere. Without one there is no point at which anyone can tell it is running long.

20. **What is the rollback if signal eligibility regresses in production?** These regressions are invisible until the operator misses something. Is reverting a seven-phase branch really the plan, when a defaults-backed passthrough switch costs almost nothing and `Static marks` is the precedent?

21. **How will you know, in six weeks, whether flags worked?** Name the number. If there is not one, add one; the events stream already exists.

22. **What is the rebase cadence against `main`?** You are branching across the four largest files in a repo whose default workflow runs parallel delegators.

23. **If the latency gate cannot be run at all, which rung of the ladder ships?** Decide now, in writing, rather than under schedule pressure at the end of Phase 5.

24. **Why did C11-183 ship a flagged-motion behavior that contradicts a spec written before it?** What in the process prevents the next prerequisite ticket from doing the same?

25. **Where does `SidebarActivityProjector.swift:55` versus `ContentView.swift:11437` duplication get deleted?** The same reduction is implemented twice at HEAD, you are adding at least two more consumers, and "one shared pure presentation value" is currently a risk-table sentence rather than a phase task.
