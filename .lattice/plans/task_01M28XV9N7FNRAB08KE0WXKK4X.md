# C11-212 — ghostty_surface_free_text ABI mismatch (plan)

Author: Orchestrator (Fable 5.1), 2026-09-11. Status: authoritative for implementation.

## 1. Root cause (verified)

- `ghostty/include/ghostty.h:1136` declares `void ghostty_surface_free_text(ghostty_surface_t, ghostty_text_s*)`.
- `ghostty/src/apprt/embedded.zig:1725` (fork tip `7604624d8`, on `stage11/main`) exports `fn ghostty_surface_free_text(ptr: *Text) void { ptr.deinit(); }`.
- Every caller follows the header and passes `(surface, &text)`. On arm64 the callee reads x0 = the Surface pointer, so `Text.deinit` runs against the Surface reinterpreted as `Text` (freeing whatever sits at `Text.text` / `Text.text_len` offsets, benign only while that reads as null) and the real text buffer from `dumpTextLocked(global.alloc)` is never freed.
- Both `ghostty-org/ghostty` main and `manaflow-ai/ghostty` main already carry the fix: `export fn ghostty_surface_free_text(_: *Surface, ptr: *Text) void { ptr.deinit(); }`. The Stage-11 fork is based on the older `bc9be90a` tip and predates it. No upstream PR is needed; we are catching up.
- c11 call sites (`Sources/TerminalController.swift:3213`, `Sources/GhosttyTerminalView.swift:5000`, `:5241`) already pass `(surface, &text)` per the header. **No Swift change is required or wanted.**

## 2. Change set

### 2a. ghostty submodule (Stage-11-Agentics/ghostty)
1. Branch from `stage11/main` (`7604624d8`): `git -C ghostty checkout -b c11-212-free-text-abi stage11/main`.
2. Edit `src/apprt/embedded.zig`: change the export to exactly upstream's form, `export fn ghostty_surface_free_text(_: *Surface, ptr: *Text) void`, so future upstream merges drop cleanly.
3. Commit with a message that names C11-212 and cites the upstream commit form. Push the branch to `stage11`, then fast-forward `stage11/main` to it (`git push stage11 c11-212-free-text-abi:main`). **Submodule safety:** verify `git -C ghostty merge-base --is-ancestor HEAD stage11/main` succeeds BEFORE touching the parent pointer.
   - Expected observable: `grep -n "fn ghostty_surface_free_text" ghostty/src/apprt/embedded.zig` prints the two-parameter form; `git -C ghostty branch -r --contains HEAD` lists `stage11/main`.

### 2b. c11 parent repo (branch `c11-212-free-text-abi`, worktree `code/c11-worktrees/c11-212-free-text-abi`)
1. `git add ghostty` (pointer bump to the new fork SHA).
2. `docs/ghostty-fork.md`: add a numbered section for this change (commit, file, summary, conflict note: "identical to upstream; drops out on the next rebase onto a base that already has it").
3. Do **not** hand-edit `scripts/ghosttykit-checksums.txt`. The `build-ghosttykit` workflow builds the xcframework for the new SHA, publishes `xcframework-<sha>` as a prerelease, and pushes the checksum line to the PR branch.
4. Open the PR against `main`. Expected CI shape: run 1 shows `build`, `workflow-guard-tests`, `compat-tests` red (checksum missing) while `build-ghosttykit` runs ~10 min; the checksum commit triggers run 2, which must be fully green. Pull the checksum commit into the worktree before any further local work.

## 3. Tests

No meaningful unit test exists for a C-header-vs-Zig-export ABI mismatch (Zig `export fn` is never checked against `ghostty.h`, and c11's test policy forbids text-grep tests). Skip the fake regression test and say so in the PR. Validation (section 4) is the gate.

Bounded audit (report only, no fixes in this PR): compare every `ghostty_surface_*` / `ghostty_*` prototype parameter count in `include/ghostty.h` against the matching `export fn` in `src/apprt/embedded.zig` (a short script is fine). Report any other count mismatch in the completion comment; if one exists for a function c11 calls, file it as a new Lattice ticket rather than widening this PR.

## 4. Validation (required before `pr_open`)

Same procedure, before and after, on tagged builds from this worktree (`./scripts/reload.sh --tag c11-212`, launched via `scripts/launch-tagged-automation.sh c11-212 --qa fresh`; socket `/tmp/c11-debug-c11-212.sock`):

1. **Before:** build with the current (old) xcframework symlink. Launch with `MallocStackLogging=1`. Drive N (e.g. 50) `surface.read_text` / `c11 read-screen` calls against one surface with real scrollback. Measure heap growth attributable to `heap.CAllocator.alloc` under `readTerminalTextBase64` (`leaks`, `heap`, or `malloc_history` on the tagged pid). Record blocks and bytes per request. The ticket's baseline: ~4.9 blocks / ~100 KB per request.
2. **After:** once `xcframework-<newsha>` exists and the checksum commit is on the branch, remove the symlink (never write through it into the main checkout) and run `scripts/download-prebuilt-ghosttykit.sh` in the worktree. Rebuild the tagged app, repeat the identical procedure. Expected: per-request growth drops to ~0 blocks from that stack.
3. **Functional:** with the after build, confirm `c11 read-screen` returns the visible text, selection read (`ghostty_surface_read_selection` path: select text with the mouse or keyboard copy mode, then copy) returns the right text, and the app neither crashes nor logs a malloc error across ≥20 repetitions. This is the double-free guard for the now-correctly-typed `Text.deinit`.
4. Attach the numbers and the commands as a `--role validation` artifact on C11-212. Also attach a `--role review` verdict (own-review is acceptable for this diff size).

## 5. Out of scope
- Any Swift call-site change. Any other fork divergence. Rebasing the fork onto a newer upstream (separate ticket if wanted).

## 6. Merge and follow-through
- Delegator merges the PR once run 2 is green and both artifacts are attached (squash, delete branch). Verify `origin/main` carries the pointer bump and the checksum line. Post the completion comment; the Orchestrator then runs `git pull` + `git submodule update` in the main checkout and completes the ticket.
