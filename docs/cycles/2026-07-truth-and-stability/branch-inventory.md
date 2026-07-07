# Stale-branch inventory: C11-160 (HYG-3)

Generated 2026-07-07 for the Truth & Stability cycle by `agent:ts-hyg-delegator`.
Baseline: `origin/main` @ `36f2a70ce` (after this ticket's dependabot merges).

**This is an inventory for operator review. No branches were deleted; deletion is operator-assisted per the cycle contract (HYG-3). `upstream` (manaflow-ai/cmux) branches are excluded; they are not ours to prune.**

## How to read this

- **Ahead / Behind**: commits on the branch not in `origin/main` (ahead) and commits in `origin/main` not on the branch (behind), via `git rev-list --left-right --count origin/main...<branch>`.
- **Merged to main**: `yes` if the branch tip is an ancestor of `origin/main` (`git merge-base --is-ancestor`). A `yes` with `Ahead: 0` is fully absorbed and the safest deletion candidate.
- **Last commit**: committer date (YYYY-MM-DD) of the branch tip.
- Tables are sorted stalest-first (oldest last-commit at top).

## Summary

| Scope | Total | Merged to main | Unmerged |
|---|---|---|---|
| Local | 87 | 23 | 64 |
| Remote (origin) | 164 | 17 | 147 |

**Deletion guidance for the operator:** branches marked `Merged to main = yes` (and especially `Ahead = 0`) are safe to delete; their work is already in `main`. Unmerged branches with very large `Behind` counts and old `Last commit` dates are likely abandoned but may hold unlanded work; review before deleting. Many local branches mirror a remote of the same name (worktree/checkout residue).

## Local branches (87)

| Branch | Last commit | Author | Ahead | Behind | Merged to main | Tip |
|---|---|---|---|---|---|---|
| `cmux-35-themes-picker` | 2026-04-20 | Atin | 2 | 503 | no | `d58d90149` |
| `c11-5-workspace-sidebar-card` | 2026-04-21 | Atin | 5 | 476 | no | `d22b62e9f` |
| `c11-8-workspace-color-chrome` | 2026-04-21 | Atin | 8 | 467 | no | `1a7054992` |
| `c11-8-workspace-color-chrome-pr` | 2026-04-21 | Atin | 8 | 464 | no | `a69a294f6` |
| `c11-12-jump-unread-shortcut` | 2026-04-23 | Atin | 1 | 400 | no | `87d437c46` |
| `c11-13-tab-bar-chrome-states` | 2026-04-23 | Atin | 1 | 406 | no | `b95b2125a` |
| `c11-15-tcc-primer-first` | 2026-04-23 | Atin | 6 | 406 | no | `1cbc3c82c` |
| `docs/c11-theme-namespace-plan-landed` | 2026-04-23 | Atin | 0 | 409 | yes | `2cd067b87` |
| `fix/tcc-primer-call-site` | 2026-04-23 | Atin | 0 | 396 | yes | `5fd1a7757` |
| `c11-14/stage-3-full-primitive` | 2026-04-24 | Atin | 0 | 383 | yes | `ccc362170` |
| `c11-agent-launcher-close-pane-buttons` | 2026-04-24 | Atin | 15 | 390 | no | `2a032c302` |
| `fix-claude-hook-silence-and-rename` | 2026-04-24 | Atin | 2 | 390 | no | `5f8bcb15e` |
| `feat/pane-close-overlay` | 2026-04-26 | Atin | 8 | 366 | no | `519c0769f` |
| `c11-24-session-resume` | 2026-04-27 | Atin | 9 | 348 | no | `987d6faa8` |
| `c11-24-session-resume-pre-rebase` | 2026-04-27 | Atin | 11 | 353 | no | `5d2776184` |
| `c11-24-session-resume-pre-squash` | 2026-04-27 | Atin | 7 | 348 | no | `48cea33d5` |
| `deps/web-vuln-cleanup` | 2026-04-29 | Atin | 4 | 330 | no | `0ca18060e` |
| `probe-main` | 2026-05-01 | Atin | 3 | 330 | no | `7a5f521fa` |
| `triage-base` | 2026-05-01 | Atin | 6 | 330 | no | `d3beca94c` |
| `c11-24-crash-visibility` | 2026-05-03 | Atin | 0 | 311 | yes | `3a3908110` |
| `c11/pane-initial-command` | 2026-05-03 | Atin | 0 | 311 | yes | `3a3908110` |
| `crash-visibility/launch-sentinel` | 2026-05-03 | Atin | 1 | 311 | no | `5402d3fcd` |
| `upstream/pr-2916` | 2026-05-03 | Atin | 0 | 311 | yes | `3a3908110` |
| `c11-24/pane-title-bar` | 2026-05-04 | Atin | 0 | 300 | yes | `a69b10ef2` |
| `c11-26-followup-handler-self-deadlock` | 2026-05-04 | Atin | 2 | 300 | no | `39191c0ac` |
| `c11-26-followup2-v1-test-sweep` | 2026-05-04 | Atin | 0 | 297 | yes | `e164a71e1` |
| `metal-deinit-drain` | 2026-05-04 | Atin | 1 | 302 | no | `2ef997e75` |
| `test-tabid-string-mismatch` | 2026-05-04 | Atin | 1 | 306 | no | `d17f42f0d` |
| `cmux-12-pane-title-bar` | 2026-05-05 | Atin | 0 | 289 | yes | `6e4046da1` |
| `perf/phase4-presentation-store` | 2026-05-06 | Atin | 5 | 291 | no | `2df71eea0` |
| `perf/workspace-switch-instrumentation` | 2026-05-06 | Atin | 4 | 291 | no | `f40f8098f` |
| `pr-138` | 2026-05-06 | Atin | 3 | 285 | no | `7d5b24140` |
| `c11-40-mode-b-anchor-lifecycle` | 2026-05-14 | Atin | 1 | 272 | no | `56a99b75e` |
| `c11-40-workspace-create-enter-and-close-pane-veto` | 2026-05-14 | Atin | 1 | 273 | no | `e617a1b32` |
| `fix/bump-version-appcast-url-c11` | 2026-05-14 | Atin | 2 | 273 | no | `4b94d32a8` |
| `fix/c11-40-anchor-stale-after-sibling-close` | 2026-05-14 | Atin | 1 | 271 | no | `f6d0f959e` |
| `pr-152` | 2026-05-14 | Atin | 1 | 273 | no | `119125259` |
| `c11-ws-name` | 2026-05-15 | Atin | 1 | 267 | no | `c7c0343e7` |
| `fix/mailbox-stdin-submit-via-textbox-submit` | 2026-05-15 | Atin | 1 | 271 | no | `1591b01fe` |
| `fix/new-workspace-help-current-window` | 2026-05-15 | Atin | 1 | 261 | no | `63f762006` |
| `fix/mailbox-unit-test-failures` | 2026-05-16 | Atin | 1 | 258 | no | `a898585e4` |
| `fix/main-test-failures` | 2026-05-16 | Atin | 2 | 255 | no | `c991d57ff` |
| `skill-preview` | 2026-05-17 | Atin | 0 | 250 | yes | `132559c90` |
| `c11-14/default-terminal-agent` | 2026-05-18 | Atin | 8 | 251 | no | `865fd873e` |
| `c11-99-abd` | 2026-05-18 | Atin | 4 | 238 | no | `bd28a8e12` |
| `c11-99-area-b` | 2026-05-18 | Atin | 4 | 238 | no | `7c8a3fda0` |
| `c11-99-c` | 2026-05-18 | Atin | 9 | 236 | no | `802d5cfb0` |
| `c11/default-agent-env-merge` | 2026-05-18 | Atin | 1 | 244 | no | `226ac7290` |
| `fix/release-slash-command` | 2026-05-18 | Atin | 1 | 246 | no | `32ab25b04` |
| `prompt/orient-before-skill-load` | 2026-05-18 | Atin | 1 | 236 | no | `5225c45b8` |
| `c11-108-send-auto-submit` | 2026-05-19 | Atin | 5 | 238 | no | `d4dcb6803` |
| `c11-109-skip-flaky-host-tests` | 2026-05-19 | Atin | 4 | 238 | no | `cfbc53707` |
| `diag/c11-105-socket-watcher` | 2026-05-19 | Atin | 2 | 236 | no | `186b3db77` |
| `fix/issue-147-ime-composition-enter-leak` | 2026-05-21 | Atin | 1 | 210 | no | `9da1f46e4` |
| `feat/lattice-orchestrator-workflow-modes` | 2026-05-22 | Atin | 1 | 202 | no | `07c33be79` |
| `feat/orchestrator-codereview-hardrule-and-plan-validation` | 2026-05-23 | Atin | 1 | 197 | no | `56859f939` |
| `feat/grok-agent` | 2026-05-26 | Atin | 1 | 194 | no | `75c0550a6` |
| `pr-212-orig` | 2026-05-26 | Atin | 1 | 194 | no | `75c0550a6` |
| `feat/etch-12-cairn-skill-export` | 2026-05-28 | Atin | 4 | 197 | no | `d44c94889` |
| `pr-215-orig` | 2026-05-29 | MdMxMyr | 1 | 192 | no | `81123c079` |
| `feat/create-workspace-dialog-tweaks` | 2026-05-30 | Atin | 5 | 197 | no | `7e26f9ea8` |
| `drawbridge-install` | 2026-06-03 | Atin | 4 | 183 | no | `cffe8c349` |
| `etch-validation-throwaway` | 2026-06-12 | Atin | 0 | 153 | yes | `a3f8855fd` |
| `land/pr-212` | 2026-06-12 | Atin | 0 | 136 | yes | `4d8e66a84` |
| `land/pr-215` | 2026-06-12 | Atin | 0 | 133 | yes | `234022829` |
| `feat/main-thread-hang-monitor` | 2026-06-14 | Atin | 0 | 131 | yes | `0801a48d5` |
| `fix/opencode-tui-launch-command` | 2026-06-16 | Atin | 1 | 112 | no | `df535b35a` |
| `feat/opencode-parity` | 2026-06-17 | Atin | 3 | 113 | no | `293a78985` |
| `design/c11-theme-directions` | 2026-06-25 | Atin | 1 | 101 | no | `f5bd6fdbb` |
| `feat/collapsing-tab-dropdown` | 2026-06-25 | Atin | 0 | 91 | yes | `2319e890f` |
| `feat/opencode-resume` | 2026-06-28 | Atin | 1 | 108 | no | `2bfa1820d` |
| `chore/cmux-to-c11-socket-env` | 2026-06-29 | Atin | 1 | 56 | no | `a09a85f4b` |
| `fix/relay-cleanup-test-timeout` | 2026-06-29 | Atin | 1 | 44 | no | `5d6221629` |
| `fix/socket-collision-bind-stomp` | 2026-06-29 | Atin | 1 | 54 | no | `5b5af566c` |
| `integration/capture-v054-into-main` | 2026-06-29 | Atin | 0 | 45 | yes | `ca6300ace` |
| `fix/sparkle-4005-graceful-failure` | 2026-06-30 | Atin | 2 | 38 | no | `9ac13bb71` |
| `overture-orchestrator-rework` | 2026-07-02 | Atin | 0 | 23 | yes | `c676d9050` |
| `chord-family` | 2026-07-03 | Atin | 0 | 16 | yes | `fc4ac3449` |
| `agent-effort-setting` | 2026-07-06 | Atin | 0 | 11 | yes | `a77dce470` |
| `effort-i18n` | 2026-07-06 | Atin | 1 | 10 | no | `a0dae5a61` |
| `fast-boot-lazy-orient` | 2026-07-06 | Atin | 1 | 26 | no | `396e19d02` |
| `i18n/model-effort-strings` | 2026-07-06 | Atin | 1 | 9 | no | `b879c6b47` |
| `no-launch-prompt` | 2026-07-06 | Atin | 0 | 15 | yes | `b42e43cc5` |
| `main` | 2026-07-07 | Atin | 0 | 6 | yes | `b0f9120b2` |
| `ts/dx-dispatcher-extraction` | 2026-07-07 | Atin | 0 | 6 | yes | `b0f9120b2` |
| `ts/hyg-repo-hygiene` | 2026-07-07 | Atin | 1 | 6 | no | `2391fd7e8` |
| `ts/web-public-surface` | 2026-07-07 | Atin | 0 | 6 | yes | `b0f9120b2` |

## Remote branches: origin (164)

| Branch | Last commit | Author | Ahead | Behind | Merged to main | Tip |
|---|---|---|---|---|---|---|
| `origin/rename/c11mux-surface` | 2026-04-16 | Atin | 0 | 557 | yes | `6ec68b4a3` |
| `origin/ci/fast-tests` | 2026-04-17 | Atin | 4 | 554 | no | `4c15e0987` |
| `origin/ci/simplify-under-4min` | 2026-04-17 | Atin | 2 | 552 | no | `825393ba3` |
| `origin/features/c11mux-1-8` | 2026-04-17 | Atin | 36 | 555 | no | `ede622bc8` |
| `origin/features/markdown-features` | 2026-04-17 | Atin | 37 | 555 | no | `2f50948b9` |
| `origin/features/welcome-quad` | 2026-04-17 | Atin | 3 | 552 | no | `162596748` |
| `origin/icon/add-banner-cleanup` | 2026-04-17 | Atin | 1 | 554 | no | `60cb570c6` |
| `origin/m10-dispatcher-safety` | 2026-04-18 | Atin | 30 | 535 | no | `54acbfac2` |
| `origin/m10-pane-interaction` | 2026-04-18 | Atin | 28 | 535 | no | `bbaa8b54f` |
| `origin/m10-review-fixes` | 2026-04-18 | Atin | 36 | 543 | no | `def4b943e` |
| `origin/m7-expandable-title-bar` | 2026-04-18 | Atin | 1 | 552 | no | `513245990` |
| `origin/m9-textbox-input` | 2026-04-18 | Atin | 11 | 547 | no | `81094365f` |
| `origin/persistence/metadata-persist` | 2026-04-18 | Atin | 14 | 542 | no | `2ef15bea8` |
| `origin/persistence/stable-panel-ids` | 2026-04-18 | Atin | 5 | 547 | no | `870319759` |
| `origin/cmux-11-pane-metadata` | 2026-04-19 | Atin | 1 | 516 | no | `9c33cfe3a` |
| `origin/cmux-11-phase-3-4` | 2026-04-19 | Atin | 4 | 508 | no | `520ea766a` |
| `origin/cmux-11-phase2-rpcs-cli` | 2026-04-19 | Atin | 3 | 515 | no | `76e9e59f0` |
| `origin/cmux-15-default-grid` | 2026-04-19 | Atin | 1 | 515 | no | `0c296414a` |
| `origin/cmux-20-followup` | 2026-04-19 | Atin | 2 | 512 | no | `4a71ba4a3` |
| `origin/cmux-22-tab-x-fix` | 2026-04-19 | Atin | 2 | 506 | no | `9d54bc55e` |
| `origin/cmux-3-phase3-persist-status-entries` | 2026-04-19 | Atin | 3 | 514 | no | `83364ebae` |
| `origin/cmux-9-m1-theme-foundation` | 2026-04-19 | Atin | 15 | 508 | no | `7c268f9b7` |
| `origin/c11/rebrand` | 2026-04-20 | Atin | 14 | 496 | no | `143a367b9` |
| `origin/cmux-32-frame-dividers` | 2026-04-20 | Atin | 4 | 503 | no | `1de071c65` |
| `origin/cmux-35-themes-picker` | 2026-04-20 | Atin | 1 | 503 | no | `02338330b` |
| `origin/cmux-36-bottom-status-bar` | 2026-04-20 | Atin | 3 | 502 | no | `d60a5b0de` |
| `origin/rename-to-c11` | 2026-04-20 | Atin | 3 | 492 | no | `776dea469` |
| `origin/theme-simplify-radical-force-dark` | 2026-04-20 | Atin | 1 | 496 | no | `eac37d208` |
| `origin/c11-5-workspace-sidebar-card` | 2026-04-21 | Atin | 2 | 476 | no | `980c36fb4` |
| `origin/c11-8-workspace-color-chrome` | 2026-04-21 | Atin | 6 | 467 | no | `ad5872584` |
| `origin/c11-8-workspace-color-chrome-pr` | 2026-04-21 | Atin | 4 | 464 | no | `1566adb18` |
| `origin/c11-cmux-coexistence` | 2026-04-21 | Atin | 2 | 489 | no | `457fbf1e1` |
| `origin/c11-theme-namespace-cli` | 2026-04-21 | Atin | 1 | 463 | no | `8139bec4b` |
| `origin/codex/agent-skill-ux` | 2026-04-21 | Atin | 3 | 463 | no | `36a470b48` |
| `origin/codex/status-bar-help-menu-polish` | 2026-04-21 | Atin | 3 | 469 | no | `7d9bf2a27` |
| `origin/codex/tab-width-tuning` | 2026-04-21 | Atin | 1 | 465 | no | `c11c5353e` |
| `origin/fix-pane-interaction-focus-acquisition` | 2026-04-21 | Atin | 3 | 489 | no | `93fada3cd` |
| `origin/fix/close-dialog-keyboard` | 2026-04-21 | Atin | 2 | 467 | no | `1380b51e4` |
| `origin/ci/reduce-actions-cost` | 2026-04-22 | Atin | 1 | 434 | no | `fe3478d56` |
| `origin/readme-first-principles` | 2026-04-22 | Atin | 2 | 438 | no | `967304ca5` |
| `origin/agent-skills-copy-tune` | 2026-04-23 | Atin | 2 | 429 | no | `76934420a` |
| `origin/c11-12-jump-to-unread-sidebar` | 2026-04-23 | Atin | 3 | 419 | no | `b80038f44` |
| `origin/c11-12-jump-unread-shortcut` | 2026-04-23 | Atin | 1 | 400 | no | `87d437c46` |
| `origin/c11-13-tab-bar-chrome-states` | 2026-04-23 | Atin | 7 | 406 | no | `4eba18c8c` |
| `origin/c11-15-tcc-primer-first` | 2026-04-23 | Atin | 6 | 406 | no | `1cbc3c82c` |
| `origin/c11-7/v2-notify` | 2026-04-23 | Atin | 1 | 412 | no | `e1aeb9b4f` |
| `origin/c11-skill-titles` | 2026-04-23 | Atin | 1 | 424 | no | `04166bdac` |
| `origin/docs/c11-theme-namespace-plan-landed` | 2026-04-23 | Atin | 0 | 409 | yes | `2cd067b87` |
| `origin/feat/tcc-primer-onboarding` | 2026-04-23 | Atin | 2 | 427 | no | `6f28a4055` |
| `origin/fix/set-metadata-env-default` | 2026-04-23 | Atin | 1 | 419 | no | `b72da0311` |
| `origin/fix/tcc-primer-call-site` | 2026-04-23 | Atin | 0 | 396 | yes | `5fd1a7757` |
| `origin/gregorovich-voice-tune` | 2026-04-23 | Atin | 28 | 434 | no | `42e2da593` |
| `origin/oss-hygiene` | 2026-04-23 | Atin | 0 | 422 | yes | `126133d1a` |
| `origin/c11-13/stage-2-vertical-slice` | 2026-04-24 | Atin | 24 | 385 | no | `993ec7f7d` |
| `origin/c11-agent-launcher-close-pane-buttons` | 2026-04-24 | Atin | 15 | 390 | no | `2a032c302` |
| `origin/cmux-37/phase-0-workspace-apply-plan` | 2026-04-24 | Atin | 19 | 390 | no | `e42ad8bfe` |
| `origin/cmux-37/phase-1-snapshots-restore` | 2026-04-24 | Atin | 12 | 383 | no | `d683f0440` |
| `origin/fix-claude-hook-silence-and-rename` | 2026-04-24 | Atin | 2 | 390 | no | `5f8bcb15e` |
| `origin/c11-7/bounded-waits` | 2026-04-25 | Atin | 6 | 397 | no | `d40ef8a67` |
| `origin/c11-14/phase-1-followup` | 2026-04-26 | Atin | 20 | 365 | no | `1c5425617` |
| `origin/c11-20-cli-hygiene` | 2026-04-26 | Atin | 11 | 353 | no | `fbe9efb35` |
| `origin/cmux-37/remaining-phases` | 2026-04-26 | Atin | 20 | 364 | no | `1e8df4a5e` |
| `origin/feat/pane-close-overlay` | 2026-04-26 | Atin | 8 | 366 | no | `519c0769f` |
| `origin/c11-21-input-handling` | 2026-04-27 | Atin | 12 | 353 | no | `8913426c0` |
| `origin/c11-22-stability` | 2026-04-27 | github-actions[bot] | 28 | 353 | no | `0a8452063` |
| `origin/c11-24-session-resume` | 2026-04-27 | Atin | 9 | 348 | no | `987d6faa8` |
| `origin/fix/orphan-portal-entry` | 2026-04-27 | Atin | 1 | 349 | no | `bf0de779f` |
| `origin/bundle/dependabot-ci-bumps` | 2026-04-28 | Atin | 8 | 335 | no | `3fda64739` |
| `origin/c11-flash-tab-and-workspace` | 2026-04-28 | Atin | 3 | 341 | no | `97fd9acc5` |
| `origin/deps/web-vuln-cleanup` | 2026-04-29 | Atin | 4 | 330 | no | `0ca18060e` |
| `origin/feat/openai-cua-runner` | 2026-04-29 | Atin | 4 | 332 | no | `75455042b` |
| `origin/menu-bar-icon` | 2026-05-01 | Atin | 1 | 328 | no | `48a5b6d4a` |
| `origin/c11-1-rebrand-cleanup` | 2026-05-02 | Atin | 11 | 317 | no | `71312ce22` |
| `origin/catchup/sweep-2026-04-15` | 2026-05-02 | Atin | 1 | 318 | no | `77000e540` |
| `origin/c11-1-completion-audit` | 2026-05-03 | Atin | 1 | 311 | no | `f32f3d6b0` |
| `origin/c11-24/health-cli` | 2026-05-03 | Atin | 21 | 311 | no | `3fddef74c` |
| `origin/c11-26-route-blocking-v2-off-main` | 2026-05-03 | Atin | 10 | 311 | no | `6d4f1c8d0` |
| `origin/cmux-37/final-push` | 2026-05-03 | Atin | 9 | 311 | no | `aea6eaa8c` |
| `origin/crash-visibility/launch-sentinel` | 2026-05-03 | Atin | 2 | 311 | no | `75394e690` |
| `origin/c11-10-surface-tab-colors` | 2026-05-04 | Atin | 17 | 295 | no | `9ba6853dc` |
| `origin/c11-26-followup-handler-self-deadlock` | 2026-05-04 | Atin | 2 | 300 | no | `39191c0ac` |
| `origin/metal-deinit-drain` | 2026-05-04 | github-actions[bot] | 2 | 302 | no | `ddf27cac0` |
| `origin/release/v0.45.1` | 2026-05-04 | Atin | 1 | 301 | no | `847ce0709` |
| `origin/release/v0.45.2` | 2026-05-04 | Atin | 1 | 297 | no | `ee3e6cc60` |
| `origin/restart-registry-project-dir-capture` | 2026-05-04 | Atin | 1 | 307 | no | `480cd733a` |
| `origin/test-tabid-string-mismatch` | 2026-05-04 | Atin | 1 | 306 | no | `d17f42f0d` |
| `origin/c11-25-surface-lifecycle` | 2026-05-05 | Atin | 21 | 293 | no | `b51b4cd2b` |
| `origin/c11-6-app-chrome-scale` | 2026-05-05 | Atin | 6 | 290 | no | `05586fd99` |
| `origin/c11-17-overnight-installer-purge` | 2026-05-06 | Atin | 4 | 285 | no | `d14c7b1c5` |
| `origin/c11-30-overnight-close-overlay` | 2026-05-06 | Atin | 11 | 285 | no | `6d3affab9` |
| `origin/cmux-10-persistent-flash` | 2026-05-06 | Atin | 16 | 289 | no | `f634d7f09` |
| `origin/perf/p8-rollup` | 2026-05-06 | Atin | 8 | 291 | no | `5d69f1724` |
| `origin/perf/phase4-presentation-store` | 2026-05-06 | Atin | 5 | 291 | no | `2df71eea0` |
| `origin/perf/phase4a-collapse-portal-layout` | 2026-05-06 | Atin | 5 | 291 | no | `16347827f` |
| `origin/perf/phase8c-ensure-focus` | 2026-05-06 | Atin | 6 | 291 | no | `1aa3ab11b` |
| `origin/perf/phase8e-setactive-async` | 2026-05-06 | Atin | 5 | 291 | no | `e4d2ae305` |
| `origin/release/v0.46.0` | 2026-05-06 | Atin | 1 | 287 | no | `d26724cc8` |
| `origin/tcc-primer-debug-bundle-isolation` | 2026-05-07 | Atin | 6 | 285 | no | `7f34e5509` |
| `origin/fix/agent-skills-onboarding-launch-trigger` | 2026-05-10 | Atin Woodard | 1 | 284 | no | `b0788e7f8` |
| `origin/perf/phase4a-instrument-focus-churn` | 2026-05-12 | Atin | 6 | 291 | no | `1b71d5baf` |
| `origin/c11-24-overnight-manifest-viewer` | 2026-05-14 | Atin | 4 | 277 | no | `9343fc03a` |
| `origin/c11-4-overnight-audit-findings` | 2026-05-14 | Atin | 5 | 285 | no | `756174dc4` |
| `origin/c11-40-mode-b-anchor-lifecycle` | 2026-05-14 | Atin | 1 | 272 | no | `56a99b75e` |
| `origin/c11-40-workspace-create-enter-and-close-pane-veto` | 2026-05-14 | Atin | 1 | 273 | no | `e617a1b32` |
| `origin/fix/bump-version-appcast-url-c11` | 2026-05-14 | Atin | 2 | 273 | no | `4b94d32a8` |
| `origin/perf/workspace-switch-instrumentation` | 2026-05-14 | Atin | 6 | 291 | no | `4c9759c7d` |
| `origin/c11-ws-name` | 2026-05-15 | Atin | 1 | 267 | no | `c7c0343e7` |
| `origin/fix/c11mux-rename-test-expectations` | 2026-05-15 | Atin | 5 | 260 | no | `b634f4b23` |
| `origin/fix/mailbox-stdin-submit-via-textbox-submit` | 2026-05-15 | Atin | 1 | 271 | no | `1591b01fe` |
| `origin/release/v0.47.1` | 2026-05-15 | Atin | 1 | 262 | no | `f39c145ea` |
| `origin/c11-16-overnight-fda-detect` | 2026-05-16 | Atin | 3 | 254 | no | `03f0e3162` |
| `origin/feat/c11-27-test-split` | 2026-05-16 | Atin | 10 | 258 | no | `b7946ff7e` |
| `origin/fix/mailbox-unit-test-failures` | 2026-05-16 | Atin | 1 | 258 | no | `a898585e4` |
| `origin/fix/main-test-failures` | 2026-05-16 | Atin | 2 | 255 | no | `c991d57ff` |
| `origin/sentry/c11-1-app-hang-instrumentation` | 2026-05-16 | Atin | 1 | 251 | no | `9f7bef220` |
| `origin/c11-14/default-terminal-agent` | 2026-05-18 | Atin | 8 | 251 | no | `865fd873e` |
| `origin/c11-99-abd` | 2026-05-18 | Atin | 4 | 238 | no | `bd28a8e12` |
| `origin/c11-99-area-b` | 2026-05-18 | Atin | 4 | 238 | no | `7c8a3fda0` |
| `origin/c11-99-area-d` | 2026-05-18 | Atin | 4 | 238 | no | `1562a44b5` |
| `origin/c11-99-c` | 2026-05-18 | Atin | 9 | 236 | no | `802d5cfb0` |
| `origin/fix/c11-103-state-dir-merge` | 2026-05-18 | Atin | 1 | 236 | no | `2f245f01f` |
| `origin/fix/release-slash-command` | 2026-05-18 | Atin | 1 | 246 | no | `32ab25b04` |
| `origin/prompt/orient-before-skill-load` | 2026-05-18 | Atin | 1 | 236 | no | `5225c45b8` |
| `origin/release/v0.48.0` | 2026-05-18 | Atin | 0 | 242 | yes | `66044e1b1` |
| `origin/c11-108-send-auto-submit` | 2026-05-19 | Atin | 5 | 238 | no | `d4dcb6803` |
| `origin/c11-109-skip-flaky-host-tests` | 2026-05-19 | Atin | 1 | 226 | no | `409f8730d` |
| `origin/c11-110/staging-build-perf` | 2026-05-19 | Atin | 6 | 225 | no | `fb4daab5e` |
| `origin/c11-99-browser-url` | 2026-05-19 | Atin | 1 | 230 | no | `0210c1a51` |
| `origin/c11-99-c-followup` | 2026-05-19 | Atin | 1 | 233 | no | `a63db3a9a` |
| `origin/diag/c11-105-socket-watcher` | 2026-05-19 | Atin | 2 | 236 | no | `186b3db77` |
| `origin/feat/c11-104-sidebar-chips` | 2026-05-19 | Atin | 5 | 233 | no | `b9ab056f8` |
| `origin/feat/c11-106-followups` | 2026-05-19 | Atin | 6 | 229 | no | `7777f76c3` |
| `origin/c11-111-skill-onboarding` | 2026-05-22 | Atin | 12 | 200 | no | `8e5fb2210` |
| `origin/feat/lattice-orchestrator-workflow-modes` | 2026-05-22 | Atin | 1 | 202 | no | `07c33be79` |
| `origin/feat/grok-agent` | 2026-05-26 | Atin | 1 | 194 | no | `75c0550a6` |
| `origin/feat/C11-119-sidebar-nav-cluster` | 2026-05-27 | Atin | 3 | 192 | no | `8f24aeef1` |
| `origin/feat/etch-12-cairn-skill-export` | 2026-05-28 | Atin | 4 | 197 | no | `d44c94889` |
| `origin/feat/main-thread-hang-monitor` | 2026-06-14 | Atin | 0 | 131 | yes | `0801a48d5` |
| `origin/dependabot/bun/web/eslint-10.5.0` | 2026-06-15 | dependabot[bot] | 1 | 123 | no | `a419bb97a` |
| `origin/fix/c11-identity-env-dualwrite` | 2026-06-16 | Atin | 1 | 113 | no | `df91ea1c6` |
| `origin/fix/opencode-tui-launch-command` | 2026-06-16 | Atin | 1 | 112 | no | `df535b35a` |
| `origin/feat/fleet-report` | 2026-06-22 | Atin | 0 | 111 | yes | `7b31ef63a` |
| `origin/feat/c11-151-opencode-resume` | 2026-06-28 | Atin | 2 | 71 | no | `d63aff65e` |
| `origin/feat/c11-152-scrape-capture` | 2026-06-28 | Atin | 1 | 72 | no | `00e5801c9` |
| `origin/feat/c11-153-pi-resume` | 2026-06-28 | Atin | 1 | 69 | no | `bcbf83c0a` |
| `origin/feat/c11-154-omp-resume` | 2026-06-28 | Atin | 1 | 68 | no | `39e875908` |
| `origin/chore/cmux-to-c11-socket-env` | 2026-06-29 | Atin | 1 | 56 | no | `a09a85f4b` |
| `origin/fix/relay-cleanup-test-timeout` | 2026-06-29 | Atin | 1 | 44 | no | `5d6221629` |
| `origin/fix/socket-collision-bind-stomp` | 2026-06-29 | Atin | 0 | 54 | yes | `9d68c02e8` |
| `origin/integration/capture-v054-into-main` | 2026-06-29 | Atin | 0 | 45 | yes | `ca6300ace` |
| `origin/release/v0.54.0` | 2026-06-29 | Atin | 0 | 54 | yes | `f2f2ad4e9` |
| `origin/fix/claude-hook-main-thread-flood` | 2026-06-30 | Atin | 3 | 38 | no | `d922e3325` |
| `origin/fix/claude-hook-main-thread-flood-main` | 2026-06-30 | Atin | 0 | 37 | yes | `11140d785` |
| `origin/fix/pi-cc-session-resume` | 2026-06-30 | Atin | 0 | 36 | yes | `514eb159d` |
| `origin/fix/pi-cc-session-resume-v0.55` | 2026-06-30 | Atin | 8 | 38 | no | `fde3d1cb8` |
| `origin/fix/skills-sheet-refires` | 2026-06-30 | Atin | 0 | 37 | yes | `5b431e1b7` |
| `origin/fix/skills-sheet-refires-v0.55` | 2026-06-30 | Atin | 2 | 38 | no | `3d2ad6adf` |
| `origin/release/v0.55.0` | 2026-06-30 | Atin | 12 | 32 | no | `52786fb6d` |
| `origin/release/v0.56.0` | 2026-06-30 | Atin | 1 | 29 | no | `831185595` |
| `origin/overture-orchestrator-rework` | 2026-07-02 | Atin | 0 | 23 | yes | `c676d9050` |
| `origin/chord-family` | 2026-07-06 | Atin | 0 | 14 | yes | `0f08e1ed8` |
| `origin/fast-boot-lazy-orient` | 2026-07-06 | Atin | 1 | 26 | no | `396e19d02` |
| `origin/i18n/model-effort-strings` | 2026-07-06 | Atin | 1 | 9 | no | `b879c6b47` |
| `origin` | 2026-07-07 | dependabot[bot] | 0 | 0 | yes | `36f2a70ce` |
| `origin/main` | 2026-07-07 | dependabot[bot] | 0 | 0 | yes | `36f2a70ce` |
