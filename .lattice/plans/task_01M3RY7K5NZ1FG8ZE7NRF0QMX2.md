# C11-246 plan

## Root cause (measured)

`ps -o pid=,ppid=,tty=,tpgid=,comm=,args=` on this Mac:

- `comm` prints argv[0] in a column capped at 16 characters (the `comm` keyword's max width, MAXCOMLEN). `/tmp/fb/claude` is 13 characters, so the basename survives and classifies as claude-code. A long absolute path is clipped to a prefix (`/private/tmp/cla`), and that prefix's basename is not the agent.
- `args` is the last column. Piped `ps` prints the full argv (it already read KERN_PROCARGS2). The classifier's argv0 rule would work if it saw that string.
- `parsePSLine` means to skip whitespace runs but walks one character at a time, so each padding space in the tty column counts as a column. A live line is `??` plus 10 spaces. The reconstructed args therefore starts at `tpgid` (`0 /clipped /full/path/claude`). The argv0 rule reads `0` and ignores the real path on purpose. Result: `unknown`.

`proc_pidpath` on the same pid returns the full executable path. It is a syscall, not a process spawn.

## Fix

- Advance `parsePSLine` past each whitespace run so args is the real argv line.
- For the foreground pid only, call `proc_pidpath` and classify on that basename as well as comm and argv0. No extra spawn; the one `ps` per sweep stays.
- Treat runtime (`node`/`bun`/`deno`/`python*`) and shell basenames from those same untruncated names, so a long interpreter path still sees the script.
- Do not prefix-match. A 21-character basename that merely starts with `claude-code` stays unknown. Symlink targets (`…/2.1.286`) do not override an argv0 basename of `claude`.

## Tests

In `c11Tests/AgentDetectorTests.swift`, through `ProcessFacts` / `parsePSLine` (no live process):

- Short path `/tmp/fb/claude` still classifies as claude-code.
- Long directory path (padded ps line, and facts whose args were sliced to `0`) classifies as claude-code.
- Basename longer than 16: the parser keeps the full component; a clipped comm is not prefix-matched to `claude-code`; a registered basename delivered only on the executable path still classifies.

## Validation

No local xcodebuild. CI `build` compiles and runs the tests.
