# Verification: C11-361 repair, PR #624

Reviewer: agent:grok-md-review-361-g. Read-only.
Head: `c428aefca8a0335287c5d7982dd308210927ee27` (checked out, asserted). Parent `bf5d53c373e0b011d8bdc04385a3598d74294930`. `fd263426f9` is an ancestor. Repair commit `c428aefc` ("fix(markdown): reject stale panel refs and clarify headings"). Owner validation `ev_01M4EB0RJSGZRP8W237XVMCGPS`, handoff `ev_01M4EB12EQY2K4BK4GRRZ83A7Y`.

Scope was B3, N10, and N11. No new discovery pass. Review 1's B1, B2, and N1–N9 were not re-opened.

**Verdict: PASS.**

## What I ran

- Atlas debug app, tag `rv-361-g`, invocation `fb2b51eaffb94507bdaec71a77cfeb92`, head `c428aefc`. Compile ok. App `c11 DEV rv-361-g.app`.
- Atlas host slice, tag `rv-361-g-test`, invocation `2515230c63a34197a81855ad9271bc46`: `testScrollToHeadingPrefersExactAndReportsAmbiguousBroaderMatches` passed (0.174 s) and `testMarkdownSocketRejectsUnresolvedPanelRefsWithoutFallingBack` passed (0.553 s). Executed 2 tests, 0 failures. `** TEST SUCCEEDED **`. An earlier fetch of the same tag died with `No space left on device` (`c989e00b55dd4ccd8099ccb3c8fd4e41`) before the test host started. The retry above is the run that counts.
- Scratch worktree `/tmp/c11-361-mut`, removed after the red runs. The review worktree was not edited.
  - B3: removed the three `v2RejectUnresolvedTargetRefs` calls in the markdown handlers. Atlas tag `rv361g-redb3`, invocation `4ef98b0f572040a9be33253d439ee0c1`, exit 65. `testMarkdownSocketRejectsUnresolvedPanelRefsWithoutFallingBack` failed at `MarkdownWebRendererTests.swift:806`: `panel:99999` theme set returned ok (`Optional(true)`), and the focused panel's theme, typeface, font scale, and last-used defaults changed (`light` / `sans` / `2.2`). `markdown.open` on that ref also split a panel (count 3, expected 2) at line 839.
  - N10: restored those calls and put the old first-match `scrollToHeading` back. Atlas tag `rv361g-redb3`, invocation `66f092e289754e02847b1df64839414a`, exit 65, compile ok. `testScrollToHeadingPrefersExactAndReportsAmbiguousBroaderMatches` failed at line 101: heading `Inst` returned `ok: true` and no `ambiguous` / `total: 3`. `stall` likewise returned ok instead of `total: 4` (line 108).
- Guest `c11-sb-rv361gv` on the second sandbox slot (`c11-sb-rv361v` held the first; `c11-sandbox-golden-b` is still missing, so the display can show Setup Assistant and is not evidence). Socket `/tmp/c11-sandbox-rv361gv.sock`. Deleted afterward (`deleted=c11-sb-rv361gv`).

## B3. An unresolvable panel ref acting on the focused panel

Fix: every markdown handler rejects a present ref that does not name a live window, workspace, area, or panel before resolution. `v2MarkdownPanelTarget` calls `v2RejectUnresolvedTargetRefs` (`MarkdownFeedbackHandlers.swift:326`). Scroll, visible, watch, theme, typeface, font, and open-external all go through that function. `v2MarkdownOpen` (`:748`) and `v2MarkdownGetContent` (`:896`) call it too. `v2RejectUnresolvedTargetRefs` (`TerminalController.swift:3198`) now accepts `fallbackWorkspaceManager` so the socket test, which has no `AppDelegate`, can still tell a live panel from a stale ref.

`v2ResolveWorkspaceSurface` (`TerminalController.swift:4928`) still uses `focusedPanelId` when `v2UUID` returns nil. `markdown.open`'s split source (`MarkdownFeedbackHandlers.swift:846`) still uses that fallback when the ref is absent. An explicit stale `surface_id` is rejected first, so it does not reach either fallback. The owner reported the same hole on non-markdown callers (debug sheet, rail, strip-scroll, hover). That matches the code. It is outside this repair.

Red without the three calls: the socket test above. The stale `panel:99999` theme, typeface, and font writes succeeded and changed the focused panel and the last-used defaults.

Guest, selected workspace `workspace:2`, focused terminal `panel:2`. `theme --list`, `visible`, and `scroll --heading Install` on `panel:99999`, on `00000000-0000-4000-8000-000000000099`, and on `workspace:1` each returned `not_found: Unknown panel_id: …; commands with explicit targets never fall back to the focused target`. `visible --watch` on `panel:99999` returned the same `not_found` and emitted no snapshot.

After opening `/tmp/C11-361-verify.md` as `panel:6` (UUID `2CF52D81-7780-4D23-B4FC-82C6140B688A`, theme `system`, typeface `theme`, font scale `1`) and focusing it: the same three refs on theme set `dark`, typeface set `mono`, font scale `2.2`, visible, and scroll returned `not_found`. `panel:6` stayed `system` / `theme` / `1`, heading path `["Guide"]`. A panel opened afterward, `panel:7`, also listed theme `system`. Workspace stayed `workspace:2`.

## N10. Ambiguous heading matches

Fix: `scrollToHeading` (`Resources/markdown-viewer/viewer.js:695`) keeps a single exact slug, otherwise a single exact text. If several exact matches exist, it returns `ambiguous`. Otherwise one prefix match wins, then one substring match. More than one match at that tier returns `{ok:false, ambiguous:true, total, matches}` capped at 12. `BRIDGE.md`, `skills/c11-markdown/SKILL.md:219`, and `references/commands.md:97` say the same thing.

Red without that function: the WebKit test above. `Inst` and `stall` scrolled to the first hit.

Guest, same document (Install, Installation, Installing the App, Well Installed, Beta, Alphabet):

- `--heading Install` scrolled to `Install`. Path `["Guide", "Install"]`.
- `--heading Inst` returned `ambiguous` and left the path on Install.
- `--heading stall` returned `ambiguous` and left the path on Install.
- `--heading Well` scrolled to `Well Installed`.
- `--heading Bet` scrolled to `Beta`. Alphabet was present. `Bet` is a unique prefix of Beta, so that scroll is the repaired rule.

## N11. The skill names panel close

Fix: `skills/c11-markdown/SKILL.md:215` says `visible --watch` ends when the panel closes, with the example `c11 close-panel --panel panel:8`. `references/commands.md:94` now uses that same example. The CLI help at `CLI/c11.swift:12240` already said the stream ends when the panel closes. This commit did not change that help line. The CLI diff in `c428aefc` is the bare-index guard and the font-scale decimal check, which belong to Review 1.

No test asserts the skill sentence. Removing it leaves the suite the same color. There is no red test to reproduce. In the guest, `visible --watch` on `panel:6` emitted an initial snapshot, `close-panel --panel panel:6` returned ok, and the watch process exited 0.

## Regression

None from these fixes. The two repaired tests pass on `c428aefc`. The guest kept the named panel, the last-used theme, and the selected workspace. A bad ref did not read or write the focused document.
