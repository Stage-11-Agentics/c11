# C11-315 plan: hourly macOS CI and Atlas self-hosted runner

## Scope and architecture

- Keep `.github/workflows/ci.yml` as the pull-request fast lane: workflow guards,
  remote-daemon tests, and web typecheck only. Remove its push-to-main trigger so
  expensive macOS work is no longer started by pushes, PRs, or merges.
- Add a scheduled/manual `ci-hourly.yml` containing the existing app build,
  CLI smoke checks, logic tests, and advisory host-bound tests. It runs on the
  labels `self-hosted, macOS, atlas` and is not reachable from `pull_request`.
- Move `ci-macos-compat.yml` and `build-ghosttykit.yml` to the same hourly/manual
  main lane and the same Atlas labels. Preserve the existing GhosttyKit release,
  pinned-checksum commit, fork protection, and `ref: ${{ github.head_ref ||
  github.ref_name }}` checkout behavior.
- Add `scripts/ci-atlas-run.sh`, which admits each heavy command through
  `scripts/atlas_build_slots.py` and `scripts/with-build-lock.sh`, and a
  process-scoped Zig bootstrap helper. Atlas jobs must not install into `/usr/local`,
  change global Xcode selection, or access keychain state.
- Extend the executable CI policy guard and Drawbridge required-check list to
  describe the new PR/full-lane boundary. Update `CLAUDE.md`, the merge/landing
  guidance in `skills/lattice-orchestrator/references/orchestrator.md`, and the
  source-only `skills/c11-hotload/SKILL.md` with the exact-head Atlas gate and the
  hourly-main fix-forward rule.

## Acceptance criteria, evidence, and tests

1. A source PR schedules only the cheap PR checks and no paid/self-hosted macOS
   job. This answers the observed CI-churn incident. `tests/test_ci_self_hosted_guard.sh`
   and a new schedule-policy test will execute the workflow-policy assertions;
   the exact-head Atlas run will execute those guards from the branch.
2. The hourly full lane runs the app build and logic tests on Atlas, and the
   compatibility and GhosttyKit workflows run hourly/manual on Atlas without a
   `pull_request` trigger. This answers the hourly-main coverage requirement.
   The policy tests assert trigger/runner boundaries; GitHub Actions and the Atlas
   exact-head validation provide the live workflow evidence.
3. Every heavy Atlas command is admitted by the existing two-slot scheduler and
   build lock; the Zig helper is process-scoped and leaves global tool/Xcode state
   unchanged. This answers the Atlas overload incident. Exercise the wrapper and
   slot behavior with the existing lock tests plus a fixture-backed wrapper test;
   inspect the Atlas job log for slot acquisition and the exact `compile=ok`
   result.
4. A Ghostty submodule bump still downloads/verifies the pinned artifact and lets
   `build-ghosttykit` publish the prerelease artifact and checksum commit. This
   answers the existing checksum-flow contract. Run the existing checksum guard
   tests and a real Atlas exact-head path; do not add a fake source-text test.
5. The written operator guidance states: Merge Captain gates the exact PR head
   with the Atlas `remote-build` route (and preserves the hosted checksum
   exception for Ghostty/bonsplit pointer changes); the hourly main result is
   authoritative after landing, and a red hourly main run is fixed forward rather
   than treated as a PR failure. Validate the docs by review and exact-head
   workflow checks; no runtime UI proof applies.

## Exact files and seams

- `.github/workflows/ci.yml`: PR trigger and fast jobs.
- `.github/workflows/ci-hourly.yml`: extracted full build/logic-test job.
- `.github/workflows/ci-macos-compat.yml` and
  `.github/workflows/build-ghosttykit.yml`: scheduled Atlas execution.
- `scripts/ci-atlas-run.sh` and `scripts/ensure-zig.sh`: admission/toolchain
  seams used by all scheduled macOS workflows.
- `tests/test_ci_self_hosted_guard.sh` plus a focused CI policy test: executable
  workflow invariants. `TRIAGE_POLICY.md`: fast checks required by Drawbridge.
- `CLAUDE.md`, `skills/lattice-orchestrator/references/orchestrator.md`, and
  `skills/c11-hotload/SKILL.md`: operator and landing contracts.

## Impact and cut line

- No Swift, app runtime, typing path, localization, persistence, migration, or
  user-facing string changes. No submodule pointer change.
- The PR intentionally does not add merge queue behavior (C11-316), change
  release/signing workflows, or make fork PRs eligible for self-hosted execution.
- `remote-daemon-tests` remains in the fast PR lane because it is the existing
  cheap required check and has no macOS/self-hosted dependency; only the native
  macOS build, compatibility, and GhosttyKit work move to hourly main.

## Landing and open decisions

- Merge Captain must verify the review and fast checks at the exact PR head, run
  the Atlas exact-head gate through `scripts/remote-build.sh` for this CI/script
  seam, and then land without waiting for an hourly run. A Ghostty/bonsplit
  pointer PR retains the hosted checksum-flow requirement and is not substituted
  by the generic Atlas fallback.
- Runner registration is repo-scoped and foreground-only under an Atlas-owned
  directory, started with `nohup` only after the registration token is issued;
  no launchd/system install/global Xcode/keychain action is in scope. If GitHub
  requires an organization/admin setting, stop at that boundary and send
  `DECISION` with the exact setting and recommended choice.
- No new localized strings or persistence impact.
