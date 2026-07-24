# Agent-Config Primitive — Design (C11-175)

**Status:** Draft for operator review. Architecture + UX only; nothing implemented or merged.
**Ticket:** C11-175 · **Author:** Config Primitive designer (Opus), 2026-07-20.
**Decisions:** all open questions resolved in the operator interview of 2026-07-20; see §8.
**Scope note:** This is the *rich, operator-facing* config layer. It composes with, and does not
replace, two sibling plans: the session-fader tier in `docs/next-agent-default-config-plan.md`
(Sekhem's `NextAgentOverride`) and the economics catalog in `docs/token-cost-awareness-design.md`
(a data source this UI *surfaces*, never owns). Where the three meet is called out in §7.

---

## 0. TL;DR

Launching an agent is a choice along four axes: **harness · model · effort · provider**, plus the
launch recipe around them (command, system prompt, initial prompt, env). Today that choice is real
but scattered, the A button launches one frozen default, and "what have I been launching?" is nowhere.
This design makes it a **native c11 primitive**:

1. A **saved, named library** of *full launch recipes* the operator curates, edits, and reorders.
   Each config layers over its harness's Settings: set a field to override, leave it to inherit.
2. A **remembered default** whose relationship to "most recent" is one explicit toggle
   (`pinned` vs `follow-recent`), so the button's behavior is always obvious. Most-recent **persists
   across relaunch**.
3. A **most-recent tracker** kept true even when the config changes outside c11's launcher, fed by
   launch-time capture (every harness), the Claude Code hook (live, mid-session), and the existing
   conversation scrapers (pi/omp/opencode). **Only claude-code reports live mid-session**; every
   other harness is tracked at launch time, so a mid-session model change on it is a documented blind
   spot (scrapers narrow, not close, that window in v2).
4. A **system-prompt field** with three modes (inherit / append / replace); `replace` + empty text is
   the Gregorovich blank-slate launch.
5. A **durable launch-history rail**: every launch appends to `agent-launches.jsonl` and bumps
   rolled-up counters, so `c11 config stats` answers "87% Opus" instantly, for all time.
6. An **enriched A-button menu**: click a row to launch it, pin it to set the default, see cost from
   the sibling catalog, and degrade cleanly when a harness is not installed.

The substrate is already ~80% built. `AgentType`, `AgentLaunchTemplate`, `DefaultAgentResolver`,
`AgentLaunchPlanner`, `c11 launch-agent`, the claude hook rail, the pi/omp scrapers, the events
stream, and the A-button's dropdown-menu seam all exist. This is mostly **composition + a couple of
new state files + a few new launch-template fields**, not new machinery.

---

## 1. The four axes and their dependency structure

The harness is the **root** axis; the others derive applicability and value space from it. Modeling
that dependency cleanly (not as a free cross-product) is the first design decision.

### 1.1 Harness is the anchor

The harness (`AgentType.kind`) is the CLI binary c11 spawns. The manifest's `AgentLaunchTemplate`
already declares, per harness, whether model and effort apply and what values are legal
(`Sources/AgentManifest.swift`):

- **model axis** applies iff `template.modelArg != nil` (every built-in but `custom`).
- **effort axis** applies iff `template.effortArg != nil`; shape is the harness's: claude
  `--effort {low…max}`, codex `-c model_reasoning_effort=` (pass-through), pi/omp `--thinking`,
  grok/kimi/opencode/copilot none.
- **system-prompt axis** (new, §1.4) applies iff the harness declares a system-prompt flag.

This gating already drives the Settings UI (`editingAgentSupportsModel/Effort`) and is reused verbatim.

### 1.2 Provider is a derived facet, presented as grouping

You cannot run Anthropic through codex; a literal four-way cross-product is mostly empty. Provider is
fused into the other axes:

| Harness class | Harnesses | Provider resolution | Picker treatment |
|---|---|---|---|
| **Fixed-provider** | claude-code→Anthropic, codex→OpenAI, grok→xAI, kimi→Moonshot, github-copilot→GitHub | constant of the harness | a **label**, no control |
| **Router** | opencode, pi, omp (OpenRouter family) | the model id **is** `provider/model` | model list **grouped under provider headers**; picking the model carries the provider (§5.4) |
| **Custom** | `custom` + `~/.config/c11/agents/<kind>.json` | whatever the template declares | unlabeled |

> **Rule:** harness gates whether model/effort/system-prompt apply and what values are legal.
> Provider is a constant for fixed harnesses and the model-id prefix for router harnesses. It is a
> derived display facet, never a stored fourth field. **Decision (§8): grouped-by-prefix, no
> first-class provider control.**

Derived descriptors, computed from the manifest + a static provider map (no new persisted state):

```swift
enum ModelAxis { case none; case families([ClaudeModelFamily]); case freeform(providerLabel: String); case router }
enum EffortAxis { case none; case tiers([String]); case passthrough }
enum SystemPromptAxis { case none; case supported(appendFlag: String?, replaceFlag: String?) }
```

### 1.3 The config value is a full launch recipe

**Decision (§8): a saved config is the whole launch recipe, layered over the harness's Settings.**
Every recipe field is optional; unset means *inherit the harness base*.

```swift
struct AgentLaunchConfig: Codable, Equatable {
    var harness: String                 // AgentType.rawValue / kind   (required)
    var model: String?                  // nil = inherit harness Settings model
    var effort: String?                 // nil = inherit
    var systemPrompt: SystemPromptSetting?   // nil = inherit; see §1.4
    var command: String?                // nil = inherit the harness's configured/factory command
    var initialPrompt: String?          // nil = inherit
    var env: [String: String]?          // merged over harness env; config wins per key
    // provider is DERIVED (fixed map, or model-id prefix); never stored.
}
struct SavedAgentConfig { let id: UUID; var name: String; var config: AgentLaunchConfig; var order: Int }
```

**Merge / precedence when composing a launch** (this is the rule the "full recipe" choice requires):

```
base command   = config.command   ?? harnessSettings.command   ?? factory.command
initial prompt = config.initialPrompt ?? harnessSettings.initialPrompt ?? factory
env            = factory.env  ◁ harnessSettings.env  ◁ config.env      (later wins per key)
model flag     = injected onto base command unless the base command hardcodes --model
                 value = config.model ?? harnessSettings.model ?? (none)
effort flag    = same ladder, gated by EffortAxis
system prompt  = §1.4, gated by SystemPromptAxis
```

The model/effort flag injection is the **exact** logic `DefaultAgentResolver` /
`AgentLaunchPlanner` already run (hardcoded-in-command detection included); the only change is that
the *value* now comes from the config overlay first, harness Settings second. The harness-level
`AgentConfig` in Settings becomes the **base layer**; a saved config is a **named overlay** on one
harness. Factory seed configs leave everything unset (pure inherit), so they reproduce today's
behavior exactly.

### 1.4 System prompt (three modes)

**Decision (§8): three modes.** `replace` + empty text is the Gregorovich blank-slate case.

```swift
struct SystemPromptSetting: Codable, Equatable {
    enum Mode: String, Codable { case inherit, append, replace }
    var mode: Mode
    var text: String        // ignored for .inherit; "" + .replace = blank slate
}
```

Delivered per-harness via a new `AgentLaunchTemplate.systemPromptArg`:

- **claude-code:** `append` → `--append-system-prompt '<text>'`; `replace` → `--system-prompt '<text>'`
  (empty allowed → strips the default to a blank slate).
- **other harnesses:** mapped where the CLI exposes an equivalent flag; where it does not, the
  system-prompt control is **disabled** in the editor (same gating pattern as effort). The exact
  per-harness flag mapping is a small implementation-time verification item, treated like effort was.

The history log (§2.4) records only the **mode**, never the prompt text, so system-prompt content
(which may be a persona or sensitive) never lands in a stats file.

---

## 2. Data model + persistence

Three persisted artifacts, all file-is-contract at the state root (resolved as
`EventLogLayout.defaultStateURL()` does, behind `StateDirectoryMigration.ensureMigrated`), atomic
writes, typed errors modeled on `WorkspaceSnapshotStore`. Each is readable by the CLI with the app
down, and compiled into both app and CLI targets.

### 2.1 `agent-configs.json` — library + default + most-recent

```jsonc
{
  "schema_version": 1,
  "configs": [
    { "id":"01J…opus", "name":"Opus deep",   "order":0,
      "harness":"claude-code", "model":"opus",   "effort":"high",
      "systemPrompt": { "mode":"inherit", "text":"" } },
    { "id":"01J…greg", "name":"Gregorovich",  "order":1,
      "harness":"claude-code", "model":"opus",
      "systemPrompt": { "mode":"replace", "text":"" } },     // blank slate
    { "id":"01J…cdx",  "name":"Codex hi",     "order":2,
      "harness":"codex", "model":"gpt-5.2", "effort":"high" },
    { "id":"01J…omp",  "name":"Cheap router", "order":3,
      "harness":"omp",   "model":"deepseek/deepseek-chat-v3.1" }
  ],
  "default": { "mode":"pinned", "config_id":"01J…opus" },     // §3
  "recent":  { "config_id":"01J…cdx", "harness":"codex", "model":"gpt-5.2", "effort":"high",
               "observed_at":"2026-07-20T21:14:00Z", "source":"launch",
               "field_sources": { "model":"launch", "effort":"launch" } }   // §4
}
```

Unset recipe fields are simply absent (inherit). A small `AgentConfigLibraryStore`
(load/save/add/remove/reorder/setDefault/recordRecent) mirrors `DefaultAgentConfigStore`'s
recompute-on-access shape so socket writes propagate live.

### 2.2 The default pointer + mode

`default = { mode: "pinned" | "follow-recent", config_id }`. `config_id` is always a saved config
("pin current" creates/updates one). Factory: `pinned`, seeded `Opus deep` (claude-code/opus/high,
matching today's pin).

### 2.3 Most-recent (persisted across relaunch)

**Decision (§8): persist across relaunch.** `recent` lives in `agent-configs.json` and reloads on
launch, so `follow-recent` resumes where you left off. It carries `field_sources` so the UI can show
which fields are live-observed vs launch-captured (relevant to the codex blind spot, §4.3).

### 2.4 `agent-launches.jsonl` + `agent-launch-stats.json` — the stats rail

**Decision (§8): durable append-log + rolled-up counters.**

```jsonc
// agent-launches.jsonl — one line appended per launch, all time
{ "ts":"2026-07-20T21:14:00Z", "harness":"claude-code", "model":"opus",
  "effort":"high", "provider":"anthropic", "config_id":"01J…opus",
  "system_prompt_mode":"inherit", "source":"a-button" }
// source ∈ a-button | launch-agent | socket | blueprint | fader

// agent-launch-stats.json — rolled-up aggregate for O(1) queries
{ "schema_version":1, "since":"2026-07-01T…",
  "totals": { "by_model": { "opus":412, "sonnet":43, "gpt-5.2":19 },
              "by_harness": { "claude-code":455, "codex":19 },
              "by_provider": { "anthropic":455, "openai":19 } },
  "count": 474, "last_ts":"2026-07-20T21:14:00Z" }
```

Every launch, through **any** tier, calls one `recordLaunch(resolvedConfig, source)` that (a) updates
`recent`, (b) appends the jsonl line, (c) bumps the aggregate. The aggregate makes
`c11 config stats` instant; the jsonl is the ground truth for windowed queries (today / 30d /
all-time) and can be rescanned if the aggregate is ever rebuilt. The log stores the **resolved**
`{harness, model, effort, provider, system_prompt_mode, config_id}` — **never** prompt/command text,
so it stays lean and non-sensitive. Append-only; rotation is optional and off by default (these are
small records the operator explicitly wants to keep for all time).

---

## 3. The core question: default vs most-recent

**They are two distinct concepts joined by one explicit, visible toggle.**

- **Most-recent** is an *observation*: the config you last launched or last used. Always tracked, now
  persisted across relaunch.
- **Default** is the *decision* about what a plain **left-click** launches, with a mode:
  - **`pinned`** (factory): left-click launches the explicitly chosen config. A throwaway Haiku
    scratch agent never silently downgrades your next real launch.
  - **`follow-recent`**: left-click launches whatever `recent` holds. "Another of what I just had."

Resolution is one branch the menu makes visible:

```
effectiveDefault = (mode == .followRecent && recent != nil) ? recent : pinnedConfig
```

### 3.1 Composition with the two sibling tiers

Every launch through any path updates `recent` and the stats log. Full precedence for a spawn's
resolved model/effort, top wins:

```
operator-hardcoded --model/--effort inside the (config or harness) command   (exists; always wins)
  ▷ NextAgentOverride — session fader, external controller         (next-agent-default-config-plan)
    ▷ effectiveDefault — pinned | follow-recent   ← THIS DESIGN, A-button left-click
      ▷ project .c11/agents.json
        ▷ user Settings per-harness config (the config overlay's inherit base)
                     … and whatever resolves feeds → recent + stats (§4, §2.4)
```

---

## 4. Session-tracking: keeping "most recent" true

Three ingestion rails feed one `record(config, source)` sink; precedence by recency with a
source-rank tiebreak so a fresh authoritative launch is never clobbered by a lagging scrape.

### 4.1 Rail 1 — launch-time capture (floor, every harness)

At the instant c11 types a launch line it knows the exact resolved `{harness, model, effort}`
(`launchAgentSurface`, `AgentLaunchPlanner`, the socket handler, blueprint). One
`recordLaunch(resolved, source)` there updates `recent` **and** appends the stats log. This alone
makes most-recent correct for the launch-through-c11 case with zero external dependency, and is what
makes the stats rail complete for launches c11 itself performs.

### 4.2 Rail 2 — Claude Code hook (live, mid-session) — claude-code only

**claude-code is the only harness with a live mid-session rail.** `/model` and `/effort` change the
active model inside a running claude session, invisible to launch-time capture. c11 already injects a
`--settings` hooks file (`Resources/bin/claude`) wiring `c11 claude-hook <event>`, and the handler
already parses `transcript_path`. On `Stop` / `prompt-submit` (already firing), read the **last
assistant record** in the transcript JSONL; its `model` is the currently-active model →
`record(.sessionHook)`. No new claude hook event; bounded tail, off-main, per the existing hook
threading. If a future claude exposes `model` in hook stdin, prefer that. Effort is not always in the
transcript; where absent it stays at last-known and `field_sources.effort` reflects that.

### 4.3 Rail 3 — every non-claude-code harness (best-effort scrape) + the general blind spot

**The mid-session blind spot is general, not codex-specific.** No harness other than claude-code has a
hook rail, so a mid-session model change (`/model` or equivalent) on **any** of codex, grok, kimi,
opencode, github-copilot, pi, or omp is **not observed live**. Launch-time capture (rail 1) is the
floor for all of them.

pi/omp already have `PiScraper`/`OmpScraper` reading session JSONL for resume; extending them (and
adding opencode's) to surface the active model → `record(.scrape)` **narrows** the window in v2 —
best-effort and eventually-consistent, not truly live. grok, kimi, github-copilot, and codex have no
scraper today, so they stay launch-capture-only until one is written (codex's session store is the
natural next candidate).

**UI honesty (Decision §8).** Wherever the UI would imply a non-claude harness's shown model is
current, it renders a **subtle hint** ("does not report live model changes") next to that most-recent
value, keyed off `field_sources`/harness so claude-code (which *is* live) never shows it. Never a
wrong-but-confident value.

### 4.4 Source ranking

`launch (just happened) ≥ sessionHook (live) ≥ scrape (eventually-consistent)`. A stale scrape never
overwrites a newer launch.

---

## 5. Launcher UX — the A button

> **Clickable prototype:** `docs/design-prototypes/model-picker/` (validated in a c11 browser
> surface). Deep-link scenes: `#sheet`, `#sheet-router`, `#sheet-greg`, `#stats`. Its README carries
> the touchpoint map and the popover-vs-menu argument that revised Decision §8.8 below.

The A button is a bonsplit `SplitToolbarButton` labeled `"A"`. Its left-click already launches the
default (`launchAgentSurface`); its dropdown seam (`menuItemsForNewTab` / `selectNewTabMenuItem`)
currently sets the default via a bonsplit `contextMenu`.

**Tier 1 is a custom popover, not an enriched menu (Decision §8.8).** The shortlist needs per-row pin
affordances, effort/system-prompt/cost chips, and hover states — none of which survive an `NSMenu`.
So the A button's secondary gesture (right-click / a caret / ⌘⇧A) triggers a **c11-owned popover
anchored to the button's frame**, and c11 renders the rich rows itself. bonsplit's only role is the
trigger: a small delegate callback ("agent menu requested at this rect") replaces the menu-item
vending. Tier 2 (configure) is a SwiftUI sheet sharing `CreateWorkspaceSheet` idioms.

### 5.1 Gesture model (Decision §8: click launches, pin sets default)

Inside the tier-1 popover:

- **Row click → launch that config now.**
- **Pin glyph (○ ghost on hover → gold ●) / ⌥-click → set as default** without launching; the pinned
  default is marked inline, and pinning toasts what a plain click on A now does.
- **Keyboard:** ↑↓ select, ⏎ launch, ⌥⏎ set default, 1–9 launch the Nth row, esc close.

This changes today's "click = set default" (which predates a launchable library) to launch-on-click.
The two gestures are visually distinct on every row — only a real popover can render that, which is
why tier 1 is a popover, not a menu (§5 intro, Decision §8.8).

### 5.2 Wireframe

```
  Right-click / long-press  ⟨A⟩ :

  ┌──────────────────────────────────────────────────────────┐
  │  Launch agent                                            │  ← section header (inert)
  │                                                          │
  │  ●  Opus deep        claude · Anthropic   high   $5/$25  │  ← DEFAULT (●). click = launch
  │  ○  Gregorovich      claude · Anthropic   ·blank·        │  ← replace/"" system prompt
  │  ○  Codex hi         codex · OpenAI       high   —       │
  │  ○  Cheap router     omp · deepseek       —      $0.3/$1 │
  │        └ [📌] on each row → set as default (no launch)   │
  │  ────────────────────────────────────────────────────── │
  │  ↻  Most recent      Codex · gpt-5.2      just now  ⓘ    │  ← click = launch recent; ⓘ = non-claude "no live model" hint
  │  ────────────────────────────────────────────────────── │
  │  ☐  Default follows most recent                          │  ← the §3 mode toggle
  │  ✎  Manage configs…                                      │  ← Settings editor (§5.4)
  │  📊 Launch stats…                                         │  ← opens the stats view (§5.5)
  └──────────────────────────────────────────────────────────┘

  ⟨A⟩  left-click → launch effectiveDefault      tooltip → "Launch agent — Opus deep · Opus · high"
```

Cost column reads the sibling token-cost catalog (`c11 token-cost <model> --json`); absent/stale →
column omitted, never blocks. A `·blank·` / mode chip marks non-inherit system prompts.

### 5.3 At-a-glance current config on the button

- **v1:** tooltip carries the resolved default's name/model/effort/provider (`tooltips.newAgent` +
  `refreshSplitButtonTooltips()` already exist; a string change).
- **v2:** subtle model-family accent on the "A" glyph (1px underline / tint), quiet in the dense bar.

### 5.4 Config editing / management (Settings → Agents & Automation)

A **Saved Configs** subsection above the existing per-harness editor:

```
  Saved configs
  ┌────────────────────────────────────────────────────────┐
  │  ⠿  Opus deep       claude-code   opus     high     ✎ ⌫ │  ← drag ⠿ reorders
  │  ⠿  Gregorovich     claude-code   opus     sys:blank ✎ ⌫│
  │  ⠿  Codex hi        codex         gpt-5.2  high     ✎ ⌫ │
  │  ⠿  Cheap router    omp           deepseek/…  —      ✎ ⌫ │
  │  ＋ New config                                          │
  └────────────────────────────────────────────────────────┘
  Default:  ( Opus deep ▾ )     ☐ follow most recent

  ── Edit config: “Gregorovich” ────────────────────────────
  name           [ Gregorovich          ]
  harness        ( Claude Code ▾ )                 ← drives which controls show
  model          ( Opus ▾ )   Inherit / Opus / Sonnet / …     ← router harness: grouped by provider (§1.2)
  effort         ( Inherit ▾ )                     ← hidden when EffortAxis == .none
  system prompt  ( Replace ▾ )  Inherit / Append / Replace     ← disabled when SystemPromptAxis == .none
                 [                        ]  (empty = blank slate)
  ▸ advanced (command · initial prompt · env)      ← the full-recipe overrides; each “inherit” by default
```

Every control's "Inherit" state pulls from the harness base (§1.3). The advanced disclosure exposes
command/initial-prompt/env overrides (the full recipe), each defaulting to inherit.

### 5.5 Stats view + keyboard/palette

- **📊 Launch stats:** a small view (and `c11 config stats`) rendering the aggregate — per-model %,
  per-harness, per-provider, over today / 30d / all-time. "Opus 87% (412)".
- **Command palette (Cmd-Shift-P):** `Launch Agent: <name>` per config, `Launch Agent (default)`,
  `Toggle: default follows most recent`, `Agent Launch Stats`.
- **In-menu:** number keys 1–9 launch the Nth config.

### 5.6 Graceful degradation

- **Harness not installed:** PATH-probe (cached) → row disabled + "not installed"; `agent.launch`
  already returns a *warning* (not error) so a forced launch still opens the pane with the shell's own
  error.
- **Axis absent:** model/effort/system-prompt controls hide/disable (Settings already gates model &
  effort this way).
- **Catalog absent/stale:** cost column omitted.
- **Config file missing/corrupt:** fall back to the seeded factory config; never fail a launch.

---

## 6. CLI + socket surface

`c11 config` family, reading/writing the state-root files (app-down capable), with socket `config.*`
methods off-main per the threading policy.

```
c11 config list [--json]                          # configs + default(+mode) + most-recent
c11 config recent [--json]                         # observed most-recent, with per-field source
c11 config stats [--window today|30d|all] [--by model|harness|provider] [--json]   # the §2.4 rollup
c11 config save <name> --harness <k> [--model] [--effort]
        [--system-prompt-mode inherit|append|replace] [--system-prompt <text>|--system-prompt-file <p>]
        [--command <c>] [--initial-prompt <p>] [--env KEY=VALUE ...]
c11 config edit <name|id> [ …same field flags… ]
c11 config rm <name|id>
c11 config reorder <name|id> --to <index>
c11 config default <name|id> | --follow-recent | --pin-current
c11 config launch <name|id> [--pane|--workspace|--new-workspace] [--cwd] [--prompt|--prompt-file] [--json]
```

`config launch` is a thin client over the existing `agent.launch` (which already composes
harness+model+effort+placement+identity atomically); it additionally passes the config's
system-prompt/command/env overlay and reuses `AgentLaunchPlanner`'s error codes. `--pin-current`
snapshots `recent` into a saved config and pins it.

**Skill sync (HARD RULE):** any command here lands in `skills/c11/SKILL.md` +
`skills/c11/references/api.md`, then `scripts/sync-installed-skills.sh c11`.

---

## 7. Integration points

| Surface | Interaction |
|---|---|
| `DefaultAgentResolver` / `AgentLaunchPlanner` | Same composition; gains the config-overlay-first value source and a `systemPromptArg` injector. |
| A button (`launchAgentSurface`, bonsplit menu seam) | Click launches; pin sets default; toggles mode. Every launch calls `recordLaunch` (recent + stats). |
| `c11 launch-agent` / `agent.launch` | `config launch` is a thin client; also calls `recordLaunch`. Gains system-prompt params. |
| `NextAgentOverride` (sibling) | Sits above `effectiveDefault`; its spawns still feed recent + stats. |
| Token-cost catalog (sibling) | Read-only cost column via `c11 token-cost … --json`. This design never writes catalog data. |
| Claude hook (`Resources/bin/claude`, `claude-hook`) | Rail 2: active model from `transcript_path`. No new hook event. |
| pi/omp/opencode scrapers | Rail 3 (v2, best-effort): extend to surface active model, narrowing the non-claude blind spot. grok/kimi/copilot/codex have no scraper yet → launch-capture only. |
| Events stream | Optional: also emit `agent.launched` for live observers; the durable stats source of truth is `agent-launches.jsonl` (survives stream rotation). |
| `AgentLaunchTemplate` | New `systemPromptArg` field (append/replace flag styles), seeded per harness. |
| Bonsplit A button | Tier 1 is a **c11-owned popover** anchored to the button, not a bonsplit menu (chips/pin/hover can't live in an `NSMenu`). bonsplit change is small: a delegate callback "agent menu requested at rect" that replaces `menuItemsForNewTab` vending; c11 renders the popover. That trigger callback is generic → **flag upstreamable to cmux**; submodule-push discipline applies. |
| Tier-2 configure sheet | New SwiftUI sheet sharing `CreateWorkspaceSheet` anatomy (gold CTA, kbd affordances); editor reuses the `editingAgentSupports*` gating generalized to the `ModelAxis`/`EffortAxis`/`SystemPromptAxis` descriptors (§1.2). |

---

## 8. Decisions (operator interview, 2026-07-20)

1. **Saved-config scope → full launch recipe.** A config carries model/effort/system-prompt and,
   via an advanced tier, command/initial-prompt/env, each layered over the harness Settings base with
   an explicit inherit-vs-override merge (§1.3).
2. **Menu gesture → click launches, pin sets default** (§5.1). A deliberate change from today's
   click-sets-default.
3. **Most-recent → persists across relaunch** (§2.3); `follow-recent` resumes across restarts.
4. **Mid-session model change on any non-claude-code harness → silent blind spot.** Only claude-code
   reports live (via its hook). Every other harness (codex, grok, kimi, opencode, github-copilot, pi,
   omp) is tracked at launch time; a subtle "does not report live model" hint shows where a stale
   value would otherwise mislead (§4.3). Best-effort scrapers for pi/omp/opencode land in v2 and
   narrow (not close) the window; grok/kimi/copilot/codex have no live signal.
5. **System prompt → three modes (inherit / append / replace)**; `replace` + "" = Gregorovich blank
   slate; per-harness delivery, disabled where unsupported (§1.4).
6. **Stats → durable `agent-launches.jsonl` append-log + rolled-up counters**, surfaced by
   `c11 config stats` and a 📊 view (§2.4, §5.5). Log stores resolved axes + mode, never prompt text.
7. **Provider for router harnesses → derived prefix, model list grouped by provider** (§1.2); no
   first-class provider control.
8. **Tier-1 picker → a c11-owned popover anchored to the A button, not bonsplit `contextMenu`
   enrichment** (revised after the picker prototype). An `NSMenu` cannot render the shortlist's
   per-row pin affordance, effort/system-prompt/cost chips, or hover states; a popover can. bonsplit's
   role shrinks to a generic "agent menu requested at rect" trigger callback (still upstreamable to
   cmux). Tier-2 configure is a SwiftUI sheet on `CreateWorkspaceSheet` idioms. See
   `docs/design-prototypes/model-picker/README.md` §4.1. *(This supersedes the earlier "enrich
   `BonsplitNewTabMenuItem`" call.)*

**Residual implementation-time items** (not blocking design; resolved during build like effort was):
per-harness system-prompt flag mapping beyond claude-code; whether to also emit `agent.launched` on
the events stream in v1 or v2; optional history-log rotation policy. **From the picker prototype
(README §4):** shortlist cap when a library grows past ~8 (cap at N + let "view all" absorb the tail);
the recent-row display when a launch came from an ad-hoc path with no config id (show resolved axes,
no name); and confirming **⌘⇧A** is free as the open-picker accelerator.

---

## 9. Recommended first cut

| Phase | Scope | Delivers |
|---|---|---|
| **v1** | `AgentConfigLibraryStore` + `agent-configs.json` (full-recipe library, default+mode, persisted recent). System-prompt field (3 modes) with claude-code delivery. **Rail 1** launch-time capture. **Stats rail**: `agent-launches.jsonl` + aggregate + `c11 config stats` + 📊 view. Enriched A-button menu (launch / pin / most-recent / mode / manage / stats). Settings Saved-Configs editor with inherit-aware controls + provider grouping. `c11 config` CLI + `config.*` socket. Tooltip at-a-glance. Cost column iff catalog present. | The whole operator-facing primitive + lifetime stats, correct for launch-through-c11, zero dependency on hooks or the sibling catalog. |
| **v2** | **Rail 2** (claude hook → live mid-session model). **Rail 3** (extend pi/omp/opencode scrapers; add a codex scraper) — best-effort, narrowing the non-claude mid-session blind spot rather than fully closing it. System-prompt delivery for non-claude harnesses that support it. Model-family accent badge. Palette entries + in-menu number accelerators. | Most-recent true even when the model changes outside c11's launcher; keyboard-first launch. |
| **v3** | Optional events-stream emission, history-log rotation, Settings "override active" banner (shared with the fader plan). | Polish. |

v1 alone satisfies the directives: a curated full-recipe library, a remembered default with an
obvious (and persistent) most-recent relationship, launch-accurate tracking, a first-class A-button
interaction, system-prompt control (incl. the blank-slate case), and lifetime "87% Opus" stats. v2
closes the "changes outside c11" loop. Each phase is a normal C11 ticket → PR through the
lattice-orchestrator flow. Tests: library codec + merge/precedence resolution, `effectiveDefault`,
source-ranked `record()`, stats aggregation/windowing, derived axis descriptors, system-prompt flag
rendering, and CLI validation are all pure logic → `c11-logic` (fast local loop). No source-text/AST
tests (repo policy). Hook/scraper reads get fixture-fed tests, never live-session tests in the
default suite.

---

*Architect-only deliverable. `needs_human` set on C11-175. Stopping for operator review before any
implementation.*
