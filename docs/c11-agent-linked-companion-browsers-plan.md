# c11 — Agent-Linked Companion Browsers

**Status:** Implementation-ready product and engineering plan

**Date:** 2026-07-22

**Scope:** Browser surfaces in c11 workspaces

**Working product name:** Agent-linked companion browsers

## 1. Executive decision

c11 should let a browser surface carry a durable link to the agent terminal that created it or that the operator explicitly chooses. Each workspace should separately remember its current **agent context**: the last agent terminal the operator explicitly focused.

When the linked agent and current agent context differ, c11 must preserve the entire workspace arrangement and the browser tab currently selected in its pane. It should place a light, pane-local **context veil** over the browser's web content instead of moving, hiding, replacing, collapsing, or automatically switching anything.

The veil says whose browser this is, which agent is active, and offers **View anyway**. That activation is consumed by c11, reveals the browser temporarily, and never changes the durable link. The toolbar remains visible and is the explicit place to link, relink, or unlink the browser.

This creates a new c11 primitive: **semantic association without spatial mutation**. Existing multiplexers know where a surface is; c11 will also know which agent's line of work a companion surface belongs to. That distinction is the feature's real value.

### Dependencies and boundaries

The plan builds on c11's existing stable workspace/surface UUIDs, canonical agent manifests and `terminal_type` detection, Bonsplit selection callbacks, WKWebView portal, session persistence, WorkspaceApplyPlan snapshot/blueprint pipeline, and caller surface environment variables. It requires no external service, new browser engine, agent-side hook, or write to a tenant tool's configuration.

The feature is browser-only in V1. Its typed relationship model can generalize to other companion surfaces later, but implementation should not prematurely turn every panel into a generic graph.

## 2. Problem

The current browser model is spatial but context-free:

1. Agent A creates an HTML prototype in a browser pane.
2. The operator reviews Agent A and the prototype together.
3. The operator then focuses Agent B in the same workspace.
4. Agent A's browser remains visible and fully interactive beside Agent B.

Nothing is geometrically wrong, but the composition is semantically false. The visible browser looks like supporting context for Agent B even though it belongs to Agent A's unrelated feature. At small scale this is tolerable; at five, ten, or thirty concurrent agents it becomes an attention and action-routing problem.

The naive fixes all discard something valuable:

- automatically swapping browsers loses the operator's selected content and makes the workspace move under them;
- hiding or collapsing browsers destroys spatial memory;
- relinking on click turns inspection into an accidental durable mutation;
- a passive badge identifies the mismatch but leaves unrelated content immediately actionable;
- a fully opaque replacement protects context but removes visual recognition.

The context veil keeps the useful invariants simultaneously: location, selected tab, recognizability, explicit control, and contextual honesty.

## 3. Product principles

### 3.1 Spatial memory is state

Pane position, size, and currently selected surface are part of the operator's working memory. An agent-context change must not alter any of them.

### 3.2 Focus is intent; activity is not

The current agent context changes only when an agent terminal becomes the explicitly selected/focused surface through a user or explicit focus-intent command. Agent output, status, progress, notifications, and background activity never change it.

Focusing a browser or markdown surface does not clear agent context. Focusing an ordinary shell does not invent a new agent context.

### 3.3 Looking is not relinking

Association, temporary access, and reassignment are separate operations:

- **Link** says which agent the browser belongs with.
- **View anyway** permits temporary human interaction during a mismatch.
- **Relink** changes the durable association.

Only the third mutates durable link state.

### 3.4 This is contextual guidance, not security

The veil blocks human pointer, keyboard, and accessibility interaction with the page. It is not an ACL, browser profile, privacy screen, or process-isolation boundary. Page execution, agent automation, audio, downloads, and notifications continue unless a future feature adds an explicit suspension policy.

Product copy must use **linked**, not **owned**, **locked**, or **restricted**.

### 3.5 Agent-created context should explain itself

When a recognized agent creates a browser through the c11 CLI/socket, that browser should link to the caller automatically. A manually created browser is workspace-wide and unlinked by default. The resulting `Linked to Maya` toolbar pill makes the automatic association visible and gives the operator an immediate path to relink or unlink it.

## 4. Research synthesis

The design combines established interaction patterns in a way that appears novel:

- Safari can bind a persistent Tab Group to a macOS Focus, establishing precedent for durable browser-to-context association: [Safari Focus and Tab Groups](https://support.apple.com/en-gb/guide/safari/ibrw36c4d917/mac).
- Arc Spaces and Profiles make browsing context persistent and visible, while also illustrating why c11 must not imply profile-level isolation: [Arc Spaces](https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas), [Arc Profiles](https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing).
- Firefox Containers use durable labels, icons, and colors to make context membership legible: [Firefox Multi-Account Containers](https://support.mozilla.org/en-US/kb/containers).
- VS Code locked editor groups preserve a group's position while routing new content elsewhere, supporting spatial stability as an explicit invariant: [VS Code custom layout](https://code.visualstudio.com/docs/configure/custom-layout).
- Arc Peek, VS Code Peek, and Quick Look separate temporary inspection from durable navigation or promotion: [Arc Peek](https://resources.arc.net/hc/en-us/articles/19335302900887-Peek-Preview-Sites-From-Pinned-Tabs), [VS Code Peek](https://code.visualstudio.com/docs/editing/editingevolved), [macOS Quick Look](https://support.apple.com/en-lamr/guide/mac-help/-mh14119/mac).
- Windows Snap Groups and macOS Stage Manager reinforce the value of arrangements that retain their spatial identity: [Windows Snap](https://support.microsoft.com/en-us/windows/experience/snap-your-windows), [Stage Manager](https://support.apple.com/guide/mac-help/use-stage-manager-mchl534ba392/mac).

No located precedent combines stable multiplexer geometry, live agent identity, durable browser association, automatic mismatch veiling, temporary interactive reveal, and explicit reassignment. The composition is new, but its constituent behaviors have familiar precedents.

## 5. Terminology and identities

| Term | Definition |
|---|---|
| **Agent surface** | A live terminal surface whose normalized `terminal_type` satisfies shared `AgentIdentityPolicy`: a canonical registry agent kind or the detected compatibility kind `opencode-run`. Ordinary `shell` and `unknown` terminals are excluded. |
| **Agent context** | The last explicitly focused agent surface in a workspace. It persists while non-agent surfaces receive focus. |
| **Companion link** | A browser's optional durable reference to exactly one agent surface. |
| **Workspace-wide browser** | An unlinked browser. It is always interactive and never context-veiled. |
| **Context veil** | A light AppKit overlay above web content that makes a mismatch legible and consumes human input. |
| **Reveal grant** | Ephemeral permission to interact with a linked browser during one particular mismatch. It is never persisted. |
| **Orphaned link** | A preserved link whose target agent is not currently resolvable in the browser's workspace. |

V1 links target a stable terminal surface UUID. A new link may be created only when browser and agent are in the same workspace, but workspace identity is not part of the durable target. This lets an unchanged link become unavailable when the surfaces separate and resolve naturally if the same UUIDs reunite. Links do not target a mutable title, model name, role string, process PID, or conversation ID. Surface identity already survives c11 session restoration and agent-process replacement within the same terminal.

Conversation- or task-level identity may become a future link target, but introducing an agent entity model is not necessary to solve this problem.

## 6. Locked V1 behavior

These are implementation decisions, not open questions:

1. A browser has zero or one linked agent; many browsers may link to the same agent.
2. Agent context is workspace-local and changes only on explicit focus of a recognized agent terminal.
3. Browser, markdown, and ordinary-shell focus leave the current agent context unchanged.
4. No browser, pane, tab, divider, or window changes position, size, order, visibility, or selection when agent context changes.
5. An unlinked browser is always interactive.
6. A linked browser is interactive when its linked agent matches current agent context.
7. A linked browser whose target resolves is also interactive before the workspace has established any agent context. An orphaned link remains veiled because its association cannot be validated.
8. A mismatch veils web content while leaving browser chrome visible for spatial recognition. Page-affecting controls such as the omnibar, back/forward, reload, and devtools are disabled until reveal; c11 pane/tab chrome and the companion-link control remain usable.
9. The entire veil is a reveal target. Its visible `View anyway` control is the keyboard and VoiceOver target. Either activation is consumed, never relinks, and never reaches the webpage.
10. A temporary reveal lasts until explicit **Hide**, c11's effective surface focus/selection leaves that browser, agent context changes, link changes, the browser changes workspace, or the app restores/relaunches. Omnibar focus, toolbar/menu focus, banner focus, WKWebView first-responder changes, and VoiceOver traversal within the same browser surface do not revoke it. It is not timer-based.
11. If the linked agent disappears or is outside the browser's current workspace, keep the link as orphaned rather than silently converting it into a workspace-wide browser.
12. Closing and reopening a browser with Cmd-Shift-T and session restore preserve its link, including an orphan tombstone. Named snapshots and blueprints preserve links whose target agents participate in the plan; they warn and restore orphaned links as unlinked. Reveal grants never persist.
13. The veil governs operator and accessibility/computer-use input. Addressed c11 browser socket operations and JavaScript/DOM automation continue.
14. Agent-originated browser creation auto-links only when the caller surface is a live, recognized agent in the same workspace. Manual UI creation remains unlinked.
15. Link, unlink, and query commands do not steal macOS focus or change c11's focused pane/surface.
16. Browser descendants created by `target=_blank`, popup promotion, duplicate, context-menu open, split, or open-to-side inherit the source browser's durable link unless the operator explicitly chooses workspace-wide creation.
17. If the active agent surface is declassified to `shell`/`unknown`, clear active context, advance its generation, revoke reveals, and derive its linked browsers as orphaned. Reclassification of the same stable surface resolves those links again.
18. c11 pane geometry, order, and selected surfaces are invariant. Transient webpage fullscreen and pointer lock are the narrow exception: they must yield when necessary for c11 to present the context veil reliably.

For reveal lifetime, **effective browser focus** means: the browser's workspace is selected in an active c11 window and `workspace.focusedPanelId` resolves to that browser. First-responder movement among the web view and its own c11 browser chrome does not change that fact.

## 7. State model

The presentation must be derived from independent durable and transient values, not stored as another mutable state machine.

```swift
struct AgentSurfaceLink: Codable, Equatable, Sendable {
    var surfaceID: UUID
    var lastKnownLabel: String?
}

struct AgentContextState: Equatable, Sendable {
    var activeAgentSurfaceID: UUID?
    var generation: UInt64
}

struct CompanionRevealGrant: Equatable, Hashable, Sendable {
    var browserSurfaceID: UUID
    var linkedAgentSurfaceID: UUID
    var activeAgentSurfaceID: UUID?
    var contextGeneration: UInt64
}

enum BrowserCompanionPresentation: Equatable {
    case unlinked
    case linkedNoContext(linked: AgentDescriptor)
    case aligned(linked: AgentDescriptor)
    case veiled(linked: AgentDescriptor, active: AgentDescriptor)
    case revealed(linked: AgentDescriptor, active: AgentDescriptor)
    case orphaned(link: AgentSurfaceLink)
    case orphanedRevealed(link: AgentSurfaceLink)
}
```

`BrowserCompanionPresentation` is produced by a pure reducer/policy from:

- browser UUID and optional durable link;
- workspace's current agent context and generation;
- live agent descriptors in that workspace;
- optional reveal grant.

### 7.1 Presentation table

| Condition | State | Web content | Visible treatment |
|---|---|---|---|
| No link | Unlinked | Interactive | `Link browser…` in toolbar |
| Link resolves; no current context | Linked, no context | Interactive | `Linked to A` pill |
| Linked agent = current context | Aligned | Interactive | `Linked to A` pill |
| Linked agent != current context | Veiled | Inert | Light veil: A's browser; B is active; View anyway |
| Mismatch + valid reveal grant | Revealed | Interactive | Slim persistent mismatch banner with Hide |
| Link target unavailable | Orphaned | Inert | Linked agent unavailable; View browser; relink remains available |
| Orphan + valid reveal grant | Orphaned revealed | Interactive | Slim `Linked agent unavailable` banner with Hide |

### 7.2 Transition table

| Event | Required result |
|---|---|
| Explicitly focus Agent B | Set B as context; increment generation if changed; revoke all reveal grants in workspace |
| Focus browser, markdown, or shell | Keep existing agent context |
| Agent B emits output/status/progress | No context change |
| Activate View anyway | Create a grant for the exact browser/link/context/generation; do not change link |
| Activate Hide | Delete that browser's reveal grant |
| Browser loses selection/focus | Delete that browser's reveal grant |
| Workspace is deselected or its window resigns active use | Revoke that workspace's reveal grants even if no panel-selection callback fires |
| Link to active agent | Replace link; clear reveal; derive aligned state |
| Link to another agent | Replace link; clear reveal; derive aligned or veiled state |
| Unlink | Delete link and reveal; derive unlinked state |
| Linked agent closes or moves away | Preserve link; derive orphaned state |
| Same stable agent returns | Resolve preserved link; derive aligned or veiled state |
| Browser navigates/reloads/opens devtools | Preserve link and current derived state |
| Browser moves workspace | Preserve target UUID; clear reveal; resolve as orphaned unless the same target agent is present there |
| Session/snapshot restore | Restore link and agent context; do not restore reveal |

Generation is important. A boolean `isRevealed` can accidentally survive A -> B -> A; a grant tied to the exact mismatch cannot.

## 8. Interaction design

### 8.1 Toolbar link control

Add a persistent companion control to `BrowserPanelView.addressBar`:

- wide state: agent glyph plus `Linked to Maya`;
- narrow state: glyph-only with complete accessibility label and tooltip;
- unlinked state: `Link browser…` when space permits, otherwise the link glyph;
- mismatch state: retain the linked agent identity and add a small context-warning indicator.

Menu contents:

- `Link to Active Agent — Build Agent`
- `Choose Agent…`
- a checked list of live agents in the workspace
- `Unlink Browser`

Equivalent commands belong in the menu bar and command palette because toolbar items can be compressed or hidden:

- `Link Browser to Active Agent`
- `Change Browser Link…`
- `Unlink Browser`
- `View Linked Browser`
- `Hide Linked Browser`

### 8.2 Mismatch veil

Suggested copy:

> **Maya's browser**<br>
> Build Agent is active.<br>
> **View anyway**<br>
> Viewing won't change the link.

The veil uses system material so the page remains faintly recognizable. It uses text and iconography in addition to color, respects Reduce Transparency and Increase Contrast, and is visibly pane-local rather than application-modal.

The toolbar remains visible outside the veil. This matters because the durable repair action—relink or unlink—must remain available even when page interaction is blocked. Controls that would mutate or inspect the page are visibly disabled until reveal.

The entire material veil accepts pointer activation, not just the central button. The button supplies a visible target and the keyboard/accessibility action; AppKit consumes the same first activation in either path.

### 8.3 Temporary reveal

After reveal, replace the central veil with a slim, persistent status treatment inside existing browser chrome:

> Viewing Maya's browser · Build Agent is active    **Hide**

Do not place the status over webpage content or resize the WKWebView viewport. In wide panes it can expand the companion toolbar pill; in narrow panes it can collapse to an icon with an accessibility label and menu. Do not dismiss it on a timer. It is the continuing explanation for why semantically mismatched content is interactive.

### 8.4 Accessibility and input

- A veiled WKWebView is pointer-inert, keyboard-inert, and removed from accessibility traversal. Browser socket/JavaScript automation remains functional; accessibility/computer-use automation intentionally sees the veil instead of the page.
- Tabbing into the browser focuses **View anyway**.
- Return or Space reveals. The activation event is consumed; the page receives only subsequent input.
- Keyboard reveal moves focus to the web-content root or last valid page element and announces the temporary state.
- The veil does not trap focus; other c11 panes remain reachable.
- Focus alone never reveals. This follows [WCAG On Focus](https://www.w3.org/WAI/WCAG22/Understanding/on-focus).
- Do not claim Escape globally while webpage content owns focus. Escape may hide only when veil/banner chrome owns focus; the menu/command-palette action is always available.
- Hover is not required for discovery or dismissal. Relevant guidance: [WCAG Content on Hover or Focus](https://www.w3.org/WAI/WCAG22/Understanding/content-on-hover-or-focus.html).
- Use system accessibility behavior and materials consistent with [Apple Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) and [Apple Materials](https://developer.apple.com/design/human-interface-guidelines/materials).

### 8.5 Explicit non-behaviors

V1 does not:

- automatically select a browser associated with the newly focused agent;
- nominate a primary browser when an agent has several;
- move or collapse panes;
- suspend page JavaScript, networking, media, downloads, or agent automation;
- isolate cookies or credentials by agent;
- make a browser exclusively addressable by its linked agent;
- infer context from the busiest or most recently updated agent;
- turn linked browser state into a privacy feature.

## 9. Current architecture findings

The feature crosses five existing seams.

### 9.1 Focus and selection

`Workspace.focusedPanelId` represents Bonsplit's focused pane plus that pane's selected tab. It intentionally includes terminals, browsers, and markdown surfaces, so it cannot itself represent agent context.

Normal selection routes converge through `Workspace.applyTabSelectionNow(...)`. That is the correct place to observe an effective selection and update workspace agent context when the selected panel is a recognized agent. `.ghosttyDidFocusSurface` is posted for all panel types and is therefore too broad to be the authority.

Agent qualification must not use `MetadataKey.canonicalTerminalTypes`, because that set includes `shell` and `unknown`. Extract a neutral `AgentIdentityPolicy.isAgentKind(...)` from the current `PaneSizePolicy.isAgentKind(...)` behavior: registry-backed canonical agent manifests plus the detected compatibility kind `opencode-run`. The companion model, agent chips, and pane sizing must share that one predicate.

`terminal_type` can arrive after a terminal was focused. The metadata store currently has no per-surface observation seam. Add a narrow typed notification/publisher for terminal-kind changes; when it identifies the currently focused terminal as an agent, promote that surface to current agent context without requiring a second click. Do not make general metadata changes a focus signal.

### 9.2 Browser view layering

Browser web content is portal-hosted. The WKWebView sits above ordinary SwiftUI panel content, so a SwiftUI `.overlay` on `BrowserPanelView` would render underneath it and fail the core input guarantee.

`WindowBrowserSlotView` in `BrowserWindowPortal.swift` already mounts search and pane-interaction overlay hosts above WKWebView and re-raises them after portal rebinds. Add the companion veil at this layer. This is more reliable than a panel-wide overlay and deliberately leaves SwiftUI browser chrome usable.

The z-order contract is:

1. pane interaction modal / destructive confirmation;
2. active drag/drop routing overlay;
3. companion veil or revealed mismatch banner;
4. browser search overlay;
5. WKWebView and Web Inspector content.

The exact search ordering should be validated: while veiled, Find-in-page must not create an interactive path into the page. The safest initial behavior closes/yields browser search when a veil appears.

### 9.3 Durable browser state

`BrowserPanel` has a stable UUID, already moves between workspaces as the same object, and owns browser-specific mutable state. Add the optional typed `AgentSurfaceLink` there. `Workspace` owns validation and mutation methods so callers cannot install an invalid link directly.

Do not use arbitrary `SurfaceMetadataStore` data as the source of truth. Metadata is agent-writeable, lacks referential validation and ID remapping, and is pruned during detach. A read-only inspectable mirror may be added later, but the typed model is authoritative.

### 9.4 Creation provenance

The CLI currently forwards caller workspace but a no-target `c11 browser open URL` does not forward the caller's surface environment variable. The socket handler then falls back to `ws.focusedPanelId`, which is operator focus, not necessarily the surface issuing the command. Reliable automatic linking therefore requires explicit caller provenance.

Do not overload `surface_id`; it already means an existing target browser or a placement source, depending on the browser verb. Add `caller_surface_id` as a distinct creation parameter. The CLI fills it from `C11_SURFACE_ID`/legacy `CMUX_SURFACE_ID`; the server validates it and uses it only for attribution, never as proof without checking the live workspace surface. Placement continues to use its existing explicit source and focused-surface fallback.

### 9.5 Persistence families

Session persistence preserves live workspace and panel UUIDs. Named snapshots and blueprints do not: `WorkspacePlanCapture` mints plan-local IDs such as `s1`, and `WorkspaceLayoutExecutor` creates fresh live UUIDs. The relationship must therefore be explicitly remapped in the plan schema. A raw UUID hidden in metadata would break on apply.

## 10. Proposed implementation architecture

### 10.1 Types and state ownership

Add `Sources/AgentCompanionContext.swift` containing only Foundation/Combine-compatible models and pure policy:

- `AgentSurfaceLink`
- `AgentDescriptor`
- `AgentContextState`
- `CompanionRevealGrant`
- `BrowserCompanionPresentation`
- `BrowserCompanionPolicy.presentation(...)`

Add to `BrowserPanel`:

```swift
@Published private(set) var linkedAgent: AgentSurfaceLink?
```

The panel carries the link naturally through same-workspace and cross-workspace detach/attach. Only workspace methods may mutate it:

```swift
func linkBrowser(_ browserID: UUID, toAgent agentID: UUID) throws
func unlinkBrowser(_ browserID: UUID) throws
func revealBrowser(_ browserID: UUID) throws
func hideBrowser(_ browserID: UUID)
func companionPresentation(for browserID: UUID) -> BrowserCompanionPresentation
```

Add to `Workspace`:

- `@Published private(set) var agentContextState`;
- a small MRU list of live agent surface UUIDs for stable chooser ordering;
- ephemeral reveal grants keyed by browser UUID;
- link validation, orphan resolution, close/move cleanup, and presentation derivation.

Increment `generation` only when active agent identity changes. Clear reveal grants when generation changes. Prune closed agents from MRU, but do not erase browser links targeting them.

### 10.2 Agent labels

Display identity resolution order:

1. live custom surface title / canonical metadata title;
2. live agent manifest display name;
3. link's persisted `lastKnownLabel`;
4. localized `Unknown agent`.

Duplicate display names are acceptable because identity is UUID-based. The chooser should disambiguate duplicates with workspace-relative surface refs or a short stable suffix.

### 10.3 Focus integration

`Workspace.applyTabSelectionNow(...)` is the convergence point for selection, but it is reached by both intentional focus and maintenance churn. Extend selection routing with an `AgentContextFocusProvenance` such as `.operatorInteraction`, `.explicitFocusCommand`, `.restore`, and `.maintenance`. User tab/pane interactions and allowlisted socket focus commands may establish context; creation, close fallback, move/detach reconciliation, and other maintenance selections may not. Where Bonsplit delegates cannot carry provenance directly, wrap programmatic selection in a scoped suppression/intent token and audit every call site.

At the effective-selection point:

1. resolve the selected panel UUID;
2. if provenance is operator/focus-intent and it is a terminal whose kind satisfies `AgentIdentityPolicy`, call `noteAgentFocus(surfaceID:)`;
3. otherwise leave agent context unchanged;
4. do not do work on terminal keystroke, drawing, or tab-row body hot paths.

Socket focus-intent methods pass the explicit provenance and count as context changes. Non-focus socket methods and maintenance selection pass suppression provenance and must not change it.

When `terminal_type` changes for the currently selected terminal, run the same recognition method once. If the active agent surface is demoted to `shell`/`unknown` or its kind is cleared, clear active context, increment generation, revoke reveals, and re-derive links as orphaned. The metadata notification originates off-main; its consumer must marshal onto `@MainActor` before reading or mutating `Workspace`. Background metadata changes on other terminals do not change context.

### 10.4 Browser portal integration

Add a `BrowserPortalCompanionConfiguration` value carrying presentation plus callbacks. Thread it through `WebViewRepresentable`, `BrowserWindowPortal.Entry`, registry update calls, and `WindowBrowserSlotView`.

Add an AppKit `BrowserCompanionOverlayHost` above WKWebView. It may host a small SwiftUI veil view, but AppKit owns:

- z-order and re-raise on each portal bind;
- hit testing and first-responder transfer;
- WKWebView accessibility suppression/restoration;
- consuming the first pointer/key activation;
- cleanup on unbind, move, hibernation, and deallocation.

Do not let search, pane-interaction, drag, and companion setters independently determine their final stacking order. Add one deterministic `refreshInteractionLayerOrder()` called after every bind and relevant configuration update so the documented z-order is re-established regardless of setter call order.

When a browser becomes veiled while its WKWebView owns first responder, yield page focus immediately to the veil without changing workspace agent context. Close/yield search UI and force transient page fullscreen/pointer lock to exit if the veil cannot reliably cover it. Pane geometry and selected surfaces remain unchanged. Native permission sheets, JavaScript dialogs, and detached/docked Web Inspector are feasibility gates: the tagged build must either place them inertly below the veil or dismiss/defer them before V1 can be enabled.

For hibernated/blank browsers that do not currently own a portal slot, render an equivalent SwiftUI placeholder treatment; the policy remains identical.

### 10.5 Toolbar and commands

Extend `BrowserPanelView.addressBar` with a compact companion control. Pass the workspace's live agent list, active context, and link actions through `PanelContentView`; do not make `TabItemView` observe Workspace or violate its typing-latency `Equatable` contract.

Add localized menu and command-palette actions in the existing browser command routing. Every user-facing string uses `String(localized:defaultValue:)`. A fresh translation agent must update all six non-English locales.

## 11. CLI and socket contract

### 11.1 Creation provenance

All browser-creation paths accept these additive parameters:

```json
{
  "workspace_id": "workspace UUID",
  "surface_id": "optional existing target or placement source",
  "caller_surface_id": "optional caller surface UUID",
  "link_mode": "automatic | workspace"
}
```

Rules:

- CLI browser creation sets `caller_surface_id` from `C11_SURFACE_ID`, falling back to legacy `CMUX_SURFACE_ID`, only when the caller has not explicitly targeted a different workspace/window.
- `link_mode` defaults to `automatic`.
- `automatic` links only if caller provenance resolves to a live recognized agent in the resolved workspace.
- `workspace` explicitly creates an unlinked browser even from an agent surface.
- `surface_id` keeps its current target/placement meaning; caller provenance never changes layout routing.
- UI/menu creation supplies no caller and creates an unlinked browser.
- `new-pane --type browser` and `new-surface --type browser` use the same provenance contract.
- Every creation handler resolves workspace from explicit routing fields; `caller_surface_id` is never allowed to retarget the request. The CLI must therefore continue forwarding caller workspace identity alongside caller surface identity.

Deterministic invalid-caller behavior:

- absent caller: create unlinked, `link_result: "no_caller"`;
- malformed UUID/ref: reject before creation with `invalid_params`;
- stale/missing surface: create unlinked, `link_result: "caller_not_found"`;
- cross-workspace surface: create unlinked, `link_result: "caller_workspace_mismatch"`;
- live non-agent terminal or non-terminal surface: create unlinked, `link_result: "caller_not_agent"`;
- valid same-workspace agent: create linked, `link_result: "automatic"`;
- `link_mode: "workspace"`: create unlinked, `link_result: "workspace"` regardless of caller.

Caller provenance is attribution, not authentication. A client that wants to mutate an existing link uses the validated explicit link operation.

CLI opt-out:

```bash
c11 browser open --workspace-wide http://localhost:3000
```

The creation response includes an explicit result rather than requiring inference:

```json
{
  "surface_ref": "surface:7",
  "linked_agent_surface_ref": "surface:3",
  "link_result": "automatic"
}
```

### 11.2 Link operations

Add socket methods:

- `surface.context.get`
- `surface.context.link`
- `surface.context.unlink`

Parameters use refs where supported and UUIDs in canonical responses. `surface.context.link` validates:

- target is a browser;
- agent target is a terminal;
- both are live in the same workspace;
- terminal kind satisfies shared `AgentIdentityPolicy`;
- refs are unambiguous.

Suggested CLI:

```bash
c11 browser link --surface surface:7 --agent surface:3
c11 browser unlink --surface surface:7
c11 browser link --surface surface:7 --active-agent
```

These are data mutations, not focus commands. They must preserve macOS focus, current workspace selection, focused pane, and selected surface.

### 11.3 Queries and events

Expose structured state in `surface.list`, `system.tree`, and `surface.context.get`:

```json
{
  "context": {
    "kind": "agent_companion",
    "linked_agent_surface_id": "...",
    "linked_agent_surface_ref": "surface:3",
    "link_state": "unlinked | resolved | orphaned",
    "presentation_state": "unlinked | linked_no_context | aligned | veiled | revealed | orphaned | orphaned_revealed",
    "active_agent_surface_id": "..."
  }
}
```

`presentation_state` is explicitly live and non-durable; it makes reveal and veil behavior a deterministic runtime oracle without confusing it with the persisted link.

V1 does not add a new event type. Link mutation responses and canonical query surfaces are the deterministic oracle, which avoids expanding the versioned event taxonomy without a concrete reactive consumer. Do not smuggle the relationship through `metadata.changed`; a later event addition must update the event schema, fixtures, API reference, and compatibility tests atomically.

## 12. Persistence and lifecycle semantics

### 12.1 Session persistence

Add optional fields:

- `SessionWorkspaceSnapshot.activeAgentSurfaceId`
- `SessionBrowserPanelSnapshot.linkedAgent`
- the companion link on the closed-browser restore snapshot used by Cmd-Shift-T

The session autosave fingerprint must include agent context and browser links; otherwise a pure link change may never trigger a write.

On restore:

1. recreate panels with stable IDs;
2. restore browser links and last-known labels;
3. restore workspace agent context only if the referenced panel is a recognized agent; otherwise clear it to nil and increment no synthetic context;
4. restore focused surface;
5. derive presentation;
6. start with no reveal grants.

All fields are optional additions. Existing session schema version 1 remains decodable; older snapshots yield unlinked browsers and no agent context.

### 12.2 Snapshots and blueprints

Add optional plan-local fields:

- `SurfaceSpec.linkedAgentSurfacePlanId` for browser specs

Capture must become two-pass:

1. assign a plan-local ID to every live surface;
2. emit surfaces and translate browser links through that map.

Apply must also be two-pass:

1. create every surface and populate `planSurfaceIdToPanelId`;
2. validate and resolve companion links after all forward references exist.

The current blueprint authoring format does not expose the traversal-minted `s1` IDs, so `linked_agent: s1` would not be safely authorable by itself. Add an optional explicit `id:` on surface declarations with document-wide uniqueness validation. The parser continues minting IDs when `id:` is absent; the exporter emits explicit IDs for linked participants and a browser field such as `linked_agent: agent-a`. Missing, duplicate, cross-workspace, or non-agent targets produce actionable diagnostics.

Agent context is session state, not blueprint intent. Named snapshots and blueprints preserve a durable browser link only when its target agent participates in the captured/applied plan; they do not encode `activeAgentSurfaceId`. An orphaned live link has no plan-local target, so capture emits a warning and restores that browser unlinked rather than inventing a portable identity. After apply, agent context begins nil until the operator or an explicit focus command focuses an agent.

### 12.3 Close, reopen, and move

- Same-workspace pane/tab moves preserve the panel object and link.
- Cross-workspace moves preserve the target surface UUID and clear reveal. It becomes orphaned in the destination unless its target agent is also there. Because the durable target does not include workspace identity, no implicit relink occurs: workspace-local panel lifecycle reconciliation simply resolves the unchanged UUID if browser and agent later reunite. Moving the browser back also resolves it.
- Closing an agent removes it from live context/MRU and makes linked browsers orphaned. It does not silently unlink them.
- A replacement terminal with a new UUID never inherits an orphaned link automatically, even if its title or agent kind matches; the operator must relink explicitly.
- Cmd-Shift-T browser reopen restores the link and derives current presentation.
- Closing a browser removes its link with the browser.
- Workspace moves between windows preserve all state because workspace identity is unchanged.
- Same-workspace browser duplicate/open-to-side operations copy the valid link because the target agent remains live there. Operations that remap into a different workspace preserve the link only when the target agent participates in the same remapped operation; otherwise the copied browser starts unlinked with an apply warning.
- `target=_blank` and popup content remains under the source browser's effective veil; promotion into a browser surface copies the source link before presentation is derived.

Run link resolution from the existing workspace panel-lifecycle diff after attach/remove, not only from the object being moved. This lets an unchanged target UUID resolve when an independently moved agent later reunites with its browser and keeps rollback behavior centralized.

Orphaning is deliberate. Silent unlinking makes a browser appear workspace-wide even though the operator never made that decision, and it throws away enough information to prevent honest restoration.

## 13. Per-file implementation map

Expected files and responsibilities:

| File | Change |
|---|---|
| `Sources/AgentCompanionContext.swift` | New typed link/context/reveal models and pure presentation policy. |
| `Sources/Panels/BrowserPanel.swift` | Store optional durable link; validated internal mutation; include link in close/reopen data. |
| `Sources/Workspace.swift` | Own active context, agent MRU, reveal grants, focus-provenance integration, panel lifecycle reconciliation, mutation validation, cleanup, and snapshot bridging. |
| `Sources/SurfaceMetadataStore.swift` | Add narrow terminal-kind change notification/publisher; do not make arbitrary metadata an agent-context signal. |
| `Sources/AgentManifest.swift` or shared resolver | Centralize canonical `isAgentTerminalKind` predicate used by context, chip, and pane sizing. |
| `Sources/Panels/PanelContentView.swift` | Pass browser companion presentation, agent choices, and actions without adding hot-path tab-row observations. |
| `Sources/Panels/BrowserPanelView.swift` | Add localized toolbar pill/menu, temporary banner configuration, and portal updates. |
| `Sources/BrowserWindowPortal.swift` | Add AppKit veil host, z-order/rebind behavior, event consumption, first-responder and accessibility handling. |
| `Sources/SessionPersistence.swift` | Add optional session link/context fields. |
| `Sources/WorkspaceApplyPlan.swift` | Add an optional plan-local browser-link reference. |
| `Sources/WorkspacePlanCapture.swift` | Two-pass live UUID -> plan ID mapping. |
| `Sources/WorkspaceLayoutExecutor.swift` | Resolve relationships after all surface IDs exist. |
| `Sources/WorkspaceBlueprintMarkdown.swift` | Parse/export optional explicit surface `id` and `linked_agent`, with uniqueness/reference validation. |
| `Sources/TabManager.swift` | Include fields in autosave fingerprint and closed-browser reopen path; revoke reveals when a workspace is deselected. |
| `Sources/AppDelegate.swift` | Preserve context link across cross-workspace/window surface transfer, revoke reveal on window deactivation, and register menu/command-palette actions. |
| `CLI/c11.swift` | Forward caller surface provenance, add `--workspace-wide`, add browser link/unlink commands, update help. |
| `Sources/SocketHandlers/BrowserHandlers.swift` | Validate caller provenance, auto-link, return link result. |
| `Sources/SocketHandlers/SurfaceHandlers.swift` | Add link/get/unlink handlers and provenance for generic browser creation. |
| `Sources/SocketHandlers/PaneHandlers.swift` | Forward caller provenance/link mode through `pane.create --type browser`. |
| `Sources/TerminalController.swift` plus surface/browser query handlers | Resolve caller workspace independently of placement and use one shared companion serializer for `v2TreeWorkspaceNode`, `surface.list`, and browser tab queries. |
| `Resources/Localizable.xcstrings` | English keys plus six translations through a fresh translation surface. |
| `skills/c11/SKILL.md`, `skills/c11/references/api.md`, and `skills/c11-browser/SKILL.md` | Teach automatic linking, workspace-wide opt-out, explicit link operations, and query shape. |
| `c11Tests/*` and `tests_v2/*` | Pure policy, persistence, workspace lifecycle, socket, CLI, portal, and accessibility coverage. |

If the portal work can be factored into a generic, agent-agnostic WKWebView occlusion host, that primitive may be worth proposing upstream to cmux. Agent context, companion semantics, copy, and auto-link behavior are c11-specific and should remain here.

## 14. Phased execution plan

Each phase should be a discrete reviewable commit or PR boundary. Later phases should not compensate for missing semantics in earlier ones.

### Phase 0 — Contract fixtures and pure policy

1. Add the typed models and pure presentation reducer.
2. Encode every state and transition from Sections 6–7 as logic tests.
3. Add stable link validation errors and agent-kind predicate tests.
4. Add a debug-only state description suitable for tagged-build inspection.

**Exit gate:** State transitions are executable and deterministic without AppKit. No UI or persistence code carries ad hoc booleans such as `isVeiled`.

### Phase 1 — Workspace context and manual links

1. Add workspace context, MRU, and reveal state ownership.
2. Add and audit explicit selection provenance across operator, socket-focus, restore, create, move, close, and reconciliation paths.
3. Integrate late `terminal_type` promotion/demotion on `@MainActor`.
4. Revoke reveals on effective surface focus loss, workspace deselection, and window deactivation.
5. Add validated browser link/unlink/reveal/hide methods.
6. Cover focus, close, same-workspace move, and orphan transitions.

**Exit gate:** Agent A -> browser -> Agent B produces a mismatch in model state; browser focus never clears B; background agent activity never changes context.

### Phase 2 — Portal veil and browser toolbar

1. Add the toolbar link control and chooser.
2. Add the AppKit portal overlay host.
3. Enforce first-event consumption, first-responder handoff, accessibility inertness, z-order, and rebind behavior.
4. Make the entire veil activatable and disable page-affecting toolbar controls until reveal.
5. Add revealed-state toolbar treatment and explicit Hide without occluding/resizing page content.
6. Handle blank, hibernated, devtools, search, popup, and portal-churn states.

**Exit gate:** A tagged build demonstrates the complete manual-link interaction without geometry or surface-selection changes and without click-through.

### Phase 3 — Creation provenance and public API

1. Add `caller_surface_id` and automatic/workspace link mode to every browser creation route.
2. Make the CLI forward its surface environment.
3. Apply source-link inheritance to popup promotion, duplicate, split, context-menu, and open-to-side descendants.
4. Add browser link/unlink/get commands and full live `presentation_state` query output.
5. Update help, API reference, deterministic caller outcomes, errors, and socket tests.
6. Keep V1 event-neutral; verify link state through mutation responses and canonical queries.

**Exit gate:** Browser creation from Agent A links to A even while the operator is focused on Agent B; manual UI creation remains unlinked; no command steals focus.

### Phase 4 — Durability and movement

1. Add session and closed-browser persistence.
2. Include context state in autosave fingerprinting.
3. Add two-pass plan capture/apply for snapshots and blueprints.
4. Implement and test orphan behavior for close, move, restore, copy, and reopen.
5. Add backward-compatibility fixtures from pre-feature snapshots/blueprints.

**Exit gate:** Links survive app restart and Cmd-Shift-T, including session orphan tombstones; links with participating targets survive named snapshot and blueprint apply; all restored reveal states are absent.

### Phase 5 — Localization, skill, and validation

1. Localize every new string at the call site.
2. Delegate six-locale `.xcstrings` translation in a fresh c11 surface.
3. Update the c11 skill and API reference.
4. Run `scripts/sync-installed-skills.sh` and verify the installed `c11` and `c11-browser` copies.
5. Build and launch a tagged QA app with startup dialogs suppressed.
6. With explicit operator approval, run visual/computer-use scenarios and capture screenshots/evidence.

**Exit gate:** The feature is documented for agents, localized for all shipped locales, visually verified, and inspectable through the socket.

### Recommended rollout switch

Keep the first integration behind an internal `AgentCompanionBrowserFeature` default-off switch until Phases 0–4 are complete. Enable it by default only after the tagged-build matrix passes. Do not ship a mode where links are durable but the veil is unreliable, or where the veil exists but agent-created browsers cannot attribute themselves.

## 15. Verification strategy

### 15.1 Pure logic tests (`c11LogicTests`)

Cover at minimum:

- unlinked, linked-no-context, aligned, mismatched, revealed, orphaned, orphaned-revealed derivation;
- reveal grant keying by browser, link target, active context, and generation;
- A -> B -> A does not retain an old reveal;
- background activity does not affect context;
- maintenance selection during create/move/close/restore does not affect context;
- shell/browser/markdown focus does not clear context;
- late recognized `terminal_type` on the selected terminal establishes context;
- declassifying the active agent clears context, advances generation, and orphans its links;
- duplicate/renamed labels do not alter identity;
- link validation rejects cross-workspace, non-browser, non-terminal, and ordinary-shell targets;
- one agent can own many browser links without any primary-browser selection;
- no-context behavior is interactive.

Safe local command, narrowed to the pure class:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme c11-logic -configuration Debug \
  -destination "platform=macOS" test \
  -only-testing:c11LogicTests/BrowserCompanionPolicyTests
```

### 15.2 Host-required tests (`c11Tests`)

Cover:

- `Workspace.applyTabSelectionNow` context transitions;
- portal first responder and accessibility suppression/restoration;
- close/reopen and cross-workspace move behavior;
- search/devtools/hibernation interactions;
- workspace deselection and window deactivation revoke reveals without relying on a panel callback;
- same-surface omnibar, toolbar menu, banner, and VoiceOver focus changes do not revoke reveal;
- page-affecting browser controls are inert while the companion link control remains usable;
- popup/duplicate/open-to-side descendants inherit the source link;
- session round-trip and autosave fingerprint changes;
- focus preservation for link socket methods;
- no pane/tab selection changes when context changes.

Use the safe wrapper, never a raw local `c11-unit` launch:

```bash
scripts/test-unit-local.sh -only-testing:c11Tests/BrowserCompanionWorkspaceTests
```

### 15.3 Persistence fixtures

- Decode a pre-feature session snapshot with absent fields.
- Round-trip a linked browser and active context.
- Assert reveal state is never encoded.
- Restore an absent agent as orphaned, then reattach the stable ID and resolve it.
- Capture/apply a blueprint where the browser precedes its linked agent in tree order, proving forward-reference remapping.
- Reject a blueprint link to a nonexistent or non-agent plan surface with an actionable error.

### 15.4 Socket/CLI tests (`tests_v2`)

- Creation with valid agent caller provenance auto-links.
- Creation with `--workspace-wide` does not link.
- Missing, stale, non-agent, wrong-workspace, malformed, and valid caller cases produce the exact documented creation result.
- `surface.context.link/unlink/get` resolve refs and return canonical UUIDs.
- Link operations do not mutate focused workspace, pane, surface, or macOS activation state.
- `surface.list` and `system.tree` show aligned/mismatched/orphaned state.
- canonical queries expose every live `presentation_state`, including revealed and linked-no-context.
- Existing clients omitting new fields retain existing behavior.

Python socket tests must target a tagged app socket; never launch an untagged DEV app.

### 15.5 Tagged visual matrix

Use a tagged build with QA dialogs suppressed:

```bash
C11_QA_LAUNCH=fresh ./scripts/reload.sh --tag agent-companion-browser
# or launch an existing tagged build:
scripts/launch-tagged-automation.sh agent-companion-browser --qa fresh
```

Visual scenarios:

1. Agent A plus its prototype; focus B; confirm geometry and selected surfaces are pixel-stable while A's page veils.
2. Click View anyway over an obvious destructive webpage control; confirm the control does not fire.
3. Interact after reveal; focus elsewhere; confirm re-veil.
4. Relink through visible toolbar while veiled; confirm immediate aligned state.
5. Multiple agents and multiple browsers, including two browsers linked to one agent.
6. Browser with devtools, Find-in-page, JavaScript alert, permission prompt, media, pointer lock, and full-screen content.
7. Split/merge/move/drag, workspace switch, window move, close/reopen, restart, snapshot, and blueprint restore.
8. Narrow browser pane; confirm adaptive toolbar and readable veil.
9. Keyboard-only and VoiceOver path; confirm underlying web content is absent while veiled and other panes remain reachable.
10. Light/Dark c11 theme slots, Increase Contrast, Reduce Transparency, and reduced-motion settings.
11. Agent automation navigates a veiled browser; confirm the veil never flashes away and automation remains functional.

Per repository policy, UI E2E runs through `gh workflow run test-e2e.yml`, not locally. Computer-use validation requires operator confirmation before invoking the expensive tool.

## 16. Acceptance criteria

### Context semantics

- **CTX-1:** Focusing Agent A sets workspace agent context to A.
- **CTX-2:** Focusing browser, markdown, or shell preserves A.
- **CTX-3:** Focusing Agent B changes context to B and revokes all prior reveals.
- **CTX-4:** Background output/status/activity never changes context.
- **CTX-5:** Late recognition of the currently selected agent terminal establishes context once.
- **CTX-6:** Create, restore, move, detach, close fallback, and reconciliation selection never change context without explicit focus provenance.
- **CTX-7:** Declassifying the active agent clears context and makes its linked browsers orphaned; reclassifying the same focused surface resolves them.

### Spatial and interaction behavior

- **UX-1:** An agent-context change never changes pane geometry, pane focus, tab ordering, or selected browser tabs.
- **UX-2:** A mismatched linked browser is visibly veiled while its toolbar remains usable.
- **UX-3:** The first reveal click/key is consumed and cannot reach page content.
- **UX-4:** Reveal does not relink.
- **UX-5:** Losing browser focus or changing context re-veils it.
- **UX-6:** Unlinked browsers and resolved linked browsers with no current agent context remain interactive; orphaned links remain veiled.
- **UX-7:** The veil is keyboard and VoiceOver operable and underlying web content is inert.
- **UX-8:** Workspace deselection/window deactivation revoke reveal, while focus changes inside the same browser chrome do not.
- **UX-9:** Page-affecting browser controls are disabled while veiled; link/relink/unlink remain available.
- **UX-10:** Revealed mismatch status lives in browser chrome and neither covers page controls nor changes the web viewport.

### Creation and API

- **API-1:** Agent-created browser surfaces auto-link to the validated caller agent regardless of operator focus.
- **API-2:** Manual UI creation and `--workspace-wide` create unlinked browsers.
- **API-3:** Link APIs validate type/workspace/identity and return structured state.
- **API-4:** Link operations preserve all focus state.
- **API-5:** Existing clients that omit new fields remain compatible.
- **API-6:** Browser descendants and same-workspace duplicates inherit their source browser's link.
- **API-7:** Canonical queries distinguish all durable link and live presentation states.

### Durability

- **PER-1:** Link and last agent context survive app restart.
- **PER-2:** Link survives same-workspace moves, window moves, and Cmd-Shift-T; snapshots and blueprints preserve it when the target agent participates in the plan.
- **PER-3:** Cross-workspace move or agent close produces an honest orphan, not silent unlinking.
- **PER-4:** Temporary reveal never survives focus loss, context generation, move, restore, or relaunch.
- **PER-5:** Pre-feature persistence artifacts decode as unlinked/no-context.
- **PER-6:** Orphan links survive session persistence; named snapshot/blueprint capture warns and unlinks when no plan-local target exists.

### Platform integrity

- **PLAT-1:** Veil remains above WKWebView through portal rebind, hibernation, devtools, and layout churn.
- **PLAT-2:** Page automation remains addressable while human interaction is veiled.
- **PLAT-3:** No new work enters terminal typing, draw, or `TabItemView` hot paths.
- **PLAT-4:** All strings are localized and the installed c11 skill matches repository source.

## 17. Risk register

| Risk | Consequence | Mitigation / gate |
|---|---|---|
| SwiftUI overlay renders below WKWebView | Veil appears ineffective or permits click-through | Implement in `WindowBrowserSlotView`; assert z-order after every bind. |
| Reveal event passes through | Accidental destructive page action | AppKit host consumes activation; destructive-control visual test. |
| Browser focus overwrites agent context | Veil disappears or oscillates | Keep typed workspace context independent from `focusedPanelId`; pure transition tests. |
| Programmatic selection looks like operator focus | Create/move/restore silently changes agent context | Thread explicit focus provenance and audit every selection call site. |
| Late agent detection misses context | Browser stays unlinked/misclassified until refocus | Narrow terminal-kind publisher for selected terminal. |
| Workspace deselection leaves a reveal alive | Returning exposes a mismatched page without a veil | Revoke at workspace/window lifecycle seams, not only panel selection. |
| Generic metadata is treated as authority | Forged/dangling links and broken snapshot remapping | Typed model with workspace validation; metadata only as optional mirror. |
| Plan capture stores live UUID | Snapshot/blueprint links break on apply | Two-pass plan-local mapping and forward-reference test. |
| Autosave fingerprint omits link | Link appears to persist but is lost after restart | Fingerprint regression test for link-only change. |
| WebKit auxiliary UI pierces veil | Dialog, inspector, full-screen, or permission UI remains actionable | Explicit scenario matrix; fail rollout gate for unsupported unsafe state. |
| Link language implies security | Operator assumes automation/credential isolation | Use `linked` and document human-context-only semantics in UI/help. |
| Too much chrome in narrow panes | Browser controls become unusable | Adaptive label/icon treatment and command/menu equivalents. |
| Revealed status occludes or resizes page | Fixed controls disappear or viewport shifts | Keep status inside existing browser chrome; never overlay/insert into page viewport. |
| Cross-workspace behavior silently changes meaning | Browser looks workspace-wide without operator action | Preserve qualified link as orphan and offer explicit relink/unlink. |
| Portal change increases upstream divergence | Future cmux sync pain | Keep policy out of portal; consider upstreaming generic occlusion host. |
| Agent switch causes widespread view invalidation | Typing or focus latency regression | Publish compact context generation; avoid `TabItemView` and keystroke paths; profile tagged build. |

## 18. Deferred extensions

The architecture deliberately leaves room for, but does not include:

- companion markdown, image, artifact, or diff surfaces;
- task/conversation-scoped links that survive terminal replacement;
- an optional “follow active agent” browser lane, which would require a non-focus-changing Bonsplit tab-selection primitive;
- grouped companion collections and agent overview modes;
- privacy veils or browser-profile isolation;
- page suspension/audio policies while veiled;
- agent authorization rules for browser automation;
- context lineage for artifacts copied between workspaces.

The optional future “follow” behavior must be a different feature. Bonsplit's current `selectTab` also focuses its pane; using it automatically would violate the locked spatial/focus invariants and recreate the original problem in a subtler form.

## 19. Definition of done

The feature is complete only when all of the following are true:

- the typed model and transition suite pass;
- manual and automatic links share one validated path;
- the AppKit veil blocks human interaction without hiding browser toolbar or altering geometry;
- the first reveal event is proven not to reach page content;
- link state is queryable, restorable, and correctly remapped through every persistence family;
- focus-preservation and typing-latency policies hold;
- all locales, CLI help, API docs, and the c11 skill agree with shipping behavior;
- the installed skill has been synced and verified;
- a tagged build passes the full visual/accessibility/lifecycle matrix;
- screenshots and runtime evidence accompany the implementation review.

At that point c11 will not merely display many agents and many surfaces. It will preserve which pieces of visible context belong together while letting the operator cross those boundaries intentionally.
