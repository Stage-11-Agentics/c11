# C11-307 plan

Verified on `0ff8887e5e`. B200. The pin is real. The idle-before-updateAvailable stop is not.

## Pin

`GhosttyTabs.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved:32-38` is Sparkle `2.8.1`, revision `5581748cef2bae787496fe6d61139aebe0a451f6`. The Xcode requirement is `upToNextMajorVersion` from `2.5.1` (`project.pbxproj:2691-2694`). There is no app `Package.swift`.

Upstream cmux `96221935ca6f` (#6678) raises that floor to `2.9.0` and resolves `2.9.3`. The commit message is the macOS 26 helper rejection ("connection was never initiated"). Sparkle's own 2.9.3 notes are a bundle-id fix, not that sentence. Cite both in the PR. Do not copy a workflow that uses `GHOSTTY_RELEASE_TOKEN`.

Change the pbxproj minimum to `2.9.3`. On remote builder, resolve so `Package.resolved` records 2.9.3. Do not hand-write the revision. If 2.9.3 does not compile against this tree, take the newest 2.x that does. c11's deployment target is macOS 14.0, so Sparkle 2.10 (requires macOS 12) is a legal fallback. Do not start there. Do not silence a compile error by catching Sparkle 4005.

`scripts/sparkle_generate_appcast.sh:18` defaults `SPARKLE_VERSION` to `2.8.1`. Change that default to the pin. Sparkle 2.9 stopped shipping `sparkle-cli` in the binary zip. The script already clones the tag and builds the `generate_appcast` scheme, then falls back to `sign_update`. If the scheme is gone, use that fallback. Do not change the committed feed URL.

## The second path is not there

`attemptUpdate` (`Sources/Update/UpdateController.swift:187-210`) stops only when progress was seen and the state is not installable. `.checking` is installable (`UpdateViewModel.swift:438-444`), and `.updateAvailable` confirms. `dismissUpdateInstallation` ignores `.checking` (`UpdateDriver.swift:163-165`). A normal check stays `.checking` until `setStateAfterMinimumCheckDelay` applies the result. Do not edit `attemptUpdate`.

The cousin is B104: the delayed work item drops Sparkle's reply if state has left `.checking` (`UpdateDriver.swift:206-209`). Out of this PR. The 10 second check timeout (`UpdateTiming.checkTimeoutDuration`, `UpdateDriver.swift:229-236`) is also out, unless the proof below returns to idle while the log says Sparkle has not answered. Then look at that timeout. Do not lengthen it in advance.

`UpdateViewModel.swift:306-307` already maps 4005 to the manual-download sentence. `isInstallerLaunchFailure` is `:399-407`. Leave both. No new `String(localized:)` key. A June 2026 note (`notes/sparkle-4005-investigation-2026-06-30.md`) attributes one 4005 to stripped framework symlinks. This ticket is the pin. `codesign --verify --deep --strict` on the downloaded signed artifacts must pass before the install attempt, so a broken wrapper is not recorded as the macOS 26 rejection.

## Proof (remote builder, macOS 26, after C11-216)

An ad-hoc tagged DEV app is not the proof. `scripts/reload.sh` signs with `codesign --sign -`. Atin chose C11-216 option A. Developer ID material and `SPARKLE_PRIVATE_KEY` stay in GitHub Actions. remote builder does not receive them. Do not copy them onto remote builder. Do not sign on remote builder. Do not generate a Sparkle key pair. Do not dispatch today's `release.yml` publish path as this smoke. Do not `gh release`. Do not move `latest`.

C11-312, owned by the atlas seat, provides the early GitHub Actions artifact-only signing path. This proof installs the signed test artifacts that path produces for C11-307. Two apps, build B's `CFBundleVersion` higher than build A, both already `com.stage11.c11.sparkle307`, and a signed appcast for those bytes. That bundle id is how `enforceSingleInstance` (`AppDelegate.swift:13136-13146`) stays off `/Applications/c11.app`. Do not commit the id. Do not change the kill. Name it in the PR. The feed URL and `SUPublicEDKey` are already inside the signed apps. Do not edit those plists and do not re-sign. Launch neither app as `c11 DEV.app` and do not launch the installed c11.

Serve the downloaded appcast and build B on `127.0.0.1`, not from `releases/latest`. The DEBUG env override (`UpdateDelegate.swift:21-28`) is compiled out of Release, so do not rely on `C11_UI_TEST_FEED_URL`. Prefer `http://c11-loopback.localtest.me:<port>/...` because `Resources/Info.plist` already allows insecure HTTP for that host. If Sparkle returns `SUInsecureFeedURLError` (code 3), serve the same files with a localhost certificate. Do not point the proof at the public feed.

Launch only build A. Check for Updates (`palette.checkForUpdates` → `checkForUpdates`, not `attemptUpdate`). Pass: the panel offers the update, the install finishes, and the running app is build B. The update log contains neither `4005` nor "connection was never initiated". Screenshot the panel. Then Check for Updates on build B. The same appcast has nothing newer, so the panel shows current and returns to idle on its own (`scheduleNoUpdateDismiss`). It does not stay on checking.

Record in the PR and `lattice comment --role validation`: Sparkle version from `Package.resolved`, proof bundle id, both build numbers, the artifact run URL, machine, macOS version, UTC, and whether the log showed 4005. No private key, token, or cookie value.

If 2.9.3 still returns 4005 or "connection was never initiated" after a strict verify, move the pin forward inside 2.x and repeat the install once against new artifacts from that same path. Do not report success by catching the error. Do not substitute an remote builder-signed build.

## Hot path, strings, persistence

None. No soak. No new localized string. No change to user defaults or the production feed.

## Test

No unit test. A test that reads `Package.resolved` is a metadata grep. The install is the proof.

## Cut

B104. B361 (Sparkle 2.9.5 endpoint-security timeout). B005, beyond naming the kill. Updater UI restyle. Rewriting the 4005 sentence. Publishing 1.0. Designing the artifact-only signing path (C11-312 owns that work). Copying Developer ID or the Sparkle release key to remote builder.

## Dependencies

C11-216 for the remote builder machine. C11-307 depends_on C11-312 on the board for the artifact-only signing workflow and its signed test artifacts. Wait for that early atlas-seat prerequisite before the install proof. This ticket does not design the signing path and does not publish. C11-293 owns later release/candidate approval and publication; it is not this ticket's signing prerequisite. The planning blocker is resolved by the C11-312 split. Keep the existing Actions-only credentials boundary; do not substitute an ad-hoc app.

## Decisions

None.

## Branch

Build mode: `c11-1.0/C11-307-sparkle-macos26` from `origin/main`. Not this worktree's crash branch.




## Build-mode corrections after C11-312 landed

Fresh base aa292e8f1c4ee95def5b3d9341a58d1a5553037c includes the artifact-only producer. Use sign-artifact.yml (purpose=proof, exact branch SHA) twice with build numbers 30701 and 30702 and isolated feed http://127.0.0.1:19307/proof. Its proof configuration already permits HTTP through ATS, so no localtest.me or certificate fallback is needed. Do not dispatch release.yml. Download through the existing authorized local client gh client and copy immutable bytes to remote builder; remote builder's existing gh token is invalid, and no credential will be provisioned.

Resolver proof: an isolated project copy on remote builder temporarily constrained Sparkle to exact 2.9.3, then restored the real upToNextMajorVersion floor of 2.9.3 and resolved again. Copy the generated Package.resolved back; both native resolutions select 2.9.3 without other package version changes. No Sparkle revision is hand-written.

No new test is needed for a package pin. Run the existing UpdateInstallerFailureMappingTests on remote builder to verify the preserved manual-install classification/copy against the new framework; native signed install/current proof remains the primary acceptance evidence. Read the official 2.9.0–2.9.3 release notes: 2.9.0 probes the agent/status service sooner and removes sparkle-cli from the binary zip; 2.9.3 fixes first update for bundle IDs ending in .app. The macOS 26 SDK mismatch/rejection evidence comes from upstream cmux #6678, not the 2.9.3 bundle-id release note. The source-built generate_appcast and sign_update schemes are still used.

Use an isolated remote builder macOS 26 sandbox for PID-scoped menu/actions and screenshots, keeping the existing two-guest cap. Preserve the signed plists and signatures. Enumerate its virtual display, bound the fixture lifetime, prove dismissal via synthesized UI, and retain exact A-to-B install plus B-current logs. These are per-ticket signed artifact acceptance checks explicitly requested by the Orchestrator, with no production feed or installed app mutation.
