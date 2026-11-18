<!-- c11-2.0:begin-keep (history: written while this line was c11h; the rename must not touch it) -->
# c11h M1 build brief (phases 1 and 2)

> **Historical.** Written while this line was c11h, before it became c11 2.0 (`C11.md`, Decisions 1-3). Names are as they were then; `docs/c11-2.0-identity.md` maps each to its 2.0 name.

Status: launched 2026-10-31 on Atin's go (16:26 PDT, relayed: "I say go, make this happen. I want all this work to be taken care of effectively running on the build host. I want signed builds of M1 and M2 on the laptop. Any questions? Otherwise, rocket."). "M1 and M2" are this brief's phase 1 and phase 2; each ends in a signed build installed on the laptop. Routing (Seats) is approved; don't ask again at intake. This is the Orchestrator's launch brief: `Read docs/c11-m1-brief.md and follow it exactly.`

You are the c11h M1 Orchestrator. Load `lattice`, `c11` and `lattice-hosted-orchestrator`, and run M1 by that skill. Read first:

- `docs/c11-plan.md`: what Atin can do when M1 and phase 2 are done, the contract ticket 2 freezes, the fifteen tickets, the go/no-go checks, what is accepted for M1. Its tables are the acceptance.
- `docs/c11-vision.md`: laws, names, separation from c11.
- `notes/c11v-herdr-core/reviews/astra.md` and `fable.md`: the review findings the plan cites as A1 to A13 and F1 to F10. Paste the relevant ones into each owner's brief as acceptance scenarios.
- `notes/c11v-herdr-core/SPIKE-0B.md`, `feature-map.md`, `hc-federation-robustness.md`: the evidence.

The spike's code is commit `dd0d4e75a9f` on the local branch `spike/c11v-hc`, in `~/src/c11-worktrees/c11v-hc-spike`. It is reference material, not a base to port unchanged (plan, "Where we start").

## Objective

The run has two phases (plan, Settled 14). Phase 1 is done when every promise in "When M1 is done" holds on the merged build, the go/no-go checks and the two-build signed update pass in a guest, and the signed build is installed on the laptop. Phase 2 is done when every line of "When phase 2 is done" holds and Atin's install is updated to it. Atin's week of local use, holder losses counted, runs during phase 2.

## Hard rules for this run

1. **Nothing reaches c11.** No push, branch or PR to `Stage-11-Agentics/c11`. No `scripts/sync-installed-skills.sh` from the c11h clone.
2. **The laptop stays Atin's.** On the laptop, never run `rebuild.sh`, `reload*.sh`, `run-tests-v*.sh`, `test-unit-local.sh` or anything that kills or launches an app by name: each can kill c11 with every agent in it. The only c11h work on the laptop is the Pathfinder's isolated hc for the build-host link check (its own session, stopped afterwards), the signing fallback (ticket 10 and the Pathfinder's dry run, only while the build host has no release keychain) and, with Atin's go, the final install.
3. **Private.** Deliverables for Atin (prototypes, reports) are local files in the repo, never published to Artifacts or any other host; the c11h Lead opens them on the laptop. The code lives only in `Stage-11-Agentics/c11h` (private). Nothing about c11h goes to herdr or any public place. Never move or export a signing key; sign through the build-host release keychain once the release-speed work lands it, else on the laptop (plan, Settled 6).
4. **The build host for builds and proofs.** Builds through `scripts/remote-build.sh` on three tags: `c11h`, `c11h-a`, `c11h-b`. Check the build host free disk before the first build; prune at each completion. Clicks and launches in a build-host guest through `scripts/sandbox-up.sh`.
5. **hc stays contained.** The pin the Pathfinder chooses (plan, Settled 8), checksum-verified, at a stable path c11h owns, session `c11h` (dev builds `c11h-<tag>`), off PATH, no XDG variables on the core. Never `hc update`. herdr-app's hc on the laptop and the build host (session `default`) is Atin's reference install: leave it and its terminals alone.

## Running on the build host

The run lives on the build host, in the build host's c11, workspace "c11h build" (Atin, 2026-10-31). The readiness Pathfinder proved the machine on 2026-10-31; its report, `<run-notes>/pathfinder-readiness-report.md`, is the runbook. The parts every seat needs:

- **Claude seats** launch with `c11 launch-agent --type claude-bravo-opus --effort high` (or `claude-bravo-sonnet`): the build host's own Claude login is logged out by design, and these bill the Bravo seat. Don't ration Anthropic usage: Atin, 16:29, "just use Grok and Sonnet build agents ... and even Opus build agents. We are Anthropic token unbound right now, so just make it happen." If Bravo hits its limit, write a `NEEDS:` line for another account and keep going on Grok meanwhile.
- **Seat models are your choice.** Any owner seat may be Astra, Grok, Sonnet or Opus. If a Codex or Astra seat stalls or misbehaves, swap it for Grok, Sonnet or Opus without asking; never hold work for Codex. Keep each reviewer from a different family than its owner.
- **Codex seats**: fixed 2026-10-31: Homebrew's codex is now 0.166 and runs (`codex login status`: logged in using ChatGPT), so plain `--type codex --model gpt-6-astra --effort xhigh` works; the report's PATH workaround is no longer needed. The folder-trust prompt takes one Enter (`c11 send-key ... enter`), once per folder or worktree. The status line must read `GPT-6-Astra xhigh` with no "fast".
- **Grok seats**: the trust prompt takes Enter, not `y`. In `review.sh trio`, run the Grok leg on its own or read its JSON and prune its worktree.
- **Builds**: the build host can't ssh to itself, so `remote-build.sh` runs through the loopback ssh shim in the run directory (report row 4); admission slots apply unchanged. A cold tag builds in about two minutes and costs about 5 GB.
- **Guests**: `C11_SANDBOX_HOST=local scripts/sandbox-up.sh`; dismiss the System Settings window the golden image opens before any UI check.
- **Signing**: the Developer ID on the build host lives in `acetate-release.keychain-db`, unlocked from its password file (never printed); c11h signs from it until c11's own build-host release keychain lands, then switches (the c11h Lead's default, open to Atin's veto). Never run `security show-keychain-info` on a locked keychain: it waits on a dialog.
- **Laptop steps** go through the c11h Lead on the laptop (the build host can't ssh to the laptop): the laptop side of the build-host link check, the phase 1 install and the phase 2 update.

## Pace (Atin, 2026-10-31 evening)

"Let's be more aggressive ... We can run as many agents we want in parallel ... However, we want you to do a great job." Agents are not the limit; the dependency chain, the build host's build slot and its two macOS guests are. So:

- **Split the big tickets once the contract freezes.** Tickets 2, 3 and 8 each split into two or three parts that build in parallel against the contract, each with its own owner and branch, and each mergeable alone. Keep a part only if it lands independently; merge order follows the contract.
- **Write the proofs ahead.** One seat per wave writes each ticket's guest proof scripts from the acceptance matrix now, so owners spend their time on code and the guest runs are ready when a PR is.
- **Build the Validator's harness now**, for both phases, so the final checks start the minute the last merge lands.
- **Pick models for speed where depth isn't needed.** Astra at high instead of xhigh, or Opus, Sonnet or Grok, for bounded parts; Astra xhigh stays on the contract and the restart logic.
- **Measure the real bottleneck.** Log every wait for a build slot or a guest with its length in run-state. When builds or guests queue for more than 15 minutes, write a `NEEDS:` line with the numbers; Atin can grant more build-host capacity.
- **Quality bar unchanged.** Every part still gets a cross-family review against the matrix and the gate at its exact head.

## Talking to Atin and the c11h Lead

Atin works from the laptop; the build host can't reach the laptop. The c11h Lead (the laptop, c11 workspace "c11h") is the bridge: it reads your panel and `<run-notes>/status.md` on `main`, relays to Atin, and does every laptop-side step.

- At each step boundary, and for anything that needs Atin or the laptop, update `<run-notes>/status.md` (newest first, local Pacific time, one line per event; a `NEEDS:` line for anything blocking) and push it to `main`.
- Stop and wait only for a go/no-go stop condition, a decision outside the plan, or a laptop step. Everything else proceeds.

## Step 0: set up

Already done before launch: the private repo `Stage-11-Agentics/c11h` (Actions off), the clone at `~/src/c11h` on the build host with the fetch-only `c11` remote and submodules, the hosted Lattice project `stage11/c11h` (code `C11H`) bound to that clone, and the "c11h build" workspace. Start at item 3's minting.


1. Create `Stage-11-Agentics/c11h` with `gh repo create --private`. Turn GitHub Actions off for it. (Since 2026-11-03 one Linux workflow, `c11h-shareable.yml`, runs; every other workflow is disabled. C11H-130.)
2. Clone to `~/src/c11h`: `origin` is the c11h repo; add `c11` (`Stage-11-Agentics/c11`) as fetch-only. Seed `main` from c11's current `origin/main`; keep the spike's commits on a reference branch. Init the `ghostty` and `vendor/bonsplit` submodules.
3. Create the hosted Lattice project `stage11/c11h` (code `C11H`), bind the clone with `lattice remote attach`, and mint the fifteen tickets with the plan's dependencies. Write `.lattice/orchestration/run-state.md`.
4. The run lives inside c11 on the laptop, in a c11 workspace named "c11h build" (never a workspace named plainly c11h, which reads as the app). Launch the Merge Captain before the first owner. The landing gate (Atin, 20:25): non-author review PASS at the exact head, a `remote-build.sh` compile, and `c11LogicTests` for the classes touched. Guest and runtime proofs run after merge on the merged build; a failure there is fixed forward. PRs land independently. There is no GitHub CI.
5. **Merging c11 in.** The Merge Captain merges `c11/main` into c11h's `main` at each wave boundary, never mid-wave, and resolves conflicts itself.

## Step 1: Pathfinder (alongside step 0)

On the spike build, tag `c11h`, in a build-host guest, before any ticket starts:

1. **The pin.** Run the spike's checklist and the go/no-go checks on hc 0.1.16; fall back to 0.1.15 only if 0.1.16 regresses a row. Record the chosen version and SHA-256.
2. **Go/no-go.** Every row of the plan's table. A stop condition ends the run there; report to Atin.
3. **The acceptance matrix** (plan, A12): every checklist row and every ticket's acceptance against the chosen pin, with owner, procedure, timeout, observation and accepted residual. Which of the "Accepted for M1" items the pin still has.
4. **Signing.** Ask c11's release-speed seat (panel 29, through the Chief of Staff) whether the build-host release keychain has landed. If yes, dry-run signing a throwaway build-host Release build there; if not, dry-run the fallback on the laptop (a c11h variant of `scripts/release-local.sh`'s tail): codesign and verify only, nothing launched.
5. **Build-host link.** The plan's "Build-host link" row: our hc on the build host in its own folder and session, linked from an isolated hc on the laptop with our binary named explicitly; typing round trip over the tailnet, a dropped and restored link, the build-host core and its terminals across both. herdr-app's installs untouched.
6. **Infrastructure.** One build timed on a warm and a cold tag; the build host free disk; one guest lease taken and released; one review through `review.sh` on a trivial diff; one landing dry run.

Results go into run-state as one table. The Result Validator re-runs the go/no-go checks on the finished build.

## Step 2: order

| Ticket | Starts when |
|---|---|
| 1 Separate identity, 2 hc backend | The Pathfinder's stop checks pass. |
| 2's contract | First deliverable of ticket 2: one page, reviewed by both Review 1 seats, then frozen. |
| 5 Rendering, 6 Reconnect, 9 Observability | 2's contract is frozen. |
| 3 Restore | 2's review handoff (pre-warm read-only before it). |
| 4 Quit and resume, 7 Agents reach c11h | 3 merged. |
| 8 Agents come back | 3, 4, 6 and 7 merged. |
| 10 Signed build and installer | 1 merged. |
| 15 Where it runs | Its prototype at once, for Atin's sign-off; its build once 2's contract is frozen. |
| 11 Our hc on the build host | 2's contract is frozen. |
| Phase 1 install on the laptop | The Validator's phase 1 run is GREEN and Atin says go. |
| 12 build-host panels, 13 build-host status | Tickets 1 to 10 and 15 merged. |
| 14 build-host agents talk back | 12 merged. |
| Result Validator, phase 1 | Tickets 1 to 10 and 15 merged. The assembled build in a guest against every promise in "When M1 is done", every go/no-go check, and ticket 10's two-build signed update. GREEN or named residuals. |
| Result Validator, phase 2 | Tickets 11 to 14 merged. Every line of "When phase 2 is done", with a real build-host link. Then ticket 10's command updates Atin's install. |

The critical path is 2 → 3 → 7 → 8 → Validator, then 12 → 14; never let it wait for a build slot or a guest. Hand each install to Atin with the command and a one-page guide, and record his verdict verbatim. A holder loss during his week moves the holder patch to the front of phase 2 (plan, Settled 12).

**Width.** One shared build-host build slot and shared guests, with the c11 1.0 run on them too. Run about one owner more than free slots, and say so in status when owners wait.

## Seats

| Seat | Who | Where |
|---|---|---|
| Orchestrator | Claude Opus 5.5 (`claude-bravo-opus`, high) | c11 tab in the build host's "c11h build" workspace |
| Pathfinder | Claude Opus 5.5 | c11 tab, closes after its report |
| Merge Captain | Claude Opus 5.5 | c11 tab with its own control worktree |
| Owners, hard: 2 hc backend, 3 Restore, 4 Quit and resume, 5 Rendering, 6 Reconnect, 7 Agents reach c11h, 8 Agents come back | Astra (`codex`, `gpt-6-astra`, xhigh) | c11 tabs; build-host builds; macOS-only, so no Prime boxes |
| Owners, hard, phase 2: 12 build-host panels, 13 build-host status, 14 build-host agents talk back | Astra (`codex`, `gpt-6-astra`, xhigh) | c11 tabs; build-host builds and a real build-host link |
| Owners, bounded: 1 Identity, 9 Observability, 10 Signed build and installer, 11 Our hc on the build host, 15 Where it runs | Grok | c11 tabs; build-host builds; ticket 10 signs on the build host, or the laptop as fallback |
| Review 1 | Astra's tickets: Opus and Fable; Grok's tickets: Astra | One tab per reviewer, own review worktree |
| Review 2 | One fresh context from another family | Same |
| Result Validator | Claude Fable 5.1 | Fresh tab after the last merge |

Only ticket 2 (the hc backend and the contract every other ticket builds on) takes the large-ticket review track. Tickets 3, 8 and 14 run the normal track (Review 1 plus Review 2) for speed (Atin, 17:34: "reduce those back end reviews to speed this along for less important tickets"). Ticket 4 moved to Astra after review A7 showed it reaches into the conversation store. Confirm the routing with Atin at intake, per the skill.

## Reports to Atin

Steady updates at each step boundary, in local time. Stop and ask only for: a go/no-go check failing, a decision the plan doesn't cover, the final laptop install, a laptop signing prompt, or ticket 15's prototype for his pick.
<!-- c11-2.0:end-keep -->
