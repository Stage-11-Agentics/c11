# Validation Plan — C11-175 v1
Source spec: [docs/agent-config-primitive-design.md](../../docs/agent-config-primitive-design.md) · Binding prototype: [docs/design-prototypes/model-picker/](../../docs/design-prototypes/model-picker/) · Date: 2026-07-20

| # | Criterion (ID) | Verification method | Artifact to inspect | Pass condition | runnable_at |
|---|---|---|---|---|---|
| 1 | §2.1 agent-configs.json schema | Read store codec + tests in PR | C11-176 PR | schema_version/configs/default/recent round-trip test exists and passes in CI | pre-merge-static |
| 2 | §3 effectiveDefault | Read resolution fn + unit test | C11-176 PR | `(mode==followRecent && recent!=nil) ? recent : pinned` branch unit-locked | pre-merge-static |
| 3 | §5.6 corrupt-file fallback | Read store load path + test | C11-176 PR | corrupt/missing file → factory seed, never a thrown launch failure | pre-merge-static |
| 4 | §1.4 tri-mode system prompt | Read rendered-command tests | C11-177 PR | append/replace/inherit + replace-empty (`--system-prompt ''`) rendering each asserted | pre-merge-static |
| 5 | §1.4 axis gating | Read injector + test | C11-177 PR | nil systemPromptArg → no injection; hardcoded flag in command wins | pre-merge-static |
| 6 | §2.4 stats consistency | Read sink + tests | C11-178 PR | jsonl append + aggregate bump consistent; windowing (today/30d/all) asserted | pre-merge-static |
| 7 | §4.4 source ranking | Read record() + test | C11-178 PR | launch ≥ sessionHook ≥ scrape; stale scrape never clobbers newer launch | pre-merge-static |
| 8 | §2.4 no-sensitive-text | Grep jsonl writer fields | C11-178 PR | record carries mode/axes only — no prompt or command text fields | pre-merge-static |
| 9 | §1.3 precedence ladder | Read overlay resolution tests | C11-179 PR | per-field `config ?? settings ?? factory`, env per-key merge, asserted per field | pre-merge-static |
| 10 | §1.3 factory regression | Read regression test | C11-179 PR | pure-inherit config produces byte-identical launch command vs pre-change resolver | pre-merge-static |
| 11 | §4.1 rail-1 coverage | Read call sites | C11-179 PR | launchAgentSurface, agent.launch, blueprint each call recordLaunch with correct source | pre-merge-static |
| 12 | §6 CLI surface | Read CLI + tests vs §6 | C11-180 PR | every §6 command incl. --json, --follow-recent, --pin-current, friendly validation | pre-merge-static |
| 13 | Skill-sync hard rule | Read PR diff | C11-180 PR | skills/c11/SKILL.md + references/api.md updated in same PR; sync script run noted | pre-merge-static |
| 14 | Socket threading policy | Read socket handlers | C11-180 PR | config.* off-main; no main-sync in telemetry-shaped paths | pre-merge-static |
| 15 | §5.1 gesture model | Read popover action wiring | C11-181 PR | row click → launch; pin/⌥-click → setDefault without launch | pre-merge-static |
| 16 | Prototype fidelity (tier 1) | Diff popover structure vs prototype | C11-181 PR | shortlist row anatomy, recent+ⓘ, follow toggle, view-all/stats rows, kbd hints present | pre-merge-static |
| 17 | Localization policy | Grep new UI strings | C11-181 + C11-182 PRs | all user-facing strings via String(localized:); no bare literals | pre-merge-static |
| 18 | Typing-latency guardrails | Read tab-bar-adjacent diff | C11-181 PR | nothing added outside isPointerEvent guard; TabItemView Equatable contract intact or == updated | pre-merge-static |
| 19 | Prototype fidelity (tier 2) | Diff editor vs prototype #sheet routes | C11-182 PR | harness grid, per-axis model control, provider-grouped router list, inherit/override chips, blank-slate note, stats view | pre-merge-static |
| 20 | Picker E2E (operator) | Tagged build: open popover, launch a config, pin another, toggle follow-recent, relaunch app → recent persists | tagged build | all gestures per prototype; A tooltip reflects effective default | post-merge-smoke |
| 21 | Blank-slate launch (operator) | Launch Gregorovich config from popover | tagged build | claude starts with `--system-prompt ''` (visible in ps) | post-merge-smoke |
| 22 | Stats truth (operator) | `c11 config stats` + 📊 view after a few launches | tagged build | counts match launches just performed; windows sane | post-merge-smoke |
| 23 | Taste verdict (felt) | Operator eyeballs popover + editor vs prototype | tagged build | operator clears needs_human on C11-181/182 | post-merge-smoke |
| 24 | Cost-column degradation | Run picker with no token-cost catalog present | tagged build | cost column absent; nothing blocks | post-merge-smoke |
