# Post-merge review C11-359 (seat f, Claude Fable), merged head `a95823705c`

Needs you: nothing. The synthesis seat (`Synth 359`) owns reproduction and any repair loop.

- Reviewer: `agent:fable-md-pm-359`. Worktree `c11-worktrees/md-pm-359-f`, detached at `a95823705c3912d8def621e3b2b7ed3384f47a4c` (asserted; submodules ghostty `e6999ae7`, bonsplit `4ead5952` initialised by me; tree clean before and after; the only temporary edit was a scratch test, reverted with `git checkout`).
- Change read: `git show a95823705c` (33 files) plus every touched file as it now sits on main.
- Prior history read and not repeated: `review-C11-359-f.md`, `review-C11-359-a.md`, the synthesis and both verify rounds, `run-state.md`'s hardening list, the eviction ruling, both briefs.

## Verdict: FAIL (one blocking regression, low severity, two-line fix)

One behaviour that worked on main regresses under ordinary operator use (B1). Everything else I probed holds. Five non-blocking findings follow, two of them documentation drift the repair introduced after the pre-merge reviews.

## Blocking

### B1. A View > Appearance switch no longer reaches a mounted system-theme reader

- **Where:** `Sources/Panels/MarkdownPanel.swift:310-344` (the only appearance triggers are `AppleInterfaceThemeChangedNotification`, which fires on OS flips, and `didChangeOcclusionStateNotification`); `Sources/Panels/MarkdownPanelView.swift:292-300` (`updateNSView` is the only other `synchronize()` caller, and it does not fire on an appearance change); `Sources/Panels/MarkdownWebRenderer.swift:252-258` (`osAppearance` is read from `effectiveAppearance` only when `synchronize()` runs).
- **Scenario:** the OS is dark and c11's appearance mode is Light (or the reverse). The operator opens a markdown panel with the default `system` theme, then switches c11's appearance mode (View > Appearance, or Settings) to Dark. `c11App.applyAppearance` sets `NSApplication.shared.appearance`; terminals, chrome and the panel's own SwiftUI header follow at once. The reader stays light until the panel is remounted (switch workspace and back, or hide and re-show it) or the OS theme flips.
- **On main:** `MarkdownPanelView` built `cmuxMarkdownTheme` from `@Environment(\.colorScheme)` (`a95823705c~1:Sources/Panels/MarkdownPanelView.swift:327-328`), so the content followed the switch live.
- **Reproduced (Atlas, exact head, only a scratch test added):**
  - Round 2, invocation `d904d97963514712a34a4561adcce519`: a `MarkdownPanelView` hosted in an `NSHostingView` in a borderless window, `NSApp.appearance = .aqua`, reader resolves `light`; then `NSApp.appearance = .darkAqua`; polled `visible().theme.resolved` for 5 s: still `light`. `** TEST FAILED **`.
  - Round 3, invocation `178637a1e95f4547ac056acae9392fe7`: same host setup, every stage recorded in one run. `effectiveAppearance` of the web view: `Aqua` → `DarkAqua` immediately after the flip. Reader `theme.resolved`: `light` initially; still `light` 4 s after the flip; still `light` 2 s after `ThemeManager.shared.objectWillChange.send()`; still `light` 2 s after resizing and relaying out the host (so `updateNSView` did not run, or ran before the appearance changed); `dark` 2 s after a manual `renderer.synchronize()`. The renderer identity was unchanged throughout. `** TEST FAILED **` on the three stage assertions, the manual-synchronize assertion passed.
- **Why it blocks:** behaviour that worked on main regresses under ordinary operator use; the reader visibly disagrees with the rest of the window. Severity is low (cosmetic, self-heals on remount), so the synthesis seat may reasonably downgrade it to the hardening ticket; I rank it by the bar as written.
- **Fix direction (two lines):** override `viewDidChangeEffectiveAppearance()` on `MarkdownWKWebView` (or observe it in the renderer) and call `synchronize()`; it already diffs `loadedSettings`, so the call is a no-op when nothing changed. Alternatively drop `osAppearance` from `setSettings` so the bundle falls back to `prefers-color-scheme`, which WebKit derives from the view's effective appearance; but that leaves the explicit `S.os` path dead, so prefer the override. Witness: the round-3 probe (in my scratchpad and quoted below), which goes green once a flip reaches the reader.

## Non-blocking (ranked)

1. **Threat model and skill do not record the `mailto:` route the repair added.** `docs/security-threat-model.md` (markdown section) still says "HTTP(S) links follow c11's browser routing settings. Other schemes and arbitrary local files are refused", and `skills/c11-markdown/SKILL.md` says only "web links follow c11's browser routing settings". `MarkdownWebRenderer.routeLink` now hands a validated `mailto:` URL to `NSWorkspace.shared.open` (`MarkdownWebRenderer.swift:320-321`, `MarkdownAssetPolicy.swift:151-172`). The threat model is the record of what reaches Launch Services; the skill is the contract an agent reads. Add one sentence to each (recipients, cc, bcc, subject and body only; control characters refused).

2. **Task-list items render as literal `[x]` / `[ ]` in panel descriptions.** `Sources/PanelTitleBarView.swift:294-351` (Foundation full-syntax parse). MarkdownUI 2.4.1 on main rendered GFM task lists as checkboxes. Standalone compile of the exact production parser: `- [x] tests green\n- [ ] docs` gives `LI[•]("[x] tests green")`, `LI[•]("[ ] docs")`. Meaning survives, decoration does not; agents do write `- [x] done` in descriptions. Fix: map a leading `[ ] `/`[x] ` in an unordered item to `☐`/`☑` markers, with a test. Everything else I probed matches CommonMark and the previous verify rounds: strikethrough, inline and block HTML as literal text, escapes, entities, backslash and two-space hard breaks, `1)` and `+` markers, ordinals above 9, tab-indented nesting, CRLF, indented code, sanitized fences, tables and images, the common paragraph plus `Lineage:` shape, empty and whitespace-only input.

3. **WebKit's default context menu is shown over the reader with dead items, and "Panel Details" is unreachable there.** `MarkdownWKWebView` overrides no `willOpenMenu`, and the bundle installs no `contextmenu` handler (grep of `viewer.js`/`index.html`). Right-click on a link shows WebKit's "Open Link", "Open Link in New Window", "Download Linked File", "Copy Link"; the first three are cancelled by `decidePolicyFor`/`createWebViewWith` and do nothing, and "Copy Link" on a relative link copies `c11md://bundle/<path>`. Right-click on the page shows "Reload" (cancelled). The SwiftUI `.contextMenu` with "Panel Details" (`MarkdownPanelView.swift:33-44`) now only answers over the file-path header, because the web view consumes right-clicks in the body. The browser panel adds "Panel Details" and retargets "Open Link in New Window" in `CmuxWebView.willOpenMenu` (`CmuxWebView.swift:1280-1372`). Not demonstrated in a real window (no UI run); reasoned from WebKit defaults and the code. Fix: a `willOpenMenu` on `MarkdownWKWebView` that strips the navigation items and appends "Panel Details", or R3's chrome ticket if it owns the menu.

4. **Three pre-existing catalog gaps surfaced by the localization sweep, not this PR's.** `workspaceGroup.error.invalidColor`, `.invalidIcon`, `.invalidName` (`Sources/WorkspaceManager.swift`, present on `a95823705c~1`) have no entry in `Resources/Localizable.xcstrings` for any locale. Every key this PR added or touched (25 `markdown.*` keys and the 12 bridge strings) is present in en, ja, ko, ru, uk, zh-Hans, zh-Hant; the catalog parses with `jq`; no interpolation tokens. `markdown.mermaid.installHint` remains in the catalog with no Swift caller. File the three with the hardening ticket or a one-line fix.

5. **`testMarkdownWebViewPreservesFileDropsWithoutSwallowingInternalDrags` is misnamed.** `MarkdownWKWebView` keeps `.fileURL` registered but refuses every drop (`draggingEntered` returns `[]`, `MarkdownWebRenderer.swift:124-126`). Harmless in product: Finder drops are intercepted above the content hierarchy by `FileDropOverlayView` on the theme frame (`ContentView.swift:484-494`), so neither file drops nor bonsplit tab drags reach the web view. Rename the test to say what it asserts.

## Seams the brief named, and what I found there

- **Description renderer swap, every render site.** The only MarkdownUI consumer on main was `PanelTitleBarView.expandedDescription` (`git grep MarkdownUI a95823705c~1`). The panel bar, panel sheet subtitle and sidebar line never used MarkdownUI; `ContentView.renderMarkdown` (sidebar metadata blocks) already used Foundation's parser. So the swap touches one site, and finding 2 is the only remaining visible difference I could produce.
- **Session restore, old and new snapshots.** `SessionMarkdownPanelSnapshot.init(from:)` decodes per field with `try?` and normalises each (`SessionPersistence.swift:360-405`); a missing `markdown` block restores built-in defaults (`Workspace.swift:1187`, the known H4 for pre-fontScale snapshots); encoding of a nil `outlineOpen` omits the key; a snapshot from this build read by the shipped 1.0 decoder ignores the three new keys. 13 presentation tests cover this; no new gap.
- **Live reload against eviction.** Hidden-retained reader: `synchronize()` reloads in place and the bridge keeps the anchor. Evicted reader: the model updates, no WebKit is created, the next show loads the latest content and restores line/offset/mode/find; a `load` is itself a pinned query, so a reload during a capture bumps the epoch and the capture is discarded. Covered by `testSourceModeEviction…LatestContent` and `testCacheDiscardsCapture…`.
- **Drag filter and link routing shared with terminal and browser.** `openC11WebLink` reproduces the old terminal path order (option, setting, external rule, host normalisation, whitelist, placement); every `.embeddedBrowser` target is http(s) with a normalisable host (`GhosttyTerminalView.swift:486-520`), so its scheme guard never changes a decision. `newBrowserSplit(from:)` and `preferredBrowserTargetPane` take any panel id, so a markdown panel with no browser pane gets a split. `webViewDragTypes` blocks the same five types CmuxWebView blocked. See finding 5 for the markdown view's refusal of what remains.
- **Localization.** See finding 4.
- **Context menu** (not in the brief, adjacent to link routing): finding 3.

## Also checked, no finding

- Eviction never evicts a visible, pinned, capturing or not-yet-ready renderer; a not-ready renderer consumes capacity until ready or failed (`canCaptureReadingPosition`), which is the safe side. Re-show clears the retained viewport before layout. Hidden renderers in other windows count app-wide, as ruled.
- Focus: `focus()` on an unmounted or evicted renderer is a no-op; the re-created web view takes first responder only through `allowsPanelFocus` on `viewDidMoveToWindow`; `updateNSView` keeps `allowsPanelFocus` equal to the SwiftUI focus flag. No socket path can raise a window.
- WebContent termination: one silent recovery with the live position; a second consecutive termination shows the failure view (H1 territory).
- Scheme handler: `stop` before the main hop drops the result; `didReceive` is never called on a stopped task; the task object is retained by the hop so `ObjectIdentifier` cannot alias.
- Baseline on Atlas, exact head, `dirty=false`, invocation `b58cf64f087f47ae8f2c72e18d9ca3d6`: 81 tests (69 logic across `DescriptionSanitizerTests`, `MarkdownAssetPolicyTests`, `MarkdownPresentationTests`, `MarkdownRendererRetentionPolicyTests`, `MarkdownPanelFontScaleTests`; 12 host across `MarkdownWebRendererTests`, `CmuxWebViewDragRoutingTests`), `** TEST SUCCEEDED **`.
- Installed skill copies: `~/.claude/skills/c11-markdown/SKILL.md` and `c11/references/metadata.md` match the repo at this head.

## Probe quoted for the synthesis seat

Add to `c11Tests/MarkdownWebRendererTests.swift` before `installVisibleGate`:

```swift
    /// PM-359-f probe (round 3): record every stage of a chrome appearance flip.
    func testProbeAppearanceFlipReachesMountedSystemThemeReader() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("markdown-appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("reader.md")
        try "# Reader\n\nA stable paragraph.\n".write(to: path, atomically: true, encoding: .utf8)
        let panel = MarkdownPanel(workspaceId: UUID(), filePath: path.path)
        defer { panel.close() }
        panel.applyRestoredPresentation(SessionMarkdownPanelSnapshot(fontScale: 1, theme: "system", typeface: "theme", outlineOpen: false))
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = oldAppearance }
        let runtime = AreaInteractionRuntime()
        let host = NSHostingView(rootView: MarkdownPanelView(
            panel: panel, isFocused: false, isVisibleInUI: true, portalPriority: 0,
            onRequestPanelFocus: {}, paneInteractionRuntime: runtime))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        var created: MarkdownWebRenderer?
        for _ in 0..<200 where created == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
            created = panel.renderer
        }
        let renderer = try XCTUnwrap(created, "The SwiftUI host must create the renderer")
        await rendered(renderer, revision: 1)
        func resolvedTheme() async throws -> String {
            let now = try await call(renderer, "visible") as? [String: Any]
            return (now?["theme"] as? [String: Any])?["resolved"] as? String ?? "?"
        }
        func effective() -> String { renderer.webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? "?" }
        func settle(_ seconds: Double, until: () async throws -> Bool) async throws {
            for _ in 0..<Int(seconds * 20) { try await Task.sleep(nanoseconds: 50_000_000); if try await until() { return } }
        }
        var log: [String] = []
        log.append("initial: effective=\(effective()) resolved=\(try await resolvedTheme())")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await settle(4) { try await resolvedTheme() == "dark" }
        log.append("after NSApp.appearance=dark + 4s: effective=\(effective()) resolved=\(try await resolvedTheme())")
        let stage1 = try await resolvedTheme()
        ThemeManager.shared.objectWillChange.send()
        try await settle(2) { try await resolvedTheme() == "dark" }
        log.append("after ThemeManager publish + 2s: effective=\(effective()) resolved=\(try await resolvedTheme())")
        let stage2 = try await resolvedTheme()
        host.frame = NSRect(x: 0, y: 0, width: 790, height: 600)
        host.layoutSubtreeIfNeeded()
        try await settle(2) { try await resolvedTheme() == "dark" }
        log.append("after host resize + 2s: effective=\(effective()) resolved=\(try await resolvedTheme())")
        let stage3 = try await resolvedTheme()
        renderer.synchronize()
        try await settle(2) { try await resolvedTheme() == "dark" }
        log.append("after manual synchronize + 2s: effective=\(effective()) resolved=\(try await resolvedTheme())")
        let stage4 = try await resolvedTheme()
        XCTAssertTrue(panel.renderer === renderer)
        XCTAssertEqual(stage4, "dark", "PROBE LOG: " + log.joined(separator: " | "))
        XCTAssertEqual(stage1, "dark", "appearance flip alone did not reach the reader. PROBE LOG: " + log.joined(separator: " | "))
        XCTAssertEqual(stage2, "dark", "ThemeManager publish did not reach the reader. PROBE LOG: " + log.joined(separator: " | "))
        XCTAssertEqual(stage3, "dark", "host relayout did not reach the reader. PROBE LOG: " + log.joined(separator: " | "))
    }

```

Atlas tag `pm-359-f` is freed after this report.
