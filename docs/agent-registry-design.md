# c11 Agent Registry — Design SPEC

**Status:** draft for operator review, 2026-06-28. Author: Claude (Opus 4.8).
**Decision context:** operator chose "data-driven agent registry" (full, incl. runtime-loadable) + "design doc first".
**Goal in one line:** adding a terminal coding agent to c11 should be *one manifest*, not edits scattered across ~15 files and 8+ switch statements.

---

## 1. Problem

c11 treats coding agents as first-class peers (A-button picker, sidebar chip + icon, process auto-detection, skill install, session resume across snapshots). Today every one of those capabilities is wired with a **per-agent `switch`/`if` in a different file**, and the agent's identity string (`"claude-code"`, `"opencode"`, …) is re-declared in **8+ places**. Adding an agent means touching ~15 files and keeping all of them in sync by hand; forgetting one produces a silent partial-citizen (e.g. `TextBoxInput` today only knows `claude-code` + `codex`, so the rest lag).

`docs/adding-a-new-agent.md` already names this moment (its closing section):
> "A data-driven agent registry (loading definitions from `~/.config/c11/agents/<name>.toml`) is feasible... If you find yourself adding a fifth or sixth coding agent and the friction is starting to bite, that's the moment to design it."

We are now adding the 5th/6th/7th (opencode + Pi + OmiPy). This is that moment.

## 2. Current touch points (the duplication to kill)

Every cell below is a place the agent's type string or per-agent behavior is hand-coded today.

| # | File | What's hardcoded | Shape |
|---|------|------------------|-------|
| 1 | `Sources/DefaultAgentConfig.swift` | `AgentType` enum + `displayName`/`factoryCommand`/`factoryInitialPrompt` switches | enum + 3 switches |
| 2 | `Sources/AgentDetector.swift` | `classify()` comm-match + node-wrap arg-match | switch + if-chain |
| 3 | `Sources/Conversation/StrategyRegistry.swift` | `v1` list instantiating each `*Strategy` | list (already data-ish) |
| 4 | `Sources/Conversation/Strategies/*.swift` | per-agent capture/resume/isValidId/transcriptExists | one struct each |
| 5 | `Sources/Conversation/Scrapers/*.swift` | per-agent on-disk session store (path/format) | one struct each, ad-hoc registration |
| 6 | `Sources/WorkspaceMetadataKeys.swift` | `<kind>.session_id` / `.session_project_dir` keys + id validators | constants + funcs |
| 7 | `Sources/SurfaceMetadataStore.swift` | `validateReservedKey()` switch + `canonicalTerminalTypes` | switch + set |
| 8 | `Sources/AgentRestartRegistry.swift` | `phase1` resume-command rows | rows (data-ish) |
| 9 | `Sources/Conversation/SnapshotBridge.swift` | per-agent legacy-metadata lift functions | one func each |
| 10 | `Sources/AgentChip.swift` | `iconAssetName()` + `sfSymbolFallback()` + `modelAliasTable` | 2 switches + dict |
| 11 | `Sources/DefaultAgentResolver.swift` | `.claudeCode` positional-prompt special case | if |
| 12 | `Sources/SkillInstaller.swift` | `SkillInstallerTarget` enum + `configRoot()` + `displayName` | enum + 2 switches |
| 13 | `Sources/AgentSkillsView.swift` | per-target `@State` opt-in + `optInBinding()` switch | state + switch |
| 14 | `Sources/TextBoxInput.swift` | `TextBoxAppDetection` (only claude+codex — already stale) | enum (incomplete) |
| 15 | `CLI/c11.swift` | `default-agent set` valid-types message | string list |
| 16 | `Resources/bin/<name>` | PATH-scoped wrapper (claude/codex/copilot) | bash script |

**The same `"<kind>"` literal appears in 8+ of these.** That redundancy is the bug; one manifest is the fix.

## 3. Goals / non-goals

**Goals**
- One declarative `AgentManifest` is the single source of truth for an agent's identity, detection, branding, launch, resume, and skill-install facts.
- Every subsystem above derives its behavior from the manifest registry instead of its own switch.
- Adding a *typical* agent (resume-by-flag, standard config dir) requires **zero Swift edits** — a manifest entry only, and eventually a runtime TOML file with no rebuild.
- Existing agents migrate with **identical observable behavior** (regression-gated by current tests).
- Resume/restore parity is expressed *declaratively per agent* via explicit capability tiers (§6).

**Non-goals**
- Not redesigning the conversation store, snapshot format, or socket protocol. Manifest is additive.
- Not forcing pure-data for agents that genuinely need code (a custom scraper, a bespoke id grammar). Those stay in Swift but *bind to* a manifest by kind (§5).
- Not changing the wrapper philosophy (CLAUDE.md "unopinionated about the terminal"): wrappers remain the narrow session-resume-capture exception, now declared by manifest rather than implied.

## 4. The `AgentManifest`

A `Codable` struct; built-ins are compiled-in instances, runtime agents decode from TOML (§7). Sketch (names illustrative):

```swift
struct AgentManifest: Codable, Identifiable {
    let kind: String                 // canonical id, kebab-case: "claude-code". THE single source.
    var id: String { kind }
    let displayName: LocalizedKey    // "Claude Code"; built-ins localized, runtime agents literal

    // --- Detection (drives AgentDetector) ---
    let binaries: [String]           // exact comm matches: ["claude", "claude-code"]
    let nodePackageHints: [String]   // args substrings when run via node: ["claude-code"]
    let variantRule: VariantRule?    // e.g. opencode "run"/"exec" -> headless "opencode-run"

    // --- Launch (drives DefaultAgentResolver / default-agent launch) ---
    let launchCommand: String        // bare launcher, e.g. "claude"
    let autoApproveArgs: [String]    // ["--dangerously-skip-permissions"] / ["--yolo"] / ...
    let promptDelivery: PromptDelivery   // .positional | .sendTextAfterReady

    // --- Resume / restore (drives Strategy + RestartRegistry + metadata) ---
    let resume: ResumeSpec           // see §6 — the capability tier + its data

    // --- Branding (drives AgentChip) ---
    let iconAsset: String?           // "AgentIcons/claude-code" if shipped
    let sfSymbolFallback: String     // "sparkles"
    let modelAliases: [String: String]  // optional display shortenings

    // --- Skill install (drives SkillInstaller / AgentSkillsView) ---
    let configRoot: ConfigRoot       // .dotHome (~/.<kind>) | .xdg("opencode") | .custom(path)
    let skillInstall: Bool           // participates in the onboarding sheet?

    let source: ManifestSource       // .builtin | .userTOML(url)   (provenance, precedence)
}
```

Derived, not stored: the reserved metadata keys are always `"<kind>.session_id"` and `"<kind>.session_project_dir"` — computed from `kind`, never re-declared.

## 5. Pure-data vs needs-code (the honest boundary)

Not everything an agent needs is data. The split:

- **Pure data (manifest only):** detection strings, display name, icon, launch command, auto-approve flag, prompt-delivery mode, config root, model aliases, resume-command *template*, session-id *grammar* (choose from a known enum: `uuid` | `ulid` | `ses-ulid` | `opaque`).
- **Needs code (Swift, bound to manifest by `kind`):**
  - A **custom scraper** (read a SQLite DB like opencode, or a JSONL dir like claude/codex). Expressed as a `ConversationScraper` conformer registered under the manifest's `kind`. The manifest declares *that a scraper exists and its store path/format*; complex parsing stays in Swift.
  - A **hook/plugin capture rail** (claude SessionStart hook, opencode plugin `session.created`). The wrapper/plugin asset ships in `Resources/bin/` or `skills/<agent>-plugins/`; the manifest declares its presence.

**Design rule:** the registry resolves a strategy for `kind` as *custom Swift strategy if one is registered, else a `GenericManifestStrategy` built from the manifest's `ResumeSpec`*. So a typical resume-by-flag agent needs no strategy struct at all; opencode/claude keep theirs.

## 6. Resume/restore parity, as declared tiers

Parity is not binary; agents differ in how recoverable a session is. The manifest's `ResumeSpec` picks a tier and supplies only that tier's data:

| Tier | Meaning | Manifest supplies | Examples |
|------|---------|-------------------|----------|
| **T0 fresh** | No resume; relaunch bare | nothing | (fallback) |
| **T1 resume-last** | A flag resumes the most-recent session | `resumeLastArgs` (`["resume","--last"]`) | codex today |
| **T2 resume-specific** | Resume an *exact* session by id | `resumeByIdTemplate` (`"--resume {id}"`), `idGrammar`, `sessionStore {path, format}` | claude, opencode |
| **T3 full-capture** | T2 + live capture event + crash-verify | T2 + `captureRail` (`event`/`watch`/`mint`/`scrape`/`wrapperClaim`) + scraper | claude, opencode (target) |

`AgentRestartRegistry` and the strategy both read the tier: a T2/T3 agent with a captured id types the templated resume command (with `cd <project_dir> &&` when a project dir is stored); a T1 types resume-last; T0 launches fresh. This is exactly today's hand-written per-agent logic, expressed once as data + tier.

## 7. Runtime extensibility — `~/.config/c11/agents/*.toml`

Hybrid model:
- **Built-in agents** stay compiled (`source = .builtin`) for branding, localization, custom scrapers, and zero-config trust.
- **User agents** load from `~/.config/c11/agents/<kind>.toml` at startup, decoded into `AgentManifest` with `source = .userTOML`.
- **Precedence:** a user TOML with the same `kind` as a built-in *overlays* declared fields (e.g. operator overrides `launchCommand`/`autoApproveArgs`), but cannot inject Swift code. Net-new kinds are fully user-defined.
- **Capability ceiling for TOML agents:** they get T0/T1/T2 (data-expressible). **T3 needs a compiled scraper/plugin, so a pure-TOML agent maxes at T2** (resume-specific via flag if the agent stores a discoverable id; otherwise T1/T0). Documented, not a surprise.

Example `~/.config/c11/agents/myagent.toml`:
```toml
kind = "myagent"
display_name = "My Agent"
binaries = ["myagent"]
launch_command = "myagent"
auto_approve_args = ["--yes"]
prompt_delivery = "positional"
sf_symbol_fallback = "wand.and.stars"
config_root = "dot-home"

[resume]
tier = "resume-last"
resume_last_args = ["--continue"]
```

Open question for §11: hot-reload on file change, or load-at-launch only (simpler, matches snapshot lifecycle).

## 8. How each subsystem changes (the refactor map)

| Subsystem | After |
|-----------|-------|
| `AgentDetector` | builds its match table by iterating `registry.all` over `binaries`/`nodePackageHints`/`variantRule`. No per-agent code. |
| `AgentChip` | icon/symbol/aliases read from manifest; `default` path unchanged. |
| `StrategyRegistry` | resolve by `kind`: custom struct if registered, else `GenericManifestStrategy(manifest)`. |
| `AgentRestartRegistry` | rows generated from each manifest's `ResumeSpec`. |
| `SurfaceMetadataStore` | `validateReservedKey` switches on derived `<kind>.session_id` keys + `idGrammar`; `canonicalTerminalTypes` = `registry.all.map(\.kind)`. |
| `SnapshotBridge` | legacy lift iterates manifests that declare a legacy key. |
| `SkillInstaller` / `AgentSkillsView` | targets + config roots + opt-ins come from `registry.all.filter(\.skillInstall)`; the per-target `@State` becomes a dictionary keyed by kind. |
| `DefaultAgentResolver` | prompt delivery read from manifest (kills the `.claudeCode` special case). |
| `DefaultAgentConfig.AgentType` | **decision (§11):** either (a) keep the enum but generate `displayName`/factory from registry, or (b) replace enum usages with `kind: String` validated against the registry. (a) is lower blast-radius; (b) is the true end state. Recommend (a) first, (b) as a follow-up. |
| `TextBoxInput` | detection set from registry (also *fixes* its current staleness for free). |
| `CLI/c11.swift` | valid-types message = `registry.all.map(\.kind)`. |

## 9. Migration plan (phased, each phase shippable + test-gated)

- **Phase 0 — introduce the registry, no behavior change.** Add `AgentManifest` + `AgentRegistry` + built-in manifests for the 6 existing agents. Subsystems still use their switches. New tests assert each manifest reproduces today's hardcoded values (golden test). *Pure addition; zero risk.*
- **Phase 1 — flip consumers to the registry, one PR per subsystem** (detector, chip, restart, metadata, skill-install, textbox, CLI). Each PR is "delete a switch, read the manifest", regression-gated by existing `c11-logic` tests (`AgentDetectorTests`, `DefaultAgentConfigTests`, `AgentRestartRegistryTests`, `SurfaceMetadataStoreTests`, …).
- **Phase 2 — opencode to T3 via manifest + scraper.** Fold the parked `feat/opencode-resume` work (scraper, reserved keys, snapshot lift, detector variant, model alias) onto the registry as the *first real consumer*. Validates the abstraction against a hard case (SQLite store, `ses_`-ULID grammar, plugin capture). Loopy live-test per `docs/opencode-parity-plan.md` §5B.
- **Phase 3 — add Pi + OmiPy** as manifests (Swift built-ins, + scraper only if their store needs one). This is the acceptance test for "easy to add": measure the diff size.
- **Phase 4 — runtime TOML loading** + `docs/adding-a-new-agent.md` rewrite (the checklist becomes "write a manifest / drop a TOML").

Orchestration: Phase 1's per-subsystem PRs are independent → ideal for the lattice-orchestrator pattern (one delegator per subsystem, one worktree each). Phase 0 must land first as the shared foundation.

## 10. Risks

- **`AgentType` enum blast radius.** It's `CaseIterable` and referenced widely. Mitigation: phased (keep enum, generate its data) before any signature change.
- **pbxproj churn.** Each new scraper/strategy file = pbxproj edits (and merge-conflict surface, as we just saw on #262). Mitigation: batch file additions; gate on `xcodebuild -list` + ref-count symmetry, not line-by-line diff (per CLAUDE.md).
- **Runtime-agent detection.** A TOML agent's binary list lets `AgentDetector` classify it, but it has no compiled icon → SF Symbol fallback only (acceptable).
- **Localization.** Built-in `displayName` stays `String(localized:)`; runtime agents are literal (can't localize user strings). Documented.
- **TOML T3 ceiling.** Must be loudly documented so operators don't expect SQLite-scrape resume from a pure-TOML agent.

## 11. Open questions for the operator

1. ~~Pi and OmiPy identity~~ **RESOLVED → `pi` + `omp` (oh-my-pi, a fork of Pi)**, both HIGH confidence (Appendix A). Both are jsonlDir / scrape / tier T2, no yolo flag. *Confirm this is what you meant* (the only assumption in the doc I'd want a thumbs-up on before wiring them).
2. **`AgentType` end state** — accept the phased "keep enum, generate data" (a) as the durable design, or commit to fully replacing the enum with registry-validated strings (b) as a later phase?
3. **TOML loading lifecycle** — load-at-launch only (simpler) vs hot-reload on file change?
4. **Scope of first delivery** — land Phase 0+1 (the refactor, no new agents) as the first reviewable chunk, then Phase 2+ separately? Or bundle opencode (Phase 2) in immediately as the proof?

---

## Appendix A — Agent landscape (from research, 2026-06-28)

Full report: `scratchpad/agent-landscape-research.md`. Two facts dominate and **directly shape the manifest**:

1. **SQLite is the new normal.** opencode, Goose (≥1.10), Crush, Copilot, Cursor all moved session storage from per-session JSONL to a SQLite DB. So `sessionStore.format` must be a first-class enum, and the scraper conformer is selected by it: `jsonlDir` (claude, qwen, pi, omp) · `jsonlRollout` (codex's dated `rollout-*.jsonl`) · `sqlite` (the new cohort) · `perRepoMarkdown` (aider) · `cloud` (amp).
2. **Capture rails come in three shapes**, so `captureRail` is an enum: **event** (claude `SessionStart` hook, opencode `session.created` plugin, cline `TaskStart`, qwen/grok `SessionStart`) · **watch** (no event → poll the store/DB: codex, copilot, gemini, goose, crush) · **mint** (allocate the id before launch: claude `--session-id`, cursor `create-chat`). Plus `scrape` (find newest by cwd+mtime) as the universal fallback.

### The two requested agents (confirmed targets — HIGH confidence)

| | Pi | oh-my-pi |
|---|---|---|
| Operator's name | "Pi" | "OmiPy"/"OmyPy" |
| Command | `pi` | `omp` |
| Why confident | literal "pie"; on every 2026 roundup | literal "oh-my-pie"; **a fork of Pi** → coherent pairing |
| Vendor / license | Earendil / M. Zechner (badlogic), MIT | Can Bölük (can1357), MIT |
| Resume specific | `pi --session <id>` | `/resume` in TUI |
| Resume last | `pi -c` | `-c` (inherited, unconfirmed) |
| Session store | `~/.pi/agent/sessions/` (jsonlDir, by cwd) | `~/.omp/agent/sessions/` (jsonlDir) |
| Id format | opaque (undocumented) | opaque (undocumented) |
| Capture rail | none known → **scrape** | none known → **scrape** |
| Auto-approve flag | **none** ("answer once") | **none** |
| Config root | `~/.pi/` | `~/.omp/` |
| Prompt as arg | `pi -p` | `omp -p` |
| → c11 tier | **T2** | **T1–T2** |

Both fit the design with **no new machinery**: a small `jsonlDir` scraper (the claude/codex shape) bound by `kind`, and a manifest declaring store path + `grammar: opaque` + `captureRail: scrape` + empty `autoApproveArgs`. They are the acceptance test for "easy to add a new agent." ⚠ Neither has a yolo flag, so c11 launches them bare (documented degradation, same as Kimi/opencode-bare today).

### Resume-parity buckets (validates the T0–T3 tier model)

- **CLEAN (T2/T3 — resume-specific + local store):** Claude Code, opencode, Codex, Cline, Qwen, Copilot, Gemini, Goose, Crush, Cursor, both Groks, Kimi, **Pi, oh-my-pi**. The bulk.
- **BEST-EFFORT (T0/T1 — no addressable session):** **Aider** (no id; only `--restore-chat-history` per repo). Tier T0/T1, store `perRepoMarkdown`.
- **CLOUD (handle local, content remote):** **Amp** (`T-…` id local, thread on ampcode.com). Store `cloud`; c11 restores the handle only, rehydrate needs network+auth.

### Condensed integration table (priority targets)

| Agent | Cmd | Yolo flag | Resume specific | Store (format) | Id | Capture rail |
|---|---|---|---|---|---|---|
| Claude Code | `claude` | `--dangerously-skip-permissions` | `--resume <id>` | `~/.claude/projects/<cwd>/*.jsonl` (jsonlDir) | UUID | event hook + mint |
| opencode | `opencode` | `--dangerously-skip-permissions` | `-s <id>` | `opencode.db` (sqlite) | `ses_`+base62 | event plugin |
| Codex | `codex` | `--yolo` | `codex resume <id>` | `rollout-*.jsonl` (jsonlRollout) | UUID | watch |
| Cline | `cline` | `--yolo` | `--id <id>` | `~/.cline/data/tasks/<id>/` | ts-derived | event hook (`TaskStart`) |
| Qwen | `qwen` | `--yolo` | `--resume <id>` | `~/.qwen/projects/<cwd>/chats` (jsonlDir) | UUID | event hook |
| Copilot | `copilot` | `--allow-all` | `--resume <id>` | `session-store.db` (sqlite) | UUID | watch |
| Gemini ⚠ | `gemini` | `--yolo` | `--resume <id>` | `~/.gemini/tmp/<hash>/chats/*.json` (jsonlDir) | UUID | watch |
| Goose | `goose` | `GOOSE_MODE=auto` | `--session-id <id>` | `sessions.db` (sqlite) | `YYYYMMDD_N` | watch (DB) |
| Crush | `crush` | `--yolo` | `-s <id>` | `<repo>/.crush/crush.db` (sqlite, project-scoped) | UUID | watch (DB) |
| Cursor | `cursor-agent` | `-f`/`--yolo` | `--resume=<id>` | `~/.cursor/chats/` (sqlite) | UUID | mint (`create-chat`) |
| **Pi** | `pi` | (none) | `pi --session <id>` | `~/.pi/agent/sessions/` (jsonlDir) | opaque | scrape |
| **oh-my-pi** | `omp` | (none) | `/resume` | `~/.omp/agent/sessions/` (jsonlDir) | opaque | scrape |
| Aider | `aider` | `--yes-always` | — | `.aider.chat.history.md` (perRepoMarkdown) | none | — |
| Amp | `amp` | (auto by default) | `threads continue <T-id>` | CLOUD | `T-<uuid>` | capture stdout |

### Recommended first-class priority (beyond Pi/omp)
opencode (already half-built on `feat/opencode-resume`) → Codex (adoption) → Cline (best hook API) → Qwen → Copilot → Gemini(⚠)/Goose/Crush/Cursor. Aider + Amp are deliberate best-effort/cloud edge cases that prove the tier model's tails.

### Gotchas the registry must encode
- `grok` + `~/.grok/` **collide** (xAI official `config.toml` vs community `grok-dev` `user-settings.json`) → disambiguate by file presence, not command. (Today's `AgentDetector` keys on command name alone — a manifest can carry a `disambiguateByFile` rule.)
- **Kimi moved** `~/.kimi/` (legacy Python) → `~/.kimi-code/` (current Node). The c11 CLAUDE.md `~/.kimi/*` reference is stale; fix when we touch Kimi's manifest.
- **Crush short-flag trap:** `-C` = continue, `-c` = `--cwd`.
- **Codex cannot pre-assign an id** (no `--session-id`); only claude + cursor support `mint`.
- ⚠ **Gemini:** reported June-2026 free-tier withdrawal + "Antigravity CLI" pivot — verify before investing.
