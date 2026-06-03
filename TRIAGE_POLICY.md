# Triage Policy — Drawbridge

This file is the ground truth for c11's autonomous inbound pipeline (Drawbridge). The
judge reads the prose on every run; the deterministic gates read the machine config
block at the bottom. Tune the pipeline by editing this file — not the workflow code.

Spec: [Drawbridge 0.01.000](https://github.com/Stage-11-Agentics) (instantiation #1).
Maintainer interview conducted 2026-06-03 with Atin Woodard.

## Mission

c11 is a native macOS terminal multiplexer for the operator:agent pair — terminals,
browsers, and markdown surfaces composed in one window, addressable and scriptable, so
one operator can keep many parallel agents legible. Fork lineage: tmux → cmux
(manaflow-ai) → c11; we pull upstream fixes and offer ours back.

**Clearly wanted:** bug fixes (esp. typing latency, rendering, socket/CLI correctness),
performance work, localization syncs, docs improvements, CLI/socket ergonomics,
agent-facing primitives (skills, telemetry, surfaces), upstream-compatible fixes.

**Out of scope even if well-made:**

- Anything that writes to users' tenant config (`~/.claude`, `~/.codex`, shell rc) —
  the "unopinionated about the terminal" principle. `c11 install <tui>` proposals are
  permanently rejected.
- App-level display links / manual draw loops (typing-latency).
- Gratuitous divergence from upstream cmux on shared code paths.
- Features that only make sense outside the operator:agent framing.

## Autonomous scope

Three categories may ever merge without a human, **always** subject to every
deterministic gate (CI green, size cap, allowlist, deny list, trust tier):

1. **Docs** — `docs/**`, `notes/**`, root-level `*.md`.
2. **Localization** — `Resources/Localizable.xcstrings` only (translation syncs for the
   six shipped locales).
3. **Bug fixes** — source changes that resolve a real, identifiable defect. Feature
   work, refactors, and "improvements" are not bug fixes and always escalate. The
   judge classifies; the gates bound.

**Deny list (always escalates, regardless of verdict or author):** workflows and CI
(`.github/**`), release/build tooling (`scripts/**`), session-resume wrappers
(`Resources/bin/**`), signing and app metadata (`Resources/Info.plist`,
`*.entitlements`), the Xcode project (`*.pbxproj`, `GhosttyTabs.xcodeproj/**`),
submodules and vendored code (`ghostty`, `vendor/**`, `.gitmodules`), package
manifests (`Package.swift`, `Package.resolved`, lockfiles), the release skill
(`skills/release/**`), agent-instruction markdown (`CLAUDE.md`, `AGENTS.md` at any
depth — these are executable instructions for agents, not prose, and they ride the
CI path-ignore), and this policy file itself.

## Trust tiers

- **Org members** (`OWNER` / `MEMBER` / `COLLABORATOR`): full autonomous scope — docs,
  localization, bug fixes.
- **Previous contributors** (`CONTRIBUTOR` — at least one merged PR here): autonomous-
  eligible for bug fixes and docs only.
- **First-time contributors and everyone else:** never autonomous, regardless of
  verdict. (Spec MUST.) Their work routes to deep review with a warm, substantive
  response.

## Size cap

Autonomous lane: **≤ 500 changed lines (additions + deletions) and ≤ 20 files.**
Anything larger escalates no matter how clean it looks.

## Additional deterministic gates

- **Required CI checks.** For any diff touching paths CI runs on, the checks named in
  `required_checks` below must each conclude `success` — a `skipped` required check
  (e.g. the paid-runner fork guard skipping the app build on fork PRs) is not green.
  Docs-tier diffs (entirely within `ci_ignored_paths`) are exempt.
- **Judged head must be current.** The verdict is bound to the head SHA the judge saw;
  if the head moved by gate time, the lane fails and the new head is re-judged.
- **Regular files only.** The autonomous lane may not introduce symlinks or
  gitlinks/submodules, verified against the head tree.
- **Deny matching is case-insensitive** (`docs/claude.md` hits `**/CLAUDE.md`);
  allowlist matching stays case-sensitive, so odd-cased paths escalate.

## Notification channels

1. **Zulip** (primary): channel `c11`, topic `drawbridge`, posted by the bot
   account. Token lives in the `ZULIP_BOT_API_KEY` repo secret — never in files.
2. Email: deliberately not wired yet. Add a channel by extending
   `scripts/drawbridge/notify.sh` and documenting it here.

## Tone

Warm by default — the bot represents the project. Thank contributors genuinely,
explain verdicts plainly, never condescend. Declines come with a reason and, where
real, a pointer to what WOULD be accepted. No corporate boilerplate.

## Mode: dry-run → live

The pipeline ships in **dry-run**: the autonomous lane computes its full decision but
posts `WOULD AUTO-MERGE` instead of acting, and pings the maintainer.

**To flip live** (maintainer-only action): change `"mode": "dry-run"` to
`"mode": "live"` in the config block below, in a commit to `main`. Per the graduation
protocol, audit 1–2 weeks of would-act decisions first, then go live for the narrowest
scope (drop categories from the tier lists below to narrow further), widening
path-by-path as trust accrues. False positives are policy edits, not code edits.

### Operational notes (live mode)

- Auto-merges are pinned to the exact head SHA the gates evaluated
  (`--match-head-commit`); a push racing the merge fails it cleanly and the new
  head is re-judged.
- Merges are performed with the workflow's `GITHUB_TOKEN`, which does not cascade
  events — post-merge `main` CI will not run on the squash commit. Accepted: the
  judged head SHA already had fully green CI as a gate.

## Audit trail

Every verdict is uploaded as a workflow artifact (`drawbridge-verdict-*`) on the run,
and every triaged item gets a `drawbridge:<route>` label. The nightly sweep re-triages
unlabeled open items and posts a digest to the Zulip topic.

## Machine config

The deterministic gates parse this block. Glob semantics: `**` matches across path
segments, `*` within one segment; a pattern with no slash and no glob matches that
exact root-level path.

```json drawbridge-config
{
  "mode": "dry-run",
  "size_cap": { "max_changed_lines": 500, "max_changed_files": 20 },
  "deny_paths": [
    ".github/**",
    "scripts/**",
    "Resources/bin/**",
    "Resources/Info.plist",
    "**/*.entitlements",
    "**/*.pbxproj",
    "GhosttyTabs.xcodeproj/**",
    "ghostty",
    "ghostty/**",
    "vendor/**",
    ".gitmodules",
    "Package.swift",
    "**/Package.resolved",
    "**/*.lock",
    "**/bun.lockb",
    "skills/release/**",
    "CLAUDE.md",
    "**/CLAUDE.md",
    "AGENTS.md",
    "**/AGENTS.md",
    "TRIAGE_POLICY.md"
  ],
  "categories": {
    "docs": ["docs/**", "notes/**", "*.md"],
    "localization": ["Resources/Localizable.xcstrings"],
    "bugfix": ["Sources/**", "daemon/**", "web/**", "spec/**", "tests/**", "tests_v2/**", "docs/**", "notes/**", "*.md"]
  },
  "tiers": {
    "org": {
      "associations": ["OWNER", "MEMBER", "COLLABORATOR"],
      "categories": ["docs", "localization", "bugfix"]
    },
    "contributor": {
      "associations": ["CONTRIBUTOR"],
      "categories": ["docs", "bugfix"]
    }
  },
  "ci_ignored_paths": ["**/*.md", "docs/**", "notes/**", "Resources/Localizable.xcstrings"],
  "required_checks": ["workflow-guard-tests", "remote-daemon-tests", "web-typecheck", "build"],
  "zulip": {
    "site": "https://zulip.stage11.ai",
    "channel": "c11",
    "topic": "drawbridge",
    "bot_email": "mcp-bot@zulip.stage11.ai"
  }
}
```
