# Spike: the c11 CLI on Linux (C11H-191)

Run Thu 2026-11-05, 16:52 to 17:16 Pacific, on the Linux host in build box `c11-191-cli` (vela-box, Debian 12, 16 CPU,
32 GiB, 60 GiB; kept). Branch `c11/C11H-191-linux-cli` from origin/main `f90125a0`.

## Result

**The whole CLI builds for Linux as one static binary, and its relay path works there.** The full `c11-cli` target
(123 files, 56.7k lines: 63 in `CLI/`, 60 shared from `Sources/`) compiles for `x86_64-swift-linux-musl` with no
errors. It took about 25 minutes of edits: 125 added lines in 14 shared files, all macOS behaviour unchanged, plus a
Linux-only package in `tools/linux-cli/`. There is no second implementation.

| Build | Time | Binary |
|---|---|---|
| static musl, debug | 66 s | 185.6 MB with symbols |
| static musl, release (whole module) | 276 s | 184.1 MB, then `strip --strip-all`: **68.0 MB** |

The release binary is in the box at `/root/out/c11`: `ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically
linked, stripped`, sha256 `90094be61889d32c5e7232bd26b6121b8bb15171acf3ff505d220951776b23f2`. It is built from this
branch's two commits, before `build.sh` learned to strip and report sizes by `stat`; rebuild for a clean artifact.

**Relay mode, offline** (`relay-offline-test.py`, against a private hc 0.1.16 core in the box, no c11 app on the
other end), all PASS with the release binary:

| Check | Result |
|---|---|
| `c11 relay-pickup` | reads the pickup document, deletes it by compare-and-set, prints the exact `export C11_RELAY_AUTH='2:<link>:<creation>:<key>'` (18 ms) |
| `rename-panel`, `set-description`, `raise-flag`, `mailbox send`, `mailbox recv --ack` | each writes a signed request into a relay slot, waits the documented 10 s reconnect tolerance, cancels by compare-and-set, exits 1 with `relay_unreachable ... nothing ran` |
| slots afterwards | all 32 free |
| `set-status` | spooled: one new record in `c11h.relay.spool`, protocol 2 |

What this does not prove: a round trip. That needs c11 on the Mac claiming the slot, verifying the HMAC and replying
(the ticket's end-to-end proof, with the relay kit installed on the Linux host). HMAC parity is by construction (CryptoKit on
macOS, swift-crypto's identical API on Linux, same `C11RelayAuth` source), but no cross-platform vector test exists
yet; a logic test that pins one request's MAC would close that.

## Toolchain (in the box)

- Swift **6.3.3** (`swift-6.3.3-RELEASE`, Debian 12 tarball, signature good; same compiler as the build host's Xcode 26.6,
  Apple Swift 6.3.3). 991 MB in `/opt/swift`, 33 s. Needs `libncurses6` beyond swift.org's package list.
- Static Linux SDK **0.1.0** for 6.3.3 (`swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz`, checksum
  `87c3eaf9...b607b`), 152 MB, 15 s.
- swift-crypto 3.x/4.x (resolved by SwiftPM); SQLite **3.54.1** amalgamation, pinned by SQLite's SHA3-256.
- Box create 1.7 s; apt 8 s; `vela-box sync` of the worktree 16 s.

## The build

```bash
tools/linux-cli/build.sh --static            # release; --debug for a debug build; output tools/linux-cli/.stage/out/c11
tools/linux-cli/relay-offline-test.py <c11> <socket>   # with a private hc core: see the script's header
```

`build.sh` stages the files in `sources.txt` (generated from the Xcode target by `gen-sources.py`, so the list cannot
drift silently) into `.stage/Sources/c11`, with three rewrites in the staged copy only: `import Darwin` becomes the
C library (`Musl`, or `Glibc` for a dynamic build), `import CryptoKit` becomes `Crypto` (swift-crypto), and a
module-qualified `Darwin.x` becomes `Musl.x`. It adds `LinuxSupport/LinuxSupport.swift` and builds with SwiftPM.

Why rewrite instead of a shim module named `Darwin`: a module of that name leaks into dependencies. swift-crypto's
`#if canImport(Darwin)` turned true and it reached for `memset_s` (50 errors). Shim modules are used only where no
dependency checks the name: `OSLog` and `os` (a silent `Logger` with the `privacy:` interpolation), and `SQLite3`.

## Errors, before and after

| Stage | Distinct errors | What |
|---|---|---|
| First build (glibc) | 1 module | `no such module 'OSLog'` (`HCBuildVerifier`), then `Security` (`HCLaunchPolicy`, `C11RelayAuth`): the only unconditional Apple imports besides Darwin, CryptoKit, SQLite3 |
| After the import shims and rewrites | 499 in ~57 files | 286 `String(localized:defaultValue:)` (absent from Foundation on Linux), 59 `Darwin.` qualifiers, 13 `autoreleasepool`, the rest platform APIs |
| After `LinuxSupport.swift` | 142 in 18 files | process inspection, peer credentials, ACLs, Keychain, kqueue, `SO_NOSIGPIPE`, `sun_len`, CF type checks, glibc's enum-typed `SOCK_STREAM` |
| After the edits below, static musl | **0** | |

## What is behind `#if` (shared files; each macOS branch is the original text)

| File | Linux |
|---|---|
| `ClaudeMailboxCommand.swift` | process birth from `/proc/<pid>/stat` (zombie = gone); no `SO_NOSIGPIPE`, no `sun_len` |
| `CMUXCLI+Mailbox.swift` | own process age from `/proc` |
| `HCBuildVerifier.swift` | executable path from `/proc/<pid>/exe`; process identity (uid, start) from `/proc` |
| `HCCoreUtilityHost.swift` | peer pid and uid by `SO_PEERCRED`; host name by `gethostname`; process facts from `/proc`; no tty clock |
| `HCLaunchPolicy.swift` | `import Security` conditional; code signing never satisfies (fails closed), no team |
| `C11RelayAuth.swift` | `import Security` conditional; random bytes from `SystemRandomNumberGenerator` (getrandom) |
| `C11RelayHCStore.swift` | no `SO_NOSIGPIPE` (the CLI ignores SIGPIPE at start) |
| `CLISocketClient.swift` | the two kqueue waits poll every 50 ms |
| `CLISocketConfig.swift` | no Keychain: no stored socket password |
| `PrivateFileWriter.swift` | plain `O_EXCL` 0600 files, no extended ACLs to strip or refuse |
| `HealthCommandCore.swift` | boot time from `/proc/stat` |
| `CMUXCLI+App.swift` | Bool inside `NSNumber` by `objCType` |
| `CMUXCLI+ThemeFiles.swift` | no distributed notification (reload not requested) |
| `c11.swift` | no Objective-C exception handler |

Three lines change on the macOS path, by type name only: `Int32(...)` and `__darwin_suseconds_t(...)` become
`suseconds_t(...)`, which is `Int32` on macOS.

`LinuxSupport/LinuxSupport.swift` (Linux-only, never in the Xcode project): `String(localized:defaultValue:)` returning
the English default, `autoreleasepool`, `stat.st_mtimespec`/`st_ctimespec`, `MAXPATHLEN`, `_NSGetExecutablePath`
from `/proc/self/exe`, `NSString.abbreviatingWithTildeInPath`, and `LinuxProc` (the `/proc`, `SO_PEERCRED` and
`gethostname` readers above).

## What remains

1. **Not compiled on macOS by me** (no xcodebuild here). The diff is additive `#if` plus three same-type renames, but an
   the build host `remote-build.sh` and `c11LogicTests` run must gate it.
2. **A glibc (dynamic) build** still fails on glibc's enum-typed `SOCK_STREAM` (5 sites) and one `Int`/`Int32` mismatch. Static musl is the target,
   so I stopped there; a cast at those sites would fix it.
3. **The version**: `c11 --version` reads `Info.plist` beside the binary; a lone binary says `c11 version unknown`
   (the debug run, inside the source tree, found `c11 1.8.1 (150)`). The relay kit's app-shaped layout
   (`c11-relay.app/Contents/{Info.plist,Resources/bin/c11}`) supplies it, as on the build host.
4. **Not exercised on Linux**: `claude-hook` (the Claude wrapper's turn edges and Stop drain), `guide` (no bundled
   skill in a lone binary), and the non-relay local commands, which on Linux have no local c11 app to talk to.
5. **Reproducibility**: one release build only; build twice and compare hashes before shipping.
6. **Shipping**: 68 MB stripped. The C11H-76 plan's question 4 (inside c11.app or a separate tarball) applies.
7. `relay-offline-test.py` is a manual check (it needs a running hc core); it is not a merge-gate test.

## Recommendation

**Take the full port.** One contract, by construction: the Linux `c11` is the same 123 files. The port cost about 25
minutes, and the relay verbs C11H-191 needs already work offline. Fold this branch into C11H-191:

1. Gate the 14 shared-file edits with a build-host build and `c11LogicTests`.
2. Ship the binary in a relay kit on the Linux host (`c11-atlas-relay.sh install` learning Linux and bash).
3. Prove the round trip from a real c11 panel: rename, flag, mail both ways.
