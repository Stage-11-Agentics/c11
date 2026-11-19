# C11-513: Named flags

**Status:** Chief of Staff approved decisions 1–5; implementation is authorized for c11 2.0.

## Baseline

A flag is a sticky attention modifier with a required, one-line reason. It is independent of lifecycle and overrides suppression. The generic, no-kind flag must keep its violet appearance and existing behavior. Today the canonical snapshot, `flag.raised` event, Feed row, sidebar, menu-bar list, banner, notification, and panel list carry or render only the reason; the tab strip and sidebar mark resolve flagged state to `#9D8AD9`.

## Decisions

1. **Flag data.** Should a flag gain an optional kind while keeping its required reason? **Decision:** yes. Store a stable kind ID alongside the reason; keep `nil` as the unchanged generic flag. A kind labels a flag and does not add severity. Snapshot the resolved name, palette color, and emoji on the active flag and `flag.raised`, so editing or removing a registry entry cannot silently change an existing alert or its event history. A reason or kind edit keeps the current raise epoch and queue position.

2. **Registry and entry points.** Should kinds be built-in, user-defined, or both, and where should they live? **Decision:** ship `chief-of-staff` and `merge-issue` as editable defaults, then store user kinds in c11-owned settings, exposed through Settings and `c11 flag-kind set|list|rm`. Creating a kind must take one command. Use a stable slug plus a display name. `raise-flag --kind <slug> <reason>` accepts only registered kinds; do not allow one-off `--color` or `--emoji` overrides. This keeps names and appearance consistent across agents and surfaces, without a repository file or tenant-config writes.

3. **Color choices.** Should users pick any color? **Decision:** use a fixed palette of named, adaptive color tokens checked in Light and Dark themes. The implementation palette was green, red, pink, and teal (C11H-223 adds orange, lime, cyan and magenta; see below); the built-ins use green and red. Keep the lifecycle colours (yellow working, white waiting on the operator, gray done; C11H-344), blue for cache cold, and violet for a generic flag distinct. Avoid arbitrary hex values until the UI can verify contrast.

4. **Attention behavior.** Does kind affect escalation or ordering? **Decision:** every kind keeps today's single flag tier: sticky until lowered, suppression override, direct flag notification, Feed and menu-bar inclusion, and the stopped-flag alarm. Use the kind color for the steady frame and its high-contrast alarm; Reduce Motion remains a hard override. Sort all flags oldest-first in one queue, regardless of kind. This preserves the existing signal contract and avoids turning names into unreviewed priority levels.

5. **Rendering contract.** What does each surface show? **Decision:** tint the existing panel-strip, rail, and sidebar marks with the kind color while preserving shape and fixed geometry; keep emoji and kind name in tooltip and accessibility text rather than squeezing emoji into a 9-point mark. Individual sidebar rows, Feed rows, menu-bar flag items, tooltips, the in-surface banner, and panel-list rows show optional emoji, kind name, and the required reason; their flag mark or text accent uses the kind color. The system notification includes kind name and reason (macOS does not offer a reliable per-kind text color). Aggregate badges, the workspace group signal, and the menu-bar icon keep today's total count and generic flag glyph/color because several kinds may be active at once. `flag.list` / Feed JSON expose the kind snapshot; `flag.raised` carries the kind ID and resolved display snapshot with the reason, while old events remain valid as generic flags.

## Source basis

`docs/c11-flagged-agent-plan.md`; `docs/c11-attention-model-skill-section.md`; `Sources/AttentionModel.swift`; `Sources/PanelMetadataStore.swift`; `Sources/Events/EventEmitter.swift`; `Sources/Workspace.swift`; `Sources/Sidebar/SidebarActivityProjector.swift`; `Sources/ContentView.swift`; `Sources/Feed/FeedProjector.swift`; `Sources/AppDelegate.swift`; `Sources/GhosttyTerminalView.swift`; `Sources/TerminalNotificationStore.swift`; `CLI/CMUXCLI+Run.swift`; `vendor/bonsplit/Sources/Bonsplit/Internal/Views/TabItemView.swift` and `CollapsedTabSheet.swift`.

## C11H-223: color-aware Flagged Agents button (c11)

Atin, 2026-11-06: kinds stay flat (decision 4 stands). A bare `raise-flag` raises the generic violet flag; `--kind` raises that kind. No rank, loudness, or workspace default kinds.

- **Palette** grows to eight tokens: green, red, pink, teal plus orange, lime, cyan and magenta. The four were the candidates farthest from gold, violet, cache-cold blue, gray and the existing tokens in both themes (CIEDE2000 at least 13.5); each keeps at least 4.5:1 contrast with black or white badge ink.
- **Sidebar Flagged Agents button** (superseded by C11H-224 below) fills with the color of the oldest flag, which its click opens. With two or more kinds up it replaces the single count with one badge per kind, generic first and then by kind id, so badges never reshuffle; past the slot limit (4 in one column, 2 in a tile) the last slot counts the remaining flags. The right-click menu jumps to one kind's oldest flag. This amends decision 5 for the sidebar button only; the menu-bar glyph and group counts stay generic.
- **Relay:** `flag.kind.list` passes the machine relay, so an agent on another machine can see the registry; `set` and `rm` stay host-only.

## C11H-224: one sidebar button per kind (c11)

Atin, 2026-11-06, after seeing #247: separate buttons rather than badges. Each named kind with flags up gets its own full sidebar button in its color (kind name with optional emoji, count, arrow), stacked above the violet Flagged Agents button, which now counts generic flags only. Named buttons are ordered by kind id, top to bottom; the generic button sits last, nearest Waiting Agent. Each button jumps to its own kind's oldest flag. A button appears only while its kind has flags. In tiles the buttons stack in the Flagged column, and the other tiles keep their own height. This replaces #247's per-kind badges, "Flags" short title and right-click kind menu.
