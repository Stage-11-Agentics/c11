## Evolutionary Code Review
- **Date:** 2026-04-22T06:07:02Z
- **Model:** codex / GPT-5
- **Branch:** gregorovich-voice-pass
- **Latest Commit:** 63ca8b8ec86d31cc6a7153797697a48ef517d3d3
- **Linear Story:** C11-9
- **Review Type:** Evolutionary/Exploratory
---

Scope note: the wrapper prompt forbids branch mutation, so I did not run `git fetch` or `git pull`. `origin/dev` is not present in this checkout; `upstream/dev` exists but produces a fork-scale diff that is not useful for this story. I reviewed the supplied `notes/.tmp/trident-C11-9/full-diff.patch`, target commit `94d80eae`, the current branch state, and the implementation files called out by the prompt.

## What's Really Being Built

This is not just "Settings got a sidebar." It is the first visible shape of a **control-plane map** for c11. The new `SettingsPage` enum names durable control domains (`general`, `appearance`, `workspaceSidebar`, `browser`, `notifications`, `input`, `keyboardShortcuts`, `agentsAutomation`, `dataPrivacy`, `advanced`) in `Sources/c11App.swift:4198`, and the sidebar renders that map directly in `SettingsSidebar` at `Sources/c11App.swift:6487`.

That matters because c11 is a room agents can drive. Settings is becoming the schema for what the room can do, what carries risk, what leaves the machine, what affects current workspaces, and what agents may safely automate. The implementation already has the first routing seam: `SettingsNavigationTarget` at `Sources/c11App.swift:2956`, `SettingsNavigationRequest` at `Sources/c11App.swift:2963`, and `SettingsPage.page(for:)` at `Sources/c11App.swift:4277`.

The unnamed capability here: **operator intent routing**. A future agent should not need to tell the operator "open Settings, scroll down, find X." It should be able to route to the exact domain, explain consequence, and maybe propose a setting change with explicit approval.

## Emerging Patterns

The good pattern is consequence-local grouping. Browser link routing has local consequence text at `Sources/c11App.swift:5409` and `Sources/c11App.swift:5433`; notification command explains `/bin/sh -c` and env vars at `Sources/c11App.swift:5774`; socket access carries blast-radius copy at `Sources/c11App.swift:5932` and `Sources/c11App.swift:5984`; reset coverage and external state boundaries live together at `Sources/c11App.swift:6042` and `Sources/c11App.swift:6061`. This matches the IA proposal's core idea: risk belongs near the control, not dumped into Advanced.

The brittle pattern is duplicated catalog knowledge. Page identity lives in `SettingsPage` (`Sources/c11App.swift:4198`), page routing in `SettingsPage.page(for:)` (`Sources/c11App.swift:4277`), rendered content in `selectedPageContent` (`Sources/c11App.swift:4924`), anchors inside individual page builders (`Sources/c11App.swift:5370`, `Sources/c11App.swift:5617`, `Sources/c11App.swift:5793`, `Sources/c11App.swift:5885`), shortcut groups in a separate array (`Sources/c11App.swift:6096`), and user-facing names in `Resources/Localizable.xcstrings:57587`. That is fine for one reorg, but it will decay when Settings grows.

The anti-pattern to catch early is `Sources/c11App.swift` continuing to absorb product architecture. The current page builders run from `generalSettingsPage` at `Sources/c11App.swift:4950` through `advancedSettingsPage` at `Sources/c11App.swift:6068`. This file is now acting as layout, state model, copy container, routing table, and IA registry at once.

## How This Could Evolve

The next natural move is a first-class `SettingsCatalog`: a list of page descriptors and section descriptors with IDs, localized title/helper, SF Symbol, navigation targets, search terms, reset coverage, privacy/risk tags, and maybe "agent-safe read/write" metadata. The current `SettingsPage` enum is 70 percent of that primitive already; it just needs to stop being only a sidebar enum.

With that catalog, Settings search becomes cheap. The command palette can search "socket password", "browser import", "notification command", or "TextBox shortcut" and deep-link to the exact section. The existing four-target `SettingsNavigationTarget` (`Sources/c11App.swift:2956`) is the seed; every section header could become addressable without inventing a second route system.

The more strategic evolution is agent-mediated settings. c11 already exposes sockets, metadata, skills, and surface handles. A read-only `settings.list` / `settings.describe` CLI or socket command could let agents reason from the same catalog the UI uses. Mutating settings should stay behind explicit user confirmation, but read/navigation/description is squarely in c11's primitive boundary.

## Mutations and Wild Ideas

**Settings as a map overlay.** The sidebar could eventually switch between "All Settings" and "Relevant to focused surface." If the focused surface is a browser, show Browser, Data & Privacy, and relevant shortcuts first. If it is a terminal running an agent, show Agents & Automation, Notifications, Input, and Workspace & Sidebar. The catalog tags make this a view, not a separate IA.

**Operator modes.** The grouped settings almost define profiles: "Quiet Review" (notifications low, stable workspace order), "Agent Orchestra" (sidebar metadata high, notifications visible, socket c11-only), "Browser Work" (embedded routing on, import hints off/on). This should not become a gimmicky preset screen, but a profile export/import primitive could be powerful for c11 users with repeatable work modes.

**Risk ledger.** Data & Privacy and Agents & Automation already name boundaries. A generated "what c11 can do from this machine" ledger could summarize socket access, skills installed, notification commands, browser HTTP exceptions, telemetry, and reset exclusions. That is both operator trust and a debugging primitive.

**Docs from live IA.** The proposal at `docs/settings-reorganization-proposal.md` and the code are already drifting in a reasonable way: proposal has "Input & Shortcuts", implementation splits Input and Keyboard Shortcuts. Rather than preventing drift with brittle source tests, generate a small runtime IA snapshot from the catalog and use it for docs, command palette, and future behavioral tests.

## Leverage Points

The highest leverage is unifying page/section metadata. It would make Settings search, command palette routing, docs, accessibility labels, agent navigation, and reset-boundary summaries all pull from one truth.

The second leverage point is extracting settings pages out of `c11App.swift` without losing local state ergonomics. A lightweight `SettingsModel` plus page subviews would let future changes land in focused files, and it would make code review far more meaningful than scrolling a 2,500-line diff in one file.

The third is expanding navigation targets. Four deep links are enough for the existing browser/import/TextBox/shortcuts flows, but the new IA deserves addressable section IDs for every high-consequence control: socket mode, socket password, notification command, reset settings, HTTP allowlist, telemetry, agent skills, and sidebar metadata.

## The Flywheel

If Settings gets a catalog, every new setting pays into the system:

1. The UI gets sidebar/search/deep-link placement.
2. The command palette can route to it.
3. Agents can describe it without scraping UI copy.
4. Reset and privacy summaries stay complete.
5. Tests can verify runtime catalog behavior instead of source-code shape.

That loop compounds. Without it, every new setting adds one more copy string, one more row, one more forgotten reset edge, and one more hard-coded navigation special case.

## Concrete Suggestions

1. **High Value - Introduce a `SettingsCatalog` before the next settings feature.** Model pages and sections as descriptors: `page`, `title`, `helper`, `iconName`, `sections`, `navigationTargets`, `riskTags`, and optional `resetCoverageKey`. `SettingsSidebar` (`Sources/c11App.swift:6487`) and `selectedPageContent` (`Sources/c11App.swift:4924`) can still render SwiftUI views, but routing and IA should come from descriptors. ✅ Confirmed — the existing `SettingsPage` enum (`Sources/c11App.swift:4198`) already owns page title/helper/icon, and `SettingsPage.page(for:)` (`Sources/c11App.swift:4277`) proves the app has a routing seam. Risk: do not over-abstract row rendering yet; start with page/section metadata only.

2. **High Value - Make all important sections addressable.** Expand `SettingsNavigationTarget` from four cases (`Sources/c11App.swift:2956`) to section-level targets for socket access, socket password, notification command, reset settings, telemetry, HTTP allowlist, agent skills, and sidebar metadata. Then attach `.id(...)` where those section headers or content blocks already exist, following the existing anchors at `Sources/c11App.swift:5370`, `Sources/c11App.swift:5617`, `Sources/c11App.swift:5793`, and `Sources/c11App.swift:5885`. ✅ Confirmed — current `ScrollViewReader` navigation at `Sources/c11App.swift:4811` and notification handling at `Sources/c11App.swift:4831` are compatible. Risk: newly selected pages must be set before scrolling, as this implementation already does at `Sources/c11App.swift:4833`.

3. **Strategic - Extract Settings into a feature module with a small state owner.** Move page subviews and support rows out of `Sources/c11App.swift`, keeping one `SettingsModel` or equivalent state container for the many `@AppStorage` values starting at `Sources/c11App.swift:4299`. ✅ Confirmed — page boundaries are already clean computed properties (`Sources/c11App.swift:4950`, `Sources/c11App.swift:4998`, `Sources/c11App.swift:5175`, `Sources/c11App.swift:5368`, `Sources/c11App.swift:5625`, `Sources/c11App.swift:5791`, `Sources/c11App.swift:5883`, `Sources/c11App.swift:5922`, `Sources/c11App.swift:6015`, `Sources/c11App.swift:6068`). Risk: SwiftUI binding churn can get noisy; extract one page at a time rather than doing a giant mechanical move.

4. **Strategic - Generate reset/privacy summaries from metadata.** Reset coverage is currently a hand-maintained sentence at `Sources/c11App.swift:6044`; external state exclusions are another hand-maintained sentence at `Sources/c11App.swift:6063`. Put `resetBehavior` / `externalStateBoundary` metadata next to the settings sections, then render these summaries from data. ✅ Confirmed — the current copy is valuable but manually synchronized. Risk: this is only worth doing after the catalog exists; otherwise it becomes a second source of truth.

5. **Strategic - Let agents read the settings map, not mutate it.** Add a read-only socket/CLI command later, backed by the catalog: `c11 settings list`, `c11 settings describe socket-access`, and perhaps `c11 settings open socket-access`. This fits c11's "host and primitive" boundary because it exposes c11's own runtime configuration, not another tool's config. ✅ Confirmed — `SettingsNavigationRequest.post` at `Sources/c11App.swift:2967` can already route UI intent; this would formalize the same concept for agents. Risk: keep writes out until there is an explicit approval flow.

6. **Experimental - Add current-context Settings lenses.** Use page/section tags so Settings can surface controls relevant to the focused surface or workspace. Browser surface: Browser/Data & Privacy. Agent terminal: Agents & Automation/Notifications/Input. ❓ Needs exploration — promising, but it needs surface-type context and careful UI restraint so Settings does not become unstable or surprising.

7. **Experimental - Create operator mode profiles.** Persist named bundles of settings for repeated work modes, but only after catalog metadata can mark which settings are profile-safe. ❓ Needs exploration — useful for c11's target operator, but risky if it hides too many side effects behind one click.

## Validation Pass

High Value item 1 is compatible with the existing architecture because page identity is already centralized enough to migrate incrementally: `SettingsPage` owns the main static metadata, and `SettingsSidebar` consumes it without knowing page internals.

High Value item 2 is compatible because the current implementation already switches pages before calling `proxy.scrollTo(...)` (`Sources/c11App.swift:4831`). Adding more targets follows the existing pattern, not a new UI mechanism.

Strategic item 3 is compatible but should be staged. `SettingsView` has many local `@AppStorage` bindings and helper functions; extracting everything at once would create a risky binding migration. Start with pure page components that receive bindings and callbacks.

Strategic item 4 depends on item 1. Do not add fake tests that assert source snippets or `xcstrings` keys exist; if tested, test a runtime catalog seam that returns reset/privacy metadata for known sections.

Strategic item 5 is compatible with the c11 mission and socket model, but should begin read-only. The highest-confidence first command is "describe/open", not "set".

No tests or builds were run. This was a read-only review, and the repo policy says tests run via CI/VM rather than local app launch.
