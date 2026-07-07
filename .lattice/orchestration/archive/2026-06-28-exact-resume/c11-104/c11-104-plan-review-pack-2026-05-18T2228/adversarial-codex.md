# Adversarial Plan Review: c11-104-plan / Codex

## Executive Summary

I am concerned. The core user need is valid, but the plan is trying to add a new derived metadata system without first reconciling three already-existing systems: per-surface canonical metadata, per-panel branch/directory sidebar state, and the current off-main git/PR probe in `TabManager`. The biggest issue is that the plan treats "derived canonical metadata chips" as a clean extension of the existing metadata store, while also saying "derive, don't store." In the current codebase those are in tension: canonical metadata is source-tagged, persisted, socket-visible, and rendered mostly for the focused surface, not a transient projection for every terminal pane.

If implemented literally, this can become a fragile duplicate git resolver that races the existing branch reporter, adds more git subprocess latency, persists supposedly-derived state, and renders branch information twice in the sidebar. The plan needs a sharper architecture boundary before delegation: either these chips are a render-time projection from the existing per-panel cwd/git state, or they are canonical metadata with all the persistence, precedence, socket, and override semantics that implies. The plan currently wants both.

## How Plans Like This Fail

This type of feature usually fails by underestimating "small UI metadata" as a rendering tweak when it is really a live systems problem. Every prompt, cwd change, pane close, workspace restore, and slow repository now participates in sidebar truth. The failure mode is not catastrophic; it is stale chips, duplicate branch displays, occasional sidebar jumps, unbounded git processes, and edge cases that make operators stop trusting the signal.

This plan is vulnerable in five predictable ways:

- It adds a second git context resolver instead of specifying how it composes with the existing `TabManager` git metadata probe and shell-reported branch/directory state.
- It defines cache invalidation around `.git/HEAD` as if git topology is uniform. Worktrees, gitfiles, submodules, packed refs, branch renames, deleted paths, network filesystems, and coarse mtimes break that assumption.
- It introduces a new metadata precedence tier without deciding whether `derived` is an internal writer source, a public socket source, a persisted source, or a render-only source.
- It makes visual acceptance criteria that are either subjective or post-merge, leaving the high-risk UI behavior under-verified before the PR lands.
- It bundles color hints with resolver/metadata/schema changes, increasing the review surface while still leaving collision behavior deliberately hand-wavy.

## Assumption Audit

Load-bearing assumption: OSC 7 is the right trigger and fires "once per prompt." In practice, shell integration behavior varies, and c11 already also accepts `report_pwd` / `report_git_branch` telemetry. The plan does not say whether derived resolution should run on OSC 7 only, on `report_pwd`, on `report_git_branch`, on restore, or on existing initial git probe refreshes. If it only hooks one path, restored or nonstandard shells can be wrong. If it hooks all paths naively, git work multiplies.

Load-bearing assumption: `(cwd, mtime-of-.git/HEAD)` is a correct cache key. It is not. In linked worktrees and submodules, `.git` is commonly a file pointing elsewhere, so `.git/HEAD` may not exist at the cwd root. Branch identity may depend on the real gitdir's `HEAD`, a ref under `refs/heads`, `packed-refs`, or worktree-specific files under `.git/worktrees/...`. HEAD mtime can change without a meaningful branch display change, and branch/ref state can change without the mtime signal the plan expects, especially across external git operations, coarse filesystem timestamps, symlinked repos, and network volumes.

Load-bearing assumption: multiple git subprocesses per cwd change are cheap enough. The plan calls for several `git rev-parse` / `symbolic-ref` commands, and the codebase already has `TabManager.initialWorkspaceGitMetadataSnapshot` running git commands and sometimes `gh` probes for PR state. The existing helper defaults to no timeout for git. Adding another resolver without explicit timeouts, concurrency limits, cancellation, and dedupe is a latency risk on slow disks, remote mounts, large repos, and repos with hooks/config weirdness.

Load-bearing assumption: "derived canonical metadata" can be in the same write path as explicit/declare/osc/heuristic without persistence drift. Current metadata is persisted through session snapshots with source sidecars. If `worktree` and `branch` are written into `SurfaceMetadataStore` as `.derived`, they will likely persist unless deliberately stripped. That directly conflicts with "store nothing, recompute on cwd change."

Load-bearing assumption: sidebar chips are per-surface but the sidebar row has a clear surface to render. Existing `AgentChip` is resolved from the workspace's focused surface. Existing branch/directory rows iterate ordered panel IDs. The plan does not state whether the new worktree/branch chips represent the focused surface, every surface in a workspace, only terminal surfaces, or an aggregated workspace state. That ambiguity is fatal in split panes and tab-stacked panes, which are exactly c11's primary use case.

Load-bearing assumption: users can override `branch` or `worktree` explicitly and that is harmless. If an explicit override wins over derived data, the sidebar can show stale or false worktree context forever until cleared. For a feature whose value is operator trust, this is not a rare corner; it is a policy decision.

Load-bearing assumption: basename-only worktree labels are sufficient because color disambiguates. With an 8-12 color palette, collisions are guaranteed once enough parallel worktrees exist, and same-basename/different-parent cases intentionally have identical text. The chip text remains ambiguous by design.

Cosmetic assumption: 15-25% opacity for main/master/trunk is safe. This may be too dim against inactive rows or custom sidebar colors. It needs a concrete contrast target or a screenshot-driven review, not "delegator's call."

## Blind Spots

The plan does not reconcile with existing branch/directory rendering. `ContentView.TabItemView` already has `sidebarShowGitBranch`, vertical/compact branch layout settings, and branch/directory rows sourced from `tab.panelGitBranches` and `tab.panelDirectories`. Adding a new branch chip without deciding whether it replaces, augments, or is gated by the existing branch row will likely duplicate branch info and confuse settings semantics.

The plan ignores the existing off-main git metadata probe in `TabManager`. That probe already has generation tokens, expected-directory checks, delayed retries, and a background queue. The plan should either reuse and extend that mechanism or explain why a new resolver is separate. As written, the delegator may create a parallel subsystem with different race behavior.

The plan does not specify stale-result cancellation. A resolver kicked for cwd A can return after the surface has cd'd to cwd B, closed, moved workspaces, or been restored. Existing `TabManager` git probing guards with generation and expected directory; the new plan only says "update when results arrive." That is how stale chips get written.

Submodule handling is under-specified and partly wrong. From inside a submodule, `git rev-parse --show-toplevel` returns the submodule top-level, not the superproject top-level. `--show-superproject-working-tree` must be used as the outer path, then branch/worktree information must be resolved from that outer path separately. The plan also does not define submodule name resolution. Basename is not always the configured submodule path/name, nested submodules are ignored, and a linked-worktree superproject containing a submodule is not called out.

Bare repos and deleted worktrees are not defined rigorously. "Bare clone returns nil" is easy to say, but a terminal can have a cwd inside a deleted directory inode, a path that no longer resolves, a worktree administrative dir left behind after deletion, or a `.git` gitfile pointing to a removed target. The plan needs a clear stale-clearing rule: failed resolution for the current cwd must clear previous derived chips for that surface, not leave the last successful result.

The settings and localization work is incomplete. The plan adds user-facing settings copy but does not mention `Resources/Localizable.xcstrings` or the six-locale translation pass required by repo policy. It also does not say how the new master toggle composes with existing sidebar detail toggles like "Show Git Branch" and "Hide All Details."

The code ownership/build-system impact is missing. Adding new Swift files to `c11LogicTests` and app targets likely touches the Xcode project. The plan does not mention pbxproj churn, target membership, or how to keep resolver logic hostless while chip rendering touches SwiftUI/AppStorage/sidebar code.

The plan omits observability. There is no debug log, metric, or counter for resolver duration, cache hits/misses, timeouts, stale result drops, or git failures. Without that, latency regressions and stale sidebar bugs will be anecdotal.

## Challenged Decisions

The `derived` source tier is questionable. If derived values are internal projections, they probably should not be a general metadata source accepted over the socket. If they are first-class metadata, they need persistence, clear semantics, socket docs, validation, and migration behavior. The plan only says "ranked below osc" and tests `osc` wins over `derived`, but `osc` currently writes title, not branch/worktree. The test proves ordering machinery, not the product behavior.

Bundling color hints with the resolver should be challenged. Color is useful, but it adds palette, contrast, collision, theme, settings, and visual review concerns. The plan already has high-risk backend semantics. Bundling D makes the PR feel complete while increasing the chance that resolver flaws hide behind UI polish.

Basename-only labels are a deliberate ambiguity. The operator may have chosen it, but the plan should admit the cost: same basename under different parents is text-identical, and the palette cannot guarantee uniqueness. The fallback should be specified, such as tooltip/full path, middle truncation on hover, or exposing full path in `sidebar.state`.

The cache key should not be mtime-centered. A safer design is to resolve the actual gitdir via `git rev-parse --git-dir --git-common-dir`, key against resolved gitdir/worktree administrative files, and always validate that the async result still matches the surface's current normalized cwd before applying. If performance requires caching, cache final context with short TTL plus generation checks, not just HEAD mtime.

The plan's "same write path" language is dangerous. The existing write path is for external and internal writers mutating a store. Derived worktree context may be better modeled as `WorktreeContextResolver` output consumed by sidebar projection and socket state, with no `SurfaceMetadataStore` write unless there is a very explicit reason.

The submodule stacked two-row layout is a bigger UI change than acknowledged. `TabItemView` is already latency-sensitive and Equatable. Adding variable chip rows per surface, possibly for multiple panels, risks row height churn and equality mistakes unless the plan specifies precomputed value structs included in `TabItemView ==`.

## Hindsight Preview

Two years from now, the likely regret is: "We should have extended the existing panel git metadata pipeline instead of creating canonical metadata for something that was never supposed to be written by agents." The current code already tracks per-panel directories and branches, schedules git probes off-main, and renders branch/directory rows. The lower-risk path is to enrich that pipeline with worktree classification and render it coherently.

Another likely regret: "We accepted tests that touched the happy git topology but missed real worktree/submodule gitfile behavior." Temp repos must exercise `.git` as a file, linked worktree admin dirs, submodule gitfiles, detached submodule HEADs, deleted cwd paths, and branch deletion/ref disappearance. Otherwise the resolver can look correct while only handling main checkouts.

Early warning signs the plan should watch for:

- Sidebar shows both old branch row and new branch chip for the same surface.
- A chip remains after `cd /tmp` or after deleting the worktree directory.
- A worktree chip briefly flashes the previous cwd after rapid `cd` commands.
- `sidebar.state` and visible sidebar disagree about branch/worktree context.
- Unit tests pass but no test can fail when git subprocesses run on the main thread indirectly.
- New `derived` appears in persisted snapshots or is accepted from user socket calls without a clear policy.
- Resolver failures are silent and indistinguishable from "not in a git repo."

## Reality Stress Test

Disruption 1: the operator runs ten agents across worktrees on a slow external or network volume. Each prompt emits cwd/branch telemetry, the existing git probe runs, and the new resolver launches several additional git commands. Without a timeout and concurrency budget, the background queue backs up and stale results arrive late. The sidebar starts showing lagging or flickering chips, undermining the feature's purpose.

Disruption 2: a delegator deletes or moves a worktree while the pane is still open. The shell may still report a cwd string, but `Process.currentDirectoryURL` may fail, `.git` may be gone, or the administrative worktree entry may be stale. If failed resolution does not actively clear previous `.derived` values and invalidate cache entries, the sidebar will continue advertising a worktree that no longer exists.

Disruption 3: the pane is inside `ghostty` or another submodule in a linked worktree, detached at a specific commit. The resolver has to show outer worktree+branch and inner submodule+detached branch. The specified command sequence does not correctly derive outer context, the render model has no clear place for two rows, and the acceptance criteria do not require the combined case of "linked worktree + submodule + detached inner HEAD."

If these happen together, the plan has no robust escape hatch: no timeout budget, no stale-result generation requirement, no failure telemetry, and no pre-merge UI smoke gate.

## The Uncomfortable Truths

The plan's acceptance criteria can be made green without proving the feature is trustworthy. AC10 is manual inspection. AC11 says the two hot methods are not modified, but a helper they call could still do work or cause invalidation. AC12 can pass by touching a file and returning the same value without proving correct cache behavior on actual branch/ref changes. AC20 is subjective and post-merge. AC4 asks two different worktree paths to produce different colors despite a tiny palette where collisions are an expected design property.

The "derived precedence" addition may be architecture theater. It sounds consistent with canonical metadata, but the real question is whether worktree context belongs in that metadata store at all. If it does, persistence and explicit overrides are not edge details; they are core behavior. If it does not, adding a source tier is unnecessary risk.

The plan underplays UI density. c11 sidebars already show title, agent chip, status metadata, logs, progress, branch/directory, PRs, ports, notifications, and remote state. Adding two chips plus possible submodule second rows may make rows taller and less scannable, especially across 8-30 agents. "Glanceable" can become "more text in the row" unless the plan sets strict display rules.

The color hint does not solve identity. It is a weak peripheral cue with guaranteed collisions. It should be treated as decorative reinforcement, not disambiguation, and the acceptance criteria should stop pretending different paths should have different colors.

The plan is too casual about "git command latency." In a terminal multiplexer whose repo notes explicitly call out typing-latency-sensitive paths, every subprocess spawned from terminal telemetry deserves a timeout, dedupe, and stale-drop policy. "Run off-main" is necessary but not sufficient.

## Hard Questions for the Plan Author

1. Are `worktree` and `branch` actually stored in `SurfaceMetadataStore`, or are they render-time projections from per-panel git context? Pick one. If stored, why does "derive, don't store" still hold?

2. If `.derived` is added to `MetadataSource`, is it accepted over `surface.set_metadata` / `pane.set_metadata`, persisted in session snapshots, and restorable? If not, where is that forbidden?

3. Why should an explicit user/agent write be allowed to override derived `branch` and `worktree` at all? What prevents a stale explicit value from defeating the feature?

4. How does the new branch chip compose with the existing sidebar branch/directory row and existing `sidebarShowGitBranch` / branch layout settings? Is duplicate branch display expected?

5. Which surface does the sidebar chip describe in a workspace with multiple terminal panes or tab-stacked surfaces: focused surface only, every surface, or an aggregate?

6. Why is this not an extension of `TabManager`'s existing git metadata probe, which already has generation checks and expected-directory stale-result protection?

7. What is the exact stale-result guard? If cwd changes A → B while A's resolver is still running, what prevents A from writing chips after B is current?

8. What timeout applies to each git subprocess? What is the concurrency limit across all panes? What happens when a repo is on a slow network mount and git hangs?

9. What is the cache key for linked worktrees where `.git` is a file and the real HEAD lives under `.git/worktrees/.../HEAD`? What is the key for submodules?

10. Which files invalidate branch display besides HEAD? Do branch ref files, `packed-refs`, `commondir`, `gitdir`, and deleted gitdir targets matter?

11. How does the resolver detect "linked worktree but not main checkout" for repos using `--separate-git-dir`, relative gitfiles, symlinked paths, or nested worktrees?

12. From inside a submodule, how exactly are the outer superproject branch/worktree and inner submodule branch/detached state resolved? Which command runs in which directory?

13. What is the submodule display name source: configured submodule name, path from `.gitmodules`, basename, or something else?

14. What happens to derived chips when cwd no longer exists, the worktree directory is deleted, or the gitdir target from a gitfile is removed?

15. Why does AC4 require two different paths to produce different colors when the palette has only 8-12 colors? Is collision acceptable or not?

16. What is the contrast requirement for main/master/trunk dimming and colored dots in both Light and Dark theme slots, active and inactive rows?

17. How will tests prove resolver work never blocks the main thread beyond code inspection? Can the resolver API assert or inject a main-thread precondition failure in tests?

18. How will cache invalidation tests prove actual bypass instead of merely getting the same result after a `touch`? Is there instrumentation for cache hits/misses?

19. Why are the most important visual checks AC18-AC20 post-merge instead of pre-merge via tagged build and screenshot/smoke validation?

20. Where are localization updates for the new Settings strings handled, including the six non-English locales required by repo policy?

21. What is the debug/telemetry story for resolver failures, timeouts, stale drops, and cache behavior so future latency bugs can be diagnosed?

22. What is the migration/backcompat story for persisted snapshots if `derived` source entries are introduced and then later changed or removed?

23. If "we don't know" is the answer for any of the above, why is the delegator being sent to implementation before those boundaries are decided?
