## Code Review
- **Date:** 2026-04-22T06:09:05Z
- **Model:** Codex (GPT-5)
- **Branch:** gregorovich-voice-pass
- **Latest Commit:** 07fe7e763e78c9fa77a95b81bb45afb1c03e52a2
- **Linear Story:** C11-9
---

### General Feedback

The settings reorganization is directionally sound: `SettingsPage` gives the IA a clear spine, `SettingsSidebar` makes page-level navigation explicit, and the existing deep-link targets are still mapped into the new page model. The implementation also keeps the proposal's important safety placement: socket access stays with agents/automation, HTTP and routing exceptions stay with Browser, and reset/data boundaries move into Data & Privacy.

The main issue is that the window and scroll behavior were not updated to match the new two-column layout. The old 640px settings window width was barely a constraint for one continuous scroll view; after adding a 220px sidebar, the default content column is too narrow for the existing fixed-width controls. Direct sidebar navigation also preserves the previous scroll offset, which makes page switches feel broken after visiting a long page.

Validation notes: `origin/dev` is not present in this checkout, so the requested `origin/dev..HEAD`/`origin/dev...HEAD` commands could not be used. I reviewed target commit `94d80eaefa3e069102ac335b2cf5b883a8f6c344`, the supplied review context, and current branch `HEAD` (`07fe7e763e78`). Per repo policy, I did not run local app/UI tests or `xcodebuild`; this is a Swift/Xcode project with no root `package.json`, so `npm run type-check`, `npm run lint`, and `npm test` are not applicable. I did validate that `Resources/Localizable.xcstrings` parses as JSON with `jq empty`.

Logic flow reviewed:

1. `SettingsWindowController` creates the settings window and hosts `SettingsRootView`.
2. `SettingsView` owns `selectedPage`, initially `.general`.
3. `SettingsSidebar` renders `SettingsPage.allCases`; button taps assign `selectedPage`.
4. The right pane renders a single page through `selectedPageContent`.
5. Deep-link notifications map `SettingsNavigationTarget` to a page and then scroll to the target anchor.

### Findings

#### Blockers

1. ✅ Confirmed - Default settings window width is now too narrow for the sidebar layout. `SettingsWindowController` still opens at 640px wide (`Sources/c11App.swift:2828`), while the new sidebar consumes 220px plus the separator (`Sources/c11App.swift:4805`, `Sources/c11App.swift:6530`). The right content then loses another 40px to horizontal padding (`Sources/c11App.swift:4827`). That leaves about 379px for the content stack at the default size. Existing rows reserve 196px for many pickers and 280px for notification sound controls (`Sources/c11App.swift:4296`, `Sources/c11App.swift:4297`, `Sources/c11App.swift:6378`), leaving only about 143px, and sometimes about 59px, for labels and subtitles. This is a branch-owned regression because the same 640px window used to feed one full-width scroll view before `94d80eae`. The Settings reorg should not ship with the primary window opening in a cramped layout. Increase the initial and minimum settings window width, or make the row control widths responsive under the sidebar layout; also consider a sidebar min-height/scroll treatment while adjusting window sizing.

#### Important

2. ✅ Confirmed - Sidebar page switches do not reset the content scroll position. Direct sidebar taps only assign `selectedPage` (`Sources/c11App.swift:6498`), while the only `proxy.scrollTo` path is the notification/deep-link handler (`Sources/c11App.swift:4831`). Because the same `ScrollView` instance is reused for every page, selecting a new page after scrolling deep into Browser or Keyboard Shortcuts can open the next page at a stale offset rather than at its title and first section. Add a top anchor per page and scroll to it when sidebar selection changes, or key the scroll/content by `selectedPage` if the intended behavior is always top-of-page navigation.

#### Potential

3. ⬇️ Confirmed - The page split is clean enough for this story, but `Sources/c11App.swift` now carries the page enum, ten page builders, shared row primitives, and the sidebar in one already-large file (`Sources/c11App.swift:4198`, `Sources/c11App.swift:4923`, `Sources/c11App.swift:6487`). This is not blocking, but the next settings expansion should probably extract page views or at least sidebar/page primitives into separate files so future IA changes do not keep growing the app entry point.
