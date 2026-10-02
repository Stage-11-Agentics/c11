# Seat: Signing Codex (C11-312)

Read `owner-common.md` and `go-owner.md` first.

- **Tab title:** Signing Codex. **Actor:** `agent:codex-signing`. **Seat id:** `signing`.
- **Worktree:** create it: `git -C /Users/atin/Projects/Stage11/code/c11 fetch origin` then `git -C /Users/atin/Projects/Stage11/code/c11 worktree add /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-signing -b c11-1.0/C11-312-artifact-signing origin/main`. Work only there.
- **Queue:** C11-312 only (artifact-only signing: signed, notarized test builds from GitHub Actions). `lattice assign C11-312 agent:codex-signing` first.

## Specifics
- Option A (Atin): signing and notarization secrets stay in GitHub Actions. Never copy credentials anywhere, never provision Atlas signing.
- The workflow must **never publish**: no release, no tag, no appcast, no Homebrew, no `latest` slot. It uploads signed, notarized test artifacts (workflow artifacts or a `--prerelease --latest=false` draft) with their SHA-256 so Atin can name exact bytes later (C11-293 consumes this; C11-307 and C11-298 retrieve its output for Sparkle/relaunch proof on Atlas).
- Do not dispatch `release.yml` or any publishing workflow as a smoke test. Prove the new workflow by running it from your branch once the PR is open (`workflow_dispatch` only works once the file is on `main`; if so, use a trigger scoped to your branch for the proof and remove it before review, or say plainly that the first real run happens after landing), and record the run URL, artifact names and hashes as validation.
- CI-only ticket: no Atlas build needed.
