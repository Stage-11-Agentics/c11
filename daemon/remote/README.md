# c11d-remote (Go)

Go daemon that runs on the remote side of a `c11 ssh` workspace. Handles bootstrap onto the remote host, capability negotiation with the local app, and proxy RPC for browser/HTTP traffic. Sits well off the terminal keystroke hot path; latency-insensitive by design.

The binary ships pre-built for `darwin/{arm64,amd64}` and `linux/{arm64,amd64}` — no Go toolchain required on the remote host.

## Commands

1. `c11d-remote version`
2. `c11d-remote serve --stdio`
3. `c11d-remote cli <command> [args...]` — returns an unavailable message; remote commands are disabled in this version

When invoked as `c11` (via wrapper/symlink installed during bootstrap), the binary auto-dispatches to the `cli` subcommand. This is busybox-style argv[0] detection.

## RPC methods (newline-delimited JSON over stdio)

1. `hello`
2. `ping`
3. `proxy.open`
4. `proxy.close`
5. `proxy.write`
6. `proxy.stream.subscribe`
7. async `proxy.stream.data` / `proxy.stream.eof` / `proxy.stream.error` events
8. `session.open`
9. `session.close`
10. `session.attach`
11. `session.resize`
12. `session.detach`
13. `session.status`

Current integration in c11:
1. `workspace.remote.configure` now bootstraps this binary over SSH when missing.
2. Client sends `hello` before enabling remote proxy transport.
3. Local workspace proxy broker serves SOCKS5 + HTTP CONNECT and tunnels stream traffic through `proxy.*` RPC over `serve --stdio`, using daemon-pushed stream events instead of polling reads.
4. Daemon status/capabilities are exposed in `workspace.remote.status -> remote.daemon` (including `session.resize.min`).

`workspace.remote.configure` contract notes:
1. `port` / `local_proxy_port` accept integer values and numeric strings; explicit `null` clears each field.
2. Out-of-range values and invalid types return `invalid_params`.
3. `local_proxy_port` is an internal deterministic test hook used by bind-conflict regressions.
4. SSH option precedence checks are case-insensitive; user overrides for `StrictHostKeyChecking` and control-socket keys prevent default injection.

## Distribution

Release and nightly builds publish prebuilt `c11d-remote` binaries on GitHub Releases for:
1. `darwin/arm64`
2. `darwin/amd64`
3. `linux/arm64`
4. `linux/amd64`

The app embeds a compact manifest in `Info.plist` with:
1. exact release asset URLs
2. pinned SHA-256 digests
3. release tag and checksums asset URL

Release and nightly apps download and cache the matching binary locally, verify its SHA-256, then upload it to the remote host if needed. Dev builds can opt into a local `go build` fallback with `C11_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1` (or the legacy `CMUX_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1`).

To inspect what a given app build trusts, run:
1. `c11 remote-daemon-status`
2. `c11 remote-daemon-status --os linux --arch amd64`

The command prints the exact release asset URL, expected SHA-256, local cache status, and a copy-pasteable `gh attestation verify` command for the selected platform.

## Remote commands

As a hardening change, remote-to-local c11 commands are disabled in this version.
`c11 ssh` still opens a remote shell in a workspace, and the stdio daemon continues
to provide browser proxy and terminal session RPCs. No command relay listener,
reverse command tunnel, relay credentials, or socket address is provisioned.

The remote shell bootstrap supplies a refusing `c11` command and `cmux` alias.
The daemon's legacy `cli` entry point also refuses commands, including requests
with an explicit socket or old relay environment variables.

### Path compat

Remote-side runtime paths under `~/.cmux/` are retained unchanged from the `cmux`/`c11mux` era to preserve compatibility with any in-flight SSH bootstraps. Rename follows the hosted/remote bootstrap refactor.
