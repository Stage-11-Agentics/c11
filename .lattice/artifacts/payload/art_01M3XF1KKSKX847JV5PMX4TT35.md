# C11-216 repair round 1

Review addressed: `ev_01M3XEJ1GFSCATSQ635HK343B2`, findings 1 and 2.
One repair commit: `21605c223c36abe2f90d1dfee8467945395aa18a`, pushed to `c11-1.0/C11-216-atlas-builds`. PR https://github.com/Stage-11-Agentics/c11/pull/498 remains draft.

1. Toolchain probe failures now normalize to exit 3, including absent/unusable executables, nonzero version probes, unsupported versions and empty version output. The remote invocation still retains diagnostics and result.json; no app is published. All other native build/test failure codes retain their original behavior.
2. Requested test result bundles are copied into invocation artifacts before inspecting the test exit status. A failed assertion retains its tests.xcresult, compile=ok, tests=failed and exit 65. The client retrieves those failure artifacts before returning the nonzero status. If copying itself fails, that diagnostic is recorded without masking the native failure status. The containment check compares canonical source paths, allowing the fixture's macOS /var alias while retaining the source boundary.

Atlas ran all 8 routing fixtures successfully in 14.653 seconds. The new toolchain fixture covers missing, unusable, wrong-version and empty-output Xcode and Zig probes (8 cases), checks exit 3/result.json/no publication and retains a predecessor sentinel. The existing no-launch client fixture now exercises both SSH exit 23 and toolchain exit 3. The failed-assertion fixture emits a requested failure.xcresult, verifies its snapshot and actual client retrieval through fake transport, and checks retained diagnostics after reusing the tag. Fixtures execute synthetic Git/worktree/submodule and subprocess paths; no source-grep assertions.

Fixture source hashes on Atlas match this committed checkout:

- scripts/remote_build.py: `a63a6338435c1d77ce70f223f4c131f6d22799a82cf2f3fe36e972f7b85f7e8b`
- tests/test_remote_build_routing.py: `0713536d168993c340b9141677021fd01aafe7da4990cd632dde4e4d00cc36f4`

A real SSH route from the isolated delegator worktree at this clean head used an intentionally missing process-scoped Xcode path with --launch. Invocation `31240c06dba641059b8e5f2ae3e4118c` returned exit 3, compile=failed/ok=false, and copied result.json back. The preceding Debug executable, Info.plist and CodeResources hashes remained identical, and no tagged Hyperion app process was observed. This probe did not run native compilation or launch a DEV app. No global Atlas selection, installations, unrelated processes or buildtest files were changed.

Local supporting files are in `build-remote/repair-round-1/` (routing.log, missing-toolchain.log/exit, toolchain-result.json and preservation.json). Initial successful native builds, nine selected tests, Release compilation, concurrency and packaged Atlas smoke remain historical evidence at `2adc575815`; they were not rerun for this two-path repair. Independent re-review and CI at the new head remain pending. Installed skill synchronization remains deferred until merge; other tickets remain planning-only.
