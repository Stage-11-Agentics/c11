# Get Atlas ready to host the c11 1.0 build fleet

You are preparing Atlas, the always-on Mac Studio at `ssh atlas` (user `atinwoodard`; never hardcode a home path), to host the c11 1.0 build. Load the `c11` skill. Your c11 tab is "Atlas Fleet Prep". Keep its description current, ending with `Lineage: cmux Harvest Lead → Atlas Fleet Prep`.

## Context
- Read `~/.claude/CLAUDE.md`, "Machines" section.
- Read the comments on C11-216 (`cd ~/Projects/Stage11/code/c11 && lattice comments C11-216`). Atlas was half-prepared on 2026-09-11: repo, zig 0.15.2 at `~/zig-0.15.2`, prebuilt GhosttyKit. A draft `scripts/remote-build.sh` sits in the worktree `code/c11-worktrees/c11-216-remote-build`. Do not build or merge anything from that worktree; that is C11-216's job.
- **Another agent is active on Atlas:** "Atlas Leak Hunt" in workspace:1 (tab:130). It is tracing fseventsd file churn and just restarted fseventsd.
  - Do not restart services or kill processes it might be watching.
  - Do not touch the Acetate release keychain or launch agents.
  - If you need to coordinate, message it once with `c11 send`.
- Today's state, as checked on 2026-10-01:

  | Tool | Atlas | Target |
  |---|---|---|
  | Xcode | missing; `xcode-select` points at CommandLineTools | installed |
  | codex-cli | 0.147.0, defaults to `gpt-5.6-luna` at max effort | Hyperion's version, 0.159.3 |
  | grok | missing | installed |
  | c11 | 0.64.0 (125) | the current release |
  | claude | 2.1.284 | fine |

## Tasks
1. **Xcode 26.** It needs Atin's admin password, so you cannot finish this alone.
   - **Stage everything you can:** check whether `mas` is installed and signed in, and check disk space.
   - **Then raise a c11 flag** with the exact one-liner for Atin to run in an Atlas terminal:
     ```
     sudo mas install 497799835 && sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch
     ```
     Also give a fallback if `mas` is unavailable or not signed in.
   - **After he runs it, verify:** `xcodebuild -version`, and a `--no-launch` dry build of c11's Debug scheme through the build lock, if the repo checkout is current.
2. **Codex.**
   - Update codex-cli on Atlas to 0.159.3, using whatever install method it already uses (brew or npm; find out).
   - **Do not change the default model** in `~/.codex/config.toml`. The orchestrator passes `--model gpt-6-astra` per launch.
   - **Verify:** `codex --version`, and a one-shot non-interactive call with `-m gpt-6-astra` returns. Report which login it uses: Atin's own `~/.codex`, not the Overwatch seat login at `~/.config/stage11/codex-seat`.
3. **Grok.**
   - Install the Grok CLI on Atlas, the same build as Hyperion (`grok 1.0.46`). Find how Hyperion's was installed.
   - **Login needs one browser approval from Atin.** Start `grok login --device-auth` on Atlas, then raise a flag with the code and URL. Do not reuse the Overwatch seat login (`~/.config/stage11/grok-seat`).
   - **Verify** a one-shot call works with `grok-4.7`.
4. **c11.** Update the c11 app on Atlas to the current release.
   - **Warning:** restarting c11 on Atlas kills every agent running in it. Check `ssh atlas c11 tree --all` (or the Atlas socket) for live agent tabs first.
   - **Stage the update without relaunching:** download or verify it. Then ask Atin, with one flag that lists exactly which tabs would die, before quitting and relaunching.
5. **c11 checkout on Atlas.** `git fetch` and fast-forward Atlas's c11 checkout (`~/Projects/Stage11/code/c11`) to `origin/main`, only if it has no local changes. Report its state either way.

## Rules
- **No secrets** in output or in files.
- **No heavy work on Hyperion.** Everything runs over `ssh atlas`.
- **Interactive approvals only through Atin.** Never guess a password or approve a login yourself.
- **Every flag** carries one concrete action and the exact command or code.

## Report
Write `~/Projects/Stage11/code/c11/upstream-triage/c11-1.0/atlas-prep.md`: a table of tool, before, after and verified (yes or no), plus anything still waiting on Atin. Then set your description to `Done: <summary>` and stop.
