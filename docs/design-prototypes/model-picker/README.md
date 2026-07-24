# Model Picker — design rationale (C11-175, picker surface)

Clickable prototype for the **model-picker interaction**: the display a c11 user gets when choosing
or configuring which model an agent launches. Companion to `docs/agent-config-primitive-design.md`
(the parent design owns the data model and decisions; this owns the picker UI it references in §5).

**Open it:** `open docs/design-prototypes/model-picker/index.html` or a c11 browser surface.
Self-contained, no dependencies. Deep-linkable scenes for review: `#closed`, `#sheet`,
`#sheet-router`, `#sheet-greg`, `#stats` (default hash opens the picker popover).

Committed to the dark/void theme only — the app's freshest sheet (`CreateWorkspaceSheet`) already
forces `.colorScheme(.dark)`, and the Stage 11 aesthetic is void-first. A light pass would be a
follow-up, not a fork of this design.

---

## 1. Touchpoint map — where a model is chosen today

| # | Touchpoint | Who / gesture | What it sets |
|---|---|---|---|
| 1 | **A button, left-click** (`launchAgentSurface`) | operator, one click | launches the frozen default; no model visible at the button |
| 2 | **A button, right-click menu** (`menuItemsForNewTab` → bonsplit `contextMenu`) | operator | today: 9 harness names, ✓ current, **click = set default** (nothing launches) |
| 3 | **Settings → Agents & Automation** (`DefaultAgentSettingsView`) | operator | per-harness base: command, model (family picker or hidden), effort, prompt, env |
| 4 | **`c11 launch-agent` / `agent.launch`** (`docs/launch-agent-reference.md`) | agents/scripts | exact `--agent/--model/--effort` per spawn |
| 5 | **Project `.c11/agents.json`** | repo author | per-project override layer |
| 6 | **Hardcoded `--model` in the configured command** | operator | always wins (resolver detects, never double-injects) |
| 7 | **Sekhem fader tier** (`NextAgentOverride`, sibling plan) | external controller | session-scoped sticky override above the default |
| 8 | **In-TUI `/model` / `/effort`** | operator, mid-session | invisible to launch capture; claude-code only is recoverable (hook rail) |
| 9 | **Blueprint agent panes** | workspace blueprints | spawn through the same resolver |

The scatter is the problem: (1) launches blind, (2) configures without launching, (3) is a
different room, (4–9) never surface anywhere. The picker unifies **2 and 3** into one flow and makes
**1** legible (tooltip + terminal echo of the effective default), while 4–9 keep feeding the same
`recent` + stats rails per the parent design.

## 2. The flow

**Tier 1 — the picker popover** (right-click A / click the caret / ⌘⇧A):

- **Shortlist = the saved library, in library order.** Each row is one full recipe: name; harness ·
  provider · model sub-line; effort chip; system-prompt chip (`·blank·` in gold for the
  Gregorovich replace-empty case); `$in/$out` per Mtok from the cost catalog; a 1–9 key badge.
- **Click launches. The pin affordance sets the default** (○ ghost on hover → gold ●, or ⌥-click).
  This is decision §8.2 made physical: the two gestures are visually distinct on every row, and
  pinning toasts what a plain click on A now does.
- **Recent section** below the rule: what you last launched (any path), relative time, and — for
  every non-claude-code harness — a quiet ⓘ whose tooltip states the launch-capture blind spot
  (decision §8.4). Click relaunches it.
- **Footer:** the `follow-recent` toggle (mode §3 of the parent design, one visible checkbox —
  when on, the header shows `◉ following recent` and the effective default annotates accordingly),
  then `View all models & configs…` (⌘⏎) and `Launch stats` with the headline number inline
  ("87% Opus · 474 launches") so the stats rail earns its menu row.
- **Keyboard:** ↑↓ select, ⏎ launch, ⌥⏎ set default, 1–9 launch nth, esc close.

**Tier 2 — the configure sheet** (`View all`, or Settings → Saved Configs):

- Modeled on `CreateWorkspaceSheet`: same head/body/foot anatomy, gold CTA, kbd affordances.
- **Left: the library** — reorderable rows (⠿), gold ● on the pinned default, `+ New config`.
- **Right: the recipe editor**, top-down in axis-dependency order (harness → model → effort →
  system prompt → advanced), exactly the §1.1 gating:
  - **Harness grid** with provider identity per card; not-installed harnesses dim with a badge but
    stay pickable (launch degrades to the shell's own error, per §5.6).
  - **Model** renders per axis: claude → family list with an explicit **Inherit** row showing what
    it resolves to ("harness Settings → opus"); router harnesses → filterable list **grouped under
    provider prefixes** (§8.7 — provider is the model id, never a control); codex/grok/kimi/copilot
    → freeform field + suggestion chips; custom → axis-off note.
  - **Effort** chips in the harness's own vocabulary (claude tiers, pi/omp `--thinking` values,
    codex pass-through), hidden-with-note when the axis is absent.
  - **System prompt** tri-mode segmented control; `replace` + empty shows the gold "blank slate"
    note naming the flag it produces.
  - Every overridable field carries an **○ inherits / ● override** state chip so the §1.3 layering
    is always visible; advanced (command · initial prompt · env) sits folded and inherit-by-default.
- **Footer:** default picker + follow-recent (same state as tier 1), `Save`, gold **Save & Launch**.
  Save returns the config to the shortlist with a gold flash; Save & Launch is the "configured an
  exact model, go" path. Esc / ‹ Back returns to the popover — the two tiers feel like one surface.
- **Stats** render in the same sheet (window chips today/30d/all, gold bar for the leader, the
  `agent-launches.jsonl` provenance line) so "87% Opus" is one click from the A button.

## 3. Mapping to doc §5 / Swift implementation notes

| Prototype element | Lands in |
|---|---|
| Popover rows, sections, launch-vs-pin actions | `BonsplitNewTabMenuItem` enrichment (§7): needs `subtitle`, `trailingText`/cost, `isSection`, chip slots, and an `action: launch \| setDefault` — or, given the row density here, a custom `NSPopover`/SwiftUI popover anchored to the A button instead of a `contextMenu` (recommended; a menu can't render pin affordances, chips, or hover states) |
| Launch on click / pin sets default | flip `splitTabBar(_:didSelectNewTabMenuItem:)` semantics per §8.2; pin path calls the library store's `setDefault` |
| Terminal echo / button tooltip of effective default | `refreshSplitButtonTooltips()` string + v2 gold accent on the A glyph (§5.3) |
| Configure sheet | new SwiftUI sheet sharing `CreateWorkspaceSheet` idioms; the editor reuses `editingAgentSupportsModel/Effort` gating generalized to the `ModelAxis`/`EffortAxis`/`SystemPromptAxis` descriptors |
| Saved-configs list + reorder + default picker | `AgentConfigLibraryStore` (§2.1) |
| Cost column | `c11 token-cost <model> --json`; absent → column empty. Anthropic prices in the mock are real current pricing; other providers are plausible stand-ins |
| Recent row + ⓘ | `recent` + `field_sources` (§2.3, §4.3) |
| Stats view | `agent-launch-stats.json` aggregate + jsonl windows (§2.4) |

## 4. Open questions for the operator

1. **Popover vs enriched menu.** The prototype assumes a real popover (hover states, pin glyphs,
   chips). If we must stay inside bonsplit's `contextMenu`, the row loses the pin affordance and
   ⌥-click becomes the only set-default gesture — worth deciding before the bonsplit enrichment PR.
2. **Shortlist length.** Prototype shows all saved configs; if libraries grow past ~8, does the
   popover cap at N with "view all" absorbing the tail?
3. **Recent row identity.** When the recent launch came from an ad-hoc path (CLI with explicit
   flags, no config id), the row would show resolved axes without a name — mock shows the named
   case only.
4. **Stats placement.** Prototype puts stats inside the configure sheet (one surface, ‹ Back
   preserved). Alternative: its own small window. Sheet felt lighter.
5. **⌘⇧A** as the global open-picker accelerator — free today?

*Prototype validated end to end in a c11 browser surface (launch, pin, follow-recent toggle,
view-all → new config → save & launch → shortlist flash, number-key launch) and screenshotted
across all five scenes. Anthropic cost values are real current API pricing; router/OpenAI values
are plausible mocks standing in for the catalog.*
