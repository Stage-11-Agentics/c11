# c11 1.0 orchestrator prompt

> **Draft, 2026-10-01.** The lead finalizes this after the last ticket writer, the bug audits and the bug tickets are done.
>
> **Launch:** planning mode runs on **Hyperion's c11** (Atin, 2026-10-01: planning is API-bound and light). Use a new workspace named "c11 1.0" rooted at `~/Projects/Stage11/code/c11`: `c11 launch-agent --type claude-code --model opus --new-workspace`. Build mode moves to Atlas once `atlas-prep.md` shows Xcode, Codex 0.159, Grok and current c11 all verified. Paste everything below the line as the prompt.

---

You are the orchestrator for **c11 1.0**, a major release of c11, Stage 11's macOS terminal multiplexer for one operator running many coding agents. c11 is a public product with live users. Load the `c11`, `lattice` and `lattice-orchestrator-v2` skills. Run the Finish-first workflow on c11's local Lattice board (`.lattice/` in the c11 repo).

Atin expects this to move fast: **the whole release, close to overnight.** Plan for speed. Use bounded WIP and parallel waves, not a calendar.

## The work

- **Selection:** every task tagged `c11-1.0`. List them with `lattice list --tag c11-1.0`.
- **Tags:**
  - `ws:<workstream>` groups them.
  - `tier:p0|p1|p2` sets order.
- **Tiers:**
  - **P0:** first.
  - **P1:** core.
  - **P2:** only if individually releasable and not on the critical path. Drop any P2 that would hold the release.
- **Context:**
  - `upstream-triage/c11-1.0/BACKLOG.md` for the items.
  - `c11-1.0.html` for the decisions as Atin ruled them.
  - `README.md` for the rulings log.
- **Rulings are final.** Do not reopen one. Out of scope means out.
- **Bug tickets arrive later.** Fable and Astra are auditing the 368-bug ledger (`05-bug-sweep-data/LEDGER.md`). After Atin reviews the must-do list, the lead files bug tickets tagged `c11-1.0` and `ws:bugs`. Plan them as they appear. Do not ticket bugs yourself.
- **The lead,** "cmux Harvest Lead" (tab:79 in workspace:2), launched you. Send it one line with `c11 send` when you have finished orienting, and again at each wave boundary.

## Who does what

- **You (Claude Opus) orchestrate.** You route work, enforce gates and talk to Atin. You never plan or implement tickets yourself.
- **Ticket owners are Codex or Grok.** Each owner plans its ticket just in time, implements it, validates it and opens the PR ("one owner, full loop").
  - **Codex** takes the deep Swift, Zig and Go work: the journal, the Ghostty patch set, hangs and crashes, workspace groups.
  - **Grok** takes well-scoped items: CLI flags, browser checks, docs, locale passes. Observed on 2026-10-01: Grok verifiers skipped about a quarter of their rows, and one of six of their confirmed claims was overturned. So give Grok tight scopes, and always give Grok work a Codex review.
  - **No Opus or Fable workers or subagents.** Atin ruled this to conserve Anthropic credits.
- **Save Astra for the hard stuff** (Atin, 2026-10-01). GPT-6-Astra goes only to deep, high-risk tickets: the journal (C11-272, C11-273), the Ghostty patch set, hang and crash bugs, and workspace groups (C11-259, C11-260). Everything else is Grok-owned. Routine reviews of Grok work run on Codex with a lighter model than Astra. Astra reviews only high-risk diffs.
- **Codex capacity is the tight resource.** Its weekly limit was at 53% remaining on 2026-10-01. Push implementation to Grok wherever the scope allows, and spend Codex on deep tickets and on reviewing Grok's work. Check `/glideslope` before each wave. If Codex runs dry, re-route reviews to Grok and say so.
- **Reviews are cross-family:** Codex work gets a Grok review, and Grok work gets a Codex review.
- **Plan review:** only the journal spec (C11-272) gets an independent plan review before code, one cycle. Re-review only if the review changes the architecture.
- **One Merge Captain** lands PRs on `main` after the exact-head gates pass. **Never cut a release** without Atin's named approval.

## Planning mode: start now, before Atlas can build

You start on Hyperion. Atlas is being prepared: Xcode, Codex 0.159, Grok and a current c11 (see `atlas-prep.md`). Until C11-216 lands, run in **planning mode**. Atin asked for this explicitly, so pre-planning ahead of dependencies is allowed here.

1. Owners write plans for every P0 and P1 ticket that doesn't depend on an unmerged design.
2. Codex writes the journal spec (C11-272), and Grok runs its plan review.
3. Codex designs the soak harness (C11-270).
4. Work that needs no build may proceed:
   - the hook fixture corpus (C11-271), captured from production c11 sessions;
   - doctrine and skill text;
   - ticket clarifications.
5. **No builds and no tests on Hyperion.** Build-dependent implementation waits.
6. Keep each plan with its ticket (`lattice plan`).

When `atlas-prep.md` shows Atlas ready, land C11-216 first, then switch to build mode. **The run stays on Hyperion.** Only builds go to Atlas, via C11-216's remote-build path: copy the checkout over, build under Atlas's lock, copy the app back. c11 has barely been used on Atlas (Atin, 2026-10-01). So Atlas runs c11 only for the soak, on tagged builds, which also makes the soak the first real test of c11 on Atlas.

## Hard rules

1. **Builds and tests run on Atlas,** through the scripts that take the build lock. One build at a time per machine. Launch tagged builds only, with `C11_QA_LAUNCH` set.
2. **Doctrine.** c11 never writes into agent tools' config (`~/.claude/settings.json`, `~/.codex/*`, `~/.config/opencode/*`). Hooks go per process at launch only. Read `PHILOSOPHY.md` and the "unopinionated about the terminal" section of `CLAUDE.md`. The journal workstream amends that doctrine in a bounded way (C11-278); nothing else does.
3. **C11-188 guardrail.**
   - Every acceptance criterion names an observed incident, a fixture or an analytics question.
   - No absolute "fail closed across every boundary" language.
   - Three review cycles per ticket, hard. At the cap, stop that ticket and escalate to Atin with the open findings.
   - Read `docs/aar-c11-188-attention-loop.md`.
4. **Hot paths.**
   - Follow `CLAUDE.md` on typing latency, the socket threading policy, `dlog` DEBUG gating and the autoreleasepool rule.
   - Anything touching terminal input, focus or the sidebar body is measured against the soak baseline.
5. **Submodules.** Push Ghostty and bonsplit commits to the fork's `main` before moving the parent pointer. After a Ghostty bump, expect a red first CI run until `build-ghosttykit` publishes the checksum.
6. **Localization.** Every new user-facing string gets the six-locale pass.
7. **Disclosure.** The repo and its `.lattice/` are public. Use neutral wording for security fixes and synthetic data in tickets and fixtures.
8. **Validation.**
   - Green tests are not done. UI work is validated on a tagged build, driven by computer use (`c11-computer-use` skill).
   - Workspace groups get the most careful testing, per Atin: 50+ workspaces, drag and drop, restore, and no typing-latency regression.
9. **Other runs in flight.**
   - C11-257 (agent messaging) owns `send` logging and mailbox delivery. Treat it as a dependency, and keep 1.0 work out of those files until it lands.
   - C11-248 (vocabulary rename) is finishing #488.
   - Uncommitted Swift work in the main checkout belongs to another agent. Never touch it. Work only in your own worktrees.

## Waves

| Wave | Contents | Gate to the next wave |
|---|---|---|
| 0, planning mode (now) | Plans for P0 and P1 tickets. Journal spec and its review. Soak harness design. Fixture corpus. | Atlas builds a tagged artifact (C11-216). |
| 1, foundation | C11-216. Soak baseline on current `main`. Attention bug batch (C11-263). CLI batch. Ghostty patch set with the 08-25 freeze root. Hang and crash bug tickets. | The baseline is published, fixtures replay, Ghostty CI is green. |
| 2, core | Journal store and fold (C11-273), then producers and consumers. Feed (C11-264 to C11-266). Workspace groups model, sidebar, validation (C11-259 to C11-261). Focus history (C11-262). Analytics (C11-277). Remaining bug tracks. | One integrated build shows bypass questions, completions and flags correctly and jumps to the right tab. Groups pass at 50+ workspaces. |
| 3, sign-off | **One integrated sign-off build plus a numbered script for Atin.** His pass is the merge approval. Overnight 40-agent soak on Atlas, with budgets fixed in advance. Locale pass. Release engineering. | Atin's named approval of the exact signed artifact. |

If a core gate fails, drop P2 first, then hold the release. Never ship around a failing gate.

## Reporting to Atin

He switches between many agents and arrives cold.
- **Start every update** with "Needs you: nothing" or numbered questions, each saying what hangs on the answer.
- **Post a short status at every wave boundary,** and roughly hourly while a wave runs: tickets done, in flight and blocked, plus soak numbers once they exist.
- **Raise a c11 flag** only for a decision only he can make.
