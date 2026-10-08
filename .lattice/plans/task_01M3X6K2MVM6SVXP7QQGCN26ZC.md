# C11-305 plan

## Citations (base `0ff8887e`)

Match. B094: `_cmux_report_git_branch_for_path` at `Resources/shell-integration/cmux-zsh-integration.zsh:243-258` runs `git branch --show-current`, then `git -C … status --porcelain -uno`. The HEAD watch calls that reporter at `:509` when the HEAD signature changes. Precmd launches it again at `:660`, about every 3 seconds. Bash does not call the zsh function. It runs the same porcelain command inline in the one-shot prompt job at `cmux-bash-integration.bash:466-475`. Upstream #2797 (`e53b9794e993`) removed `git status` from automatic reporting. `reportGitBranch` (`Sources/TerminalController.swift:8365`) already treats a missing `--status` as not dirty. Git can refresh and lock the index. It does not lock on every call. The fix is to delete the porcelain call. Suppressing optional locks is not the fix.

B023: the zsh PR watcher `_cmux_start_pr_poll_loop` (`:447-472`) loops on `kill -0` of `$$` only, and precmd starts it disowned at `:690`. The zsh HEAD watch (`:500-512`) is `while true; sleep 1` with no parent check, disowned at `:512`, started from preexec `:540`, and stopped from precmd `:544` only while that shell is still alive. The bash PR poll (`:328-355`) is the same `kill -0` plus `disown`. Bash has no forever HEAD watch. Its git job is one shot. Upstream #11035 (`22eec580cb`) records the parent pid and `ps -o lstart=`. The `while true` at zsh `:158` is `_cmux_git_resolve_head_path` walking directories. Leave it.

`kill -0` on the helper pid (zsh `:458`, `:639`, `:681`; bash `:339`, `:454`, `:495`) is the shell checking its own child. Leave those.

## Git status

Delete the porcelain pipeline and the `--status=dirty` argument at both automatic sites. Keep `git branch --show-current`, and keep `clear_git_branch` when there is no branch. Do not change `reportGitBranch`. The next automatic report omits `--status`, and the existing parser stores that as not dirty, so the chip's dirty mark clears on the next branch report. No new socket flag. No other command starts asking for dirty state.

## Watchers

Add `_cmux_parent_shell_lstart` and `_cmux_parent_shell_alive` to both integration files. `lstart` is `ps -o lstart= -p <pid>` with leading and trailing whitespace stripped. Compare those strings. Do not parse the date. Call `ps` unqualified so a fixture function can replace it.

Capture `$$` and its lstart in the parent, before the fork. If that lstart is empty, do not start the forever loop. Precmd branch reports still run.

Leave the loop when `ps` prints nothing for that pid, or prints a different start time. A reused pid fails the compare. Empty output from a failed `ps` also ends the watcher, so a missing `ps` cannot leave an immortal loop. Check at least once a second. Keep the PR probe on `_CMUX_PR_POLL_INTERVAL` (45 seconds): sleep in 1-second slices and `break` out of both loops. Do not `exit` the parent shell. Keep zsh `&!` and bash `disown`, so the watcher is not a foreground job.

Use that check in the zsh PR watcher, the zsh HEAD watcher, and the bash PR watcher, including while a PR probe is blocked as specified below. Do not add a bash HEAD watcher. Do not add identity loops to the one-shot sends (pwd, ports, tty, or the git job).

## Acceptance → incident → test

1. While an agent runs `git commit`, the watcher does not fail that commit with `index.lock`. Incident: B094, porcelain in the reporter that the HEAD watch and the precmd job call. Fixture: `tests/test_shell_git_watchers.sh` sources each file under `zsh -f` and under `bash`. A tiny Python listener holds a unix socket. Functions replace `git` and `_cmux_send`, and `git` appends its argv. Neither log contains `status`. The send is `report_git_branch <name>` with no `--status=dirty`. Atlas, after C11-216: one repo, one `git commit` in a tagged c11 zsh tab, exit 0, and stderr has no `index.lock`.
2. After the shell exits, its watchers are gone within a couple of seconds, including when a new process reuses the pid. Incident: B023, `kill -0` on the pid only, and a HEAD watch with no parent check. Fixture: stub `ps`. The same pid with a new lstart, or empty output, ends each of the three loops within a couple of seconds. The same lstart keeps the loop alive across one stubbed probe. Atlas: in the tagged app, list processes before exit and about two seconds after. Those watcher pids are gone. The live listing shows exit. The stub shows pid reuse. A live pid-reuse race is not the proof.
3. The branch name in the UI still updates on checkout. Incident: the reporter has to keep `git branch --show-current`, and the HEAD watch still calls it when the HEAD file signature changes. Fixture: a signature change sends `report_git_branch` with the new name. `git branch --show-current` does not take `index.lock`. Atlas: check out another branch in the tagged tab and the sidebar branch chip follows.
4. A normal terminal outside c11 is unchanged. Incident: doctrine. These scripts are sourced in c11 terminals and are not installed into shell rc. The diff is the two bundled scripts plus the new test. No installer, and no write to `~/.zshrc`, `~/.bashrc`, or `~/.gitconfig`.

No soak. No source-grep test. Computer use is unnecessary. The socket result and the process list are the Atlas proof.

## Hot path, threading, persistence

The prompt path loses `git status` and keeps `git branch --show-current`. The HEAD watch adds one `ps` per second, and only while a foreground command is running. The PR watcher checks identity once a second instead of `kill -0` once per 45 seconds, and it still runs its probe on the old interval. No app change, no main-thread work, no new UI strings.

## Cut

Bash prompt rewriting (B098) and `$?` (B100). The stale branch chip after `cd` (B092). `gh` polling, `lsof`, fork-per-send, and git-in-non-repos (B125, B185, B150, B182, B181). Nested extra watchers (B155). The Claude wrapper (B064). Dirty state from any command other than this automatic reporter. A new long-lived process. Optional index locks.

## Dependencies

None inside ws:bugs. The tagged terminal waits on C11-216. The shell fixture does not.

## Decisions

None. Owner calls: skip the forever loop when `lstart` cannot be read; check identity every second and leave the PR probe at 45 seconds; prove pid reuse with the stub.

## Codex takeover correction (base 0ff8887e5e)

No build/test/product change performed. Citations match, including bash's porcelain call at line 470. `_cmux_run_pr_probe_with_timeout` is the missing in-flight case: zsh `:407-435`, bash `:288-316` wait on a child while the probe can run for `_CMUX_ASYNC_JOB_TIMEOUT=20` (zsh `:54`, bash `:51`). Checking parent identity only in the outer loop and the idle sleep cannot satisfy exit within a couple of seconds when the shell dies during that probe; timeout-disabled probes can wait indefinitely.

Pass the captured parent pid/start identity to the existing PR probe wait helper. During its existing one-second child-wait loop, compare that identity as well as the probe timeout. Parent death/reuse cancels the probe's own child tree through the existing bounded TERM/KILL cleanup and returns a distinct parent-gone result so the outer watcher exits instead of continuing through `|| true`. A still-live parent keeps today's probe timeout/output behavior. Do not alter one-shot git/pwd sends or generic shell job behavior.

Add executable shell fixtures for both shells: hold a fake probe open beyond the 20s normal timeout, change the parent start-time response or remove the parent, and require watcher plus attributable probe descendants to exit within three seconds (one polling tick plus existing cleanup margin). Cover `_CMUX_ASYNC_JOB_TIMEOUT=0` so parent death still terminates the wait. The idle-sleep and zsh HEAD fixtures remain. Fixtures invoke sourced bundled functions and assert executed commands/output/process lifetime, not source text. Use real-git branch reporting in a temporary repo for branch-checkout behavior, and retain the packaged tagged terminal commit/process/socket proof on Atlas.

The extra one-second `ps` polling is intentional but scales with every idle terminal's PR watcher. Register and compare its fork/process overhead with C11-270's baseline during the fleet soak, rather than adding a separate soak for this small ticket. Keep `gh` polling at its old 45s interval. No main-thread or typing-event mutation, tenant config, new process or new UI strings. Note the shared upstream origin of these shell fixes in the later PR for a possible cmux contribution; do not contact upstream from this seat.

## History lane execution update (base 9eb8fdc9172fc048180f6f89799af05a07afc92c)

Orchestrator reassigned C11-305 to agent:codex-history after C11-262 merged. Worktree remains the history lane; branch c11-1.0/C11-305-shell-helpers starts from fetched origin/main. All cited shell mechanisms still match. C11-216 is merged and Atlas builds are live. Use remote-build.sh; a queued build-slot wait is not a blocker.

Keep the captured pid/start-time comparison and distinct parent-gone result 2. For parent-gone cancellation specifically, call the existing recursive KILL cleanup (the same policy as preexec) so a TERM-ignoring descendant cannot be orphaned when the probe root dies before escalation. The ordinary probe-timeout path keeps its existing TERM/KILL behavior. Add the descendant fixture. The HEAD watcher checks identity after each one-second sleep, before reporting, with one ps per tick.

File ownership: bundled bash/zsh scripts; tests/test_shell_git_watchers.sh and its Python behavioral support; one CI step invoking that executable fixture. The fixture can also target the tagged bundle's Resources/shell-integration via C11_SHELL_INTEGRATION_ROOT. No native app source, installed skills, tenant configs or prompt rewrite changes.

Low-risk batch-validation flow applies: shell fixtures prove identity, cancellation, actual branch reporting and a real Git commit without a tagged UI launch before handoff. Record numbered Validator steps for the packaged tagged terminal: commit/checkout/sidebar branch output, live process disappearance on shell exit during idle and blocked probes, and unchanged outside-c11 shell behavior. Runtime process/socket proof is delegated to the batch Validator; do not revive the stopped Tart route. Package with an Atlas tagged build when a slot is available. No per-ticket soak; the typing/fleet soak remains C11-270.

## Reset 2026-10-02 by agent:codex-history
