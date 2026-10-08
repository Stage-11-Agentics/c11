# Repair brief 1: C11-361 (PR #624, head 5de1c48772)

Review 1 (Claude Opus) is a FAIL. The full review is at `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review1-C11-361.md`. Grok's Review 2 is running on the same head; its blocking findings come as an addendum. **Start now; push once, after the addendum.** First rebase onto current `origin/main`: C11-359's follow-up `fd263426f9` landed after your base and touches the renderer and cache you call into.

## Blocking
- **B1 Unmounted and evicted panels.** `scroll`, `visible` and `visible --watch` must work against a markdown panel that has never been shown (an unselected workspace, a non-selected panel in its area) or that C11-359's cache evicted, without selecting a workspace or panel and without stealing focus. Also handle a mounted renderer that hasn't posted `ready` yet: bounded wait, not an immediate `not_ready`. Pick one design and say which in your plan:
  - (a) Create the reader on demand without showing it, laid out at the panel's last known area width. Pin it for the query through the cache's existing pinning, so memory stays bounded by the cache's cap. Wait off-main, bounded, for `ready` and the first `rendered`, then run the call; or
  - (b) Answer `visible` from the native reading position plus presentation (marked `mounted: false`), and queue a pending scroll target that applies on mount.

  My recommendation is (a): `scroll --heading` needs the renderer's heading matching, and (b) would duplicate it natively. The gold flash only needs to happen when the panel is shown; record that in the skill. Add a socket-level test against a panel with no reader, and the Atlas proof the review lists (never-shown panel in an unselected workspace, then again after eviction, with the workspace selection unchanged).
- **B2 `open-external` must not steal focus.** Use `NSWorkspace.shared.open(url, configuration:)` with `activates = false`, report success from its completion (off-main wait), and add one line to the skill saying it opens behind c11. Prove it: with c11 frontmost, c11 is still frontmost afterwards and the file opened.

## Repair in place (the rest of the review's list; same files, all related)
- **N1, N2** Add the tests the plan named, each red under the review's mutations (M3, M4, M5), and make `testFinishingWakesAnEventWaiter` actually prove the wakeup.
- **N3** A running `--watch` must not pin its reader forever (that defeats C11-359's eviction cap). Pin per query, not per stream; an evicted watched panel keeps streaming model state and resumes rendered state when re-created or shown.
- **N4–N6** A deadline for the watch's initial state, the fresh result preferred over cached state, and disconnect cancellation that waits for completion.
- **N7** The stream path calls `startupNotReadyResponse`, honours `shouldContinue()` (so a watch ends on Restart CLI Listener or stop), and checks auth before routing keys.
- **N8** Close the skill gaps the review lists.
- **N9** Reject a bare integer `--panel N` for these commands, with an error pointing to the `panel:N` form (the c11 convention), or support `--workspace` scoping. Rejecting is simpler. Reject non-decimal `--scale` too.

Then push once, refresh the validation comment (include each reviewer's "what repair must show" items), and send `HANDOFF C11-361 REVIEW <head> …`.
