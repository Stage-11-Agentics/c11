# cmux upstream PR bundle: orphan portal entry fix

A ready-to-submit upstream contribution to [`manaflow-ai/cmux`](https://github.com/manaflow-ai/cmux). Branch is committed locally on `upstream-cmux-orphan-portal-entry` and not yet pushed. Everything in this doc can be copy-pasted into the PR or the maintainer outreach.

## Cover note (draft for outreach)

Adapt as needed. Keep it short.

> Hi [maintainer],
>
> I'm Atin. We've been running [c11](https://github.com/Stage-11-Agentics/c11), a downstream fork of cmux focused on the operator-agent pair use case (lots of parallel agents, addressable surfaces, that kind of thing). Heavy users of the work you've done. Big thanks for the Ghostty embed, the portal architecture, and the CLI shape: those carry the whole project for us.
>
> While shipping our fork we've found and fixed a few bugs that I think would benefit upstream cmux directly. I'd like to start sending those back. Here's the first one: a portal-entry orphan bug that produces a stale rendering artifact on launch and persists for the rest of the session. It's intermittent and timing-sensitive, but reproducible. We tracked it down with instrumentation, confirmed the mechanism, and shipped a fix on our side. The same mechanism exists in cmux's `entriesByHostedId` / `entriesByWebViewId` registries, so the fix ports cleanly with c11-specific surfaces stripped out.
>
> Branch: `upstream-cmux-orphan-portal-entry` (113 lines added across `Sources/TerminalWindowPortal.swift` and `Sources/BrowserWindowPortal.swift`, no behaviour changes for non-orphan entries). Full PR description and technical detail in the attached writeup.
>
> Happy to discuss any questions, iterate on the patch, or split it differently. Looking forward to a long, friendly relationship between the two projects. More fixes coming as we find them.
>
> Thanks again for building this.

## PR — title and one-line summary

**Title**: `Hide orphan portal entries that paint stale frames`

**One-line summary**: Reap portal entries whose anchor weak reference deallocated mid-bind so they stop painting stale Ghostty surfaces or WKWebView containers on top of the live workspace for the rest of the session.

## PR — body

### What this fixes

Portal entries can be bound against a SwiftUI host view that gets dismantled mid-bind, for example when bonsplit's `_ConditionalContent` flips between branches between the bind call and the next geometry sync. The entry's `weak var anchorView` deallocates, but the entry itself stays in `entriesByHostedId` / `entriesByWebViewId` with `visibleInUI = true`. Its `hostedView` (terminal) or `containerView` (browser) keeps its bind-time frame and continues painting on top of the live workspace forever.

Symptoms a user sees:

- A stale Ghostty surface or WKWebView container rendered at a frozen frame, occluding parts of other panes.
- Permanent for the session: no resize, scroll, divider drag, focus change, or workspace switch clears it.
- Survives workspace switches because the registries are per-window, not per-workspace.
- Appears on plain launches, no crash recovery required. Timing-sensitive: the same bind/dismantle race fires on some launches and not others depending on bonsplit's `_ConditionalContent` resolution timing.

### Where the bug lives

Both portal classes share the shape:

- `Sources/TerminalWindowPortal.swift`
  - `private struct Entry` at line 620 (`weak var anchorView: NSView?`)
  - `private var entriesByHostedId` at line 628
  - `fileprivate func synchronizeAllEntriesFromExternalGeometryChange()` at line 784
- `Sources/BrowserWindowPortal.swift`
  - `private struct Entry` at line 2128 (`weak var anchorView: NSView?`)
  - `private var entriesByWebViewId`
  - `private func synchronizeAllEntriesFromExternalGeometryChange()` at line 2320

(Line numbers as of `manaflow-ai/cmux@3b5ce50f`. The fix is on a branch based on that commit.)

### Root cause

1. SwiftUI mounts a pane. Some intermediate state of `_ConditionalContent` provides a host container view to the portal layer.
2. `TerminalWindowPortalRegistry.bind(...)` (or the browser equivalent) registers an entry against that host as the anchor, with `visibleInUI = true`.
3. The conditional flips to the actual settled branch. The original anchor is removed from the SwiftUI tree and deallocated. The entry's `weak var anchorView` becomes nil.
4. The entry stays in the registry. `synchronizeHostedView` does have an `anchorView == nil` check, but it routes through `scheduleTransientRecoveryRetryIfNeeded`, which (because the retry budget resets to full whenever it hits zero) effectively retries forever and never gives up. So the entry never gets hidden.
5. Every paint cycle the orphan's `hostedView` / `containerView` keeps drawing at its bind-time frame.

### The fix

Add a single new private method to each portal that walks its registry once and hides entries whose anchor is definitively gone. Call it from `synchronizeAllEntriesFromExternalGeometryChange` before `synchronizeAllHostedViews`. For the terminal portal, also flip `dividerOverlayView.needsDisplay = true` if anything was hidden so any divider segments that referenced the orphan repaint clean.

"Definitively gone" means one of:

- the anchor weak reference deallocated (`anchor == nil`), or
- the anchor migrated to a different window (`anchor.window !== window`).

We deliberately skip the case `anchor != nil && anchor.window == nil`. That's a momentary window-less limbo state during attach/detach, and `synchronizeHostedView`'s existing transient-recovery path handles it. Hiding aggressively there would cause a flash during legitimate workspace remounts.

### Diff summary

- `Sources/TerminalWindowPortal.swift`: +66 lines
  - Six lines in `synchronizeAllEntriesFromExternalGeometryChange`: call `hideOrphanEntriesIfNeeded()` before the existing sync, and invalidate `dividerOverlayView` if anything was hidden.
  - One new private method `hideOrphanEntriesIfNeeded()` with the orphan detection loop and a `cmuxDebugLog("portal.orphan.hide ...")` trace inside `#if DEBUG`.
- `Sources/BrowserWindowPortal.swift`: +47 lines
  - Same pattern, slightly smaller because the browser portal doesn't use `dividerOverlayView`. Logs as `browser.portal.orphan.hide ...`.

Total: 113 lines added, 0 removed.

### What this fix does not do

It catches orphans after they form. It does not prevent the orphan from being created in the first place. The bind path still hands `bind(...)` a host view that's about to be dismantled. The right architectural fix is to gate the bind on the anchor having been stable in the live tree across at least one settle cycle, or to register a one-shot "anchor stable" observer and only enter the registry once that fires. That's a bigger change and we wanted to ship the visible-symptom stop first. Happy to take a swing at the deeper fix as a follow-up if it'd be welcome.

### Risk and compatibility

- No behaviour change for non-orphan entries. The new code path returns early when the anchor is alive in the right window.
- The new code does not touch the existing transient-recovery path, the bind path, the entry creation path, or any anchor binding. It only walks the registry and toggles `visibleInUI` and `isHidden` on already-orphaned entries.
- `setNeedsDisplay = true` on the divider overlay is the same call already made by `ensureDividerOverlayOnTop` and other paths. Cheap, idempotent.
- No typing-latency hot path is touched (`hitTest`, `forceRefresh`, `TabItemView` body all untouched).
- No public API change. All new code is `private`.
- Compatible with the existing `transientRecoveryRetriesRemaining` machinery: the orphan check runs first, hides the entry, and then `synchronizeHostedView` sees `visibleInUI = false` and follows the existing not-visible-in-UI branch (which sets `hostedView.isHidden = true` and resets the retry counter).

### Reproduction

The bug is timing-sensitive on bonsplit's `_ConditionalContent` resolution. To reproduce manually:

1. Open or create a workspace with at least two panes (any combination of terminal / browser / split).
2. Quit cmux.
3. Relaunch. Watch the workspace as it settles.

On a fraction of launches you'll see a thin or rectangular region painted at a position that doesn't correspond to any current pane boundary, persisting until the next quit. The exact x/y depends on the intermediate bonsplit layout at bind time.

A more deterministic repro requires instrumentation. We instrumented the registry's bind/sync path and confirmed the orphan formation in our investigation; happy to share a probe patch if that'd be useful for you to reproduce on demand.

### Validation we ran

On the c11 fork:

- Tagged debug build with the same fix applied.
- Reproduced the orphan formation under instrumentation: `portal.bind hosted=…380 anchor=…` followed shortly by `portal.orphan.hide hosted=…380 anchor=nil anchorWindow=deallocated`.
- Five orphan reaps captured across one extended session involving normal launches plus pane edits and workspace switches, all `anchor=nil anchorWindow=deallocated`. No false-positive hides observed (no flicker on legitimate workspace remounts).
- The visible artifact appears briefly during the form-then-reap window (one or two frames) and then self-clears. With the follow-up bind-gate fix it would not appear at all.

### Debug observability added

In `#if DEBUG` builds the fix emits new traces into `cmuxDebugLog`:

- `portal.orphan.hide hosted=<token> anchor=<token> anchorWindow=<deallocated|nil|self|other>`
- `browser.portal.orphan.hide web=<token> anchor=<token> anchorWindow=<deallocated|nil|self|other>`

Useful for confirming the fix is firing in your environment.

## How this was found

We hit a recurring "white line that survives workspace switches and ignores theme color changes" artifact in c11 and dug in with instrumentation around the portal registries. The investigation went through several wrong theories (workspace frame stroke, theme color caching, divider overlay rasterization) before the operator's observation that "the line is at the same x across different workspaces" narrowed the cause to per-window state. From there we added probes inside `synchronizeAllEntriesFromExternalGeometryChange` and the chrome-segment computation, captured a reproduction, and saw an entry with frame `200,108 920x740` that never moved across multiple bonsplit settle passes while sibling entries did. Detach-time logs showed `anchor=nil` for that entry, confirming the weak reference had deallocated mid-bind.

The full investigation log lives in our fork at `notes/launch-white-line-artifact.md`. It's c11-specific in places but the upstream-relevant mechanics are reproduced in this PR description.

## About c11

[c11](https://github.com/Stage-11-Agentics/c11) is a downstream fork of cmux. We've layered on agent-facing primitives (a skill system, addressable surface handles, sidebar telemetry written by agents, markdown surfaces, theme work) but the underlying terminal multiplexer, browser substrate, portal architecture, and CLI shape are all yours. The relationship we'd like is bidirectional: pull upstream fixes when they apply, push fixes back when they're not c11-specific. This is the first one we're sending back. We'd love feedback on the patch and on how you'd like contributions structured going forward.

## Logistics (operator-only, strip before sending)

### Branch and worktree

- Worktree path: `/Users/atin/Projects/Stage11/code/cmux-upstream-orphan-portal`
- Branch (local only): `upstream-cmux-orphan-portal-entry`
- Base: `upstream/main` at `3b5ce50f Harden cloud VM production controls`
- Commit: `523597d7 Hide orphan portal entries that paint stale frames`

### Pushing to your personal cmux fork

```bash
# Add the fork remote once if you haven't already.
cd /Users/atin/Projects/Stage11/code/cmux-upstream-orphan-portal
git remote add atin git@github.com:<your-username>/cmux.git

git push atin upstream-cmux-orphan-portal-entry

# Then open the PR via the GitHub UI or:
gh pr create \
  --repo manaflow-ai/cmux \
  --base main \
  --head <your-username>:upstream-cmux-orphan-portal-entry \
  --title "Hide orphan portal entries that paint stale frames" \
  --body-file <path-to-trimmed-version-of-this-doc>
```

If you want to bundle additional bug fixes into the same outreach, consider whether they should be one PR (rare) or a series (more common upstream). Each fix has its own commit on its own branch by default. Reach back out and we'll help you stack them.

### After the PR lands or is closed

```bash
git worktree remove /Users/atin/Projects/Stage11/code/cmux-upstream-orphan-portal
git branch -D upstream-cmux-orphan-portal-entry
```

### Cross-references

- Our merged fix on c11: PR #88 on [Stage-11-Agentics/c11](https://github.com/Stage-11-Agentics/c11)
- Investigation log: `notes/launch-white-line-artifact.md` in the c11 repo
- This bundle: `notes/cmux-upstream-pr-bundle.md` in the c11 repo
