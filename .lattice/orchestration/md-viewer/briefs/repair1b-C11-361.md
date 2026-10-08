# Repair brief 1, addendum: C11-361 Review 2 (Grok), FAIL at 5de1c48772

The full review is at `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review2-C11-361.md`. This is the last addendum; fold it in, then push once.

## Blocking
- **B3, wrong target: an explicit panel ref that resolves to nothing runs on the focused panel.** `panel:99999` (or a stale ordinal kept across a restart) falls through `v2ResolveWorkspaceSurface`'s nil branch to the selected workspace's `focusedPanelId`. Then `theme --set`, `scroll` and `visible` act on the operator's document, and the theme, typeface or font change becomes the new-panel default. Fix: when the caller supplied `panel_id`/`surface_id` and it doesn't resolve, return `not_found` and never fall back to the focused panel. Use the existing `v2RejectUnresolvedTargetRefs` shape in every markdown handler, including `visible --watch`. Tests through the socket seam: an unresolvable `panel:N`, an unknown UUID, and a non-panel ref all return `not_found` and change nothing (assert the focused panel's theme and the last-used defaults are untouched). This overlaps Review 1's N9 (rejecting bare integers); do both.
- While you're in the resolver, check whether any other command in this PR's paths (`markdown open`, `markdown-content`) has the same fallback. Fix it in the markdown handlers only, and tell me in the handoff if the shared resolver has the same hole for non-markdown commands, so I can flag it as a separate follow-up (that's shared code from upstream).

## Repair in place
- **N10** `scroll --heading` should prefer an exact match, and when only prefix or substring matches exist and there's more than one, report the ambiguity instead of silently choosing the first (or document the order in the skill; your call, but say which).
- **N11** The skill names panel close as a way a `--watch` ends.

Then push once, refresh the validation comment (cover both reviewers' repair items), and send `HANDOFF C11-361 REVIEW <head> …`.
