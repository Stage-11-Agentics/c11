# Evolutionary Plan Review: c11-104-plan / Codex

## Executive Summary

The biggest opportunity is to treat C11-104 as the first visible slice of **spatial metadata**: c11 learning where a surface lives in the operator's working topology, then making that topology glanceable and eventually navigable. The plan says "show worktree and branch chips." The deeper capability is "derive environment context from the surface itself and render it as operator-native control information."

If this evolves well, the chip is not just a label. It becomes the seed for jump commands, grouping, routing, clipboard handoff, batch operations, validation targeting, and agent coordination across worktrees. The plan should therefore avoid baking the implementation too narrowly around two string chips. It should land the current feature, but shape the resolver/output model as a small `SpatialContext` or `DerivedContext` layer that can later grow host, container, repo, package, daemon, language, port, and process-role signals without another conceptual rewrite.

## What's Really Being Built

This plan is building c11's first serious **ambient context inference system**. The surface already exposes cwd and terminal state; C11-104 turns that into derived metadata that the operator can see without asking an agent. That is a different class of feature from normal sidebar decoration.

The core new primitive is:

> Given a surface's live runtime facts, c11 can derive a structured context row and render it as a stable visual/navigational affordance.

Worktree and branch are the right first facts because they map directly to the operator's pain during parallel delegator work. But the durable abstraction is broader:

- `location`: repo, worktree, submodule, container, remote host.
- `state`: branch, dirty status, detached head, active task, daemon health.
- `identity`: project basename, package, language/runtime, service name.
- `relation`: main checkout vs linked worktree, superproject vs submodule, sibling worktrees with same basename, agent surfaces sharing the same context.

That relation layer is especially important. Option C+D creates a row-level visual primitive that says "these surfaces are spatially related." Option E, jump-to-worktree, and clipboard handoff all fall out of that once the relation has a structured representation.

## How It Could Be Better

The plan would be stronger if it explicitly named the new layer as more than metadata-source plumbing. Adding `derived` to the precedence chain is necessary, but the bigger design decision is how c11 represents derived facts before they become chips.

I would add one implementation constraint:

> Build a typed git/spatial context result first, then project it into canonical metadata chips.

For example, the resolver could produce something conceptually like:

```swift
struct SurfaceSpatialContext {
    var primary: GitContext?
    var secondary: GitContext?
    var groupKey: String?
    var colorKey: String?
}
```

The exact names should follow the codebase, but the shape matters. If the implementation goes straight from cwd -> `metadata["worktree"]` / `metadata["branch"]` -> sidebar view, later features will have to reverse-engineer grouping and commands out of display strings. If it produces a context object and then emits chips, Option E becomes a view over `groupKey`, not a second resolver.

I would also separate two concepts that the plan currently blends:

- **Canonical metadata keys**: public, per-surface vocabulary that agents and c11 can read.
- **Derived render context**: c11-owned computed facts, possibly richer than what belongs in the metadata blob.

`worktree` and `branch` can still become canonical keys, but the submodule two-row case already exceeds a flat key model. A row model now would prevent the renderer from becoming special-case-heavy.

Finally, the plan should define whether `derived` is publicly writable through `surface.set_metadata`. If any socket client can write `source: derived`, the word loses its meaning. Better: `derived` is a source tag accepted only by c11 internal writers, while external clients use `declare` or `explicit`. If that is too much scope, at least document the intended boundary so future features do not rely on third-party "derived" writes.

## Mutations and Wild Ideas

### Spatial Command Palette

Once c11 knows worktree context per surface, add command palette entries like:

- `Jump to worktree: c11-104-sidebar-chips`
- `Focus next surface in this worktree`
- `Copy cwd from this worktree`
- `Open browser/docs beside this worktree`
- `Send command to all surfaces in this worktree`

The chips become the visual handle for command targeting.

### Worktree Clipboard Handoff

The operator often needs to move snippets, failing commands, PR URLs, or test output between agents in sibling worktrees. A "copy to worktree" or "paste into all surfaces with this worktree chip" workflow would make the chip operational:

- Copy selected output from one surface.
- Command palette: `Paste into worktree...`
- Pick the chip/color/worktree name.
- c11 sends the text to the selected terminal surface or opens a scratch markdown surface in that worktree's group.

### Context-Aware Agent Launch

The agent launcher button could inherit spatial context:

- Launch agent in same cwd/worktree as the focused surface.
- Name the tab using `<task> :: <worktree> :: Codex`.
- Pre-fill metadata with `task`, `role`, and derived context.

This turns the sidebar chip from "where am I?" into "spawn more work here."

### Derived Environment Stack

Worktree/branch can be the first row in a future stack:

- `host: prod-shell` or `local`
- `container: api-dev`
- `runtime: node 22` / `swift 6`
- `service: websocket-daemon`
- `port: 5173`
- `package: c11`

This should not all render at once by default. But if the derived layer exists, c11 can choose the highest-signal facts per surface and expose the rest in titlebar expanded state, hover, or command palette filters.

### Worktree Health Beacons

Once branch/worktree is known, c11 can attach health signals by context:

- Dirty state.
- Tests running / last result.
- PR open / CI red.
- Lattice ticket state.

That creates a future "operator cockpit" path without making C11-104 itself too large.

## What It Unlocks

C11-104 unlocks three important things.

First, it reduces operator polling. The operator no longer has to ask "which pane is in which worktree?" That matters because every manual query breaks the parallel-agent rhythm.

Second, it creates a stable visual vocabulary for work context. The dot color and chip text let the operator build peripheral memory: "green dot is C11-104, blue dot is C11-103." That is valuable even before grouping exists.

Third, it creates a natural grouping key. Option E becomes much easier if C+D stores or exposes a normalized worktree identity:

- display label: basename
- color key: absolute worktree path
- group key: absolute worktree path or repo-root + worktree path
- command target: surfaces whose current context matches the group key

If C+D ships with those concepts only implicit inside view code, E gets harder. The future grouping implementation would have to find the resolver, duplicate the hashing, decide whether submodule rows group by outer or inner context, and reconcile display strings with target identities. If C+D ships a real group key, E is mostly layout and interaction design.

## Sequencing and Compounding

The right sequence is mostly the plan's current sequence, with one architectural addition up front.

1. Land a typed resolver result and cache model before rendering chips.
2. Project the resolver result into canonical metadata/chip rows.
3. Render C+D behind the settings toggle.
4. Add tests for resolver behavior, projection behavior, and precedence.
5. Document `derived` and the new keys.
6. After operator use, mine the chip interaction pain for Option E and command palette follow-ups.

The main compounding improvement is to make every phase produce reusable structure. Resolver tests should test the typed context, not just final labels. Projection tests should test chip rows from constructed context, not just flat metadata. Docs should describe the concept of c11-derived metadata as a future family, not just two new rows.

I would defer any attempt to generalize UI beyond git for this PR. Do not add host/container/language chips now. Instead, leave the extension point obvious in code and docs so the next derived context does not feel like a one-off.

## The Flywheel

The flywheel is:

1. c11 derives useful context without agent effort.
2. The operator sees the context in the sidebar.
3. The operator trusts c11 as the spatial map of the work.
4. Agents and commands can target that map.
5. More workflows move from "ask an agent / inspect a terminal" to "operate on visible context."
6. More derived signals become worth adding because they have somewhere coherent to render and something useful to drive.

The colored dot is not cosmetic in this loop. It teaches the operator to think of a worktree as a spatial object inside c11. Once that association exists, features like "jump to worktree," "group by worktree," and "send to all surfaces in this worktree" feel inevitable rather than bolted on.

To accelerate the flywheel, C11-104 should make the worktree identity internally targetable even if no target commands ship yet. That means stable IDs, not only labels.

## Concrete Suggestions

1. Add a named internal concept such as `SurfaceSpatialContext`, `DerivedSurfaceContext`, or `GitContextRows`. The exact type can be small, but it should be distinct from raw metadata writes.

2. Include a normalized identity triple for worktree context:
   - `label`: basename for display.
   - `path`: absolute worktree path for stable identity/color.
   - `groupKey`: future grouping/command target key.

3. Make the renderer consume chip rows, not two special flat strings. Submodule support already wants rows; model it directly.

4. Treat `derived` as c11-owned. If the socket accepts it, document whether external writers are allowed to use it. My preference is internal-only.

5. In `metadata.md`, add one paragraph explaining that `derived` is for c11-computed projections of runtime state. List worktree/branch as first examples and mention that future derived keys may describe host, container, runtime, service, or repo context.

6. Add a short "Future hooks" note to the PR or implementation docs:
   - Option E can group by `groupKey`.
   - command palette can filter by `groupKey`.
   - agent launcher can inherit the focused surface's context.

7. Keep the settings toggle rendering-only. Do not stop deriving context when chips are hidden unless there is a clear performance reason. Hidden context can still power command palette and future automation.

8. Add one test for same basename / different absolute paths at the context level, not only color projection. This protects the future grouping identity from collapsing to display text.

9. For main-checkout branch chips, consider whether the absence of color is enough. It is probably right for this PR, but future grouping may need a repo-level group color for main checkouts so "main c11" is still targetable.

10. Preserve the post-merge smoke tests, but add one operator observation prompt: "After 30 minutes of parallel work, did the chip answer the question you actually had?" That feedback is what should decide Option E's shape.

## Questions for the Plan Author

1. Should `derived` be a public metadata source that any socket client can write, or a c11-internal source only?

2. Is `worktree` intended to be only a display key, or should it become a stable command/grouping identity for future features?

3. For Option E, should submodule surfaces group under the superproject worktree, the submodule, or both?

4. Should the settings toggle hide only the sidebar chips, or disable derivation entirely?

5. Do future command-palette workflows need a hidden stable worktree ID now, before grouping exists?

6. Should branch dimming be hardcoded to `main/master/trunk`, or should this eventually follow repo default branch detection?

7. Does c11 want derived metadata to remain per-surface only, or is C11-104 the first reason to introduce workspace-level aggregate context?

8. Should same-basename worktrees deliberately look text-identical with only color distinguishing them, or should hover/titlebar expose the full absolute path?

9. What is the expected behavior when a terminal is ssh'd into a remote host and OSC 7 reports a local-looking path that c11 cannot inspect?

10. Is the long-term goal for chips to be purely informational, or should every chip eventually become a command target?
