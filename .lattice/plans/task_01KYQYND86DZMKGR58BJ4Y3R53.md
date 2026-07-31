# C11-185 implementation plan

Rev 2 — reworked per trident plan review (pack:
`.lattice/plans/c11-185-plan-review-pack-2026-07-29T1828/`, verdict:
rework-then-rereview). Architecture from rev 1 is affirmed and unchanged: one
shared projection consumed by tooltip and Surface Details; no renderer
re-infers lifecycle; structured details capture stays out of
`SurfaceMetadataStore`; Bonsplit stays generic; submodule before parent
pointer; terminal state `pr_open`.

## Open decisions (resolve before implementation — see needs-human flag)

- **D1 (from S1): `createdAt` ownership.** Contract architecture item 5 says
  promote to a first-class panel/session property; evolutionary review argues a
  `SurfaceCreationRegistry` mirroring `SurfaceActivityTracker` (4 existing touch
  points, avoids a wide diff through ~10k-line `BrowserPanel.swift`). The
  registry deviates from a locked contract item, so this is an operator/author
  call. Either way `created_at` lands on `SessionPanelSnapshot`.
- **D2 (from S2): tooltip mechanism.** Three candidates, each relaxing a
  different constraint: (a) `.help()` with sync-time string + documented
  staleness bound (relaxes the contract's "refresh on hover entry" line);
  (b) `NSViewRepresentable` owning `NSView.toolTip` via `NSToolTipOwner`
  (literal hover-entry freshness, must prove the owner view is hit-testable —
  note `SafeTooltip.swift`'s recorded lesson: `.help` on the view works, AppKit
  `addToolTip` on an occluded click-through view silently never appears);
  (c) Bonsplit samples `Date()` against a Codable temporal payload at hover.
  Relaxing a contract line needs operator authorization.
- **D3 (from S3): does `stateEnteredAt` persist across restart?** Contract is
  silent. Not-persist: "Working for 3 days" across a reboot is a lie. Persist:
  beside the proven `last_activity_at`, it is what makes the data durable.

## Step 0 — Worktree, ancestry, and submodule gate

- Confirm execution inside the C11-185 worktree; the primary checkout is dirty
  in `Sources/ContentView.swift`, a file this ticket edits — prove the shared
  checkout stays untouched. Record the base commit and verify C11-183/C11-184
  ancestry.
- Provision: `git submodule update --init --recursive ghostty vendor/bonsplit`;
  symlink `GhosttyKit.xcframework` from the main checkout.
- **Bonsplit precondition (it is detached right now):** `cd vendor/bonsplit &&
  git checkout main && git fetch origin && git merge --ff-only origin/main`;
  confirm `git symbolic-ref --short HEAD` prints `main` before the first
  Bonsplit edit.

## Step 1 — Baselines and mapping (unchanged intent)

Map the shared lifecycle/attention projection, panel creation/restore paths,
Surface Details capture, and Bonsplit mark renderer. Recording *when* presented
inference changed (step 2's stamp) is **not** "changing lifecycle inference";
this fence forbids altering what state is derived, not timestamping it.

## Step 2 — Temporal evidence layer (new; the core of the ticket)

- **Timestamp-source matrix** — implement exactly this, one row per presented
  state:
  | Presented state | Start-time source | Fallback |
  |---|---|---|
  | working | `stateEnteredAt` stamp at transition edge | state alone (no duration) |
  | idle | `stateEnteredAt`; reconstruct from tracker `lastActivity` only as fallback | state alone |
  | cold | published crossing `Date` (see below); not "total idle time" | state alone |
  | waiting | oldest currently-unread signal-eligible exact-surface notification `createdAt` | state alone |
  | suppressed-waiting (presented idle) | the **activity** boundary, not the unread timestamp | state alone |
  | flagged (modifier) | existing `flagRaisedAt` if copy includes age | omit age |
  | suppressed (modifier) | none by design | — |
  | no evidence | — | localized state alone; never fabricate `0 minutes` |
- **Stamp `stateEnteredAt`** at the presented-state transition edge (beside the
  existing changed/unchanged branch in `setDerivedActivity`,
  `Workspace.swift:~7160`). `derivedActivityBySurface` is a bare enum and
  `coldAgentSurfaceIds` a bare `Set` — nothing existing supplies this;
  `SurfaceActivityTracker.lastActivity` is a last-touch clock and must never be
  used as a working-state start (one keystroke would reset an idle tooltip to
  the banned `0 minutes`).
- **Cold crossing:** `publishCold` currently discards `observedLastTouchedAt`
  and publishes only a Bool; carry the crossing `Date` to the render site
  (either a published crossing date or the `stateEnteredAt` stamp covering cold
  as a presented state — pick and record which). If reconstructing from the
  live threshold instead, state the Settings-edit behavior deliberately
  (displayed cold duration would jump retroactively).
- **Waiting accessor:** add a bounded, precomputed exact-surface
  waiting-boundary accessor/index on `TerminalNotificationStore` (only
  `hasUnreadNotification` exists today; scanning the published array from a
  renderer violates the perf guardrail). Epoch rule: oldest currently-unread
  signal-eligible exact-surface record, continuous until no qualifying unread
  remains; missing record → no duration.
- **Churn-boundary invariant (hard rule):** only stable `Date?` / enum / Bool
  values cross into `WorkspacePulseAgent` and `BonsplitTabActivityPresentation`;
  localized strings are composed at the leaf. Negative rule: no time-derived or
  formatted field may be added to any type reachable from `TabItemView.==`
  (`ContentView.swift:~11745`) or from the Bonsplit presentation value (it is
  `Codable` and persists into layout).
- **Bulk tracker read:** the precompute takes one
  `SurfaceActivityTracker.snapshot()` per sync and indexes into it — never a
  per-agent `queue.sync` point read from the roster path.
- Pure projection + fixed-clock test matrix land **in this step**, before any
  renderer wiring (see step-test table in Step 6).

## Step 3 — Tooltips (mechanism per D2)

- Name one mechanism per consumer (top-tab mark, sidebar summary mark, sidebar
  census mark) once D2 is resolved, and record per consumer, in one line, the
  constraint relaxed and why acceptable. The chosen set must simultaneously
  satisfy: no per-agent repeating timer; no store read or date formatting in
  `TabItemView` body or `WindowTerminalHostView.hitTest()`; no parent-row
  invalidation on a clock tick; AC5 (tooltip and Surface Details agree at one
  instant).
- **Tooltip owner:** the padded hit area already exists as a fixed-size
  container around the mark in Bonsplit's `TabItemView` (~`:737-775`) — name it
  as the top-tab tooltip owner (no geometry change), and name the equivalent
  owner for each sidebar mark location. The owner must be hit-testable for
  tooltip queries while transparent to click routing — this is an explicit
  requirement with its own verification, not a clause.
- **Scope decision for AC1:** the collapsed/overflow tab mark
  (`TabBarView.swift:~1238`, `collapsedActivityMark`) and the sidebar census
  `+N` chip and its hidden marks are **out of scope**; AC1 is read as "every
  *visible* individual agent mark" (top tab accessory, sidebar summary row,
  expanded census marks). Record this reading on the ticket.
- **Duration formatting:** `DateComponentsFormatter` for the locale-correct
  duration noun phrase, composed into a `String(localized:defaultValue:)`
  sentence template (`RelativeDateTimeFormatter` yields "ago" phrasing — wrong
  shape). Unit ladder and rounding: floor; sub-minute real durations display
  `less than a minute` (distinct from no-evidence, which shows state alone);
  negative/future timestamps fail closed to state-alone. Boundary cases go in
  the step-2 test matrix.

## Step 4 — Surface Details

- Activity/timing facts live on `SurfaceManifestSnapshot` as siblings of
  `metadata`/`sources` — never inside metadata JSON, never on the
  construction-time `handle` (`refresh()` reassigns only `snapshot`, so
  anything on `handle` is structurally unrefreshable). `capture` calls a named
  injectable provider collecting panel `createdAt`, tracker last activity, the
  shared projection, and the waiting evidence; `refresh()` reruns that same
  provider; the provider stays injectable so AC5 is assertable at a fixed `now`
  in a pure test.
- Build the new group from the existing `refRow` / `copyButton` / `copiedField`
  affordances in `SurfaceManifestView.swift` — selectable text and copy come
  for free and the group is visually native.
- **Formatters:** the existing `timestampFormatter` has no `timeZone`/`locale`
  — do not reuse it as-is for the new rows. New rows: fixed-pattern
  `DateFormatter` with explicit timezone display and `locale = en_US_POSIX`
  discipline for pattern stability. Display shows localized timezone-bearing
  text; the copy action puts ISO 8601 with numeric UTC offset on the
  pasteboard. `Captured` row keeps its current format (stays separate per
  contract) — record that as deliberate.
- **Non-agent surfaces:** browser/markdown/plain-shell surfaces show `Created`
  (all panels get it) and `Last activity` only where c11 has a trustworthy
  observation source; otherwise `Not recorded`. `Activity` row appears only for
  agent surfaces. Never broaden what c11 claims to observe.
- **`createdAt` invariant (route per D1):** same logical surface identity
  preserves its date; a genuinely new surface mints a new date; missing legacy
  provenance stays nil. Enumerate and mark every path as preserve-or-mint:
  fresh create (terminal/browser/markdown), split creation,
  placeholder/last-panel replacement, terminal replacement, browser reopen,
  layout-executor restore, CLI/socket creation, detach/transfer
  (`Workspace.swift:~9548` re-mints panels — must preserve). Restore passes the
  decoded value verbatim **including explicit nil** — no defaulted `Date()`
  parameter on any restore path. `SessionPanelSnapshot.lastActivityAt`
  (`SessionPersistence.swift:~369`) is the proven backward-compatible optional
  pattern; `created_at` copies it.

## Step 5 — Bonsplit seam

- **Accessibility precedence rule:** when the host supplies a complete activity
  presentation, it **replaces** Bonsplit's derived activity value and built-in
  activity hint; tabs without host presentation keep Bonsplit's localized
  default. `TabActivityAccessibility.help(for:)` becomes the no-presentation
  fallback. Bonsplit tests assert the final combined value and order in both
  the normal and collapsed/overflow renderers, and that Loading, Pinned,
  Unread, Modified, Zoomed still appear exactly once.
- **Data-only decision:** c11 composes localized strings and passes them as
  data; Bonsplit gains zero new catalog entries across its seven `.lproj`
  catalogs. If implementation contradicts this, stop and re-plan the
  localization ordering.
- Flag the generic tooltip capability as an upstream candidate.

## Step 6 — Tests (authored with the code they cover)

Per-step placement: step 2 owns the pure projection matrix (state-start
arithmetic, missing evidence, cold threshold crossing, suppressed waiting
presented as idle, flag+suppression composition, unit-ladder boundaries,
negative/future timestamps); step 4 owns created-at round trip, legacy decode
through the **real restore constructor** (not just Codable) asserting
`createdAt == nil`, detach/transfer preservation, and activity/details
agreement at a fixed clock; step 5 owns Bonsplit help payload and accessibility
composition through executable paths.

Target assignment: pure projection/persistence → `c11LogicTests`;
workspace-constructing and provider-integration → `c11Tests` (CI);
Bonsplit → Bonsplit's own target. No source-text or project-file assertions.

**Execution: author coverage locally; use `xcodebuild build` /
`build-for-testing` only as compile-and-link checks (green build-for-testing
proves linking, not assertions); ALL local `xcodebuild test` actions —
including the `c11-logic` scheme and `scripts/test-unit-local.sh` — are
deferred to PR CI per standing operator rule (C11-181).**

## Step 7 — Localization, commits, and submodule ordering

- Freeze English copy first; then delegate the six-locale translation pass
  (ja, uk, ko, zh-Hans, zh-Hant, ru) in one fresh c11 surface. Validation
  beyond `jq .`: every locale entry has required plural variations (ru/uk need
  one/few/many/other — `jq` well-formedness cannot catch a missing category)
  and every English interpolation token survives in all six.
- Only after copy is frozen: commit Bonsplit on `main`, push to
  `Stage-11-Agentics/bonsplit`, re-fetch, verify
  `git merge-base --is-ancestor HEAD origin/main`, then commit the parent
  pointer. Parent diff stays clean and scoped; no dirty-checkout absorption.

## Step 8 — Review, validation, and correction loop

- **Front-loaded render probe (before step 3's full wiring is polished):** in a
  tagged build, attach a hardcoded placeholder tooltip to all three target
  views and confirm each actually appears — a tooltip on a non-hit-testable
  view fails silently with all tests green (recorded in `SafeTooltip.swift`).
- Rigorous self-review, attach review evidence, enter validation. Build/launch
  only tagged QA with dialogs suppressed (`launch-tagged-automation.sh --qa`).
  After the separately requested computer-use approval: capture visible hover
  evidence for top tab and both sidebar marks plus Surface Details. If approval
  is denied a second time: ship the code with Surface Details evidence only
  (capturable without hover), record tooltips as validated-by-probe +
  CI-tested, and state that explicitly in the PR rather than deferring
  silently.
- **Correction loop:** after any post-review fix, re-run the scoped
  `git status`/diff check; re-verify Bonsplit remote reachability if the
  submodule changed; re-run translation/token validation if copy changed; only
  then re-enter validation. Open a draft PR and leave C11-185 at `pr_open`.

## Reset 2026-07-29 by agent:trident-pane-C11-185
