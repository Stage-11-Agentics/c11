# Crabbox — research, worldview, and what c11 should do about it

*Research date: 2026-05-25. Crabbox at v0.19.0, 26 days old.*

---

## TL;DR for the operator

Crabbox is the **cloud arm** of the local-first agentic operator. Where c11
is the room the operator runs in, Crabbox is one appliance you wheel into
that room: a single CLI that, with one command, leases a fresh remote VM
from any of ~22 cloud or sandbox providers, rsyncs your dirty checkout to
it, runs a command there, streams output back, and releases the lease.
Architecturally it's lean and quietly impressive. Culturally it shares
almost every value c11 has, applied to a different surface of the same
problem. Your friend recommended a piece of tooling that is, as far as I
can tell, the closest external thing to the c11 worldview I've encountered.

**A subsequent survey of the field** (next major section) confirmed the
slot is genuinely sparse: only one other tool — **Blacksmith Testbox** —
hits the same `warmup → sync diff → run → release` shape, and it's locked
to a single substrate (Crabbox even wraps it as a provider). The next
closest contender, **Daytona**, has the loop on its roadmap but hasn't
shipped it. So Crabbox is real and differentiated; the question is whether
to pilot it now or wait for the field to thicken.

The integration story is "agent reaches into Crabbox," not the reverse.
There are no required code changes in c11 to start using them together —
a thin **generic `crabbox` skill** (not a c11-specific one) is the
highest-leverage first move, with three deeper c11 integrations queued
behind it if Crabbox proves durable: **lease as a sidebar object**,
**crabbox surface type**, and **snapshot/restore lease binding**. Details
below.

---

## What Crabbox actually is

In Crabbox's own words: *"A short-lived box for every run. Warm a box, sync
the diff, run the suite."* The longer self-description: *"A shared agent
workspace control plane for software maintainers and AI agents."*

Distilled to one paragraph: **A Go CLI on the operator's laptop plus a
Cloudflare Worker broker.** The CLI is named `crabbox`. You run
`crabbox warmup` and get a fresh Linux VM from your choice of ~22
providers (Hetzner, AWS, Azure, GCP, Hetzner microVMs called Sprites, E2B,
Modal, Daytona, Cloudflare Containers, RunPod, plain SSH to a static host,
local Docker, …). The VM gets a cute slug like `blue-lobster`. From then
on `crabbox run --id blue-lobster -- pnpm test` rsyncs your current dirty
checkout to the box and runs the command, streaming output back. Local
edit-save-run loop, cloud-grade compute. When you're done,
`crabbox stop blue-lobster` and the lease is released. The Worker brokers
provider credentials so the agent and the laptop never hold them; the
laptop mints a fresh ed25519 keypair per lease and the box only sees that
one key.

That's the whole product. Everything else — capsules, sprites, browser
portal, desktop input, capability flags — is variations and accessories on
that core loop.

---

## The architecture in one diagram

From `how-it-works.html`, verbatim:

```
┌──────────────────────┐   HTTPS / JSON   ┌──────────────────────┐
│ your laptop          │ ───────────────► │ Cloudflare Worker    │
│ crabbox CLI          │  bearer + owner  │ Fleet Durable Object │
│ repo checkout        │                  │ provider creds       │
│ per-lease SSH key    │                  │ lease + usage state  │
└──────────┬───────────┘                  └──────────┬───────────┘
           │                                         │ provider API
           │                                         ▼
           │                          ┌──────────────────────────────┐
           │ SSH (primary + fallback) │ Hetzner Cloud / AWS EC2      │
           └────────── rsync ────────►│ Ubuntu runner                │
                                      │ /work/crabbox/<lease>/<repo> │
                                      └──────────────────────────────┘
```

Two things to notice about this diagram, because they're the whole game:

1. **The data plane bypasses the broker.** SSH and rsync go laptop → VM
   directly. The broker only ever sees control-plane JSON. The broker
   can't read your code, your env vars, or your test output, and it can't
   become a performance bottleneck for a large checkout.
2. **The runner holds zero broker credentials.** From the architecture
   docs, verbatim: *"Runners hold no broker credentials — they are leaf
   nodes."* The runner can SSH-receive your checkout and run a command;
   it can't reach back into the control plane.

These two choices together mean: a compromised box can leak whatever code
you happen to be running on it (which is on you to keep small) but cannot
escalate to the rest of your fleet, the broker, or your other leases.
That's a serious security model, casually expressed.

---

## What's clever in the design

Beyond the broker/leaf split, half a dozen choices struck me as worth
naming explicitly. They're the kind of details that distinguish "someone
who has run agents in production" from "someone who has shipped a sandbox
SDK."

- **Per-lease ed25519 keys, minted on the laptop, never reused, deleted
  on release.** Trust radius is exactly one VM, dies with the VM.

- **Fingerprint-skip rsync.** Crabbox hashes (commit SHA + dirty-file
  metadata + manifest) and compares against the remote fingerprint. If
  unchanged, the rsync is skipped entirely. Re-running a test against a
  warm box pays roughly local-network latency. This is the technical
  trick behind the "feels local" claim.

- **A `crabbox-ready` marker instead of probing services.** Avoids the
  "SSH responds but cloud-init isn't done" race. Small, but the kind of
  detail that gets sprinkled across half a year of operator pain.

- **Crustacean slugs.** Lease IDs are `cbx_8f2`; the friendly handle is
  `blue-lobster`, `swift-hermit`, etc. Deterministic from the lease ID,
  not random. Operator-readable in logs and PR comments without losing
  the canonical handle.

- **Spend caps live in the Durable Object.** At lease creation the broker
  reserves worst-case TTL cost (`hourlyRate × ttl`) against a monthly USD
  cap; freed on release. AWS Spot pricing is fetched live. The CLI never
  sees provider pricing — it lives entirely in the Worker. The doctor
  command checks AWS quota pressure before recommending a class.

- **Capsules are not snapshots.** They are *"local-first failure replay
  manifests"* — explicitly recipes for reproducing a CI failure, not
  preserved machine state. `crabbox capsule from-actions <url>` →
  `crabbox capsule replay <yaml>`. Turns a flaky CI job into a portable
  local-on-cloud reproducible. Most CI products don't articulate this as
  its own primitive.

- **22 providers behind one CLI, registered by blank import.** New
  providers add one line to `internal/providers/all/all.go`. No central
  switch statement, no `if provider == "aws"` branches in core. Two clean
  backend interfaces — `SSHLeaseBackend` (Crabbox owns sync/run) and
  `DelegatedRunBackend` (provider owns transport) — and the run path type-
  switches once to pick the right path. This is exactly the abstraction
  shape that lets the project grow without rotting.

- **The OpenClaw plugin is a 459-line zero-dependency Node shim.** It
  shells out to the `crabbox` binary, captures bounded stdout/stderr,
  enforces a 30-minute wrapper timeout, and returns formatted text. No
  wrapping, no proxying, no clever IPC. The plugin contract is
  deliberately narrow (5 lifecycle tools: `crabbox_run`, `warmup`,
  `status`, `list`, `stop`); run inspection (`history`, `events`,
  `attach`, `logs`, `results`) is pushed to the agent's shell capability.

If you want to know the author's taste in one place, that plugin shim is
where to look. It's the same instinct that produces good c11 commands.

---

## What your friend probably saw in it

The narrative shape underneath Crabbox is the same shape we've been
articulating for c11:

- **The operator's local editor loop is sacred.** Don't move them to a
  browser IDE, don't make them push a commit before testing, don't ask
  them to wait for a CI queue. Keep the dirty checkout in place. Move the
  *compute* off the laptop, not the operator.

- **One command should be enough.** `crabbox run -- pnpm test`. There is
  no "configure your YAML, set up a workflow, register a runner." Sane
  defaults, brokered creds, automatic sync. The cognitive surface of the
  product is tiny.

- **Agents are first-class users, not an integration target.** The init
  command writes `.agents/skills/crabbox/SKILL.md` automatically. The
  repo root is itself an agent plugin. The CLI surface is shaped for
  programmatic invocation as much as for humans.

- **The substrate is plural.** Crabbox doesn't pick a sandbox vendor for
  you. It abstracts over the entire current market (E2B, Modal, Daytona,
  Sprites, Cloudflare Containers, plain Hetzner VMs, even your own static
  SSH host) and lets the operator pick. This is the same instinct as c11
  supporting Claude Code, Codex, Kimi, opencode etc. via `set-agent
  --type` rather than committing to one.

- **Cost is a first-order concern, not a footnote.** The `usage` command,
  the spend caps, the Spot pricing integration, the per-lease cost
  estimation — all baked in. Crabbox respects that you're paying real
  money for these boxes.

- **Evidence is plural too.** Capsules, JUnit captures, telemetry samples,
  artifact globs, video/GIF/screenshot pipelines, `crabbox results` for
  durable run inspection. Same pattern as c11's sidebar telemetry and
  Lattice's artifact discipline: instrument the loop, not the model.

The contributors point in the same direction. **Peter Steinberger**
(steipete, 409 commits, the primary author) writes extensively on
agentic engineering — "Claude Code is My Computer," "Just Talk To It,"
"Slot Machines for Programmers," "My Current AI Dev Workflow." His blog
through 2025 is the closest external articulation of the worldview Stage
11 has been building under. Crabbox is the productized form of the
"remote compute leg" of that workflow.

Your friend with high taste pointed you at this because **the design
sensibilities are sympatico with ours**. It's not the same product —
Crabbox solves "lease a remote box from one command," c11 solves "compose
many surfaces and many agents in one window" — but the values stack up
identically: operator-centric, one-command surface, agents first-class,
substrate-pluralist, evidence-rich, cost-aware, local-first wherever
possible.

---

## How to easily start using it

### Today, standalone

```bash
brew install openclaw/tap/crabbox
cd <some-repo>
crabbox init        # writes .crabbox.yaml, .github/workflows/crabbox.yml,
                    # .agents/skills/crabbox/SKILL.md
crabbox login       # GitHub OAuth → broker token in ~/.config/crabbox/
crabbox doctor      # local tool check + broker reachability + provider readiness
```

Then the canonical loop:

```bash
crabbox warmup --provider hetzner --class standard       # → blue-lobster
crabbox run --id blue-lobster -- pnpm test
crabbox run --id blue-lobster -- pnpm test:e2e            # warm; rsync is a no-op
crabbox stop blue-lobster
```

### The hurdle to know about up front

The hosted broker at `crabbox.openclaw.ai` is **restricted to trusted
OpenClaw maintainers.** If you `crabbox login` and it complains about org
membership, your three options are:

1. **Direct-provider mode** — point Crabbox at your own Hetzner / AWS /
   Azure / GCP / etc. credentials and skip the hosted broker. The provider
   call goes straight from your laptop. This is the realistic path for
   personal/Stage-11 use.

2. **Self-host the Worker** — the broker source lives in `worker/` in the
   repo with `wrangler.toml`. Spin up your own Cloudflare Worker + Durable
   Object, point your CLI at it via `crabbox config set-broker`. ~10
   minutes of Cloudflare work, gives you the full multi-user/spend-cap
   model.

3. **Ask to be added** — peter@openclaw.ai is the contact.

For first-time exploration I'd recommend **(1) direct-provider mode with
Hetzner**. Hetzner is the cheapest of the brokered providers, the CX31 /
CCX13 classes are plenty for most test suites, and you can get a feel for
the loop without spinning up Cloudflare infrastructure. Move to
self-hosted broker later if the spend-cap and multi-user features start
to matter.

### Inside c11, today, with no integration work

```bash
# In a dedicated pane:
c11 rename-tab "🦀 blue-lobster"
c11 set-description "Hetzner CX31, idle 30m, last cmd: pnpm test"
crabbox warmup --provider hetzner --class standard --slug feature-x
crabbox run --id feature-x -- pnpm test
```

The pane title becomes the lease handle, the description carries the
context, and any agent watching the workspace can see at a glance what's
warm and what it's doing. This is "the c11 skill applied to a `crabbox`
command" with zero infrastructure work — just convention.

For an agent in c11 calling Crabbox from its own pane, the same pattern
works: agent runs `crabbox warmup`, captures the slug, writes it to its
own metadata via `c11 set-metadata --key crabbox.lease --value
<slug>`, the sidebar starts showing it. No code changes anywhere.

---

## Surveying the field — is Crabbox the right bet?

Before committing, I mapped the landscape carefully. The headline finding:
**the slot Crabbox sits in is genuinely sparse.** Only one other tool
matches the shape, and Crabbox already wraps it as a provider.

### The three-layer mental map

To see why the slot is sparse, split the field into three layers:

- **Layer A — sandbox SDKs / raw compute primitives.** E2B, Modal
  Sandboxes, Vercel Sandbox, Cloudflare Sandbox SDK, Fly Machines /
  Sprites, Hopx, Tensorlake, Northflank Sandboxes, Runloop, Daytona's
  SDK, Cased's `sandboxes` library. Programmatic `Sandbox.create() →
  exec()` interfaces. Most assume the caller lives in the cloud already
  and is invoking the SDK from server code, not from a developer's
  laptop.

- **Layer B — cloud development environments.** Coder, Ona (formerly
  Gitpod), DevPod, GitHub Codespaces, Namespace Devbox, JetBrains Space,
  Microsoft Dev Box, Replit. Persistent workspaces in the cloud with an
  IDE attached. The loop is "open the workspace, edit *inside* it." Not
  designed for "edit locally, run remotely once, throw away."

- **Layer C — local sandboxes for the agent process itself.** Anthropic
  Sandbox Runtime (`srt`), Claude Code's `sandbox-utils`, ClaudeBox,
  packnplay, the dozens of bubblewrap/seatbelt/landlock wrappers in the
  Wincent gist. Keep the agent contained on your laptop.

**Crabbox occupies the thin middle band that none of these owns
cleanly:** keep your editor and git workflow exactly where they are
(Layer C's win) but push the actual `pytest` / `cargo build` / `npm test`
to *real* remote capacity (Layer A's win) without becoming a workspace-
shaped lock-in (Layer B's failure mode). The bridge is rsync-the-dirty-
checkout-to-a-leased-box-and-release. Almost nothing else has the same
four-property combination: thin CLI invoked from local dev, brokered
credentials, genuinely multi-provider, ephemeral lease lifecycle with
spend caps.

### The competitive map, ordered by closeness

| Tool | Layer | Slot fit | Substrate | Sync model | Notable vs Crabbox |
|---|---|---|---|---|---|
| **Blacksmith Testbox** | Middle | **Direct hit** | Blacksmith microVMs only | Rsync-style incremental | Same `warmup → run → sync diff` shape. Single-provider. Tied to your Blacksmith GHA workflow for hydration. **Crabbox wraps it as a provider.** |
| **Daytona (with roadmapped `sandbox sync`)** | Layer A creeping into middle | **Plausibly close, not shipped** | Daytona cloud (self-hostable) | Live file sync on roadmap (issue #3309) | Will get close on a single substrate when shipped. Loses pluralism + broker. Funded team. |
| **Cased Sandboxes** | Layer A abstraction | Same pluralism instinct, opposite architecture | 7 providers (E2B/Modal/Daytona/Hopx/Vercel/Sprites/Cloudflare) | SDK upload/download | Client-side pluralism, no broker, library not CLI. Different audience (app authors, not maintainers). |
| **DevPod** | Layer B | Same BYO-cloud pluralism instinct | AWS/Azure/GCP/K8s/SSH/Docker | IDE attaches; you edit inside | Workspace shape, not run shape. Loft Labs OSS. |
| **Depot Remote Agent Sandboxes** | Middle | Adjacent | Depot only | Git-based, persists | Hosts the *whole agent session* in the cloud. Crabbox keeps the agent local and dispatches runs. |
| **E2B / Modal / Vercel Sandbox / Cloudflare Sandbox SDK / Fly Machines** | Layer A | Substrate, not slot | Each one its own | SDK | Each is one of Crabbox's ~22 providers. Standalone they're SDK primitives, not maintainer CLIs. |
| **Namespace Devbox** | Layer B | Adjacent | Namespace | Persistent | Crabbox lists it as a provider. Standalone it's a managed workspace, not an ephemeral runner. |
| **Coder / Ona / Codespaces / Microsoft Dev Box** | Layer B | Different slot | Each | IDE-attached, persistent | Cloud workspace shape. Optimization is "the agent lives in our env, we govern it." |
| **Sketch / Shelley (exe.dev)** | Different | Different slot | Local Docker / exe.dev VMs | The product *is* the agent | Vertically integrated agents. Complementary in principle (you could run Shelley on a Crabbox lease), not competitive. |
| **Mutagen** | Primitive | Substrate, not slot | Anywhere with SSH | The *sync engine* underneath | You could build half of Crabbox on Mutagen + flyctl + a shell script. You'd lose the broker, capsules, spend caps, pluralism. |

### What's actually rare about Crabbox

The combination of:
1. Brokered provider credentials in a Cloudflare Worker (so neither the
   laptop nor the leased VM holds AWS/Hetzner keys),
2. Genuine pluralism over *both* raw cloud (Hetzner, AWS, Azure, GCP,
   Proxmox, static SSH) *and* delegated sandbox SDKs (E2B, Modal,
   Daytona, Cloudflare, Tensorlake, Sprites, …),
3. Ephemeral per-run lease lifecycle with spend caps in the Durable
   Object,
4. A thin CLI that agents can call directly,

…is, as far as this survey could establish, not duplicated anywhere. The
field has Layer A primitives in abundance and Layer B workspaces in
abundance, but the middle-band broker-CLI shape is a one-tool slot today.

### What's fragile about Crabbox (sharper after the survey)

- **Single-maintainer, very new.** Created 2026-04-30, ~25 days old at
  v0.19.0. Peter Steinberger (PSPDFKit founder, prolific 2025 agentic-
  engineering writer) + Vincent Koc account for ~750 of ~860 commits.
  Bus factor is two. If Steinberger pivots, the brokered Worker at
  `crabbox.openclaw.ai` and the integration matrix it enables are
  exposed.
- **The brokered Worker is a single point of failure.** If the hosted
  Worker goes dark, brokered-cloud providers (Hetzner/AWS/Azure/GCP)
  become unusable until someone forks and stands up their own. Delegated
  providers (E2B, Daytona, Blacksmith Testbox) degrade more gracefully
  because Crabbox is a thin shim there.
- **The provider matrix is wide but uneven.** "22 providers" is real but
  for any given one there will be feature gaps, untested edges, churn.
  For delegated providers, Crabbox's actual value-add is local ergonomics
  (slugs, claims, timing) rather than core functionality — you might
  reasonably reach for the provider's own CLI directly.
- **Brokered creds = trust transfer.** Putting your Hetzner/AWS keys in
  someone else's Worker DO means trusting their custody, audit, and
  durability. Crabbox is open-source, so self-hosting the Worker is an
  out — but you lose the network-effect benefit and add operational
  burden.
- **Provenance noise.** Several of the survey's web searches surfaced
  fabricated-sounding claims about Steinberger and the OpenClaw cluster
  (alleged OpenAI affiliation, Wikipedia entries that don't exist,
  TechCrunch/Fortune coverage with Sam Altman / Zuckerberg references).
  None of those check out against Steinberger's primary surfaces
  (steipete.me, his GitHub). Not a strike against the tool, but the
  noise itself signals the provenance story isn't yet stable in
  trustworthy sources. Worth weighting cautiously when reading anything
  *about* Crabbox secondhand.

### Credible alternatives, ranked

1. **Blacksmith Testbox** — closest direct fit; loses pluralism, gains a
   funded team behind one substrate. If we don't need multi-provider
   and were already considering Blacksmith for CI, Testbox is the
   single-vendor answer. (Note: Stage 11 isn't on Blacksmith CI today,
   so adopting Testbox means adopting Blacksmith.)
2. **Daytona once `sandbox sync` ships** — most likely contender to
   absorb the slot from a Layer A start. Still single-substrate, no
   broker. Wait-and-watch.
3. **DIY on Mutagen + Fly Machines (or similar)** — a senior infra
   engineer could write the Crabbox loop themselves in a weekend for any
   *single* substrate. Lose capsules, multi-provider, broker, spend
   caps. Gain full control and zero external dependency.
4. **DevPod** — if we actually wanted the workspace shape rather than
   the run shape. Different optimization; closest "open-source, BYO
   cloud, pluralist" project in the broader landscape.
5. **Cased Sandboxes** — if we were building this *into our own
   application* rather than calling it from a CLI/agent context.
   Library-shaped pluralism.

### Net read

The slot is real. The architectural choice (broker that doesn't see your
code, per-lease keys, multi-provider) is sharp. Nothing else has this
exact shape today. That makes Crabbox a worthwhile bet for a **defined
pilot**, but it isn't yet a "commit the whole org's CI story to it" bet.

The honest middle path: **build the dependency at the level where the
failure mode is acceptable, and watch how the project matures over the
next ~90 days.** Specifically:

- Ship the generic `crabbox` skill (Tier 0 below) — risk-free, lives
  forever regardless of what we choose.
- Pilot the brokered-cloud path on a non-critical AWS or Hetzner sub-
  account. Verify the broker actually works for our provider, that spend
  caps fire, that lease ID churn doesn't break the iteration loop.
- Pilot a delegated-provider path (E2B or Blacksmith Testbox) and
  *measure* how much of Crabbox's value-add is real vs "I could have
  just used the provider's CLI."
- Test the failure mode: what happens when the Cloudflare Worker is
  unreachable? When a lease leaks? When the broker DB loses fleet
  state? A 25-day-old single-maintainer tool with a centralized broker
  needs a satisfying answer to "what do we do at 3am when it falls
  over."

If those pilots come back clean, deepen toward the Tier 1-2 c11
integrations. If they expose real cracks, the DIY-on-Mutagen path is
always available and the work on the skill isn't wasted (the skill
content covers the broader category, not just Crabbox).

---

## What c11 could do to support Crabbox, graded by ambition

I'll order these from "free, do this week" to "real engineering, do if
Crabbox proves durable."

### Tier 0 — convention only, ship this week

**A generic `crabbox` skill.** Not c11-specific. Same shape as the
existing `claude-api` skill: portable, harness-agnostic, lives in user-
scope skills so any agent (in c11 or not, Claude Code or Codex or
opencode or anywhere skills get loaded) picks it up automatically.

The skill teaches Crabbox itself:

- When to reach for it (heavy test suite, agent sandbox, parallel
  scenario runs, anything that would tie up the laptop for >2 min).
- The canonical lifecycle (`warmup → run --id <slug> → stop`).
- The provider-selection cheat sheet (Hetzner for cheapest Linux,
  Blacksmith Testbox if you're already on Blacksmith CI, E2B for fast
  ephemeral microVM SDK semantics, Modal for GPU, static SSH for a box
  you own).
- The credential/broker decision (direct-provider vs hosted vs
  self-hosted Worker) and what to pick when.
- The `.crabbox.yaml` shape and `crabbox init` first-run flow.
- Cost discipline (TTL and idle-timeout defaults, when to set
  `CRABBOX_MAX_MONTHLY_USD`).
- The `--fresh-pr`, `--script`, capsule, and artifact patterns.
- Failure-mode triage (what to do when a lease leaks, the broker is
  unreachable, a provider rejects the request).

**c11-specific patterns stay out of this skill.** How an operator in c11
happens to title a pane after a lease slug, or surface lease state in the
sidebar via `c11 set-metadata`, is c11-side practice. The c11 skill can
gain a one-liner: "for remote compute, see the `crabbox` skill." But the
crabbox skill itself doesn't know c11 exists, and that's the point —
it's equally useful to an agent running in a bare shell, in Codex Cloud,
or in someone else's harness.

Zero code changes anywhere. Pure agent education. Highest-leverage move
because the skill compounds across every harness the operator (or any
collaborator) uses, not just c11.

### Tier 1 — small protocol additions

**Canonical metadata keys for leases.** Today the surface manifest
already supports arbitrary keys; the canonical ones (`role`, `status`,
`task`, `progress`) get sidebar rendering. Add `crabbox.lease` (string),
`crabbox.provider` (string), `crabbox.expires_at` (number, unix
timestamp), `crabbox.cost_hourly_usd` (number). Sidebar rendering
displays the slug as a small chip with a countdown when present. Doesn't
require Crabbox-specific code — just a few canonical keys with renderers
in the existing metadata system.

**Snapshot/restore lease binding.** When `c11 snapshot` runs on a
workspace containing a Crabbox-bound pane, include the lease slug in the
snapshot. On `c11 restore`, if `C11_SESSION_RESUME=1`, attempt
`crabbox warmup --id <slug> --reclaim` (Crabbox is built for exactly this
case). If the slug is expired or stopped, restore as a plain terminal
pane with a placeholder. This makes leases survive c11 restarts the way
Claude Code sessions already do.

### Tier 2 — first-class surface type

**`c11 new-pane --type crabbox-lease --slug <slug>`** (and corresponding
`new-surface`). A new surface type that wraps an SSH connection to a
Crabbox lease and carries the lease binding in its manifest. The title
bar shows the slug + provider + idle countdown automatically. Closing the
surface optionally calls `crabbox stop`. The pane survives snapshot/
restore via the binding in Tier 1.

This is where Crabbox stops being "a CLI you happen to run in a c11 pane"
and starts being "an addressable substrate inside c11."

**A "Boxes" section in the sidebar** alongside the current Workspaces
list. Shows live leases for the current operator (`crabbox list --json`
polled every N seconds, or pushed by the broker). Each row: slug,
provider, idle countdown, current $/h, currently-running command. Click
to focus the corresponding `crabbox-lease` surface, or to open a new one
SSH'd in.

### Tier 3 — fleet awareness

**Cost telemetry in the workspace footer.** "$0.42 this session, 3 leases
active, monthly cap 23%." Trivially small in display real estate; a
single field-of-view for "what is my orchestra costing me right now."
Flash signal when the cap is about to bite. Reads from `crabbox usage
--json --scope user` periodically.

**Lease-as-mailbox-recipient.** This is forward-looking. c11's mailbox
primitive resolves recipients by surface name. If a Crabbox lease ran a
small c11 bridge process (one extra binary, registered in the broker as a
"c11-aware lease"), the lease could appear in the c11 mailbox namespace.
An agent could fan out: send the same envelope to three sibling leases
("run this scenario suite against your dependency-tree variant") and
read replies as they come back, no shell-glue required. The architecture
is symmetric to how c11 already coordinates local sub-agents.

This is the most ambitious item and the one most contingent on Crabbox
durability. Worth designing only once Crabbox is past v1.0 and the
operator is actually running 5+ leases in parallel routinely.

### Tier 4 — speculative

**Capsule surface type.** A first-class viewer for Crabbox capsule YAML
files: shows recipe + evidence inline, with a "Replay" button that spawns
a fresh pane running `crabbox capsule replay`. Live-streams the output.
Probably premature; revisit after Crabbox 1.0 if capsules see genuine
operator adoption.

---

## The relationship to think about

c11 and Crabbox are **orthogonal halves of the same operator-centric
worldview**:

| | c11 | Crabbox |
|---|---|---|
| Substrate | The operator's laptop | The cloud |
| Atom | Surface (pane, browser, markdown) | Lease (a VM with a slug) |
| Reach | Local, addressable | Remote, addressable |
| Coordination | Mailbox, sidebar telemetry, lineage chains | Broker + Durable Object |
| Persistence | Workspace snapshot/restore | Stable slugs + `--reclaim` |
| Credentials | None held; per-surface env | Broker holds; laptop and lease never |
| Cost model | Free | Per-hour cloud spend, capped |
| Pluralist substrate | Multiple agent types (Claude/Codex/Kimi/…) | Multiple providers (~22) |
| Operator metaphor | A room | A fleet |

You'd use both for any non-trivial agentic work: c11 is the room with the
panes, the markdown surfaces, the browser pane, the orchestrator, the
sub-agent delegators, the operator's attention; Crabbox is the cloud
appliance that any agent in any pane can call into when the work outgrows
the laptop. They never compete for the same job, and the seams between
them are clean.

The one place where they *do* converge conceptually is **sub-agent
spawning under load**. Today, c11's lattice-orchestrator pattern says
"one delegator per ticket in its own git worktree." If the test suite for
that worktree is heavy (Stage 11 deployments increasingly involve real
infrastructure), the natural next step is "one delegator per worktree +
one Crabbox lease pinned to that worktree." The delegator edits code
locally in the worktree, dispatches runs against the lease, reads
results, iterates. The pairing is so natural it's worth calling out in
the lattice-orchestrator skill itself once Crabbox is past v1.0.

---

## Caveats worth knowing before betting on it

- **Project is 26 days old.** v0.19.0 with 22 releases in 26 days
  (one minor every 1–2 days). Genuinely impressive cadence; also means
  the API surface is still being shaped. Pin to a specific Crabbox
  version in any production-adjacent use.

- **Two-person bus factor.** Steinberger (409 commits) + Vincent Koc
  (342) account for ~750 of ~860 commits. The remaining commits are
  drive-by. If either author steps away, the project's velocity drops
  hard. Worth factoring into a long-term bet.

- **Hosted broker access is gated** to OpenClaw-trusted maintainers.
  Direct-provider mode and self-hosted broker are real fallbacks but
  shouldn't be glossed over. Plan around being on a fallback for at
  least the medium term.

- **Delegated providers vary wildly in capability.** SSH-based providers
  (Hetzner, AWS, Azure, GCP, Proxmox, static SSH, local Docker) get the
  full feature surface: `--script`, `--fresh-pr`, captures, downloads,
  `--full-resync`. Delegated providers (E2B, Modal, Daytona, Cloudflare
  Containers, Islo, Upstash, Tensorlake, RunPod, W&B, Railway) reject
  most of these because the provider owns command transport. Pick your
  provider for the workflow, not the other way around.

- **Documentation drift.** *Coordinator*, *Orchestrator*, and *Broker*
  are used somewhat interchangeably across docs pages for the same
  Cloudflare Worker + Durable Object. Minor but real signal that the
  docs are being written in flight.

- **Native Windows + macOS lease paths are newer and rougher.** The
  CHANGELOG is dominated by Windows desktop-environment fixes in recent
  releases. If your workflow needs Windows test boxes, expect to file
  issues. Linux is the well-trod path.

- **Don't conflate Crabbox with OpenClaw the agent.** Steinberger has
  publicly said *"crabbox and openclaw is not really related, don't get
  the question."* Crabbox lives in the openclaw org for organizational
  reasons, but it's a generic remote-execution tool, not an extension of
  the openclaw assistant. The plugin shape is a convenience for openclaw
  users, not a coupling.

- **Cost-cap-respect is on you.** The broker enforces per-lease and
  per-org monthly caps. Direct-provider mode (no broker) doesn't have
  this guardrail; you're on the hook for paying attention to your
  Hetzner / AWS bill. Set conservative `--ttl` and `--idle-timeout`
  values until you've calibrated.

---

## What I'd actually do this week, if it were me

Reordered after the survey to lead with the lowest-risk, highest-leverage
moves.

1. **Write the generic `crabbox` skill** (Tier 0 above). One markdown
   file in user-scope skills (`~/.claude/skills/crabbox/SKILL.md`) or
   wherever portable skills live for Stage 11. ~1 hour of writing.
   Harness-agnostic. Useful regardless of whether we end up running
   Crabbox heavily, lightly, or eventually swap it for Daytona's loop
   when it ships. Cost: ~1 hour. Value: durable.

2. **Install on Hyperion**, `crabbox init` in a small repo, get the
   loop working with **Hetzner direct-provider mode** (skip the hosted
   broker initially — fastest way to a working loop without the trust-
   transfer question). ~20 min. You'll know if the loop feels right
   within five runs.

3. **Pick one real Stage 11 workload** that currently runs locally and
   is either slow or contention-heavy — the obvious candidates are c11
   unit tests in the host-required scheme, or a Lattice dashboard
   rebuild under load. Wire it up to `crabbox run --id <slug> -- <cmd>`
   and measure the operator-attention cost cut.

4. **Run the survey's three pilot checks.** Specifically: (a) confirm
   spend caps actually fire on your direct-provider account; (b) try a
   delegated provider (E2B or Blacksmith Testbox) and measure how much
   value Crabbox adds *over* using that provider's own CLI; (c) simulate
   the broker being unreachable and check the failure path. This is
   what tells you whether the 25-day-old single-maintainer dependency
   is acceptable at the level you'd use it.

5. **Decide on hosted vs self-hosted vs direct-provider broker.** If
   multi-user spend caps matter for the Stage 11 ops board, stand up
   the Worker yourself on Cloudflare — we already have credentials in
   `code/platform/cloudflare.md`. If single-user direct-provider is
   enough for now, stay there and revisit when collaborators want in.

6. **Park Tiers 1-3 of the c11 integration.** Watch Crabbox for 60-90
   days. If cadence holds and a real community forms, design the
   first-class surface type and snapshot/restore binding. If it plateaus
   or Steinberger pivots, you've lost nothing — the generic `crabbox`
   skill still works against the surviving subset of providers, and the
   Mutagen + Fly Machines DIY fallback is always available.

The friend who recommended this has good taste, and the survey backs
that taste up: nothing else hits this exact slot today. Worth the ~2
hours of total skill + pilot work. The deeper c11 integration moves can
wait for evidence that Crabbox is the durable answer in this space and
not just the well-designed early entrant.

---

## Sources (primary, high confidence)

- https://crabbox.sh/ — full docs site
- https://crabbox.sh/architecture.html
- https://crabbox.sh/how-it-works.html
- https://crabbox.sh/features/openclaw-plugin.html
- https://crabbox.sh/features/capsules.html
- https://crabbox.sh/features/cost-usage.html
- https://crabbox.sh/security.html
- https://github.com/openclaw/crabbox (Go 68.6% + TS 24.3%, MIT, v0.19.0)
- README, AGENTS.md, docs/concepts.md, docs/architecture.md
- `cmd/crabbox/main.go`, `internal/cli/app.go`, `internal/cli/run.go`,
  `internal/providers/all/all.go`, `worker/src/index.ts`
- https://github.com/openclaw — org page
- https://steipete.me — author's blog (2025 agentic-engineering arc)
- https://x.com/steipete — release announcements
