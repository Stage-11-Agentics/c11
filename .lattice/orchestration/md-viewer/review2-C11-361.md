# Review 2: C11-361 agent CLI and skill, PR #624

Reviewer: agent:grok-md-review-361-g (Grok, cross-family). Read-only.
Head reviewed: `5de1c487722acd26b58ce332f0235c8cdb5feba2` (asserted), diff `origin/main...HEAD` (12 files, +1105). Branched before C11-359 follow-up `fd263426f9`.

Review 1's B1, B2, and N1–N9 stand. This review does not repeat them.

**Verdict: FAIL.** One new blocking finding.

## What I ran

- Atlas debug build, tag `rv-361-g`, head `5de1c487`, compile ok. App: `c11 DEV rv-361-g.app`.
- Atlas host slice, tag `rv-361-g-test`: `MarkdownWebRendererTests`, 9 tests, 0 failures. The other class names in that invocation live in `c11LogicTests`, so the `c11-unit` scheme did not execute them under the `c11Tests/` filter.
- Atlas logic slice, tag `rv-361-g-logic`: `CapabilityFeaturesTests` (4), `MarkdownPanelFontScaleTests` (7), `MarkdownPresentationTests` (13), `MarkdownRendererRetentionPolicyTests` (11), `MarkdownVisibleStateBufferTests` (3). 38 tests, 0 failures.
- `tests/test_cli_markdown_agent.py` against that debug app's bundled CLI. Pass. The six commands send `panel_id` through unchanged, `font --scale 3.1` and `nan` never reach `markdown.font`, and `--watch` prints two NDJSON snapshots.
- Scratch mutations, worktree `/tmp/c11-361-mut`, not this review tree:
  - Removed the six `markdown.*` entries from `socketWorkerV2Methods`. `testMarkdownAgentMethodsRunOnSocketWorkersWithoutInAppFocusIntent` failed: each method resolved to `mainActor` (`CapabilityFeaturesTests.swift:28`). Exit 65.
  - `MarkdownVisibleStateBuffer.publish` appended every change. `testWatchDeduplicatesAndBoundsQueuedChangesToLatestState` failed: the second read was `0.2` (`MarkdownPanelFontScaleTests.swift:127`). Exit 65.
  - Removed the CLI `0.5...3.0` check and rebuilt tag `rv-361-g-mutcli`. The same Python test failed on `font --scale 3.1`, which printed `OK font_scale=3.1`.
- Sandbox guest `c11-sb-rv361g` on Atlas, app `c11 DEV rv-361-g`, socket `/tmp/c11-sandbox-rv361g.sock`. The first slot was held by `c11-sb-md360ui`, so this guest used `--allow-second`. Deleted with `sandbox-down` (`deleted=c11-sb-rv361g`). The second golden image is not on the host, so the display shot is the guest Setup Assistant sheet and is not evidence. The proof is the socket transcript below.
- Owner validation `ev_01M4E2B19R561Z9HYKDTSZZ7V5` claims no reds. Nothing in that claim failed here. The new failure has no test on this branch.

## Invariants

- **(a) Right panel, clear rejection.** Scroll, visible, theme, typeface, font, and open-external must act on the named `--panel` and reject a bad ref with a clear error. **Broken (B3).** A ref the process cannot resolve is carried out on the focused panel.
- **(b) Threading and focus.** The six methods run on the socket worker, take bounded main hops, and are not focus intents. Holds. The worker-set mutation is what turns that test red. These commands did not move in-app focus or the selected workspace in the guest. The failure is the target, not a focus change.
- **(c) `visible --watch` is bounded.** Coalescing holds. Dropping it makes `testWatchDeduplicatesAndBoundsQueuedChangesToLatestState` fail. Review 1's N3–N6 still cover pin, deadline, cached snapshot, and disconnect. No new leak.
- **(d) Evicted or never-shown panels.** No new finding. Review 1 B1 stands. Theme, typeface, and font still answer from the panel model once the panel is the one the caller named.
- **(e) Skill matches the CLI.** Command forms match `c11 markdown --help`. One gap (N11). `references/commands.md` says these commands never fall back to the focused panel. That sentence is the contract. The implementation breaks it (B3). The repair is in the resolver, not in the skill.
- **(f) Capability registration.** Holds. `markdown.agent_cli` version 1 is enabled, and the six methods are advertised only while it is supported. Same `supports()` shape as feed and selection.

## Blocking

**B3. An explicit panel ref the app cannot resolve is executed on the focused panel.**

- Where: `CLI/c11.swift:6094` accepts any `panel:<integer>` with no existence check, and `CLI/c11.swift:6337` forwards that string as `panel_id`. `LegacyWireAliases` copies it onto `surface_id`. `v2MarkdownPanelTarget` (`Sources/SocketHandlers/MarkdownFeedbackHandlers.swift:166`) only rejects a missing or empty ref, then calls `v2ResolveWorkspaceSurface` (`Sources/TerminalController.swift:4896`). `v2UUID` (`TerminalController.swift:3176`) returns nil when `v2ResolveHandleRef` (`TerminalController.swift:2983`) has no entry. The nil branch at `TerminalController.swift:4907` then uses `v2ResolveWorkspace`'s selected-workspace fallback (`TerminalController.swift:3523`) and `focusedPanelId`. `v2RejectUnresolvedTargetRefs` (`TerminalController.swift:3188`) already forbids this for destructive commands. The markdown handlers do not call it.
- A handle that resolves to a UUID, and a UUID that names no panel, take the `not_found` return at `TerminalController.swift:4905`. Only a string that resolves to nothing reaches the focused panel.
- Guest, selected workspace `workspace:2`, focused panel `panel:2` (a terminal):
  - `c11 markdown theme --panel panel:99999 --list` returned `invalid_params: Panel is not a markdown panel` (exit 1).
  - `c11 markdown theme --panel 00000000-0000-4000-8000-000000000099 --list` returned `not_found: Panel not found`.
  - `c11 markdown theme --panel workspace:1 --list` returned `not_found: Panel not found`.
- After `focus-panel --panel panel:6` on `/tmp/C11-361-review2.md` (focused panel stayed `panel:6`, UUID `4CA06752-615C-411A-B7D0-61BFBB0AF46B`, theme `system`):
  - `c11 markdown theme --panel panel:99999 --set dark` returned `applied: true` and `panel_id: 4CA06752-615C-411A-B7D0-61BFBB0AF46B`. `theme --list` on `panel:6` then reported `current: dark`.
  - Without `--json` the same command prints `OK theme=dark` and does not name a panel.
  - `visible --panel panel:99999 --json` reported file `/tmp/C11-361-review2.md`, heading `Alpha`.
  - `scroll --panel panel:99999 --heading Beta` returned `scrolled: true` for that same UUID. `visible` on `panel:6` then reported heading `Beta`.
  - `setTheme` calls `presentation.saveLastUsed` (`Sources/Panels/MarkdownPanel.swift:70`). A panel opened afterwards, `panel:7` on `/tmp/C11-361-review2-next.md`, listed `current: dark`.
- Normal path: an agent keeps a `panel:N` from an earlier session. After restart that ordinal is not in the handle map, and the CLI still forwards it. Scroll, visible, watch, theme, typeface, font, and open-external then read or mutate whichever panel is focused, including the operator's document, and a theme, typeface, or font change also becomes the default for new panels. `visible --watch` uses the same `v2MarkdownPanelTarget` (`MarkdownFeedbackHandlers.swift:387`).
- Fix: if the caller supplied a `panel_id` or `surface_id` and `v2UUID` cannot resolve it, return `not_found` and do not use `focusedPanelId`. `v2RejectUnresolvedTargetRefs` is the existing shape. The focused-panel branch remains for callers that omit the ref. These six commands never omit it.

## Non-blocking

- **N10. Scroll accepts a prefix or substring and returns the first heading that matches.** `scrollToHeading` (`Resources/markdown-viewer/viewer.js:697`) tries exact slug, exact text, `startsWith`, then `includes`. In the guest, `scroll --panel panel:6 --heading Bet` scrolled to `Beta` in a document that also has `Alphabet`. The JSON heading object includes `children`. A short query can land on a different section and flash that one.
- **N11. `SKILL.md` omits panel close as a watch ending.** `skills/c11-markdown/SKILL.md:204` says interrupting the command or closing its output pipe ends `--watch`. `c11 markdown --help` (`CLI/c11.swift:12235`) and `skills/c11-markdown/references/commands.md:82` say the stream ends when the panel closes or the client disconnects.

## Not re-opened

Review 1 B1, B2, and N1–N9. Reader chrome (C11-360) and linked-doc navigation (C11-357).
