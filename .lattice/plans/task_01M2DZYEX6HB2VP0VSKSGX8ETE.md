# C11-225 plan

1. Cherry-pick upstream ghostty-org `14d9e600a` (renderer: skip updateFrame when surface is not visible) onto `Stage-11-Agentics/ghostty` main with `-x`; resolve the one context conflict in `src/renderer/Thread.zig` in favor of upstream. Done: fork main `26c3e499e`.
2. Bump the c11 submodule pointer, add fork-doc section 10 and the rebase note. Done: PR #444.
3. Let `build-ghosttykit` pin the checksum (run 1 red on the guard jobs, run 2 `action_required` → approve).
4. Validate on a tagged build: `/usr/bin/sample` c11 with a background workspace streaming; occluded renderer threads show no `updateFrame`/`rebuildRow`; switching to that workspace shows current content.
5. Merge; ship in the next patch release with C11-224.
