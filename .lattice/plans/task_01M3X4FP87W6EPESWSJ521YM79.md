# C11-292 plan: one sign-off build and Atin's numbered script

Planning only. Later branch: `c11-1.0/C11-292-signoff-script` from origin/main. Do not cut that branch in planning mode. Do not implement on `c11-1.0/C11-216-atlas-builds`. No product diff in this planning pass.

Codex takeover: base `0ff8887e5e965400b01645ef40b85fd0b2605cf2` checked; planning only. Audit repair. Must-fix 5: the rehearsal waits on the complete admitted P0/P1 closure and on C11-270's final-candidate evidence. Must-fix 6, as it binds this gate: C11-291 is required before that rehearsal; English fallback is not a cut. Must-fix 7: rehearsal and computer use run on Atlas. This ticket does not sign and does not publish. The signed-byte approval is C11-293.

## Independence

This is the P1 sign-off gate (X2). The PR is the script plus one rehearsal note. It does not change `MARKETING_VERSION`, push a `v*` tag, or take GitHub `latest`. Other owners merge without waiting on this branch. The rehearsal does not start until their admitted P0/P1 commits are in the sign-off SHA. A failed step names the owning ticket and becomes that ticket's fix. This script is not edited to skip a failed P1 step. P2 items C11-267, C11-268, C11-285, C11-286, C11-289, and C11-311 stay omitted unless the lead admits one. C11-293 does not publish until Atin has passed this script and, separately, named the signed candidate hashes.

## What ships

One integrated tagged Debug app of the admitted P0/P1 work, and `docs/signoff-1.0.md`. The research tree `upstream-triage/c11-1.0/` is not the product PR.

The script is English, checkbox markdown, public-repo safe. No account names, cookies, ssh private material, home paths, or IP addresses. Say "the remote host" and use `https://example.com` for the ordinary browser page. The ssh egress check records only whether the browser matched the remote host.

Header blanks, filled at rehearsal and left blank in the template: full git SHA, c11 DEV tag, `MARKETING_VERSION` reported by the app, UTC time, machine `Atlas`. A line "Atin's pass" stays blank. The script never writes "approved". His pass is a Lattice comment or an operator message that names this tag and this SHA. That pass approves the integrated candidate. It is not approval of signed bytes. This seat does not mark the ticket done and does not merge.

## Build

Wait until C11-216 has merged, the Orchestrator has sent BUILD MODE, every admitted P0/P1 ticket below is an ancestor of the SHA or the lead has explicitly cut it, C11-291 has passed on that SHA, and C11-270's final-candidate evidence names the same source/submodule identities. An ancestor alone is not product equivalence; material candidate changes refresh evidence. One Atlas build, from a delegator worktree, through the corrected remote path:

`scripts/remote-build.sh --tag signoff-10 --mode debug`

Launch and walk the script on Atlas:

`scripts/launch-tagged-automation.sh signoff-10 --qa fresh`

Do not launch this app on Hyperion. Computer use for focus, browser, import, ⌘I, groups, and the journal relaunch runs on Atlas. Tag charset is `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. `--launch` stays off on the remote command. Do not run `reload.sh`, `reloads.sh`, or `xcodebuild` on Hyperion. Do not publish. Do not `git tag`.

If a required ancestor is missing, send BLOCKED naming that ticket. Do not drop the chapter. If Ghostty reports `OutOfMemory` while the Atlas screen is locked, park and ask the operator to unlock. That is not a product failure.

Identity check is step 0. Doctor/About verifies bundle path, tag and version, not a source SHA that this base does not expose there. Bind the active process executable path and finalized executable hash to C11-216's source/submodule manifest and header SHA; do not infer source identity from version alone.

## Chapters

Each step says what Atin does, what he should see, and where to stop. Another ticket's script is one step. Steps 19–22 are the tracks the previous dependency list left out.

| Step | Owner | What he does and what he should see |
|---|---|---|
| 0 | this ticket | On Atlas, doctor/About matches path, tag and version; active executable path/hash matches the build manifest recording header source/submodule SHAs. Stop on mismatch. |
| 1 | C11-279 | C11-279's named normalized-selector typo fixture refuses without hitting the focused tab; do not claim arbitrary typo detection. |
| 2 | C11-280 | `--command` runs in a new terminal, not the focused one. |
| 3 | C11-281 | `send --raw` behaves as that ticket documents, and the three delivery words match the build. |
| 4 | C11-282 | `read-selection` returns the selection. The app stays responsive. |
| 5 | C11-283 | `--window` scopes the command and does not steal focus. Screenshot. |
| 6 | C11-284 | `c11 guide` matches this build's bundled skill and capabilities list. |
| 7 | C11-287 | Recover a crashed browser. Terminals in the workspace stay up. Screenshot. |
| 8 | C11-288 | Chrome or Arc import smoke on this tagged app. No cookies and no account names. Screenshot. |
| 9 | C11-290 | `c11 ssh` to the remote host: a shell, a browser proxy, and a refusal. `c11 ping` in that shell prints "c11 commands are not available over c11 ssh in this version", exits non-zero, and does not print `pong`. Record hostname. Record the directory only as "remote home". Do not turn the relay back on. |
| 10 | C11-261 | Run `docs/groups-signoff.md` on this same Atlas tagged app. Do not copy its steps into this file. If that file is absent, this step fails and names C11-261. |
| 11 | C11-263 | A bypass AskUserQuestion or ExitPlanMode shows waiting without waiting for PermissionRequest. A flag stays in the menu-bar extra when routine unread is zero. Clearing one agent does not clear the sibling. c11 does not activate. |
| 12 | C11-264 | `c11 feed list` shows a typed ask (`question`, `plan`, or `permission`). `feed open` opens that tab. A closed tab is unavailable. No feed command sends an answer. |
| 13 | C11-265 | Flags oldest-first, then open asks oldest-first, then eligible unread completion/legacy targets. A completion-only tab stays reachable even when the view hides turns. Ask and unread counts match their distinct facts. c11 does not activate. |
| 14 | C11-266 | ⌘I opens the quick view. Return opens the selected tab. Esc returns. Nothing is sent. Asks hides finished turns. Turns shows them. |
| 15 | C11-273 | Force-quit the tagged app on Atlas and relaunch with `--qa resume`. Prior blocked or error evidence shows as unconfirmed. An old run is not shown as live. The sidebar and configured Jump to Unread action still reach the ask (fresh-app default Control-Command-Return; no operator-shortcut installation). Screenshot. |
| 16 | C11-291 | Cite C11-291's six-locale and interpolation checks on this artifact; show one new translated string as the visible smoke. This step is required. A missing locale pass fails the rehearsal and names C11-291. |
| 17 | this ticket | While other agents are running on Atlas, type one short sentence in a terminal and read it back. Record whether the keystrokes landed. No hit-test instrumentation. |
| 18 | C11-270 | The final-candidate evidence (the 10h candidate, not the 3h baseline alone) names this candidate's source/submodule identities; an ancestor alone does not qualify. Cite `wall_hours`, the classify status, and the C11-310 `sidebar_verdict` from that same artifact. Absence is BLOCKED. Do not start a soak from this ticket. |
| 19 | C11-231 | `c11 agents --json` shows journal `state`. A blocked row's `reason` is `approval`, `question`, or `plan_review`. The command does not launch an agent. On the same artifact, answer a real blocked ask: correlated human `operator_response` populates Q2, C11-274 continuation resolves it, Feed/sidebar resume then complete, and an independent unread completion remains reachable. Seeing a tab and generated keys are not human responses. |
| 20 | C11-277 | `c11 journal query` answers one named question. A row with no `operator_response` stays unavailable. Export is structural NDJSON and contains no prompt body. Do not use `c11 stats`. |
| 21 | C11-262 | On Atlas, look at a tab long enough to qualify, then `c11 history` lists it. `c11 history back` returns to the previous tab. Typing in a terminal does not add a history row. |
| 22 | C11-294–C11-309 | One checkbox per admitted bug ticket: C11-294, C11-295, C11-296, C11-297, C11-298, C11-299, C11-300, C11-301, C11-302, C11-303, C11-304, C11-305, C11-306, C11-307, C11-308, C11-309. Each box cites that ticket's validation comment on this SHA. Do not re-run those labs here. A missing comment fails the step and names the ticket. |

C11-312's artifact-only signing infrastructure lands before C11-307/C11-298 proof and this rehearsal; final release preparation/publication remain later. The signed update/relaunch proof for C11-307 and C11-298 uses C11-312's artifact-only signed builds on Atlas. Step 22 cites those comments. It does not dispatch `release.yml`.

## Acceptance

1. Header identity matches the Atlas app. Incident: a sign-off run against a different binary than the one named in the script. Proof: doctor/About output plus active executable path/hash and build manifest quoted in the validation comment, tying the header SHA/submodules to the running artifact on Atlas.
2. Numbered steps, including 19–22, each with an action and a visible result. C11-261 is one step. Incident: groups sign-off rewritten a second time, or a core track left out of the script. Proof: read `docs/signoff-1.0.md` on the PR SHA. No markdown-grep unit test.
3. One rehearsal on Atlas before Atin walks it there. Incident: green tests, or a Hyperion walk, treated as the release. Proof: `lattice comment --role validation` with pass or fail per step, a CLI quote for socket steps, and a screenshot for focus, browser, import, ⌘I, and the journal relaunch. Tag, SHA, UTC. The comment states that C11-291 and the C11-270 final candidate were already on this SHA.
4. A failed P1 step names its owner. The script is not edited to skip it. Incident: a sign-off that goes green by deleting the failing check. Proof: the comment links the owner ticket.
5. No publish and no release-remote git tag from this ticket. Incident: a sign-off PR that ships 1.0.0 or treats the debug SHA as the signed artifact. Proof: `releases/latest` is unchanged, and the comment does not record a publish approval.

## Hot path, strings, persistence

Step 17 is an observation while other agents run. Do not edit `WindowTerminalHostView.hitTest`, `WorkspaceRowView`, or `TerminalSurface.forceRefresh`. No new `String(localized:)` key. No session-schema change. No tenant-config write. No skill install. Do not edit `skills/c11`.

## Cut

Publishing and the signing workflow (C11-293). Deciding P2 admission. Rewriting `docs/groups-signoff.md`. Running the soak. Implementing feed, journal, roster, history, or bug fixes on this branch. Approving signed bytes.

## Dependencies

Admitted P0/P1 closure, each an ancestor or an explicit lead cut, before the tag: C11-216, C11-258, C11-259, C11-260, C11-261, C11-262, C11-263, C11-264, C11-265, C11-266, C11-269, C11-270, C11-271, C11-272, C11-273, C11-274, C11-275, C11-276, C11-231, C11-277, C11-278, C11-279, C11-280, C11-281, C11-282, C11-283, C11-284, C11-287, C11-288, C11-290, C11-291, C11-294, C11-295, C11-296, C11-297, C11-298, C11-299, C11-300, C11-301, C11-302, C11-303, C11-304, C11-305, C11-306, C11-307, C11-308, C11-309. C11-310 is the measurement inside the C11-270 artifact, not a separate merge. C11-291 cannot be cut. A string change after that pass runs C11-291 again before this rehearsal.

## Decisions

None.

## Review

Three cycles, then Atin. Computer-use prompts require a verified Atlas display, hard termination timer, and proven synthesized-input dismissal of validation windows; verify readable areas before success. The Atlas rehearsal is the validation. Do not mark done.
