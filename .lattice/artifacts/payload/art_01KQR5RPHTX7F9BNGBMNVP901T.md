# Plan Review — C11-6 (App chrome UI scale)

## 1. Verdict

**FAIL (plan-level)**

## 2. Summary

Reviewed C11-6's plan: a persisted "App Chrome UI Scale" preset with a token resolver, sidebar workspace card wiring, Bonsplit appearance plumbing (Phase 1 via existing knobs, Phase 2 via new public Bonsplit knobs), and surface-title-bar wiring. The plan is unusually thorough — accurate code-area survey (line numbers verified), strong typing-latency awareness, sensible phase split, exemplary "Open decisions" section. **The blocker is the Bonsplit submodule push target**: the plan instructs PR'ing to `manaflow-ai/bonsplit:main` and referring to a `manaflow` fork remote, both of which are wrong on the ground (the remote is `origin = Stage-11-Agentics/bonsplit`, and pushing to `manaflow-ai/*` is a hard-rule violation per saved operator memory). Two structural issues compound it: the proposed Workspace integration test is gated on whether `Workspace` can be constructed without `GhosttyApp.shared`, and the live-update path depends on a custom `Notification` that bypasses external `defaults write` paths. Each is small to fix individually, but together they take the plan back to planning rather than implementation.

## 3. Issues

**[CRITICAL] §"Submodule discipline" / Phase 2 — Bonsplit push/PR target is wrong on two axes**

The plan says: "`cd vendor/bonsplit && git push manaflow <branch>` (Bonsplit fork remote is `manaflow`, mirroring the ghostty pattern)" and "Open a PR to `manaflow-ai/bonsplit:main` (these knobs are upstream-worthy…)". On the ground:

1. `vendor/bonsplit`'s only remote is `origin = https://github.com/Stage-11-Agentics/bonsplit.git`. There is no `manaflow` remote; the push command will fail.
2. The Bonsplit upstream lineage per `CLAUDE.md` is **`almonk/bonsplit`**, not `manaflow-ai/bonsplit`. There is no `manaflow-ai/bonsplit` repo to PR against.
3. Saved operator memory (`feedback_no_upstream_writes.md`) is explicit: **"never push, branch, or PR against manaflow-ai/* … All work stays in Stage-11-Agentics forks."** Following the plan as written would either fail at the push step or violate this hard rule.

This matters because submodule discipline is also called out as mandatory in `CLAUDE.md` ("verify with `git -C vendor/bonsplit merge-base --is-ancestor HEAD origin/main`"). A wrong remote name leads directly to the orphaned-detached-HEAD failure mode the project guards against.

**Recommendation:** Rewrite the discipline section as: (a) push the Bonsplit branch to `origin` (Stage-11-Agentics/bonsplit); (b) open the PR against `Stage-11-Agentics/bonsplit:main`; (c) optionally flag the new Appearance knobs as an upstream-suggestion candidate to `almonk/bonsplit` per the cmux↔c11 bidirectional pattern in `CLAUDE.md`, but **never** to manaflow-ai. Update the merge-base verification step accordingly. Drop the "mirroring the ghostty pattern" sentence: that pattern doesn't hold here either — `ghostty` in this checkout is also `origin = Stage-11-Agentics/ghostty` with no `manaflow` remote.

---

**[MAJOR] §"Persistence design" / §"Bonsplit wiring" — live-update relies on a custom Notification that external writers won't post**

`@AppStorage` propagates UserDefaults changes to subscribed SwiftUI views automatically, so the sidebar updates correctly regardless of writer. But the plan's `Workspace.applyChromeScale(reason:)` is wired only to `ChromeScaleSettings.didChangeNotification`, which the plan says is posted by the Settings UI setter and the optional socket command. Any other writer — `defaults write com.stage11.c11 chromeScalePreset large`, a future migration path, a keyboard shortcut not yet imagined, or even the `@AppStorage` binding's own write that a future code path doesn't accompany with a manual post — will update the sidebar but leave the Bonsplit tab strip stale until the next chrome-affecting event (theme change, etc.). That's a partial-update bug class which is exactly the kind of "looks fine in dev, drifts in the wild" issue that's painful to root-cause later.

**Recommendation:** Use `UserDefaults.standard` KVO on `chromeScalePreset` (or `NSUserDefaultsDidChangeNotification`) for `Workspace`'s subscription, instead of (or in addition to) the custom `didChangeNotification`. KVO fires regardless of writer. Keep the custom notification as belt-and-suspenders only if there's a reason to.

---

**[MAJOR] §"Test plan" item 4 — primary integration test is gated on a "if it works in unit context" caveat that probably won't work**

The plan's test #4 ("Workspace appearance plumbing") is the only proposed test that actually exercises the resolver → Bonsplit appearance path end-to-end. The plan acknowledges: "if `Workspace` cannot be constructed in unit-test context (depends on `GhosttyApp.shared`), this test moves to the Validate phase as a runtime check." Given how many existing `Workspace` paths route through `GhosttyApp.shared` in `Workspace.swift`, it's highly likely this caveat fires.

If it does, the only automated tests are pure token math (compute multiplier × constant) — which doesn't catch a regression where, say, someone adds a new field to `BonsplitConfiguration.Appearance` and `Workspace.bonsplitAppearance(...)` quietly stops threading the scale through. The acceptance criterion "Tests cover scale resolution/persistence and any pure token math" is met narrowly, but the actual integration is invisible to CI.

**Recommendation:** Refactor `Workspace.bonsplitAppearance(...)` so the chrome-scale wiring lives in a *pure*, testable helper — e.g. `Workspace.applyChromeScaleTokens(_ tokens: ChromeScaleTokens, to appearance: inout BonsplitConfiguration.Appearance)` — and call that from both the existing static factory and the new `applyChromeScale(reason:)`. Then the test becomes "given a default `Appearance` and `tokens` with `multiplier=1.12`, the helper produces an `Appearance` with `tabTitleFontSize ≈ 12.32`, `tabBarHeight ≈ 36.96`, …". This decouples the test from `GhosttyApp.shared` and gives you a clean seam per the c11 test-quality policy ("If a behavior cannot be exercised end-to-end yet, add a small runtime seam or harness first, then test through that seam").

---

**[MAJOR] §"Bonsplit wiring" Phase 2 deferral path vs. acceptance criteria**

The plan says: "If the Bonsplit PR review takes longer than the c11 PR, the c11 PR should ship Phase 1 only and link a follow-up commit for Phase 2 once the submodule lands." But the ticket's acceptance criteria explicitly list "Bonsplit surface tab titles, tab icons/accessories, and tab bar height scale visibly". Phase 1 alone scales tab titles, the *public* `tabBarHeight` Appearance value, and accessory affordances (because Bonsplit's `accessoryFontSize` is already derived from `tabTitleFontSize`). It does **not** scale tab icons (`TabBarMetrics.iconSize` constant), tab item height (`TabBarMetrics.tabHeight`), or the tab bar shell (`TabBarView` reads `TabBarMetrics.barHeight = 30` directly, separate from `Appearance.tabBarHeight = 33`).

So a "Phase 1 only" merge would leave at least the *icons scale* acceptance criterion unmet. The plan downplays this ("validate at default size only and note 'icon scale follows Bonsplit pointer bump'") but the criterion is binary, not aspirational.

**Recommendation:** Either (a) commit to landing Phase 2 in the same c11 PR (Bonsplit PR is small and self-contained — three new public knobs with default-preserving initializers), or (b) explicitly negotiate the criterion down with the operator before splitting. Don't ship a partial that doesn't meet the criterion and call it done.

Also: while editing this section, be explicit that `glyphSize(for:)` (line 299–306) needs to read `appearance.tabIconSize` in Phase 2 — the plan currently says it "continues to derive from `appearance.tabIconSize`," but it currently reads `TabBarMetrics.iconSize`, so this is a real change, not a no-op.

---

**[MINOR] §"Sidebar wiring" — `@AppStorage` policy rationale is misstated**

The plan says: "Per `CLAUDE.md`'s typing-latency policy, do not add a new `@AppStorage` directly to `TabItemView`." But `CLAUDE.md`'s actual rule (verified at `Sources/ContentView.swift:10907–10913` and the existing typing-latency comment) prohibits adding **`@EnvironmentObject`, `@ObservedObject` (besides `tab`), or `@Binding` properties without updating `==`** — not `@AppStorage`. `TabItemView` already has 12 `@AppStorage` declarations (lines 10974–10994). The threading-via-parent recommendation is still defensible (one fewer `UserDefaults` observer per row, keeps the resolver computation amortized), but the rationale stated isn't quite right.

**Recommendation:** Either (a) restate as "the resolver is cheap to compute once at parent level and threading it as a precomputed `let` keeps `TabItemView`'s `@AppStorage` set from growing further," or (b) accept the existing pattern and add a `@AppStorage(ChromeScaleSettings.presetKey)` directly to `TabItemView` (no change to `==`, since the derived size flows into `body` as a `font` arg, not a stored property). Don't pin the choice to a CLAUDE.md rule that doesn't exist.

---

**[MINOR] §"Bonsplit wiring" Phase 1 — no-op guard axes underspecified**

The plan says `applyChromeScale(reason:)` will "mirror the shape" of `applyGhosttyChrome`'s no-op guard. The existing guard compares background hex, border hex, divider thickness, and active-indicator hex. The chrome-scale equivalent needs to compare `tabBarHeight`, `tabTitleFontSize`, `tabMinWidth`, `tabMaxWidth` (Phase 1) plus `tabIconSize`, `tabItemHeight`, `tabHorizontalPadding`, `tabBarShellHeight`, `tabCloseIconSize` (Phase 2). All `CGFloat`. Naive `==` is fine on these because they're produced by the same multiplier path each time, but the impl should be explicit so a future reader doesn't refactor it into something that drifts (e.g., comparing a freshly multiplied value against a previously stored multiplied value with a different intermediate cast).

**Recommendation:** Spell out the no-op axes in the plan (or in a code comment in the impl). One sentence is enough.

---

**[MINOR] §"Token resolver design" — `Workspace.bonsplitAppearance` becomes UserDefaults-dependent without a parameter seam**

The plan extends `bonsplitAppearance(...)` to read `UserDefaults.standard.string(forKey: ChromeScaleSettings.presetKey)` directly. That works, but it makes the function impure: it now has a hidden dependency on global state, which complicates the testability concern in MAJOR #3 above and makes Workspace init order more fragile (if anything writes the key after `init` but before the first `applyChromeScale` fires, you get a one-frame staleness).

**Recommendation:** Take the multiplier (or `ChromeScaleTokens`) as a parameter on `bonsplitAppearance(...)`, with the call sites resolving it from `UserDefaults.standard` once. This is the same shape `WorkspacePresentationModeSettings.mode(defaults:)` already follows in this codebase, and combines naturally with the testable seam above.

---

**[MINOR] §"Settings UI design" — picker style is not specified consistently**

The plan suggests `.pickerStyle(.segmented)` for the chrome scale preset picker, but the existing nearby pickers in `appearanceSettingsPage` (e.g. `SettingsPickerRow` for "Workspace Color Indicator") use the default `Picker` style with `controlWidth: pickerColumnWidth`. A segmented picker introduces a visual inconsistency in the Appearance pane. Probably fine, but worth a sentence justifying the choice (or matching the existing `SettingsPickerRow` shape).

**Recommendation:** Either match the existing `SettingsPickerRow(... selection: ...) { ForEach(...) { Text(...).tag(...) } }` shape, or note explicitly that segmented is a deliberate UX choice for the four-preset swatch and accept the visual delta.

## 4. Positive Observations

- **Code-area survey is accurate.** Every line number I spot-checked (`c11App.swift:4226`, `c11App.swift:5032`, `Workspace.swift:5326`/`:5382`/`:5404`/`:5419`, `BonsplitConfiguration.swift:138`, `TabItemView.swift:90`, `TabBarMetrics.swift:4`, `ContentView.swift:8314`/`:10914`/`:11237`/`:11240`/`:12596`/`:12748`, `SurfaceTitleBarView.swift:135`) matches the source. The 17-field `==` count for `TabItemView` is correct. That kind of grounded survey makes the plan trustworthy at a glance.
- **C11-5 hierarchy preservation is explicit.** The plan calls out that "the workspace title stays the largest, semibold element; secondary elements scale by the same multiplier so the title never gets visually outranked" — this is the kind of invariant that's easy to break silently and worth pinning down before code is written.
- **Phase split is sensible.** Phase 1 in c11-only code lands the resolver and the title/bar wiring; Phase 2 adds Bonsplit knobs. Even after the criticisms above, the split itself is the right shape — it lets the c11 PR demonstrate value early and treats the submodule change as a deliberate, separately-reviewable artifact.
- **Equatable + value-typed `ChromeScaleTokens` thread cleanly through the typing-latency-sensitive `TabItemView`.** The decision to derive sizes from a single `multiplier` (instead of per-token stored values) means `==` short-circuits to a single CGFloat compare — exactly the right shape for the hot path.
- **"Open decisions" section is exemplary.** Nine decisions, each with the recommendation and rationale, each clearly the operator's call (not the agent's). This is the format other plans should copy.
- **Out-of-scope list is concrete.** "No freeform slider for v1," "no per-workspace overrides," "no resizing of agent skills panel/command palette/mailbox" — the right boundaries to declare upfront.
- **Localization plan covers all six locales and the right keys.** Subtitle copy is realistic. The hand-off to the Translator sub-agent is in line with the project's localization workflow.
- **Test plan correctly distinguishes permitted from forbidden tests.** No grep tests, no xcstrings introspection, no AST fragments. The constraint is internalized.
- **Validation plan addresses live-update without focus changes, `c11 tree --no-layout` rebalance, Ghostty-unchanged check, and a screenshot pack.** All of these are exactly the visual/behavioral things that "code is correct" tests can't catch — and the plan asks for them at the right granularity.
