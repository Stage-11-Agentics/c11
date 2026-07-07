# Truth & Stability Cycle — SPEC

Cycle contract for the July 2026 orchestrated run. Four fronts, two waves. Source dialogue: operator interview 2026-07-06 (see `notes/c11-consultant-review-2026-07.md` §6, §8). Base: `main` at v0.57.0.

Normative companion docs referenced below are part of this contract:
- `notes/c11-audit-merged-2026-06-09.md` (the P0/P1 findings this cycle draws from)
- `docs/c11-waiting-agent-cluster-plan.md` (waiting-agent cluster restyle, folded into TEL)
- `docs/conversation-store-architecture.md` and `docs/c11-state-save-load-and-crash-resume.md` (resume)

Hard constraints inherited from project `CLAUDE.md` (apply to every ticket):
- No new work on typing-latency hot paths (`hitTest`, `TabItemView`, `forceRefresh`).
- Socket telemetry handling stays off-main; no `DispatchQueue.main.sync` on telemetry paths.
- Socket commands never steal macOS focus.
- Every CLI/socket surface change updates `skills/c11/` in the same PR, and the installed copy is synced (`scripts/sync-installed-skills.sh`).
- All user-facing strings localized at the call site; translation pass delegated per CLAUDE.md.
- `dlog` calls gated `#if DEBUG`.

---

## Wave 1

### DX — Socket dispatcher extraction (mechanical)

The 551-case socket command dispatch moves out of `Sources/TerminalController.swift` into per-domain handler files. **No behavior change.**

- **DX-1** The socket dispatch switch no longer lives in `TerminalController.swift`; command handling is organized into per-domain handler units (e.g. surface, pane, workspace, browser, theme, conversation, mailbox, metadata) under a dedicated directory.
- **DX-2** Behavior parity: the full `c11-logic` suite passes unchanged, and the tests_v2 socket suites pass against a tagged build with results identical to a pre-change baseline run recorded in the ticket.
- **DX-3** Threading and focus policy are preserved verbatim per handler: commands that ran off-main still run off-main; main-actor commands remain main-actor. No handler gains main-thread work.
- **DX-4** `TerminalController.swift` shrinks by at least the size of the relocated dispatch (target: file drops below ~10k LOC); no new god file is created (no single new handler file above ~3k LOC).
- **DX-5** This is a mechanical relocation: no renamed socket methods, no changed wire responses, no new abstractions beyond the handler seam itself. Deeper router redesign is explicitly out of scope.

### HYG — Repo hygiene

- **HYG-1** `node_modules/` is untracked and gitignored; `git ls-files | grep -c node_modules` returns 0; build and CI remain green with install steps documented where needed.
- **HYG-2** All open dependabot PRs are resolved: merged where CI is green, or closed with a one-line reason.
- **HYG-3** A stale-branch inventory (local + remote, last-commit date, merged-status) is produced as an artifact for operator review. Deletion itself is operator-assisted, not autonomous.

### WEB — Public-surface rebrand and docs truth

- **WEB-1** `web/` contains no manaflow-era pointers: PostHog keys, legal pages, feedback endpoints, and repo links all reference Stage 11 / c11 surfaces. Grep-clean for manaflow domains except deliberate lineage credits.
- **WEB-2** `CONTRIBUTING.md` directs contributions to `Stage-11-Agentics/c11`.
- **WEB-3** `docs/socket-api-reference.md` is rewritten for the real surface: c11-branded, v2 JSON-RPC framing documented, and a complete method index of all dotted v2 methods (generated from source if practical) with per-domain sections. Stale cmux naming eliminated.
- **WEB-4** A minimal `ROADMAP.md` exists at repo root ("directions we care about" stub, per operator: minimal placeholder), and `PHILOSOPHY.md`'s reference to it is no longer dangling.
- **WEB-5** tests_v2 binary discovery no longer requires a binary named `cmux` (audit P1: 35 files); suites locate the `c11` binary.

## Wave 2 (rebased on DX)

### TEL — Telemetry truth (liveness) + waiting-agent cluster

The sidebar must stop lying. Two mechanisms, deterministic, no model inference in this cycle.

- **TEL-1** Every self-reported canonical metadata key (status, progress, task, description) records a last-updated timestamp, persisted with the metadata and exposed over the socket (`get_metadata` returns it) and to the UI.
- **TEL-2** Sidebar status/progress pills visually decay by age: fresh renders normally; past a staleness threshold the pill dims with a relative-age indicator; past an expiry threshold it grays out. Thresholds have sensible defaults (suggested 5m / 15m) and are operator-tunable in settings.
- **TEL-3** c11 derives a per-surface activity state (`working` / `idle`) from what it already observes externally: PTY output flow and prompt state. The derived state is written at the existing `derived` precedence tier, never overwriting `explicit` while fresh.
- **TEL-4** When an explicit status is past expiry, the derived activity state takes over the visible pill, visually distinguished as derived (not agent-claimed). When the agent reports again, explicit resumes.
- **TEL-5** Derived-state computation adds no per-keystroke or per-frame work on hot paths; it piggybacks on existing output/prompt signals or coarse timers.
- **TEL-6** The waiting-agent sidebar cluster is restyled per `docs/c11-waiting-agent-cluster-plan.md` (two-row cluster, rename, lit-state inversion, workspace prev/next arrows), integrated with the liveness work so the sidebar region is touched once.
- **TEL-7** Scenario proof (recorded): an agent sets a status then goes silent → the pill decays on schedule and flips to derived; an agent that never self-reports but produces output → sidebar shows derived `working` without any agent cooperation.
- **TEL-8** The c11 skill's metadata reference documents the age/decay semantics and the derived-liveness behavior.

### EVT — Events stream (file-first pub/sub)

- **EVT-1** The app appends structured events as NDJSON to a per-instance event log under c11's Application Support runtime dir. Each event carries a monotonic sequence number, ISO-8601 timestamp, event type, subject refs (workspace/pane/surface as applicable), and a type-specific payload.
- **EVT-2** v1 event taxonomy (minimum): surface lifecycle (created/closed), workspace selected, canonical-metadata changes (status/title/description/progress, including source tier), derived-liveness transitions (from TEL), waiting-agent transitions, mailbox envelope accepted/delivered.
- **EVT-3** Event writes happen off-main and are non-blocking for the emitting path; a slow or full disk never stalls the UI or socket handling.
- **EVT-4** The log rotates at a size cap with at least one rolled generation retained; consumers can detect rotation (seq reset or rotation marker).
- **EVT-5** `c11 events tail` exists with `--follow`, `--filter type=...`, and `--since <seq|duration>`; it is sugar over the file (the file is the contract; any process may consume it directly).
- **EVT-6** Latency: an event is observable by a tailing consumer within 1 second of the underlying transition under normal load.
- **EVT-7** Scenario proof (recorded): a consumer tails the stream; a status change, a mailbox delivery, and a surface close each appear as events and the consumer reacts.
- **EVT-8** The c11 skill documents the event file location, schema, taxonomy, and CLI. A JSON schema for the envelope lands in `spec/`.

### RES — Crash-resume completion (metric-driven)

Definition of done is the scenario, not a task list.

- **RES-1** THE SCENARIO: with at least 10 live agent conversations across at least 3 workspaces spanning at least 3 conversation kinds (must include claude-code and codex; plus pi, omp, or opencode), the app is force-killed (`kill -9`). On relaunch, every conversation either resumes exactly per its kind's declared resume tier, or the surface presents an honest, specific `diagnostic_reason`. Zero silent fresh-launches presented as resumes.
- **RES-2** Whatever the scenario requires is in scope: wiring the pull-scrape rail into the live restore path, crash-path recovery ordering, SurfaceActivityTracker persistence, Codex cwd/ambiguity handling. Anything the scenario does not exercise is out of scope for this cycle.
- **RES-3** The scenario is encoded as a repeatable script/harness (agents may be lightweight stand-ins that create real conversations), runnable by the delegator, the Result Validator, and future CI.
- **RES-4** Clean-shutdown resume (the existing path) does not regress: the current resume test suites stay green.
- **RES-5** Skill/reference docs (`references/conversation.md`) reflect the actual post-cycle behavior, including what crash recovery now guarantees per kind.

### COR — P0 correctness fixes

- **COR-1** Empty or absent surface refs on surface-scoped socket writes are rejected with a clear error; they never default to the operator-focused surface. All write-family commands covered (set-metadata, set-agent, set-title, set-description, rename-tab, clear-metadata, trigger-flash, set-status, set-progress, log).
- **COR-2** The c11 skill's footgun guidance is updated to reflect the new contract (explicit `--surface` still recommended; silent misrouting no longer possible).
- **COR-3** Main-thread-reachable socket paths from the June audit are eliminated: `pane.confirm`, `feedback.submit`, and any nested `CFRunLoopRun` genre instances found by a fresh sweep. Verified by code audit plus the hang monitor staying clean under a scripted multi-agent load test (parallel hook/telemetry flood, the C11-156 reproduction shape).
- **COR-4** Regression tests exist for both genres: an empty-ref rejection test in the logic suite and a socket-flood test that fails on reintroduced main-thread sync work.

---

## Out of scope this cycle (explicitly)

Local-model scrollback observation (charter it later per operator), socket subscribe channel for events (file-first only), mailbox Stage 3 (topics/watch/caps), inter-agent trust model, c11d persistent remote host, README register pass and launch assets (operator-collaboration track, after this cycle), deeper dispatcher router redesign, upstream sync.
