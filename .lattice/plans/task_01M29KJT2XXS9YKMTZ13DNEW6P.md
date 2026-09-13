# C11-218 implementation plan

1. Add one executable `scripts/assert-ghosttykit.sh` shared by local build
   entry points. Derive the pinned SHA from the checked-out `ghostty` gitlink,
   treat a root symlink as valid only when it resolves to the matching
   SHA-keyed cache entry, and treat an in-place directory as an unknown/stale
   artifact unless it can be safely replaced. Matching kits must return before
   any network or filesystem repair work.
2. For a missing/stale kit with a checked-in checksum row, download through the
   existing checksum-verifying helper into the SHA-keyed cache and atomically
   replace the root artifact with a symlink. If the row is absent or repair
   cannot complete, stop with a concise one-line remedy before `xcodebuild`.
   Keep failed repairs from destroying an existing real directory.
3. Call the guard once immediately before the build invocation in
   `reload.sh` and `reloads.sh`, without touching their launch or environment
   scrubbing blocks. Add the same early guard to `reloadp.sh`,
   `test-unit-local.sh`, and `test-unit.sh`, the other documented local
   xcodebuild entry points.
4. Update the CLAUDE.md fresh-worktree recipe to link directly to the
   SHA-keyed cache path (and initialize the requested submodules as before).
   CI continues to provision its checked-out root directory via the existing
   download step; the guard is local-entry-point-only and will not alter CI's
   direct xcodebuild commands.
5. Add a behavioral shell test under `tests/` and wire it into
   `workflow-guard-tests`. Exercise refusal with a wrong cached SHA and a real
   directory, successful repair with a pinned fixture and stubbed download,
   and the matching no-network path. Validate shell syntax, run the guard
   suite, measure the matching-path cost, and record exact refusal/repair
   evidence in the final ticket comment.
