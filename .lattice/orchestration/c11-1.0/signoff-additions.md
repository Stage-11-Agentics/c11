# C11-292 sign-off additions (validator, 2026-10-02)

Human-visible steps routed from the c11 1.0 validation pass. Run on a fresh tagged merged-main build (QA launch). Each step: setup, action, expected result, ticket.

1. **Setup:** Fresh tagged merged-main build with a terminal tab in a normal window (QA launch, neutral prompt); print the word SELECTIONFIXTURE on a line
   **Action:** Double-click the word with the mouse, then run `c11 read-selection --workspace <ws> --tab <t> --json` from another tab; click empty space to clear and run it again; repeat the select/read/clear cycle several times
   **Expected:** First call shows has_selection true, kind terminal, text SELECTIONFIXTURE and base64 that decodes to the same text; after clearing, exit 0 with has_selection false and empty text; app stays up
   **Ticket:** C11-282

2. **Setup:** Same build; print more than 1 MiB of numbered text in a terminal with large scrollback, then select all of it with the mouse (or shift-click from the top of scrollback)
   **Action:** Run `c11 read-selection --workspace <ws> --tab <t> --json`
   **Expected:** Command returns promptly with has_selection true, truncated true, text valid UTF-8 and no longer than 1 MiB, base64 decodes to the same text; window stays responsive
   **Ticket:** C11-282

3. **Setup:** Fresh tagged merged-main build with two windows A and B, each with a terminal printing a distinct marker; click A so it is the visible key window
   **Action:** Run from A's terminal `c11 --window <B> read-screen --tab <tab in B>`, then `c11 --window not-a-window read-screen`, then `c11 --window <B> send --tab <tab in A> hi`
   **Expected:** First returns B's marker and A remains the key window; second exits non-zero naming not-a-window with A still key; third errors not_found and nothing typed appears in A or B
   **Ticket:** C11-283

4. **Setup:** Same two windows, A key
   **Action:** Run `c11 focus-window --window <B>`
   **Expected:** B comes to the front and becomes key (focus-window still focuses; only this command raises)
   **Ticket:** C11-283

5. **Setup:** Tagged build running with a normal second c11 window open; Finder frontmost (activate Finder and confirm its PID is frontmost)
   **Action:** Run `c11 resize-window --window <second-window-id> 1200 800`; compare frontmost PID and c11 key window before and after
   **Expected:** Finder stays frontmost, key identity unchanged, second window top-left unchanged and size 1200x800 (or clamped=true matching applied)
   **Ticket:** C11-286

6. **Setup:** Tagged build frontmost, first c11 window key, second window open
   **Action:** Run `c11 resize-window --window <second-window-id> 1200 800`; compare frontmost PID and key window before and after
   **Expected:** Frontmost PID and first-window key unchanged; second window resized with top-left unchanged
   **Ticket:** C11-286

7. **Setup:** Two displays, tagged build, disposable window dragged near an edge of the non-main display
   **Action:** Run `c11 resize-window --window <id> 99999 99999` and note screen.display_id and visible_frame in the JSON
   **Expected:** clamped=true, top-left unchanged, display_id is the non-main display, applied size equals that display's visible frame (record unproven if only one display); restore or close the window after
   **Ticket:** C11-286

8. **Setup:** Tagged build, any c11 window
   **Action:** Run `c11 resize-window --window <id> 1000 700` and watch the socket diagnostic log (C11 debug event log)
   **Expected:** Log shows the request handled by the worker route, then one main-thread frame set; response reports requested, applied, clamped
   **Ticket:** C11-286

9. **Setup:** Merged tagged build with the app frontmost and a second app available; no browser profile named smoke-b3
   **Action:** Run `c11 browser profiles add smoke-b3`, `profiles rename smoke-b3 smoke-b3b`, `browser open https://example.com --profile smoke-b3b`, then `profiles delete smoke-b3b` (no --yes) and `delete --yes smoke-b3b` while the tab is open, watching the screen throughout
   **Expected:** Key window and frontmost app never change, no sheet or dialog appears, delete is refused while the tab is open, the tab visibly loads in the new profile
   **Ticket:** C11-289

10. **Setup:** Same build; a cookie set by visiting a site in smoke-b3b and a different cookie in the default profile
   **Action:** Close the tab, run `c11 browser profiles clear --yes smoke-b3b`, reopen with `--profile smoke-b3b`, then open the same site with no `--profile`
   **Expected:** The smoke-b3b cookie is gone, the default-profile cookie remains, then `delete --yes smoke-b3b` removes the profile from `list --json`
   **Ticket:** C11-289

11. **Setup:** Tagged build with a saved session of two windows, four workspaces, several terminals
   **Action:** Quit through the app menu, relaunch, and look at both windows
   **Expected:** Same workspaces and tabs return, both windows readable and the key window is correct, `c11 tree` shows the full tree with no not_ready after the window appears
   **Ticket:** C11-297

12. **Setup:** Same build, shell-integration terminals restored
   **Action:** Run `c11 ping` and `c11 tree` repeatedly during and just after startup
   **Expected:** No crash, any early reply is a typed not_ready that clears within seconds, no command lands on an unrelated tab
   **Ticket:** C11-297

13. **Setup:** Tagged build, a folder in Finder
   **Action:** Run the Services entry that opens a folder in c11, once with the app's own bundle selected and once with a real folder
   **Expected:** The own-bundle request opens nothing and does not cancel the pending restore; the real folder opens one new window
   **Ticket:** C11-297

14. **Setup:** Tagged build started with the control socket unable to bind (invalid socket path)
   **Action:** Open the command palette, run Restart CLI Listener after making the path bindable; close the original window first and open a replacement
   **Expected:** No restore while the listener is down; after recovery the saved graph appears in the replacement window and `c11 tree` succeeds
   **Ticket:** C11-297

15. **Setup:** Release build with the restore policy set to ask
   **Action:** Choose Resume, then repeat with Skip, then close the picker's parent window without answering, then repeat each with the listener failing after the picker appears
   **Expected:** Resume restores the saved graph, Skip starts fresh, an unanswered parent-close leaves the saved session intact, and a new session still saves and restores
   **Ticket:** C11-297

16. **Setup:** Two c11 windows (A and B), each with a workspace; in B, a tab in B's currently selected workspace holds a flagged open question (raise a flag and a real or synthetic question on it), and a second workspace in B that is not selected holds another flagged tab; in A, type unsent text at a terminal prompt; bring a non-c11 app frontmost
   **Action:** From a shell, run `c11 feed list --json`, then `c11 feed open <tab handle in B>`, then `c11 feed open <flagged tab in B's unselected workspace>`, then `c11 feed open <unknown tab handle>`
   **Expected:** The B tab becomes selected in B; opening the tab in B's unselected workspace returns `workspace_switch_blocked` and B's visible workspace does not change (C11-323); A's unsent text is unchanged and nothing is sent anywhere; `list` and `watch` alone never move focus; the unknown handle reports unavailable and selection does not change; the Feed text is readable
   **Ticket:** C11-264

17. **Setup:** Real Claude Code agent in one tab, `c11 feed watch` running in another
   **Action:** Have the agent ask a question (AskUserQuestion or a permission prompt) and then answer it in the agent tab
   **Expected:** Watch shows the typed row on open (ask.opened) and drops it after the answer (ask.closed); a flag raised on the same tab stays visible throughout
   **Ticket:** C11-264

18. **Setup:** Fresh sign-off build with an isolated temporary home containing an old marked plugin, an edited plugin, and an unrelated file
   **Action:** Open Settings > Agent Skills, then Install, Update and Remove the OpenCode skills
   **Expected:** Skill copies change as requested; no plugins directory appears when absent; existing plugin, sidecar and unrelated files stay byte-identical; nothing is deleted automatically
   **Ticket:** C11-269

19. **Setup:** Fresh sign-off build with a Notification Command configured to dump its environment to a file
   **Action:** Trigger a routine Claude notice and then raise a flag on a tab, from another tab
   **Expected:** The command receives two invocations with workspace, tab and kind fields; the originating tab clears as documented and an unknown tab is preserved
   **Ticket:** C11-269

20. **Setup:** Final-head tagged build launched with the app language set to Japanese (`-AppleLanguages "(ja)"`)
   **Action:** Open the menu-bar extra attention menu, the Feed, and Settings > Agent Skills
   **Expected:** New 1.0 strings (attention counts, Feed rows, skill install labels) show in Japanese, nothing truncated or overlapping, menus dismiss cleanly
   **Ticket:** C11-291 (ticket stays open for the string-freeze refresh)

21. **Setup:** Tagged build of main running with the QA fresh policy; Claude in normal permission mode in a synthetic working directory; record `claude --version`
   **Action:** Ask Claude to run a Bash command that needs native approval; leave the permission dialog untouched for 2 seconds, then approve it in Claude's own UI
   **Expected:** Claude's permission dialog stays visible and c11 never answers it; the command runs only after your approval; the tab's mark shows waiting while the dialog is open and clears after approval
   **Ticket:** C11-274

22. **Setup:** Same build; run Claude once in normal mode and once in bypass mode; record the Claude version
   **Action:** Provoke an AskUserQuestion and an ExitPlanMode in each mode, then answer or approve each once
   **Expected:** The tab shows the blocked mark before you answer, clears on answer, and ends idle/completed after Stop; a Stop while a question is open keeps the mark blocked
   **Ticket:** C11-274

23. **Setup:** Same build; two Claude tabs, A and B
   **Action:** Hold tab A on an open question, run a Bash tool in tab B, spawn and finish a subagent in A, trigger a compaction, and (if the provider supports it) a failed turn
   **Expected:** Tab A stays waiting while B runs; the subagent finishing does not idle the parent; compaction does not mark completion; a failed turn shows error evidence
   **Ticket:** C11-274

24. **Setup:** Tagged build of main with several Claude tabs running hook-heavy turns at once (tool calls, questions, subagents)
   **Action:** Type steadily in a plain terminal tab in the same window for about a minute while they run
   **Expected:** Every keystroke appears without visible lag or dropped glyphs, marks keep updating, the window stays readable; record the observation (no numeric verdict, the measured baseline stays with C11-270)
   **Ticket:** C11-274

25. **Setup:** Tagged build of main launched with the QA fresh policy; Codex 0.159.3 (record `codex --version`) started from a tagged-build terminal
   **Action:** Run one short Codex turn and let it finish
   **Expected:** The tab ends idle/completed; the Waiting Agent mark appears while the turn runs and is readable; status shows degraded hook coverage with a live connection
   **Ticket:** C11-275

26. **Setup:** Same build and Codex tab, exact current root
   **Action:** Fire the Codex child callback, then the matching root completion, then the same root completion a second time
   **Expected:** The child callback leaves the root state and unread count unchanged; the root completion counts once; the repeat adds no second completion or unread
   **Ticket:** C11-275

27. **Setup:** Tagged build of main launched with the QA fresh policy; Codex in a synthetic workspace (record `codex --version`)
   **Action:** Complete two benign Codex turns, then start a third and press Escape in the Codex UI
   **Expected:** The tab ends idle/completed after each turn and idle/interrupted after Escape; the tab is never marked blocked; no stale mark remains after the next turn
   **Ticket:** C11-276

28. **Setup:** Same build; a primary Grok session (record the Grok client version)
   **Action:** Complete one benign Grok turn
   **Expected:** One start and one completion appear for the turn; no interruption and no blocked state appears while the session is quiet
   **Ticket:** C11-276

29. **Setup:** Same build, after the Codex and Grok runs
   **Action:** Inspect the stored journal rows for those sessions and then dismiss the tagged window with synthesized input
   **Expected:** No prompt, output, tool or chat text appears in the stored rows; provenance shows transcript source; the window dismisses cleanly
   **Ticket:** C11-276

30. **Setup:** Tagged build of main launched with the QA fresh policy and a journal with at least several thousand rows (a few hours of agent activity)
   **Action:** In one terminal type continuously while a second runs the journal query and a full NDJSON export
   **Expected:** Typing in the first terminal stays smooth with no visible stall; the export finishes and the report shows its retained coverage window
   **Ticket:** C11-277

31. **Setup:** Same build and journal
   **Action:** Run the journal clear while the app is running, then again with the app closed
   **Expected:** Both clears finish; the high-water mark and coverage floor stay consistent; the ready spool drains; a following query reports reduced coverage instead of silent zeros
   **Ticket:** C11-277

32. **Setup:** Tagged build of main launched with the QA fresh policy; Claude and Codex both installed (record `claude --version` and `codex --version`)
   **Action:** In a tagged-build terminal start Claude with an argument, then start Codex with an argument
   **Expected:** Each agent starts once with its arguments intact and no wrapper loop or double launch; an agent started inside the other still starts normally
   **Ticket:** C11-311 (ticket stays open)

33. **Setup:** Same build; two workspaces with four terminals each running a visible heartbeat
   **Action:** Save the session, restore it with the same workspace IDs, and repeat ten times while the terminals print output
   **Expected:** Old terminals exit, new terminals are usable and show output, layout, titles and selection survive, no blank workspace flashes, and an empty snapshot gives one usable workspace
   **Ticket:** C11-311 (ticket stays open)

34. **Setup:** Same build; a browser surface on a slow page (a page whose snapshot takes about 2 seconds)
   **Action:** Run a browser snapshot while typing in another terminal and listing workspaces; try a never-opened browser surface
   **Expected:** The workspace list answers within 1 second; typing stays smooth; app focus does not move; the never-opened browser reports no document promptly
   **Ticket:** C11-311 (ticket stays open)

35. **Setup:** Tagged merged-main build (main at or after 75aec1d345) on Atlas, per docs/groups-signoff.md "Preconditions" (identity block recorded, tagged socket only, QA launch)
   **Action:** Run the steps in docs/groups-signoff.md by reference, not copied here: (a) "Automated socket chapters" via scripts/groups-signoff.sh, which runs the tests_v2/test_workspace_groups_scale.py oracle on the tagged app; (b) A10 with the event stream observed; (c) A11 as a graceful quit with synthesized dismissal; (d) fresh reprovision, then "Independent computer-use chapters C1-C6", including C4 omnibar to terminal focus; (e) H1-H3 in the "Operator block"
   **Expected:** The outcomes stated in that document: A1-A13 PASS, A10 event observed, A11 termination recorded graceful (not forced-restore), C1-C6 each pass with evidence. H1-H3 are filled by Atin only. AC5 performance is not part of this step; it runs with the C11-270 soak
   **Ticket:** C11-261

36. **Setup:** Disposable macOS guest (never a real user's profiles or the operator's Mac), packaged c11 build from main at or after ea24ef5876, synthetic data from `scripts/c11-288-seed-import-fixtures.py` (writes under /tmp only) and its loopback server on 127.0.0.1; Chrome and Safari installed in the guest; in each, visit `http://127.0.0.1:<port>/c11-288` once and quit the browser through its menu
   **Action:** In c11, create fresh profiles `chrome-live` and `safari-live` from the profile menu. Browser menu > Import Browser Data > Google Chrome, destination `chrome-live`, History only, domain filter `127.0.0.1`. Repeat for Safari into `safari-live`. Then switch to each profile and open History (docs/smoke/c11-288-browser-import.md steps 3-6)
   **Expected:** Each import reports 1 history entry, 0 cookies, no warning (Safari in particular shows no `no such column` warning). Each profile's History lists the loopback URL with its page title
   **Ticket:** C11-288

37. **Setup:** Same guest and build
   **Action:** Import Browser Data > Safari with Cookies selected, into `safari-live`
   **Expected:** The wizard shows the existing `Cookies.binarycookies` warning, history still imports, and c11 does not crash
   **Ticket:** C11-288

38. **Setup:** Same guest and build; the seeder's synthetic Chrome profile (1 plaintext and 1 `v10`-encrypted loopback cookie, plus 1 history row)
   **Action:** Import Browser Data > Google Chrome with Cookies and History selected into a fresh profile `chrome-deny`; when the macOS Keychain prompt for Chrome Safe Storage appears, click Cancel
   **Expected:** The Keychain prompt appears before any cookie is read; after Cancel the encrypted cookie is not imported (reported skipped), history still imports, and the result shows a Safe Storage warning naming the cancel; c11 stays up
   **Ticket:** C11-288

39. **Setup:** Same guest and build; the seeder's synthetic Chrome profile (its plaintext `c11_288` cookie is the loopback sign-in); loopback server running (`--serve`)
   **Action:** Import it with Cookies selected into a fresh profile `chrome-cookie` (click Allow if the Keychain prompt appears). Open `http://127.0.0.1:<port>/c11-288` in `chrome-cookie`, then open the same URL in a second fresh profile `other`
   **Expected:** The page shows SIGNED IN in `chrome-cookie` and SIGNED OUT in `other` (the server log records only the boolean); the imported cookie is not visible in `other`
   **Ticket:** C11-288

40. **Setup:** Same guest; install Arc if the guest allows it, visit the loopback URL in Arc once, quit Arc
   **Action:** Import Browser Data > Arc into a fresh profile `arc-live`, History only; open History in `arc-live`. If Arc cannot be installed, record that and the detector path `$HOME/Library/Application Support/Arc`
   **Expected:** 1 history entry with the loopback URL and title, no warning; or a recorded written blocker (Arc absent), which already satisfies acceptance criterion 2
   **Ticket:** C11-288

41. **Setup:** Same guest and build after the steps above
   **Action:** Quit c11 through its menu and confirm; then list processes; delete the guest
   **Expected:** No c11 process remains; the guest is deleted; no source browser database changed (source hashes match the pre-import values)
   **Ticket:** C11-288

42. **Setup:** Tagged build of main at or after 9cd4178826 (QA launch), real keyboard and mouse; one area holding a browser tab next to a second area; drag the divider until the second area collapses to about one point
   **Action:** Press the mouse on the collapsed divider and drag it open; then click and scroll inside the browser page (notes/c11-253-host-test-triage.md scenario 9)
   **Expected:** The divider takes the gesture and the collapsed area reopens; ordinary browser content still receives clicks and scrolling
   **Ticket:** C11-253

43. **Setup:** Tagged build of main at or after 9cd4178826 (QA launch), real keyboard and mouse; same layout with a terminal tab instead of a browser
   **Action:** Press the mouse on the collapsed divider and drag it open; then click into the terminal and type `echo ok` (triage scenario 10)
   **Expected:** The divider takes the gesture and the area reopens; the terminal still takes focus and input
   **Ticket:** C11-253

44. **Setup:** Tagged build of main at or after 9cd4178826 (QA launch), real keyboard and mouse; a US keyboard layout and a Korean (2-Set) input source enabled; a plain terminal tab
   **Action:** Type Shift+Backquote; type `hello world` then Option+Delete; switch to Korean, type `한` and press Return
   **Expected:** A literal `~` appears (not Escape); Option+Delete removes the word `world`; the Korean syllable commits and Return submits the line exactly once
   **Ticket:** C11-253

45. **Setup:** Tagged build of main at or after 9cd4178826 (QA launch), real keyboard and mouse; one workspace split into two terminal areas, the left one active
   **Action:** Click into the right terminal; then click back into the left one and type; repeat a few times
   **Expected:** The active-split highlight and the terminal that receives typing always agree; no keystroke lands in the inactive split
   **Ticket:** C11-253

46. **Setup:** Tagged build of main at or after dcbe3b261f (picks up Bonsplit bb8a38dac7), QA fresh, Tab Layout = Tabs, English UI. Split one workspace into two areas; open tabs in the front area until its strip overflows. Run `defaults write `com.stage11.c11.debug.<tag>` (the tag's dashes become dots) c11.tabRailTip.forceOffer -bool true`, then change tabs once
   **Action:** Look at the front area's count cell; then click the count cell number (not Show tab list); close the tab sheet; run `defaults read `com.stage11.c11.debug.<tag>` (the tag's dashes become dots)` for the `c11.tabRailTip.*` keys
   **Expected:** The tip appears under the front area's count cell. Clicking the number opens that area's tab sheet; closing it shows the "that list is the number" return tip. `lastOffered` holds only today's single stamp and there is no `dismissed` key
   **Ticket:** C11-249

47. **Setup:** Same build and layout; force the tip again (forceOffer write plus a tab change)
   **Action:** Click Try Rail and watch the popover as the bar changes
   **Expected:** Tab Layout becomes Rail; the front area's rail is open; the other area is on Rail with its rail closed; the tip reads "This area's tab list stays open on the left. Undo puts Tabs back."; the popover sits under the new rail bar's count cell at once, without needing a resize (no detached or vanished tip)
   **Ticket:** C11-249

48. **Setup:** Same build, tip from the previous step still showing
   **Action:** Click Undo. Then set Tab Layout to Rail in Settings > General > Tabs & Areas, and let the session autosave
   **Expected:** Undo returns to Tabs with no rail out. After picking Rail, the previously previewed area's rail is closed, and the saved session snapshot for that area has no `railOpen`
   **Ticket:** C11-249

49. **Setup:** Same build; set Tab Layout back to Tabs in Settings; force a fresh offer (forceOffer write plus a tab change, which is required because Undo keeps the 30-day wait)
   **Action:** With the tip showing, drag the window and the area divider wider and narrower
   **Expected:** The tip reappears under the live count cell and follows it through every resize; it never points at an empty or stale position. Quit the tagged app and delete the `forceOffer` key afterward
   **Ticket:** C11-249

50. **Setup:** Tagged build of main at or after f7ac4fc1ea, QA fresh; a workspace split into two terminal areas, no `split-divider-color` set
   **Action:** Look at the divider with the default c11 theme in Light and Dark, then set a custom Ghostty `background` color (for example `#808080`) and reload the config
   **Expected:** The divider stays visible in every case as a slightly darker line than the background, never missing or black; no error in the config reload. (Regression smoke only; the fixed grayscale input is not reachable from shipped config)
   **Ticket:** C11-311 B083 (ticket stays open)

51. **Setup:** Tagged build of main at or after 8cfd73f8e4, QA fresh; open a second c11 window with a terminal running a long-lived command (for example `sleep 600`) so closing it asks for confirmation; note its window id from `c11 tree --all`
   **Action:** Click the second window's red close button so the close sheet appears. From another window run `c11 rpc window.close '{"window_id":"<id>"}'` and `c11 close-window --window <id>`. Then click Cancel on the sheet, stop the command, and run the same `window.close` again
   **Expected:** Both socket closes return invalid_state "Window has an attached sheet"; the window and its sheet stay. Cancel dismisses the sheet and keeps the window. With no sheet attached, `window.close` closes the window normally
   **Ticket:** C11-250

52. **Setup:** Same build; in a terminal tab run `sleep 600`, then press Cmd+W so the in-area close confirm card (Confirm / Cancel) appears; do not touch the arrow keys yet
   **Action:** Look at which button is highlighted, then press Return. Press Cmd+W again to bring the card back, press Right/Left arrow to move the highlight to Confirm and back, and press Return on each choice in turn
   **Expected:** With no selection Cancel is highlighted and Return cancels (highlight and action agree). The arrow keys move the highlight between the buttons and Return activates exactly the highlighted one
   **Ticket:** C11-250

53. **Setup:** Tagged build of main at or after 37fbd0ecbf in an isolated Atlas guest (`scripts/remote-build.sh --tag <tag>`, then `C11_SANDBOX_HOST=local scripts/sandbox-up.sh` on Atlas; nothing uploaded from Hyperion). Enable the turn clock on the tag domain: `defaults write com.stage11.c11.debug.<tag> c11.tabSheet.clocks -string "active,turn,launched"`, then relaunch
   **Action:** Run the restart-clock scenario exactly as written in C11-231 comment ev_01M3ZF5486FMV5MTK8QMRQ8RJD, steps 1-7 (it supersedes earlier versions). In order: session and turn (record T0); a duplicate turn-start while working; then the ask; baseline capture after all setup appends (event count, S0, T0, O0) and two tab-sheet reads 60 s apart; then `conversation.clear`, `session.save`, SIGKILL of the exact tagged process, relaunch with `C11_QA_LAUNCH=resume`, and exact-owner reattach by `conversation.push`, with no provider events after the baseline; finally two restored tab-sheet reads 60 s apart
   **Expected:** As the comment states. T0 is unchanged by the duplicate turn-start. Blocked state age equals now - S0 and grows. Turn duration equals O0 - T0 and stays frozen across both read pairs and the downtime. Before reattach, the candidate shows `historical_candidate` / `unconfirmed` / `since` = S0 (no `turn_started_at` on the candidate). After reattach, the row shows `turn_started_at` T0, `since` S0, `unconfirmed`, the same event count and the same O0. The sheet shows the Unconfirmed qualifier
   **Ticket:** C11-231

54. **Setup:** Isolated Atlas guest with Claude Code 2.1.287 and credentials, tagged build of main at or after 37fbd0ecbf, synthetic content only
   **Action:** Run the pinned bypass AskUserQuestion picker fixture (C11-231 comment ev_01M3ZF5486FMV5MTK8QMRQ8RJD, step P1). Watch which key navigates and which commits, and count `operator_response` rows for each
   **Expected:** Navigation records 0 rows. The commit key is identified on screen. Only after this may `AgentRoster.pickerCommitKeyCode` be set, and that change needs its own once-per-ask test through the production key path. Until then, picker response coverage stays unsupported, as documented
   **Ticket:** C11-231

55. **Setup:** Tagged build of main at or after 4994d7fce3 in an isolated Atlas guest (`C11_SANDBOX_HOST=local scripts/sandbox-up.sh`)
   **Action:** `C11_SANDBOX_HOST=local scripts/sandbox-tests-v2.sh <run> tests_v2/test_cli_sidebar_metadata_commands.py`, then `sandbox-down.sh`
   **Expected:** passed=1 failed=0; guest deleted afterward
   **Ticket:** C11-251

56. **Setup:** Same tagged build with two workspaces, A selected (on screen) and B not. In A, from inside c11, set `c11 set-status sentinel keep --workspace <A>`, `c11 log --workspace <A> -- keep-log` and a progress value. Then open a bare shell outside c11 (no `C11_WORKSPACE_ID`) and point it at the tagged socket with `C11_SOCKET_PATH`
   **Action:** From that shell run, with no target: `c11 clear-status sentinel`, `c11 clear-progress`, `c11 clear-log`, `c11 list-status`, `c11 list-log`, `c11 sidebar-state`. Then run `c11 clear-status sentinel --workspace <B>` and `c11 list-status --workspace <A>`
   **Expected:** Each targetless command exits non-zero and names the missing target (`--workspace` or `C11_WORKSPACE_ID`). Workspace A's sidebar still shows the sentinel status, log line and progress on screen. The explicit-target commands act only on the named workspace
   **Ticket:** C11-251

57. **Setup:** Tagged build of main at or after 32bb08b8ec, QA fresh; one window with three workspaces W1 (selected), W2 and W3, each with a terminal
   **Action:** As the operator: press Cmd+P and pick W2; click W3 in the sidebar; use the keyboard next/previous workspace shortcuts; trigger the attention jump on a flagged tab in another workspace
   **Expected:** Each operator path switches the visible workspace as before, with no error or delay
   **Ticket:** C11-323 (regression smoke; ticket already done)

58. **Setup:** Same build, W1 selected and visible; from a terminal inside W1 note the W2 and W3 refs from `c11 tree --no-layout`
   **Action:** Run `c11 select-workspace --workspace <W2>`, `c11 next-window`, `c11 previous-window`, `c11 history back` (after visiting W2 and returning), and `c11 focus-tab --workspace <W3> --tab <tab in W3>`; then `c11 send --workspace <W3> --tab <tab in W3> "echo bg-ok"`
   **Expected:** The first four return `workspace_switch_blocked` and W1 stays visible. `focus-tab` succeeds without showing W3 (W3's focused tab changes in the background). The background `send` delivers: switching to W3 by hand shows `bg-ok`. c11 is never activated or raised by any of these
   **Ticket:** C11-323 (regression smoke; ticket already done)

59. **Setup:** Tagged build of main at or after 82d74f3370, built with the GhosttyKit for ghostty e6999ae7 (checksum already pinned), QA fresh. Open a fresh terminal tab T1 at an empty prompt
   **Action:** From another tab: `c11 input-state --tab <T1>`, then `c11 send --tab <T1> "echo send-ok" && c11 send-key --tab <T1> enter`
   **Expected:** `input-state` reports no prompt text. The send succeeds and T1 prints `send-ok`
   **Ticket:** C11-267 (regression smoke; ticket already done)

60. **Setup:** Same build; in tab T2 type `draft-in-progress` at the prompt without pressing Return
   **Action:** From another tab: `c11 input-state --tab <T2>`, then `c11 send --tab <T2> "echo should-not-appear"`; check the exit code and look at T2
   **Expected:** `input-state` reports the draft. `send` exits non-zero with `input_guard_refused`, and nothing is typed: T2 still shows exactly `draft-in-progress` with the cursor where it was. Optionally, `--allow-unguarded` sends anyway, which shows the override is explicit
   **Ticket:** C11-267 (regression smoke; ticket already done)

61. **Setup:** Same build; a Claude Code tab showing a question or plan-review dialog (or the synthetic equivalent from the C11-267 tests)
   **Action:** From another tab: `c11 send --tab <that tab> "1"`
   **Expected:** Exits non-zero with `input_guard_refused`; the dialog is unchanged and no option is chosen
   **Ticket:** C11-267 (regression smoke; ticket already done)

62. **Setup:** Tagged build of main at or after 30a168921d, QA fresh; two c11 windows. In window W2, a single area with one terminal tab running `sleep 600`; note the window count and tab ids with `c11 tree --all`
   **Action:** In W2 press Cmd+W so the in-area close confirm card appears, and leave it unanswered. Close W2 with its red close button (confirm the window close if asked). If the card is still reachable, answer Confirm. Then run `c11 tree --all` and look at the screen for a few seconds
   **Expected:** W2 is gone. No new window opens, no terminal appears in W1 or anywhere else, and `c11 tree --all` shows only W1 with its original tabs. The app stays up
   **Ticket:** C11-311 B069 (ticket stays open)

63. **Setup:** Same build; one window whose only area holds a single idle terminal tab, plus a second area or window to fall back to
   **Action:** Close that last tab normally (Cmd+W or the tab close button)
   **Expected:** The tab closes as before (the area or window follows the existing last-tab behavior); nothing is refused and no stray terminal appears
   **Ticket:** C11-311 B069 (ticket stays open)

64. **Setup:** Tagged build of main at or after a2418ebc64, QA fresh (synthetic data only)
   **Action:** Run each `c11 agents` and `c11 journal` command example in `skills/c11/references/journal.md` as written, then `c11 journal clear --yes` on the tagged journal only
   **Expected:** Each output matches the schema documented next to its example: `agents --json` has `schema_version` 1 with `coverage`, `live_identity`, `restore_candidates` and `tabs`; query output has the documented analytics keys with unavailable or null values where coverage is missing; export rows are `manifest`, `gap`, `event` and `coverage_summary`, with no prompt, command, argument, output or answer fields. (The owner already ran these at 7a942d0222, whose examples are identical to merged main; this is the merged-main recheck)
   **Ticket:** C11-278

65. **Setup:** Tagged build of main at or after 3c00ea7637 in an isolated guest, QA fresh. Make a directory with spaces and an apostrophe, for example `/tmp/b248 it's here`. Put fake `claude` and `codex` executables first on PATH that write their argv and `PWD` to a file. Give one Claude tab and one Codex tab a recorded session (synthetic session id) whose working directory is that path, then start their shells in a different, drifted directory such as `/tmp`
   **Action:** Resume each tab (relaunch with `C11_QA_LAUNCH=resume`, or the resume path the B248 test uses). Read the fake executables' capture files
   **Expected:** Each resume command is `cd '<recorded path>' && <provider> resume ...`, with the path quoted correctly. Each fake executable runs once, with the stored session id, and records `PWD` as the recorded directory, not `/tmp`
   **Ticket:** C11-311 B248 (ticket stays open)

66. **Setup:** Same build; recorded working directory set to a path that does not exist (for both Claude and Codex)
   **Action:** Resume both tabs
   **Expected:** The `cd` fails visibly in each tab and neither fake executable runs (no capture file is written); c11 stays up
   **Ticket:** C11-311 B248 (ticket stays open)

67. **Setup:** Same build; a plain shell tab with no recorded session
   **Action:** Relaunch with resume and open the tab
   **Expected:** The tab's startup command and working directory are unchanged (no `cd` prefix is added). Delete the guest and the temporary fixtures afterward
   **Ticket:** C11-311 B248 (ticket stays open)

68. **Setup:** Tagged build of main at or after 24dbf1afb1, QA fresh, English UI. In one workspace, three terminal tabs: tab X with a flag (`c11 raise-flag --tab <X> "synthetic flag"`), and tabs Y and Z each with an open synthetic ask: one with a short prompt, one with a multiline or missing prompt and a very long tab name. Type some unsent text in a fourth terminal T and keep focus there
   **Action:** Press Cmd+I. Use Down/Up. While the view is open, raise a flag on another tab from a shell; then resolve the highlighted ask; then close one listed tab. Press Tab and Shift-Tab. Finally press Esc and type a letter
   **Expected:** The 520x420 Feed popover opens flag-first, with 64 pt rows, counts that match `c11 feed list`, and the hint bar visible. Arrows move the highlight without opening anything. A new flag appears without moving the highlight. Resolving the highlighted ask moves the highlight to a neighbor without opening it. The closed tab's row shows "That tab is unavailable" in the status row with no focus change. Tab and Shift-Tab switch Asks and Turns with no frame change and nothing opened. Long and multiline content never changes a row height. Esc closes the view, and the letter lands in T after its existing draft
   **Ticket:** C11-266

69. **Setup:** Same build; the flagged tab is in workspace W2 while W1 is selected
   **Action:** Open Cmd+I and highlight the W2 row. Send the v1 socket command `simulate_shortcut return` to the tagged socket (as `tests_v2/feed_quick_view_workspace_switch_probe.py` does), then press the real Return key
   **Expected:** The socket Return is refused (`workspace_switch_blocked`): W1 stays visible and the view stays open. The real Return switches to W2 and lands on the flagged tab, and the view closes
   **Ticket:** C11-266

70. **Setup:** Tagged build of main at or after 24dbf1afb1 in an isolated Atlas guest from the primary golden image (`C11_SANDBOX_HOST=local scripts/sandbox-up.sh`; decline c11's own notifications prompt with Not Now if it appears)
   **Action:** Run `tests_v2/feed_quick_view_probe.py`, `tests_v2/feed_quick_view_keyboard_probe.py` and `tests_v2/feed_quick_view_workspace_switch_probe.py` through the sandbox runner. Inspect their screenshots, then `sandbox-down.sh`
   **Expected:** All three PASS. In the screenshots, every row is the same 64 pt height and the filter, hint and status frames do not move between frames. After each Tab or Shift-Tab, the active filter (Asks or Turns) shows the selected fill, and its focus ring, when drawn, is on that same segment, never the inactive one (an absent ring is the known cosmetic residual). The workspace-switch probe shows the socket Return refused and the operator Return switching. Guest deleted afterward
   **Ticket:** C11-266

71. **Setup:** Tagged build of main at or after 6f62330f54 in an isolated Atlas guest. A fake `claude` (or `codex`) first on PATH that appends each invocation's argv to a log. A saved session in which tab R holds one synthetic suspended Claude session S, and no other surface is attributed to S
   **Action:** Relaunch with `C11_QA_LAUNCH=resume` so c11 creates the eligible deferred resume plan for R and starts its submission delay. During the delay, before submission, start a second c11-attributed agent for the same provider and session S on another tab and confirm with `c11 get-metadata` that it is attributed to S. Let the deadline pass and read the fake executable's log and R's screen
   **Expected:** No resume command is submitted into R while the second writer for S stays live: the log shows only the second writer's own launch, and R's input contains no `resume` line (the owner's scenario steps 1-3 in ev_01M3ZKWVQY6M21S6TYAFAESX1S)
   **Ticket:** C11-311 B247 (ticket stays open)

72. **Setup:** Same build and fixture; reset the log
   **Action:** Repeat three times, each with one change. (a) The second writer for S exits before the deadline. (b) Only an unrelated plain shell is open on the other tab. (c) The other tab is attributed to a different provider or a different session. Read the log after each deadline
   **Expected:** Each case submits exactly one resume command into R. Close the synthetic sessions and delete the guest afterward
   **Ticket:** C11-311 B247 (ticket stays open)

73. **Setup:** Tagged build of main at or after 28f640e557 in an isolated Atlas guest (`C11_SANDBOX_HOST=local scripts/sandbox-up.sh`)
   **Action:** Run `tests_v2/test_b046_debug_save_purpose.py` through the sandbox runner, then `sandbox-down.sh`
   **Expected:** PASS: the explicit debug save-and-load writes the current one-panel metadata even though an ordinary autosave would hold it back; guest deleted
   **Ticket:** C11-311 B046 (ticket stays open)

74. **Setup:** Same build, QA fresh, one workspace split into two terminal areas (A and B), each running a visible marker; wait for one autosave (about a minute)
   **Action:** Close area B. Within five minutes, force-kill the exact tagged c11 process (confirm its command line is the tagged bundle first, then `kill -9`), then relaunch it with `C11_QA_LAUNCH=resume`
   **Expected:** The restore shows the richer two-area layout (A and B), not the poorer one-area layout saved after the close
   **Ticket:** C11-311 B046 (ticket stays open)

75. **Setup:** Same build; rebuild the two-area layout, wait for an autosave, then close area B
   **Action:** Quit c11 deliberately through the app menu (Quit, confirm), then relaunch with `C11_QA_LAUNCH=resume`
   **Expected:** The clean-shutdown save wins: the restore shows the smaller one-area layout, without area B
   **Ticket:** C11-311 B046 (ticket stays open)

76. **Setup:** Tagged build of main at or after a85e6f2d36, QA fresh; several workspaces, three terminals each holding large scrollback (for example `seq 1 200000` in each)
   **Action:** Switch away from c11 and back (Cmd+Tab to another app and return) about 20 times in quick succession, typing a few characters into a terminal after each return
   **Expected:** No beachball or visible hitch at the moment c11 loses focus; typed characters appear immediately after each return; c11 stays responsive throughout
   **Ticket:** C11-311 B193 (ticket stays open)

77. **Setup:** Same build; make a visible layout change (open a new area with a marker command) and wait about a minute for an autosave, without switching apps
   **Action:** Force-kill the exact tagged c11 process (`kill -9` after confirming its command line is the tagged bundle), then relaunch with `C11_QA_LAUNCH=resume`
   **Expected:** The restore includes the layout change from the recent autosave (the new area with its marker), so dropping the resign-time save did not lose recent state
   **Ticket:** C11-311 B193 (ticket stays open)

78. **Setup:** Tagged build of main at or after abfb39b499, QA fresh, with telemetry consent enabled in Settings. Generate analytics activity just before quitting (open and close several tabs and workspaces, switch focus rapidly for about 30 seconds). Note the session file's modification time under `~/Library/Application Support/c11/session-com.stage11.c11.debug.<tag>.json`
   **Action:** Quit through the app menu (Quit, confirm) and time from the click to the process disappearing (`pgrep -f "<tagged bundle>"` in a loop). Relaunch with `C11_QA_LAUNCH=resume`
   **Expected:** The process exits promptly (within a couple of seconds, with no hang). The session file has a new modification time from the quit. The relaunch restores the final layout cleanly (clean-shutdown snapshot). Telemetry delivery is best-effort and is not checked
   **Ticket:** C11-311 B050 (ticket stays open)

79. **Setup:** Tagged build of main at or after b46cf452b6, QA fresh, launched once per language with `-AppleLanguages "(ru)"`, then `"(uk)"` (tagged bundle only, never the operator's global setting). Prepare workspaces holding 1, 2 and 5 terminal tabs
   **Action:** In each language, trigger the close-other-tabs confirmation with 1, 2 and 5 other tabs, the close-workspaces confirmation with 1, 2 and 5 workspaces, and the close-window confirmation with 2 workspaces. Read each dialog, then cancel. For ja, ko, zh-Hans and zh-Hant, open one of the same dialogs plus the Feed (Cmd+I) and the sidebar group header
   **Expected:** Every dialog is in the target language, with no raw keys, English fallback or `%lld` / `%@` literals. In ru and uk the count is grammatical for 1, 2 and 5 (count-neutral wording, no "2 вкладок" / "2 рабочих пространств" style errors). The list of names sits on its own line. Nothing clips. Cancel leaves everything open
   **Ticket:** C11-291

80. **Setup:** Tagged sign-off build of main at or after 92e2a39a78, QA fresh. A Codex tab (synthetic task) that has just finished a turn and sits waiting at an empty prompt, so `c11 feed list --scope all --json` shows a `turn_end` row for it (or a flag with no blocking ask)
   **Action:** From another tab: `c11 feed answer <codex tab> --text "continue with the next step" --json`
   **Expected:** JSON reports delivered and submitted. The Codex tab receives the line exactly once and starts a turn. If the row was a flag, it is lowered only after the handoff succeeds
   **Ticket:** C11-268 (regression smoke; ticket already done)

81. **Setup:** Same build and tab, waiting again
   **Action:** Run `c11 feed answer <codex tab> --text $'line one\nline two' --json`
   **Expected:** Refused with `multiline_unsupported`, `delivered: false`, `submitted: false`, `nothing_was_sent: true`. Nothing is typed into the tab, and the message points to `c11 feed open`
   **Ticket:** C11-268 (regression smoke; ticket already done)

82. **Setup:** Same build; in the waiting tab, type `draft text` at the prompt without pressing Return
   **Action:** Run `c11 feed answer <codex tab> --text "should not appear" --json`
   **Expected:** Refused with `input_guard_refused`. The tab still shows exactly `draft text`, and any flag stays raised
   **Ticket:** C11-268 (regression smoke; ticket already done)

83. **Setup:** Sign-off build at cde01d1571 (or later main), QA fresh, launched once each with `-AppleLanguages "(ru)"`, `"(uk)"` and `"(ja)"` (tagged bundle only). In each run, a waiting Codex tab that is eligible for `feed answer`, plus a terminal tab with an unsent draft
   **Action:** Run `c11 feed answer <codex tab> --text $'one\ntwo'` (multiline), then `c11 send --tab <draft tab> "x"`
   **Expected:** The multiline refusal (`feed.answer.multilineUnsupported`) and the send refusal (`socket.send.guard_refused`, with the reason filled in for `%@`) both appear in the launch language, with no English fallback or raw placeholder. Nothing is typed into either tab
   **Ticket:** C11-291

84. **Setup:** Sign-off build at cde01d1571 (or later main), QA fresh; two c11 windows, with window 1 frontmost and key; another app (Finder) open behind
   **Action:** From a terminal in window 1, run `c11 focus-window --window window:2`. Then click Finder so it is frontmost, and run `c11 focus-window --window 2` (index form). Then, with Finder still frontmost, run `c11 rpc workspace.select` on a workspace in window 2 (or `c11 select-workspace`) and `c11 focus-tab --workspace <ws> --tab <tab>` on a tab in window 2
   **Expected:** Both `focus-window` forms resolve the ref and raise window 2 to the front as the key window, activating c11 when needed. The `workspace.select` / `focus-tab` socket calls do not activate c11 or raise any window: Finder stays frontmost (a cross-workspace select returns `workspace_switch_blocked` per C11-323; `focus-tab` changes only the in-window focus). Only `focus-window` / `window.focus` may activate
   **Ticket:** C11-283 (re-cut check; ticket stays done)

