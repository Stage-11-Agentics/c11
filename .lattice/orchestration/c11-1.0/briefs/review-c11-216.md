# Review: C11-216 (Atlas tagged, test and release builds), cycle 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-216**. PR https://github.com/Stage-11-Agentics/c11/pull/498, branch `c11-1.0/C11-216-atlas-builds`. **Head: the SHA in your launch prompt.** Base: origin/main at review time (`git merge-base origin/main <head>`).
- Title `C11-216 Review Astra`. Actor `agent:astra-review-216`. Owner was Codex Sol.
- Plan: `.lattice/plans/task_01M29FFY3V06CKD2EPVKYC0J6V.md` (Architecture, Acceptance 1-4, the build admission amendment for two Atlas slots). Validation evidence: Lattice comments with role validation on C11-216.

## Focus (this ticket gates every build in the run)
1. **Identity:** the transfer is a real git bundle plus pinned submodule SHAs, never a rsynced `.git` gitdir pointer; dirty overlays are content-hashed per path (bytes, mode, symlink target, tombstones) and verified remotely before any `xcodebuild`. Two different edits of the same path must not share an identity.
2. **Failure never launches or replaces a stale app:** SSH exit status survives `| tee` (PIPESTATUS), missing `C11_REMOTE_OK` or an invocation-id mismatch exits nonzero, the previous local app stays byte-identical. `reload.sh`'s masked pipeline status is fixed.
3. **Locks:** Atlas two-slot admission (flock, load gate >40 → one slot), same-tag serialization, nested `with-build-lock.sh` reuse only for an ancestor owner inside an admitted slot. **Default Hyperion behavior of `with-build-lock.sh` is unchanged** (one machine lock, takeover, exit 75); confirm by reading, and that no path lets a Hyperion caller skip the lock.
4. **Toolchain pin:** Xcode 26.3 via `DEVELOPER_DIR` and Zig 0.15.2, verified by version output, exit 3 otherwise; no `xcode-select`, no global change.
5. **`--no-launch`:** no socket-path writes, no killing socket holders, no `~/.local/bin` rewrites, no `open`/`pkill`/`osascript` on the build machine. Client-side plist rewrite (home prefix, repo root) and re-sign are correct for an Atlas-built app.
6. **Tests:** behavioral (fake ssh/rsync/codesign, real lock script, synthetic repos), not source grep. Runtime proofs in validation match Acceptance 1-4 (Hyperion `pgrep xcodebuild` empty, Atlas log shows lock + 26.3 + 0.15.2, identities match, two overlapping tags, forced failure, selected test with separate compile/test fields, Release compile, QA launch on Atlas).
7. Skill/doc text (`skills/c11-hotload/SKILL.md`, `CLAUDE.md` one-liner) teaches the remote route accurately and timelessly.

Blocking only for concrete failures (input/state → wrong result) against the acceptance criteria or the incidents named in the plan. Do not demand new mechanism.
