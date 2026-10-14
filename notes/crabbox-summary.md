# Crabbox — capability summary

*Captured 2026-05-26 after research + competitive survey, before any pilot.
Full thinking trail in `crabbox-research.md` (this directory).*

---

## What it is

Crabbox is a Go CLI + Cloudflare Worker broker that lets an operator (or
an agent acting for them) lease ephemeral remote VMs from any of ~22
cloud and sandbox providers with one command. The canonical loop is
`crabbox warmup → crabbox run --id <slug> -- <command> → crabbox stop`.
The CLI rsyncs the dirty checkout to the leased box; the Worker holds the
provider credentials so neither the laptop nor the leased box ever does;
each lease gets a fresh per-lease ed25519 SSH keypair minted on the
laptop.

Headline: *"A short-lived box for every run. Warm a box, sync the diff,
run the suite."*

Created 2026-04-30 by Peter Steinberger (steipete, ex-PSPDFKit founder)
and Vincent Koc, ~26 days old at v0.19.0 as of this writing. MIT-licensed.
Lives in the `openclaw` GitHub org. Install: `brew install
openclaw/tap/crabbox`.

## What's architecturally distinctive

Four properties together that don't appear anywhere else in the field:

1. **Brokered credentials.** The Cloudflare Worker holds AWS / Hetzner /
   Azure / GCP keys. The laptop has a bearer token. The leased box has
   nothing.
2. **Provider pluralism.** ~22 backends spanning raw cloud (Hetzner / AWS
   / Azure / GCP / Proxmox / static SSH / local Docker) and delegated
   sandbox SDKs (E2B / Modal / Daytona / Cloudflare Containers /
   Tensorlake / Sprites / Blacksmith Testbox / Namespace Devbox / …).
3. **Ephemeral lease lifecycle.** Stable lease IDs (`cbx_8f2`) +
   crustacean-themed slugs (`blue-lobster`). Spend caps and idle timeouts
   enforced in the broker's Durable Object. Live AWS Spot pricing.
4. **Thin CLI agents can call directly.** No SDK requirement, no IDE
   integration — `crabbox run -- <cmd>` and the rest is plumbing.

Quieter niceties worth noting:

- **Data plane bypasses the broker.** SSH and rsync go laptop → VM
  directly. The broker only sees control-plane JSON. Cannot become a
  performance bottleneck or read your code/env/output.
- **Fingerprint-skip rsync.** No-op when the checkout hasn't changed —
  warm-box re-runs feel near-local.
- **OpenClaw plugin is a 459-line zero-dep Node shellout.** Doesn't wrap
  the agent; just exposes 5 lifecycle tools (`crabbox_run`, `warmup`,
  `status`, `list`, `stop`). Per-tool allow/deny knobs.
- **Capsules** (`crabbox capsule from-actions <url>` →
  `crabbox capsule replay <yaml>`) — turn a failed GitHub Actions run
  into a portable local-on-cloud replay manifest.
- **Native Windows / macOS support** on the providers that can offer it
  (Azure native Windows + WSL2, EC2 Mac, Parallels). Unusual in this
  space, mostly Linux-only.
- **Desktop input primitives** (`crabbox desktop click/paste/type/key`)
  for VNC-attached leases. Saves agents from rolling their own `xdotool`.

## What you can do with it (the capability map)

A Crabbox lease is fundamentally a Linux SSH target with sync-to-it +
manage-its-lifecycle batteries included. Practical patterns:

| Pattern | Shape | When it fits |
|---|---|---|
| **One-shot remote run** | `crabbox run -- <test or build>` | Heavy test suite, contention-heavy build, anything that ties up the laptop for >2 min. The marketing example. |
| **Heavy single command** | `crabbox run -- ./scripts/migrate.sh` | Same shape as above, longer-running. Use `--keep-on-failure` to retain the box for SSH debugging if it fails. |
| **Interactive sandbox** | `crabbox warmup` → `crabbox ssh <slug>` | Exploratory hands-on work. Sketchy installs. "What happens if I run this script of unknown provenance?" Throw the box away when done. |
| **Risky operation** | Same as above, in a fresh lease | Anything you don't want to taint your laptop with. The lease isolates blast radius to one VM. |
| **Parallel scenario fan-out** | N leases × N configs, same `crabbox run` against each | "Run my test against Python 3.10, 3.11, 3.12 simultaneously and compare." Limited only by your spend cap and the broker's per-user lease cap. |
| **Long autonomous agent run** | `crabbox warmup --keep --ttl 8h` → `crabbox ssh <slug>` → start Claude/Codex with a prompt → walk away | The pattern Depot Remote Agent Sandboxes pitches specifically. Crabbox supports it via `--keep` and explicit TTL; less directly marketed but fully capable. |
| **Capsule replay** | `crabbox capsule from-actions <url>` → `crabbox capsule replay <yaml>` | Take a failing GHA run, get a portable manifest, replay it on a Crabbox lease to debug locally with cloud-grade compute. |
| **PR replay** | `crabbox run --fresh-pr owner/repo#123 -- <cmd>` | Test a pull request's branch on a fresh box without polluting your local checkout. |
| **GHA runner** | `crabbox warmup --actions-runner` | Register a lease as a GitHub Actions runner for that workflow run. Burst capacity for CI. |

Things Crabbox is **not**:

- Not a cloud IDE. There's no editor in the box, no in-browser shell as
  primary UX. Your editor stays on your laptop.
- Not a persistent dev environment. Leases are throwaway by design
  (though `--keep` extends one).
- Not a CI service. CI is job-triggered and queue-shaped; Crabbox is
  command-triggered and interactive-shaped. Crabbox can *integrate* with
  GHA via the runner-registration path, but it's not a replacement.
- Not an agent runtime. Crabbox doesn't host or wrap your agent — it
  provisions a Linux box and lets you put whatever you want on it,
  including an agent.
- Not free of cloud bill. Direct-provider mode pays your Hetzner / AWS /
  etc. bill directly; brokered mode adds spend-cap guardrails but the
  underlying compute is still real money.

## The competitive map (short version)

The field splits into three layers:

- **Layer A — sandbox SDKs / raw compute primitives.** E2B, Modal
  Sandboxes, Vercel Sandbox, Cloudflare Sandbox SDK, Fly Machines /
  Sprites, Tensorlake, Hopx, Northflank Sandboxes, Runloop, Daytona's
  SDK, Cased's `sandboxes` library.
- **Layer B — cloud development environments.** Coder, Ona (formerly
  Gitpod), DevPod, GitHub Codespaces, Namespace Devbox, JetBrains Space,
  Microsoft Dev Box, Replit.
- **Layer C — local sandboxes for the agent process itself.** Anthropic
  Sandbox Runtime (`srt`), Claude Code's `sandbox-utils`, ClaudeBox,
  packnplay, the bubblewrap/seatbelt/landlock family.

**Crabbox occupies the thin middle band that none of these owns
cleanly:** keep your editor local (Layer C's win), push compute to real
remote capacity (Layer A's win), without becoming a workspace lock-in
(Layer B's failure mode).

**Only one other tool hits the same `warmup → sync diff → run → release`
shape today: Blacksmith Testbox.** It's single-substrate (Blacksmith's
own microVMs), tied to a Blacksmith account, and **Crabbox actually wraps
it as a delegated provider.** So they're more co-existent than
competitive.

**Daytona** has live file sync on the roadmap (issue #3309); when it
ships, Daytona becomes the closest Layer A → middle-band contender. It
will still be single-substrate and SDK-shaped rather than CLI-shaped.

Everything else (Coder, DevPod, Codespaces, E2B, Modal, Cloudflare
Sandbox SDK, Depot Remote Agent Sandboxes, …) lives in adjacent slots
solving related-but-distinct problems.

## Where Crabbox would help Stage 11

Realistic candidates if/when we have a workload that fits:

- **Lattice delegators offloaded to leased boxes.** Today the
  lattice-orchestrator pattern gives "one delegator per worktree." The
  natural extension is "one delegator per worktree, running on its own
  Crabbox lease." The agent works autonomously on remote compute for
  hours; the operator's laptop stays clear; the lease's stable slug is
  the addressable handle.
- **Heavy Python/Linux test suites.** Lattice, stage-11-company-board,
  any future Python project with a real test pyramid. Cheap to offload.
- **Risky experiments at scale.** Try a sketchy install, see what breaks,
  throw the box away.
- **Parallel scenario runs.** Same test, N different dependency versions,
  N boxes, compare results.
- **Capsule-based CI debug loop.** When a GHA run fails on a Stage 11
  repo, capture it as a capsule and replay locally on a fast Crabbox
  lease — better than re-running the workflow with `act` or in CI.

## Why we're not piloting today

Two reasons:

1. **The natural Stage 11 workload doesn't fit yet.** c11's
   host-required tests need macOS — Crabbox's managed providers default
   to Linux (EC2 Mac is supported but a much heavier setup path). The
   Linux-test-suite candidates that would fit (Lattice, the company
   board's dashboards) aren't slow enough on Hyperion today to justify
   offloading.
2. **Crabbox is too young to commit to without a real workload.** 26
   days old, ~750 of ~860 commits from two authors, hosted Worker is a
   single point of failure for brokered-cloud providers. Piloting
   without a real pain to test against would produce thin signal and
   carry sunk-cost risk.

## What would change our answer

Concrete triggers to revisit:

- We start running long-running autonomous agent sessions
  (lattice-orchestrator delegators that work for hours) and Hyperion's
  compute becomes the bottleneck.
- A Stage 11 Python project's test suite grows past ~5 minutes locally.
- We start doing parallel scenario tests across dependency-version
  matrices.
- We start needing isolated environments for risky / unattended agent
  experiments where laptop blast radius matters.
- **Daytona** ships live file sync — single-substrate alternative with a
  larger team behind it becomes worth comparing.
- **Blacksmith Testbox** becomes worth evaluating because we end up on
  Blacksmith CI for some other reason.
- Crabbox passes the 60–90 day mark with shipping cadence holding, a
  real community forming, and the broker SPOF mitigated (multi-region
  Worker, foundation backing, third maintainer landing meaningful
  commits, etc.).

## Resources

- **Full research trail:** `crabbox-research.md` (this directory) —
  architecture deep dive, full competitive survey, c11 integration angles
  graded by ambition.
- **Primary:** https://crabbox.sh/, https://github.com/openclaw/crabbox
- **Author writing on agentic engineering** (closest external articulation
  of our worldview I've seen): https://steipete.me
- **Closest direct competitor:**
  https://docs.blacksmith.sh/blacksmith-testbox/overview
- **Most likely future contender:** Daytona's `sandbox sync` —
  https://github.com/daytonaio/daytona/issues/3309
