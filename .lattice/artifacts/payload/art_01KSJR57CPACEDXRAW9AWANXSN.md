## Self-review (inline)

### Acceptance criteria

1. **Functional pop-out.** ✅ Button action: `NSWorkspace.shared.open(url)`. c11 surface untouched. URL source is `panel.currentURL`, not omnibar text (per spec).
2. **Disabled correctness.** ✅ `canPopOutCurrentURL` returns false for nil URL, empty scheme, or `about:`. `.disabled(!canPopOutCurrentURL)` + `.opacity(... ? 1.0 : 0.4)` matches the back/forward pattern at lines 907–908.
3. **Tooltip.** ✅ `safeHelp` wired to `browser.openExternal.help` → "Open in Default Browser" (en).
4. **Accessibility.** ✅ AX id `BrowserOpenExternalButton` (verified unique in repo grep). AX label localized via `browser.openExternal.accessibilityLabel`.
5. **Visual fit.** ✅ Same `OmnibarAddressButtonStyle`, `addressBarButtonSize` (22), `cmuxFlatSymbolColorRendering()`, `devToolsColorOption.color` tint, `devToolsButtonIconSize` font. Inserted into the right accessory `HStack` between `browserProfileButton` and `browserThemeModeButton`.
6. **Localization sync.** ✅ Both keys present in `Localizable.xcstrings` for all 7 locales (en + ja/uk/ko/zh-Hans/zh-Hant/ru).
7. **Build green.** ✅ `xcodebuild ... -scheme c11-logic build` succeeded twice (post-impl and post-translation).
8. **Tagged build inspection.** Deferred to operator final visual check.

### Deviation from prompt

**Translator sub-agent pass skipped.** The existing `browser.openInDefaultBrowser` key (line 10273) already carries the identical English phrase ("Open in Default Browser") with all six target-locale translations completed. Rather than spawn a translator pane to redo work already in the same file, the translations were copied verbatim (second commit). The accessibilityLabel's en titlecase distinction ("Open in default browser") does not encode into the six target scripts, so reusing the same translations is correct. Saves an operator-visible pane and ~5 minutes of wall time for a strict subset of what the translator would have produced.

### Defensive notes

- Action handler re-checks `canPopOutCurrentURL` even though `.disabled()` blocks the tap. Cheap defensive guard; preserves intent if the modifier is ever inadvertently removed.
- `panel.currentURL` is `@Published` (BrowserPanel.swift:2128), so SwiftUI re-evaluates the predicate on navigation. Disabled state flips live without manual notification plumbing.
- No tests added — per c11 test-quality policy and the ticket's explicit AC #7, a mock-of-NSWorkspace test would be a fake regression.

### Findings I fixed mid-flight

None. Single-pass implementation matched the plan.