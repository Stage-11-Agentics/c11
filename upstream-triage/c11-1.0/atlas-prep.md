# Atlas c11 1.0 fleet preparation

Checked October 1, 2026 PDT (October 2 UTC). Needs Atin: nothing. Fleet preparation is complete, including a successful unsigned, no-launch Debug build with Xcode 26.3. No macOS upgrade was performed.

| Tool | Before, observed live | After | Verified |
|---|---|---|---|
| macOS | 26.5.2 | 26.5.2, unchanged | Yes |
| Xcode | Missing; CommandLineTools selected | Xcode 26.6 (17F113) remains globally selected; Xcode 26.3 (17C529) installed alongside it for c11, both setup checks passed | Yes |
| mas / disk | mas 7.0.0 at `~/.local/bin/mas`; approximately 297 GiB available | App Store route superseded by Apple archive download | Yes, tool/disk only |
| Codex CLI | Homebrew cask 0.147.0 | 0.159.3; `gpt-6-astra` one-shot returned `ATLAS_CODEX_OK`, exit 0 | Yes |
| Codex login / defaults | Personal `~/.codex`; default `gpt-5.6-luna`, effort `max` | Personal ChatGPT login verified; defaults unchanged | Yes |
| Grok | Already 1.0.46 (2765805b9442); personal login absent | Same binary as Hyperion; Atin authorized personal device login; `grok-4.7` returned `ATLAS_GROK_OK`, exit 0 | Yes |
| c11 app | 0.64.0 (125) | Running 0.67.0 (131), updated and restarted manually by Atin | Yes |
| c11 checkout | Clean main at `609d40eb76f7252ec8a13a55d86aaa86063106ca` | Clean main at `0ff8887e5e965400b01645ef40b85fd0b2605cf2`, matching live origin/main | Yes |
| GhosttyKit | Artifact from older checkout | Checksum-verified pinned kit `26c3e499ed8c4d65e3748248de7fd04c1e9a8103`, provisioned and linked | Yes |
| c11 Debug build | Xcode unavailable | Xcode 26.3 + Zig 0.15.2 + Metal Toolchain 17C7003j: BUILD SUCCEEDED, exit 0 | Yes, build only |
| Liquid Voice | Absent on Atlas | 1.6.9 (20), copied from Hyperion, signature verified and running | Yes, install/launch |
| FluidVoice | 1.6.8 (19), not running | Moved out of Applications into Trash; settings/data preserved | Yes |

## Verification and boundaries

Codex retained its Homebrew installation method. A local `atlas/prep/codex` cask pins the requested official 0.159.3 artifact because the current upstream cask had advanced to 0.160.0. No formula dependencies were upgraded and no `brew cleanup` ran. Installation disabled automatic updates and install cleanup. A Homebrew metadata refresh had already run before Leak Hunt's warning arrived. Codex config SHA256 was unchanged: `b1c95ff40649da95d09aa7086322f6ea2bc557ddd9d1dfbddaa010473ccda939`. Its smoke call selected `gpt-6-astra` per invocation, with personal `CODEX_HOME="$HOME/.codex"`. Neither Overwatch seat login was used.

Grok's existing vendor-style binary matched Hyperion exactly, SHA256 `e8daa302364c9c3b6a5546d511cfbd1ab5e5d407a9b04282f660665ea405f9f3`. The device-code browser could run on any machine; it authorized the CLI waiting on Atlas.

[Apple lists Xcode 26.6 as compatible with macOS 26.2 through 26.x](https://developer.apple.com/xcode/system-requirements). Atin downloaded `Xcode_26.6_Apple_silicon.xip` (2,318,258,791 bytes) on Atlas; the archive's Apple signature verified. Atin completed installation and setup manually while the detached extraction job was active. `/Applications/Xcode.app` passed strict signature verification, `xcode-select -p` selects its Developer directory, and `xcodebuild -checkFirstLaunchStatus` exits 0. The earlier inference that Xcode's App Store download was paused was not conclusive; Atin subsequently identified the newest App Store Xcode's higher macOS requirement.

macOS upgrade was considered only if seamless remotely. Live Software Update offered 26.7.1 and 27.0.1. FileVault is off and automatic login is configured, but [the installed standalone Tailscale variant does not run before login](https://tailscale.com/docs/concepts/macos-variants). Remote return after a major upgrade was not established. Atin chose the compatible Xcode route instead; no OS update or reboot ran.

The agent staged and verified c11 0.67.0 before requesting restart approval. Atin subsequently installed/restarted it manually: the running process began at 22:30:41 EDT, both CLI and application report 0.67.0, and the live socket tree now has four terminals in one workspace. The agent did not close or restart c11. The historical restart warning covered all 26 then-open terminals. File-watching recovery after restart was not independently exercised.

## Debug build

The checkout and both submodules are clean. HEAD matched live origin/main immediately before the build. No C11-216 draft worktree was built or merged.

The build ran on Atlas through `scripts/with-build-lock.sh`, with eight jobs, isolated DerivedData and signing disabled. It compiled the Debug scheme without launching an app; it did not run tests or prove UI behavior. The current `reload.sh` has no `--no-launch` option, so the locked `xcodebuild build` invocation provides the requested no-launch behavior without using the draft worktree.

```bash
cd "$HOME/Projects/Stage11/code/c11"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
export DEVELOPER_DIR=/Applications/Xcode-26.3.app/Contents/Developer
scripts/with-build-lock.sh xcodebuild \
  -project GhosttyTabs.xcodeproj -scheme c11 -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/c11-atlas-prep" \
  -jobs 8 CODE_SIGNING_ALLOWED=NO build
```

Atlas logs: `~/Library/Logs/c11-atlas-prep/progress.log`, `xcodebuild.log`, and `build.exit` (0). The final build ran 23:04:08–23:05:30 EDT on October 1 (03:04:08–03:05:30 UTC October 2). The resulting `~/Library/Developer/Xcode/DerivedData/c11-atlas-prep/Build/Products/Debug/c11 DEV.app` is version 0.67.0 (131), with an arm64 Mach-O executable. The checkout remained clean after the build. The earlier Downloads staging directory was removed during Atin's manual cleanup.

## Additional authorized work

App Store was quit and relaunched at Atin's request. A subagent installed `/Applications/Liquid Voice.app` version 1.6.9 (20), bundle ID `com.stage11.liquidvoice`. Strict/deep signature verification passed; the executable matched Hyperion's SHA256 `2c7da7ccdb0b772e1be3710dcdc687a7ca27c0dfa63cc0aa846782ea2c2b9183`. Launch and a running process were verified. Actual speech transcription, microphone routing, model setup and privacy permissions remain unverified.

FluidVoice was moved to `~/.Trash/FluidVoice-removed-20261001-222301.app`. Its settings/data were preserved. No reboot was required.

Leak Hunt received the write windows: checkout/tool/app staging approximately 21:50–21:55 EDT; GhosttyKit completion around 21:58; voice installation 22:21:33–22:23:01; Xcode archive download 22:27–22:32:37, followed by extraction/manual setup; Debug build began 22:36:20. Additional churn: Xcode 26.3 archive complete by 22:58:28; extraction/install 22:58:53–23:00:06; Metal component installation completed before 23:04:08; final Debug build 23:04:08–23:05:30. Leak Hunt was sent these completion times. All were October 1 EDT. No agent action signaled fseventsd or touched Acetate keychains, launch agents, or `~/atlas-diag`. All downloads, installation and compilation ran on Atlas.


Build follow-up: attempt 1 reached packaging and failed because Zig was not on PATH. Added `~/.local/bin/zig` pointing to the existing `~/zig-0.15.2/zig` (version verified). Attempt 2 failed while Zig linked its own build runner: the newer SDK has arm64e-only libSystem stubs that Zig 0.15.2 cannot resolve. This matches [Ghostty upstream issue 11991](https://github.com/ghostty-org/ghostty/issues/11991). The current SDK and older installed macOS 15.4 SDK stub architecture lists were inspected. Simple SDKROOT and --sysroot overrides did not fix Zig's bootstrap. No repository changes or shared package upgrades were made. An independent read-only diagnosis confirmed that Zig bootstrap discovers its SDK through xcrun. Xcode 26.3 was installed alongside 26.6, with Apple archive and strict app signatures verified, and setup checks passed at 23:00:06 EDT. The build selects 26.3 using process-scoped DEVELOPER_DIR; global xcode-select remains unchanged. Retry began 23:00:35 EDT. The 26.3 retry passed Zig bootstrap, then exposed a missing Metal compiler component. Installed it using `DEVELOPER_DIR=/Applications/Xcode-26.3.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain`; `xcrun -sdk macosx metal --version` verified it. The subsequent build succeeded. Prior failures are preserved in attempt1-*, attempt2-* and attempt3-* logs.

## Toolchain follow-up

For C11-216, explicitly select the supported Xcode/Zig pair and fail early on incompatible SDKs. This report does not change that ticket's draft implementation. The durable upgrade is a coordinated Ghostty fork and Zig update, followed by regenerated GhosttyKit/checksums and build/runtime validation. [Ghostty upstream reports that the SDK compatibility fix is in Zig 0.16 and will not be backported to 0.15](https://github.com/ghostty-org/ghostty/issues/11991). Replacing the compiler alone is not validated against our pinned Ghostty source.
