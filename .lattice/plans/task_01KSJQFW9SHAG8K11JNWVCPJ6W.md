# Plan: C11-118 — Browser "Open in Default Browser" toolbar button

## 1. Insertion points in `Sources/Panels/BrowserPanelView.swift`

- **HStack call-site, line 871–874:** insert `openInExternalBrowserButton` between `browserProfileButton` and `browserThemeModeButton`.
- **View definition section:** add `openInExternalBrowserButton` computed property immediately after `browserProfileButton` (ends line 1005) and before `browserThemeModeButton` (begins line 1007).
- **Predicate:** add `canPopOutCurrentURL` near the other browser predicates (e.g. just above the new button definition).

## 2. The button view

```swift
private var openInExternalBrowserButton: some View {
    Button(action: {
        guard let url = panel.currentURL, canPopOutCurrentURL else { return }
        NSWorkspace.shared.open(url)
    }) {
        Image(systemName: "arrow.up.right.square")
            .symbolRenderingMode(.monochrome)
            .cmuxFlatSymbolColorRendering()
            .font(.system(size: devToolsButtonIconSize, weight: .medium))
            .foregroundStyle(devToolsColorOption.color)
            .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
    }
    .buttonStyle(OmnibarAddressButtonStyle())
    .frame(width: addressBarButtonSize, height: addressBarButtonSize, alignment: .center)
    .disabled(!canPopOutCurrentURL)
    .opacity(canPopOutCurrentURL ? 1.0 : 0.4)
    .safeHelp(String(localized: "browser.openExternal.help", defaultValue: "Open in Default Browser"))
    .accessibilityLabel(String(localized: "browser.openExternal.accessibilityLabel", defaultValue: "Open in default browser"))
    .accessibilityIdentifier("BrowserOpenExternalButton")
}
```

Mirrors `browserProfileButton` for style (OmnibarAddressButtonStyle, addressBarButtonSize, cmuxFlatSymbolColorRendering, devToolsColorOption tint) and the back/forward button pattern for the disabled-state opacity dimming.

## 3. The predicate

```swift
private var canPopOutCurrentURL: Bool {
    guard let url = panel.currentURL else { return false }
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme.isEmpty || scheme == "about" { return false }
    return true
}
```

`panel.currentURL: URL?` is `@Published` (see `Sources/Panels/BrowserPanel.swift:2128`), so SwiftUI re-evaluates the predicate when navigation lands.

## 4. New xcstrings keys

Two new entries in `Resources/Localizable.xcstrings`:

| Key | en source |
|---|---|
| `browser.openExternal.help` | `Open in Default Browser` |
| `browser.openExternal.accessibilityLabel` | `Open in default browser` |

English value lives in `defaultValue:` at the call site; xcstrings entry holds the en source-of-truth plus a stringUnit per locale. Following the existing pattern for `browser.profile.buttonHelp` (line 10414) and `browser.theme.buttonHelp` (line 11072), I'll insert the new entries in alphabetical order. Six locales (ja/uk/ko/zh-Hans/zh-Hant/ru) start empty — translator fills them.

## 5. Imports

`AppKit` is already imported (line 5), so `NSWorkspace.shared.open(_:)` is available without changes.

## 6. Translator sub-agent

After the implementation commit lands the English entries, spawn a translator in a fresh c11 split. Prompt file at `/tmp/c11-118-translator-prompt.md`. Translator's scope: the two new keys, six locales, second commit on `feat/browser-popout-button`, nothing else.

## 7. Verification

1. `xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug -destination "platform=macOS" build` — green compile.
2. Self-review against the 8 acceptance criteria.
3. Optionally `./scripts/reload.sh --tag popout-btn` for an operator-visible tagged build (mention tag in final report).
4. Open PR.

## 8. Out of scope (confirming)

No menu wiring, no keyboard shortcut, no right-click entry, no "open in specific browser" submenu, no surface-close-after-popout, no changes to `panel.currentURL` plumbing, no new tests (mock-only fakes blocked by c11 test-quality policy).
