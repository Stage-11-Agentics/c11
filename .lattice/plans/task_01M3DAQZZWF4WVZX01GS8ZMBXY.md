# C11-236: c11: launch-agent warns 'binary exec not found' for a command that starts with a shell builtin

launch-agent with a custom agent kind whose command begins with exec (a shell builtin) prints a false-positive warning that the binary 'exec' was not found; the command runs fine. Expected: builtins are not looked up on PATH. Found by the Overwatch seat launcher (2026-09-25).
