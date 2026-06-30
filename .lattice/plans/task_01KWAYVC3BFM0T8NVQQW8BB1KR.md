# Plan — bind-time socket stomp fix

Full design: `docs/socket-collision-fix-design.md`.

1. **B (load-bearing):** liveness-probe before unlink in `TerminalController.bindListenerSocket`; add `.peerAlive` result; `start()` falls back to a safe path. Add `socketHasLiveListener(path:)` static helper.
2. **C:** in `SocketControlSettings.shouldHonorSocketPathOverride` / `socketPath`, reject an ambient `CMUX_SOCKET_PATH` equal to another bundle's stable default unless `CMUX_ALLOW_SOCKET_OVERRIDE`.
3. **A:** namespace prod stable socket per `CFBundleIdentifier` in `stableSocketDirectoryURL()` (app + CLI). `/tmp` tagged schemes untouched.
4. Inject the **bound** path + `C11_SOCKET_PATH` into child PTY env.
5. Logic-target regression tests; keep existing socket tests green. Build via `reload.sh --tag`. Hand restart to operator.
