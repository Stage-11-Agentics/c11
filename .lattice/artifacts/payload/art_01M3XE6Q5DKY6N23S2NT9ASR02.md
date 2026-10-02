# C11-216 validation

Owner: `agent:codex-atlas`. Head: `2adc5758157c0707f474b65b1654f80ba323cbfb`.
Branch: `c11-1.0/C11-216-atlas-builds`. Draft PR: https://github.com/Stage-11-Agentics/c11/pull/498
Implementation base: `0ff8887e5e965400b01645ef40b85fd0b2605cf2`.

All native builds and tests ran on Atlas. Xcode was selected per process: `Xcode 26.3`, build `17C529`, with Zig `0.15.2`. Atlas's global Xcode selection was not changed. The first request waited until the separate `~/c11-buildtest/phases.log` contained `DONE`; that test tree was only read. No Hyperion xcodebuild process was observed and no Hyperion DEV app was launched.

## Final-head native results

Every manifest below records this exact head, no dirty overlays, Ghostty `26c3e499ed8c4d65e3748248de7fd04c1e9a8103`, and Bonsplit `c17c6f41cd71066bda9bec82c54465fe34821c75`.

| Route | Invocation | Result |
| --- | --- | --- |
| Debug `c11-216-gate` | `21e16118a0cd4a9ba3b637fcc2fa47ff` | compile=ok; artifact copied back; final local ad-hoc signature verified |
| Debug `c11-216-pair` | `01cc172ffa8a466da82c9b59065d8202` | compile=ok; separate artifact copied back; final local ad-hoc signature verified |
| Selected test `c11-216-tests` | `fa41f21026404670bd9e09e672a77fc7` | compile=ok; tests=ok; 9 HealthSentinelParserTests tests, zero failures; xcresult copied back |
| Release `c11-216-rel` | `52ded218124e46acb7bad64b7daad4fc` | compile=ok; ad-hoc staging app copied back; no publication or notarization |
| Forced missing toolchain, Debug with `--launch` | `3a3550f41cd147de985708eddcebc24e` | compile=failed; exit 1; no launch; preceding local executable hash preserved |

The first acceptance invocation, `eac634a7c2e74fe38642c57c6cf8251c`, succeeded at earlier head `4c62188d6dabf0095a605e8bcdd359b5c99c7698`. A reused-tag attempt at `a46d08aa9f` then failed nonzero because Git recursively fetched historical gitlinks from old bundle origins. This was fixed by disabling recursive fetch and provisioning each pinned module explicitly. The final reused-tag runs above passed; the failure is retained in `build-remote/8d294b3d47aa40dfb812e18d418b3029/`.

## Concurrency and executable fixtures

At `2026-10-02 04:27:03 UTC`, Atlas simultaneously ran Debug xcodebuild PIDs 3067 and 3079, using `c11-c11-216-pair` and `c11-c11-216-gate` DerivedData. Their transport logs report slots 1 and 2 respectively, capacity 2. See `two-debug-slots.txt` and the two invocation transport logs.

At the final source revision, Atlas passed 7 routing fixtures, 5 slot fixtures and the existing `test_with_build_lock.sh` check. These execute synthetic worktree/bundle/overlay transfers, staged deletion/mode/symlink behavior, tamper and dirty-submodule refusal, immutable cache/delta transfer, reused-tag pinned-module fetching, native/test/SSH failure propagation, two-slot/third-waiter admission, same-tag exclusion, sustained high-load fallback and recovery, nested lock reuse, and default single-lock serialization. High load was exercised through the load-file fixture; no stress workload was injected. See `hermetic-summary.txt`.

## Packaged Atlas smoke

From Atlas's retained tagged staging path, `launch-tagged-automation.sh c11-216-gate --qa fresh` reported `socket_ready: yes`. The packaged CLI identified `/tmp/c11-debug-c11-216-gate.sock`. A newly created terminal tab attached, executed a synthetic printf command, and returned `C11_216_SMOKE_ATTACHED` through read-screen. The full tree was captured. The only online display was verified before launch, and a 120-second timer bounded the run. Closing this tagged app's windows yielded `remaining_windows: []`; its tagged process then quit. No unrelated session was driven or terminated. This is a CLI/terminal packaged smoke, with no claim of a separate visual interaction scenario.

Local evidence is under `build-remote/validation-2adc575815/`; native logs and result manifests are in `build-remote/<invocation>/`. Each result contains source identity and executable hashes. Atlas retains the corresponding `~/c11-builds/<tag>/artifacts/<invocation>/` directory.

## Remaining gates

Independent review belongs to the Orchestrator. GitHub build and compatibility checks were still pending at this evidence checkpoint; four other checks passed. The PR remains draft and is not merged. Installed skill synchronization is deferred until the Orchestrator confirms merge. Artifact-only signing is C11-312; approved production publication is C11-293. Neither was implemented here.
