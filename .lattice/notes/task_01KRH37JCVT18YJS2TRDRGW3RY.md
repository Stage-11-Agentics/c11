# C11-37 — Slice 1: `c11-spawn-agent` server-side primitive

**Parent:** C11-36 (Autonomous Connections — remote agents over c11)
**Architecture doc:** `/Users/atin/Projects/Stage11/ideation/remote-agents-architecture.md`

## Goal

Ship `code/c11/Resources/bin/c11-spawn-agent` as a portable bash script that launches one autonomous Claude Code agent in a named tmux window on a dedicated `-L agents` socket. Runnable on any *nix box (macOS + Debian/Ubuntu) that already has `tmux` and an authenticated `claude` on `PATH`. The script does not touch credentials.

## Deliverables

1. `code/c11/Resources/bin/c11-spawn-agent` — the bash script (~50 lines).
2. Atlas validation: a haiku-writing agent runs, survives SSH detach, writes the expected file.
3. `CHANGELOG.md` entry in `code/c11/` noting the new `Resources/bin/c11-spawn-agent` script (Unreleased section).

## Script contract

```
c11-spawn-agent --workspace <name> --window <name>
                (--prompt-file <path> | --prompt <text>)
                [--cwd <path>]    # default: $HOME
                [--model <id>]    # passthrough to claude; default: claude-opus-4-7
                [--socket <name>] # tmux -L value; default: agents
                [--help]
```

### Behavior

- Required: `--workspace`, `--window`, and exactly one of `--prompt-file` / `--prompt`. Error if both or neither.
- Idempotency on the session: if `tmux -L <socket>` server isn't running, start it implicitly via the first new-session call; if the session exists, reuse it.
- The **window is required to be new** — if `tmux -L <socket> list-windows -t <workspace>` already contains a window named `<window>`, exit non-zero with a clear message. Do not clobber a running agent.
- `--cwd` is passed as the new window's start directory (`-c <cwd>` on `new-session` / `new-window`).
- Auth: take whatever `claude login` already wrote to disk on this box. The script never reads, writes, or env-injects credentials.
- Prompt delivery:
  - For `--prompt-file <p>`: send `cd <cwd> && claude --dangerously-skip-permissions --model <m> "Read <p> and follow the instructions."`
  - For `--prompt <text>`: write `<text>` to a temp file (`mktemp` in `/tmp`), then use the same form. Going through a file avoids shell-escaping pain inside `tmux send-keys` for any non-trivial prompt.
- Print the tmux target on success and exit 0:
  ```
  spawned: tmux -L agents <workspace>:<window>
  attach: ssh <this-host> -t "tmux -L agents attach -t <workspace> \; select-window -t <window>"
  ```
- Use `set -euo pipefail`; quote everything; pass `--` where needed.

## Tmux specifics

- Socket: `tmux -L "$SOCKET"` (default `agents`). Every tmux call uses it; no exceptions.
- Create-or-reuse session:
  ```bash
  if ! tmux -L "$SOCKET" has-session -t "$WORKSPACE" 2>/dev/null; then
    tmux -L "$SOCKET" new-session -d -s "$WORKSPACE" -n "$WINDOW" -c "$CWD"
    NEED_NEW_WINDOW=0
  else
    NEED_NEW_WINDOW=1
  fi
  ```
- Window-exists check (the duplicate-name guard — tmux allows duplicate names by default, so we do it ourselves):
  ```bash
  if tmux -L "$SOCKET" list-windows -t "$WORKSPACE" -F '#W' 2>/dev/null | grep -qx "$WINDOW"; then
    # window already exists in the session
    if [ "$NEED_NEW_WINDOW" -eq 0 ]; then
      # we just created the session with this window — fine
      :
    else
      echo "error: window '$WINDOW' already exists in session '$WORKSPACE' on socket '$SOCKET'" >&2
      exit 1
    fi
  fi
  ```
  Then create the window if needed:
  ```bash
  if [ "$NEED_NEW_WINDOW" -eq 1 ]; then
    tmux -L "$SOCKET" new-window -t "$WORKSPACE:" -n "$WINDOW" -c "$CWD"
  fi
  ```
- Send the claude command:
  ```bash
  CMD="cd $(printf '%q' "$CWD") && claude --dangerously-skip-permissions --model $(printf '%q' "$MODEL") $(printf '%q' "Read $PROMPT_FILE and follow the instructions.")"
  tmux -L "$SOCKET" send-keys -t "$WORKSPACE:$WINDOW" "$CMD" Enter
  ```
  Note: `printf '%q'` is the portable shell-quote. Works on macOS bash 3.2 and Linux bash 5+.

## Portability constraints

- Atlas runs macOS (bash 3.2 by default — yes, still). Hetzner runs Linux (bash 5+).
- Avoid bash 4+ features: no associative arrays, no `mapfile`, no `${var,,}` lowercasing, no `&>` redirection (use `>file 2>&1`).
- `printf '%q'` is available on both — preferred over manual escaping.
- `mktemp` flags differ; use the portable form `mktemp /tmp/c11-spawn-agent.XXXXXX`.

## Validation steps (Atlas)

Run these in order. The whole thing should take under 5 minutes.

1. **Preflight on Atlas** (SSH in once, manually):
   - `claude --version` → confirm installed and authenticated.
   - `echo hi | claude --dangerously-skip-permissions -p "say ok"` → no-op invocation, confirms auth works.
   - `tmux -V` → confirm tmux installed.
   - `mkdir -p ~/.local/bin && echo $PATH | tr : '\n' | grep -q "$HOME/.local/bin"` → confirm `~/.local/bin` is on PATH; if not, add it to `~/.zshrc` or `~/.bash_profile`.

2. **Deploy the script** (from local):
   - `scp code/c11/Resources/bin/c11-spawn-agent atlas:~/.local/bin/c11-spawn-agent`
   - `ssh atlas chmod +x ~/.local/bin/c11-spawn-agent`

3. **Spawn the haiku agent**:
   ```bash
   ssh atlas 'c11-spawn-agent \
     --workspace test \
     --window haiku \
     --cwd /tmp \
     --prompt "Write a 3-line haiku about the spike. Save it to /tmp/haiku.txt with no other content. Then exit."'
   ```
   Expect output containing `spawned: tmux -L agents test:haiku`.

4. **Verify the agent is running**:
   - `ssh atlas 'tmux -L agents ls'` → shows `test:` session.
   - `ssh atlas 'tmux -L agents list-windows -t test -F "#I #W"'` → shows `... haiku`.

5. **Disconnect + reconnect to confirm survival**:
   - Close the SSH session entirely. Wait ~30 seconds.
   - `ssh atlas 'tmux -L agents list-windows -t test -F "#I #W"'` → still shows `haiku`.

6. **Wait for the agent to finish, verify output**:
   - `ssh atlas 'cat /tmp/haiku.txt'` → should print a haiku.
   - If still running: `ssh atlas -t "tmux -L agents attach -t test \; select-window -t haiku"` to watch live.

7. **Negative test — duplicate-window guard**:
   - Re-run the same `c11-spawn-agent` invocation → expect non-zero exit with the duplicate-window message.

8. **Cleanup**:
   - `ssh atlas 'tmux -L agents kill-session -t test'`
   - `ssh atlas 'rm -f /tmp/haiku.txt'`

## Acceptance criteria

- [ ] Script exists at `code/c11/Resources/bin/c11-spawn-agent`, executable, with `--help` text.
- [ ] All required flags validated; clear error messages on misuse.
- [ ] Uses `-L agents` socket exclusively (configurable but defaulted).
- [ ] Duplicate-window guard works (negative test passes).
- [ ] Atlas validation steps 1–8 all pass.
- [ ] Agent survives SSH detach (step 5 passes).
- [ ] No credentials handled in the script — auth is entirely `claude login` on the box.
- [ ] CHANGELOG entry added under Unreleased.

## Explicitly out of scope (deferred to later slices or never)

- Crash/restart logic. Window dies → it dies; we observe and decide later.
- Reboot persistence (tmux-resurrect, systemd, launchd).
- Logging/transcript capture beyond what tmux scrollback gives us.
- Status reporting back into Lattice.
- The local-side `c11 remote spawn` wrapping — that's slice 3 (C11-39).
- Hetzner — that's slice 2 (C11-38). Slice 1 is Atlas-only.
- Bootstrap automation — manual scp is fine for slice 1.

## When done

- `lattice status C11-37 review --actor agent:claude-opus-4`
- `lattice complete C11-37 --review "<one-paragraph summary of what shipped and what was verified>" --actor agent:claude-opus-4`
- Then unblock slice 2 (C11-38).
