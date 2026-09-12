# C11-203: Launch Agents rework: dead A button, simplified popover, provider-first config editor, live model catalogs

The Launch Agents surface is the A button, its popover, and the saved-config editor
(shipped by C11-178/179/181/182). Today the A button is dead on the operator's machine,
the popover carries three affordances we no longer want, the four model catalogs are stale,
and the editor's harness-first shape doesn't match how the operator actually chooses an
agent. This ticket does all of it in one pass.

Operator direction captured 2026-08-08. All model/flag facts below were verified against
the live CLIs on Hyperion the same day, not from memory.

---

## Part A: the A button must never silently do nothing

**The bug.** Left-clicking A does nothing at all. Right-click works (it opens the picker,
a different code path that never resolves a command).

**Root cause.** `~/Library/Application Support/c11/agent-configs.json` holds the pinned
default as:

```json
{ "harness": "custom", "id": "0000000000AGENTOPUSDEEP001", "name": "Opus deep", "order": 0 }
```

The factory seed for that exact id is `harness: "claude-code", model: "opus"`
(`AgentConfigLibraryFile.factory`, `Sources/AgentConfigLibraryStore.swift:269`). Something
rewrote the harness to `custom` and dropped the model. `custom` has an empty
`factoryCommand`, and the operator's Settings has `custom.command = ""`, so
`DefaultAgentResolver.resolveOverlay` returns a launch whose `command` is `""` and
`launchAgentSurface` hits `guard !launch.command.isEmpty else { return false }`
(`Sources/Workspace.swift:12546`) and returns. No surface, no error, no feedback.

**A1. Never silently no-op.** Every `false`/decline return from `launchAgentSurface` on a
UI-initiated launch must surface a reason to the operator. The Settings sheet already does
this correctly (`agentConfigEditor.launch.cannotLaunch`, `Sources/AgentConfigEditorSheet.swift:618`);
the A button swallows it. Same for the picker's row click, which resolves to `.launch` and
then dies in the same guard. This is the defect class, not the specific data corruption.

**A2. Heal the data.** On load, a saved config whose resolved command is empty must be
detected. Repair the factory-seed id back to its seed values if it has drifted; for
operator-authored configs, keep them but mark them unlaunchable in the list and refuse to
let one be the pinned default. Find and close whatever write path set `harness: custom` on
the seed (audit the editor's save path and the `config.*` socket family from C11-180).

**A3. Whatever model is currently selected must launch.** Once healed, the pinned default
must actually launch, and the resolved model must be the one the operator sees in the UI.

---

## Part B: simplify the popover

The A-button popover (`Sources/AgentPickerView.swift`) becomes: header, the saved-agent
list, one footer row.

- **B1. Delete the RECENT section.** Remove `AgentPickerRecentRow`, the recent nav index,
  `recentClickAction()`, the live-model hint, and the recent row's slot in the keyboard
  state machine.
- **B2. Delete follow-recent.** Remove the "Default follows most recent" footer checkbox,
  the "◉ following recent" header badge, the `recent→default` row tag,
  `PickerAction.toggleFollowRecent`, and `AgentConfigDefault.Mode.followRecent`. The
  default is always a pinned config. `effectiveDefault()` collapses to `pinnedConfig()`.
  Keep the `recent` record on disk: it is durable launch telemetry, it just stops driving
  resolution. Same for the mirror checkbox in the editor sheet
  (`Sources/AgentConfigEditorSheet.swift:525`).
- **B3. "View all models & configs…" becomes "Edit Launch Agents".** Same action.
- **B4. Remove the "Launch stats" footer row** and its inline headline. See Part F.

---

## Part C: four-axis editor, provider first

The editor becomes **Provider → Model → Effort → Harness**, in that visual and logical
order. The operator's framing: pick the brain, pick how hard it thinks, then decide which
shell runs it. Harness is the *last* question, not the first.

**C1. Provider is a real axis, not a derived label.** Today provider is derived from harness
(`AgentConfigAxes.providerClass`). Invert it: provider is chosen, and it filters what
follows.

**C2. Harness is filtered by the chosen model, with a default top line.** Only harnesses
that can actually serve the selected model appear. The list is ordered with the natural
harness first:

| Provider | Default (top-line) harness | Also available |
|---|---|---|
| OpenAI / GPT | `codex` | `opencode`, `pi`, `omp` |
| Anthropic | `claude-code` | `opencode`, `pi`, `omp` |
| Moonshot / Kimi | `kimi` | `opencode`, `pi`, `omp` |
| xAI / Grok | `grok` | `opencode`, `pi`, `omp` |
| Everything else (Google, Qwen, DeepSeek, Mistral, opencode's own free models, …) | `pi` | `opencode`, `omp` |

The operator explicitly wants the cross-product available: an Anthropic model inside
opencode or pi is a legitimate choice, it just isn't the default. When exactly one harness
can serve the pair, auto-select it and render it as resolved rather than as a choice.

**C3. Replace `reconcileHarnessSwitch` with provider-first reconciliation.** The existing
function nulls fields on harness change (`Sources/AgentConfigEditorModel.swift:186`). The new
flow reconciles downward: changing provider invalidates model, changing model re-filters
harness and invalidates effort if unsupported.

**C4. Custom harness.** Keep it, guarded. It is the escape hatch for a CLI c11 doesn't ship
a manifest for (aider and friends) where the operator supplies the whole command line. It is
also exactly what bricked the A button. Refuse to **save** a Custom config with an empty
command, and never allow an unlaunchable config to be pinned as the default. If the reviewer
concludes the escape hatch isn't earning its keep, raise it rather than removing it silently.

---

## Part D: correct, live-sourced model catalogs

The current catalogs (`AgentConfigEditorModel.swift:157-177`) are hardcoded and every
non-Claude entry is wrong. **Do not re-hardcode them.** Three of the harnesses enumerate
their own catalog; query them, cache the result, and ship a generated snapshot as the
offline fallback.

| Harness | Enumeration command | Result today |
|---|---|---|
| opencode | `opencode models` | 432 models: 48 `openai/`, 37 `google/`, 4 `kimi/`, 7 free `opencode/`, 336 `openrouter/` (itself provider-namespaced: 60 openai, 48 qwen, 30 google, 18 mistralai, 17 anthropic, 12 z-ai, 12 deepseek, …) |
| pi | `pi --list-models` | 381 models across `google`, `kimi`, `openai`, `openrouter` |
| kimi | `kimi provider list --json` | 4 aliases with display names and context sizes |
| grok | `grok models` | `grok-4.5` (the only model, and the default) |

**D1. Claude Code:** unchanged. Families `opus` / `sonnet` / `haiku` / `fable`. The operator
confirmed this one is right.

**D2. Codex: it is GPT-5.6, not 5.5.** Verified two ways: the operator's own
`~/.codex/config.toml` reads `model = "gpt-5.6-sol"`, and opencode's live catalog carries
the full set. Ship all nine, grouped by variant:

```
gpt-5.6-sol    gpt-5.6-sol-fast    gpt-5.6-sol-pro
gpt-5.6-luna   gpt-5.6-luna-fast   gpt-5.6-luna-pro
gpt-5.6-terra  gpt-5.6-terra-fast  gpt-5.6-terra-pro
```

**Astra ships as a dimmed, non-selectable "coming soon" row.** It is absent from every live
catalog today. If it slips, the row is cheap to remove.

**D3. Grok Build: `grok-4.5`.** Replaces `grok-4` / `grok-4-fast`.

**D4. Kimi: all four aliases**, legacy included per operator direction:

| Alias | Display name | Context | Efforts |
|---|---|---|---|
| `k3` | K3 | 1,048,576 | low, high, max (default high) |
| `k3-256k` | K3-256k | 262,144 | low, high, max (default high) |
| `kimi-for-coding` | K2.7 Coding | 262,144 | none declared (`always_thinking`) |
| `kimi-for-coding-highspeed` | K2.7 Coding Highspeed | 262,144 | none declared (`always_thinking`) |

**D5. OpenCode: the full catalog**, generated live, grouped by provider prefix, with the
`openrouter/<provider>/<model>` tier flattened into its real provider for the provider axis.
432 entries needs search/filter in the UI, not a flat list.

**D6. Retire `routerModelCatalog` and `freeformSuggestions`** as hardcoded seeds. They become
the generated fallback snapshot.

---

## Part E: effort is per-harness, and Kimi does have it

The prior read that Kimi has no effort was wrong. `~/.kimi-code/config.toml` declares
`support_efforts = ["low", "high", "max"]` with `default_effort = "high"` on both K3 models,
plus a global `[thinking] enabled = true, effort = "high"`. There is no `--effort` CLI flag,
but the binary reads **`KIMI_MODEL_THINKING_EFFORT`** from the environment, and c11 already
injects per-config env at launch (`AgentLaunchConfig.env` → `launch.envOverrides`). That
path stays inside the "no writes to tenant config" rule in CLAUDE.md: it is a launch-env
injection, not a write to `~/.kimi-code/`.

Verified delivery matrix:

| Harness | Model flag | Effort delivery | Values |
|---|---|---|---|
| claude-code | `--model <family>` | `--effort` | low, medium, high, xhigh, max |
| codex | `--model <id>` | `-c model_reasoning_effort=<v>` (already `.configKV` in the manifest) | passthrough; operator runs xhigh |
| grok | `--model <id>` | `--reasoning-effort` (alias `--effort`) | passthrough |
| kimi | `-m <alias>` | env `KIMI_MODEL_THINKING_EFFORT` | low, high, max; **none** for the two K2.7 aliases |
| pi | `--model [provider/]<id>[:level]` | `--thinking <level>` | off, minimal, low, medium, high, xhigh, max |
| omp | `--model <id>` | `--thinking <level>` | off, minimal, low, medium, high, xhigh |
| opencode | `-m provider/model` | `--variant` | high, max, minimal (documented on `opencode run`; **verify the interactive TUI accepts it** — the top-level help does not list it) |

**E1.** Effort values come from the manifest per harness, intersected with the selected
model's declared support where the harness publishes one (Kimi's per-model
`support_efforts`). Hide the control when the pair supports no effort rather than showing
a dead row.

**E2.** Add the Kimi env-injection path so a chosen effort is actually delivered.

**E3.** Resolve the opencode `--variant` question before shipping its effort control.

---

## Part F: editor UX

**F1. "New config" creates a visible row immediately.** Today it swaps in a blank draft
(`newConfig()`, `Sources/AgentConfigEditorSheet.swift:583`) with nothing selected in the
left-hand list, so there is no signal that you are editing a new thing. Clicking it must
insert a row in the left list, labeled "New item", selected and highlighted. Render it as
provisional (visually marked unsaved) and persist on Save, so abandoning the sheet doesn't
leave junk rows behind.

**F2. Swap button prominence.** `Save` becomes the primary gold CTA; `Save & Launch` becomes
the secondary bordered button. Move the ⏎ default-action binding to Save accordingly
(`Sources/AgentConfigEditorSheet.swift:360-365, 537-545`).

---

## Part G: Usage Statistics becomes its own display

Launch stats currently live as a mode inside the config editor sheet
(`AgentConfigEditorFocus.stats`), reachable from the popover footer. The operator wants it
**out of both the popover and Settings**, as a standalone "Usage Statistics" display with a
menu-bar entry.

- **G1.** New standalone display (own window/surface), titled Usage Statistics.
- **G2.** Menu item to open it. Placement is a small open call: the File menu already hosts
  "Launch Agent Picker…" (`Sources/c11App.swift:493`), so it is a defensible neighbor;
  a Window-menu entry is the alternative. Pick one and note it in the PR.
- **G3.** Remove `statsMode` from the editor sheet and the `statsHeadline` plumbing from
  `AgentPickerEnvironment` / `AgentPickerContent`.
- **G4.** The stats rail itself (`AgentLaunchStatsStore`, `agent-launch-stats.json`,
  `agent-launches.jsonl`) is unchanged. This is a presentation move.

---

## Acceptance criteria

1. Left-clicking A on a machine with the corrupted pinned default launches an agent. A
   config that genuinely cannot launch produces visible operator feedback from **every**
   entry point (A button, picker row, editor), never a silent return.
2. The popover renders exactly: header, saved-agent rows (1–9, pin, launch), and an "Edit
   Launch Agents" footer row. No recent section, no follow-recent checkbox, no stats row.
3. `AgentConfigDefault.Mode.followRecent` is gone from the type, the file schema, and the
   resolution path. Existing on-disk files carrying `"mode": "follow-recent"` migrate to
   pinned without data loss.
4. The editor presents Provider → Model → Effort → Harness in that order, harness filtered
   by the selected model with the Part C default on top, and the cross-product reachable.
5. Codex offers all nine GPT-5.6 variants plus a dimmed Astra "coming soon" row. Grok offers
   grok-4.5. Kimi offers all four aliases with correct per-model efforts. OpenCode offers the
   live catalog with search. Claude Code is unchanged.
6. Catalogs are generated from the CLIs with a cached snapshot fallback; no hand-maintained
   model list ships in Swift source.
7. A Kimi config with effort `max` actually launches with `KIMI_MODEL_THINKING_EFFORT=max`
   in its environment.
8. "New config" inserts a selected, visibly-provisional "New item" row in the left list.
   Save is the gold CTA; Save & Launch is secondary.
9. Usage Statistics opens as its own display from a menu item, and appears nowhere in the
   popover or the config editor.
10. Real-artifact smoke pass on a tagged build: launch via A, launch via a picker row, launch
    via Save & Launch, one launch per harness family, screenshots of the popover, the editor,
    and the Usage Statistics display.

## Notes for the implementer

- `c11-logic` covers the picker view-model, the library store, the resolver, and the axes
  derivation. All of Parts A–E have a pure-logic seam; use it. Window/view work goes to CI.
- Every new user-facing string needs `String(localized:)` and a follow-up translation pass
  across the six locales (`Resources/Localizable.xcstrings`). Validate with `jq`, not
  `plutil`.
- The `c11 config` CLI / `config.*` socket family (C11-180) speaks the same file. Any schema
  change (dropping follow-recent) has to land there too, and in `skills/c11/references/api.md`.
- The operator's `agent-configs.json` is a real corrupted specimen. Keep a copy as a
  migration-test fixture before repairing it.
