# C11-37 Atlas validation runbook

How to validate `Resources/bin/c11-spawn-agent` on **Atlas** once back on the home network. This is the procedure that was originally specced in `.lattice/notes/task_01KRH37JCVT18YJS2TRDRGW3RY.md`; the script was merged to `main` (PR #151, squash `37786e689`) on 2026-05-13 after passing 8/8 steps on `yew` with a `claude` stub. Atlas remains the canonical end-to-end validation host because it's the only one with an authenticated `claude` installed and is the Mac Studio that will host the production agent fleet.

## What this validates

The script's contract: spawn one Claude Code agent in a named tmux window on the dedicated `tmux -L agents` socket, survive SSH detach, refuse to clobber a live window. The **load-bearing** step is **Step 5** (window survives 30s SSH detach + reconnect) — that's the property that makes the agent "autonomous" in the Autonomous Connections sense.

## Prerequisites (one-time per Atlas)

Atlas needs:
- `tmux` installed (`brew install tmux` if missing)
- `claude` on PATH and **already authenticated** via `claude login` (interactive — requires a browser)
- `~/.local/bin` on PATH (or another writable PATH directory you prefer)

You're running these commands from **Hyperion** (or any operator machine that can reach Atlas via SSH / Tailscale SSH).

## Step 1 — preflight on Atlas

```bash
ssh atlas '
claude --version
echo hi | claude --dangerously-skip-permissions -p "say ok"
tmux -V
mkdir -p ~/.local/bin
echo "$PATH" | tr : "\n" | grep -q "$HOME/.local/bin" && echo "PATH OK" || echo "PATH needs ~/.local/bin"
'
```

Expect: a claude version line, `ok` (or similar) from claude, a `tmux 3.x` line, and `PATH OK`. If PATH is missing `~/.local/bin`, add it to `~/.zshrc` (`export PATH="$HOME/.local/bin:$PATH"`) and reload.

If `claude --version` fails or the `-p "say ok"` test errors with an auth message, run `ssh -t atlas claude login` and complete the browser flow before continuing.

## Step 2 — deploy the script

From the c11 repo root on Hyperion:

```bash
scp Resources/bin/c11-spawn-agent atlas:~/.local/bin/c11-spawn-agent
ssh atlas 'chmod +x ~/.local/bin/c11-spawn-agent && c11-spawn-agent --help | head -3'
```

Expect: the `Usage:` line plus the first two flags from the help text.

## Step 3 — spawn the haiku agent

```bash
ssh atlas 'c11-spawn-agent \
  --workspace test \
  --window haiku \
  --cwd /tmp \
  --prompt "Write a 3-line haiku about the spike. Save it to /tmp/haiku.txt with no other content. Then exit."'
```

Expect output containing:

```
spawned: tmux -L agents test:haiku
attach: ssh atlas -t "tmux -L agents attach -t test \; select-window -t haiku"
```

## Step 4 — verify session + window exist

```bash
ssh atlas 'tmux -L agents ls'
ssh atlas 'tmux -L agents list-windows -t test -F "#I #W"'
ssh atlas 'tmux -L agents capture-pane -t test:haiku -p | head -20'
```

Expect:
- `test: 1 windows (created ...)`
- `0 haiku`
- The captured pane content showing `cd /tmp && claude --dangerously-skip-permissions --model claude-opus-4-7 Read\ /tmp/c11-spawn-agent.XXXXXX\ and\ follow\ the\ instructions.` typed in, and the Claude Code UI rendering the prompt.

## Step 5 — SSH-detach survival (LOAD-BEARING)

```bash
# Make sure no SSH connections to Atlas are open (close any tmux attach sessions, ssh -t, etc.)
# Then:
sleep 30
ssh atlas 'tmux -L agents list-windows -t test -F "#I #W"; tmux -L agents list-panes -t test:haiku -F "pid=#{pane_pid} cmd=#{pane_current_command}"'
```

Expect the window `0 haiku` still listed and `pid=N cmd=claude` (or whatever sub-process claude is running). **This is the load-bearing assertion: the tmux server outlives the SSH socket, so the agent keeps working when you disconnect.** If the window is gone after a 30s no-connection window, the script's contract is violated.

## Step 6 — wait for completion, verify output

Claude may take 30s–2m to write the haiku and exit, depending on Atlas load.

```bash
# Optional — attach to watch live (Ctrl-b d to detach without killing):
ssh atlas -t "tmux -L agents attach -t test \; select-window -t haiku"

# Or just check the file:
ssh atlas 'cat /tmp/haiku.txt'
```

Expect 3 lines of haiku in `/tmp/haiku.txt` and nothing else.

## Step 7 — negative test (duplicate-window guard)

```bash
ssh atlas 'c11-spawn-agent \
  --workspace test \
  --window haiku \
  --cwd /tmp \
  --prompt "should be rejected"; echo "exit=$?"'
```

Expect:

```
c11-spawn-agent: error: window 'haiku' already exists in session 'test' on socket 'agents' (refusing to clobber)
exit=1
```

If this succeeds (exit 0) and silently clobbers the running agent, the guard is broken — file a bug immediately. The guard is what keeps `c11 remote spawn` (slice 3) safe to re-run idempotently.

Sanity check: a *different* window in the same session should still work:

```bash
ssh atlas 'c11-spawn-agent --workspace test --window scout --cwd /tmp --prompt "second window test"'
ssh atlas 'tmux -L agents list-windows -t test -F "#I #W"'
```

Expect both `0 haiku` and `1 scout`.

## Step 8 — cleanup

```bash
ssh atlas '
tmux -L agents kill-session -t test 2>/dev/null || true
tmux -L agents kill-server 2>/dev/null || true
rm -f /tmp/haiku.txt /tmp/c11-spawn-agent.*
'
```

Verify nothing residual:

```bash
ssh atlas 'find /tmp -maxdepth 1 -name "c11-spawn-agent*" -o -name "haiku.txt" 2>/dev/null; tmux -L agents ls 2>&1'
```

Expect empty find output and `no server running on /private/tmp/.../agents` (or similar).

## After validation passes

1. Flip C11-37 to `done`:
   ```bash
   lattice complete C11-37 --review "Atlas validation 8/8 PASS — spawn + detach survival + duplicate guard all verified on Atlas with real authenticated claude. Slice 1 (server-side primitive) shipped." --actor agent:claude-opus-4
   ```
2. Unblock slice 2 (C11-38 — Hetzner provisioning + manual SSH viewer).

## If something fails

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| `claude: command not found` | not installed or not on PATH on Atlas | install + `claude login`, then redo Step 1 |
| auth error from claude during Step 3 | `claude login` was never run, or session expired | `ssh -t atlas claude login` (browser flow), redo |
| Step 5 window disappears after 30s detach | the agent process crashed OR tmux server got killed | check `tmux -L agents ls` immediately after Step 4; if window was alive at Step 4 and gone at Step 5, capture-pane the death message and file a bug — this would invalidate slice 1's contract |
| Step 7 guard does NOT fire | re-running clobbered the live window | confirm with `tmux -L agents list-windows -t test` before/after; this is a regression — file a bug |
| `scp` fails with permission denied | `~/.local/bin` doesn't exist or isn't yours | `ssh atlas mkdir -p ~/.local/bin` then retry |

## Why this lived as a separate file

The plan note at `.lattice/notes/task_01KRH37JCVT18YJS2TRDRGW3RY.md` carries the design context, contract, portability constraints, and original 8-step plan. This file is the **operator-facing runbook** — distilled, copy-pasteable, with no design narrative. When validating on Atlas, follow this file; reach for the plan note only if something surprises you and you need design intent.

## Reference

- Script: `Resources/bin/c11-spawn-agent`
- Merge: PR #151 → `37786e689`
- Ticket: C11-37 (`task_01KRH37JCVT18YJS2TRDRGW3RY`), currently in `review`
- Parent: C11-36 — Autonomous Connections
- Architecture doc: `/Users/atin/Projects/Stage11/ideation/remote-agents-architecture.md`
- Yew substitute validation (mechanism-only, on Linux with `claude` stub): see C11-37 lattice comment dated 2026-05-13T20:29:01Z
