# C11-291: six-locale pass for new 1.0 strings

Owner: `agent:codex-history`. Planning only. No catalog edits in this mode. Implementation waits for `BUILD MODE` and for the English freeze commit the orchestrator names on `origin/main`. Branch, created only then: `c11-1.0/C11-291-six-locale` from that commit. If that freeze commit has not been named, send `BLOCKED` and stop. Do not translate from this inventory in place of the freeze diff.

This is X1, tier P1. The diff is `Resources/Localizable.xcstrings` plus one token script. No Swift, no socket, no skill body, no feature behavior. English feature PRs may land first, with English `defaultValue`, and do not wait on this PR to merge. Every admitted new string must pass this six-locale catalog before integrated sign-off. A later English change refreshes the pass: recompute the freeze list and translate again before that sign-off. Fallback English is not an approved release cut. Reverting this catalog restores the previous translations and leaves feature behavior in place. P2 tickets do not gate the start of this pass. A P2 key that is already on the freeze commit is admitted and must be covered before sign-off.

## What the freeze is

At execution, on the `origin/main` the orchestrator names:

1. Resolve the previous public release tag the Orchestrator names, or confirm the nearest reachable stable `v*` release tag as that baseline. Reachability alone must not select a prerelease or a differently ordered reachable tag as the prior public release; record the resolved tag SHA with the freeze SHA. Do not hardcode a tag in advance.
2. Diff `Resources/Localizable.xcstrings` against that tag.
3. Every key whose English `stringUnit.value` is new or changed is in the freeze list, regardless of whether non-English values already exist or look translated. A formerly correct Japanese/Russian/etc. translation can remain non-empty and non-English after English changes; presence/token parity does not prove it was refreshed. Re-evaluate all six locale values for each changed/new key. Extract English recursively from any plural/device variations without flattening their structure. Removed keys are reported as removed and are not invented again.
4. The inventory below is the coverage check, not a second source of English. A planned key that is absent from the merged catalog is listed in the PR as "not in this release" and is not invented. A key the diff finds that this inventory missed is translated. An open feature PR is not admitted until its strings are on the commit being signed off. Strings that merge or change after a pass are admitted by the next diff and must pass again before integrated sign-off.

Do not edit English. Do not change `sourceLanguage`, the catalog `version`, or any `en` value. Do not run `plutil` on this file. `plutil -lint Resources/Localizable.xcstrings` fails because it parses JSON as a plist. That failure is not a broken catalog.

## Inventory at plan time

Grep of `.lattice/plans/task_*.md` for the c11-1.0 tickets, 2026-10-02. None of these keys exist yet in `Resources/Localizable.xcstrings` on `0ff8887e5e`. English below is the feature plan's sentence. Where the feature plan named a key and no sentence, the English cell says "merged call site".

Tokens must be copied from the merged English, not from this table.

### Named sentences

| Ticket | Key | English | Tokens |
|---|---|---|---|
| C11-262 | `shortcut.focusHistoryBack.label` | Focus History Back | none |
| C11-262 | `shortcut.focusHistoryForward.label` | Focus History Forward | none |
| C11-262 | `shortcut.unbound` | None | none |
| C11-262 | `menu.history.title` | History | none |
| C11-262 | `menu.history.back` | Back | none |
| C11-262 | `menu.history.forward` | Forward | none |
| C11-273 | `journal.state.unknown` | Unknown | none |
| C11-273 | `journal.state.disconnected` | Disconnected | none |
| C11-273 | `journal.state.degraded` | Degraded | none |
| C11-273 | `journal.state.error` | Error | none |
| C11-273 | `journal.evidence.unconfirmed` | Unconfirmed | none |
| C11-273 | `journal.reason.approval` | Approval | none |
| C11-273 | `journal.reason.question` | Question | none |
| C11-273 | `journal.reason.planReview` | Plan review | none |
| C11-265 | `statusMenu.attention.none` | No flags · no open asks | none |
| C11-265 | `statusMenu.attention.flags.one` | 1 flag | none |
| C11-265 | `statusMenu.attention.flags.other` | %lld flags | `%lld` |
| C11-265 | `statusMenu.attention.asks.one` | 1 open ask | none |
| C11-265 | `statusMenu.attention.asks.other` | %lld open asks | `%lld` |
| C11-266 | `feed.quick.title` | Feed | none |
| C11-266 | `feed.quick.filter.asks` | Asks | none |
| C11-266 | `feed.quick.filter.turns` | Turns | none |
| C11-266 | `feed.quick.empty.asks` | No open asks | none |
| C11-266 | `feed.quick.empty.turns` | No finished turns | none |
| C11-266 | `feed.quick.loading` | Loading | none |
| C11-266 | `feed.quick.unavailable` | That tab is unavailable | none |
| C11-266 | `feed.quick.hint` | Arrows move. Return opens. Esc closes. | none |
| C11-266 | `feed.quick.kind.question` | Question | none |
| C11-266 | `feed.quick.kind.plan` | Plan | none |
| C11-266 | `feed.quick.kind.permission` | Permission | none |
| C11-266 | `feed.quick.kind.turnEnd` | Turn ended | none |
| C11-266 | `feed.quick.kind.flag` | Flag | none |
| C11-266 | `feed.quick.prompt.missing` | — | none |
| C11-266 | `feed.quick.age.missing` | — | none |
| C11-279 | `socket.error.unsupported_routing_key` | Unsupported parameter '%1$@'; use '%2$@'. | `%1$@` `%2$@` |
| C11-280 | `cli.create.command.nonTerminal` | `--command` is only for a terminal (%@). | `%@` |
| C11-280 | `cli.create.command.withLayout` | `--command` cannot be combined with `--layout`. | none |
| C11-280 | `cli.create.inputQueued` | input queued into the new shell | none |
| C11-281 | `cli.send.unknown_flag` | Unknown flag '%@'. | `%@` |
| C11-281 | `cli.send.stdin_conflict` | '-' reads stdin and takes no other text. | none |
| C11-281 | `cli.send.queued` | queued, not delivered (tab not attached; the agent has not seen it) | none |
| C11-281 | `cli.send.delivered_submitted` | delivered, return scheduled | none |
| C11-281 | `cli.send.delivered` | delivered, not submitted | none |
| C11-282 | `socket.error.tab_not_terminal` | Tab is not a terminal. | none |
| C11-282 | `cli.read_selection.none` | No selection. | none |
| C11-283 | `cli.window.unknown` | Unknown window '%@'. | `%@` |
| C11-284 | `cli.guide.missing` | This build has no bundled c11 skill. | none |
| C11-284 | `cli.guide.unknown_page` | No bundled skill page '%@'. | `%@` |
| C11-297 | `socket.error.sessionNotReady` | Session restoration is still in progress. Try again shortly. | none |
| C11-308 | `cli.send_key.extra` | takes one key; extra argument '%@'. Send the next key in a second call. | `%@` |

C11-263 adds `menu.flagged` = "Flagged" only if its menu needs a section header. Include it only when the merged catalog has it.

C11-272 reserves the same journal keys as C11-273 except `journal.state.error`, which C11-273 adds. C11-231 reuses those keys and adds none. If C11-273 reused an existing key instead of adding one, translate the key it actually used and do not add a duplicate.

### Keys whose English is the merged call site

C11-259, prefix `workspaceGroup.error.`: `invalidName`, `invalidColor`, `invalidIcon`, `duplicateWorkspace`, `alreadyGrouped`, `notMember`, `groupNotFound`, `workspaceNotFound`, `wrongWindow`, `emptyGroup`. No `workspaceGroup.defaultName`. Protocol codes (`invalid_params` and the rest) are not strings.

C11-260, prefix `workspaceGroup.`: `new`, `name`, `rename`, `color`, `icon`, `pin`, `unpin`, `ungroup`, `delete`, `deleteHelp`, `moveToGroup`, `ungrouped`, `expand`, `collapse`, `memberCount`, `waitingCount`, `unreadCount`, `flaggedCount`, `accessibility.summary`, `accessibility.empty`, `drop.join`, `drop.ungroup`, `drop.reorder`. The plan says count keys carry `%lld`, and `accessibility.summary` carries the group name `%@` plus explicit numeric counts. Confirm each token against the merged English. Reuse of an existing generic key means that key is in the freeze list only if its English changed.

### Planned tickets that add no catalog key

Do not go hunting in these diffs for copy: C11-216, C11-231, C11-258, C11-261, C11-264, C11-269, C11-270, C11-274, C11-275, C11-276, C11-277, C11-278, C11-287, C11-288, C11-290, C11-294, C11-296, C11-306, C11-307, C11-309. C11-261's six-locale screenshots consume this catalog. A clipped badge or a raw key comes back as a note. Do not shorten a translation to fit. File clipping on C11-260.

### Not in the freeze unless already merged

P2 plans name no keys. They say new UI or CLI errors use `String(localized:)` and point the fill here: C11-267, C11-268, C11-285, C11-286, C11-289, C11-310, C11-311. This pass does not wait for them. A key from one of them is in scope only when that PR is already on the freeze commit.

## How to write the six locales

Locales, matching the catalog: `ja`, `uk`, `ko`, `zh-Hans`, `zh-Hant`, `ru`. One sub-pass per locale, parallel within available harness slots. Each worker writes a separate temporary locale patch, never the shared catalog; the owner merges those six patches serially against the same frozen English hash. This avoids one worker overwriting another locale from an older whole-file copy. No Claude, Opus, or Fable workers. Each pass receives the freeze list, the English value, and the token multiset, and emits only its locale's `stringUnit`/matching variation leaves in its patch. Keep `state` as `translated`, the same shape as `about.appName` in the catalog (`extractionState` left as the feature PR set it).

Preserve plural/device `variations` if the merged key has them. The token checker walks every localized string leaf, validates English/translation variant correspondence and interpolation references, and checks required target plural forms against the catalog shape. It does not silently skip a key lacking a top-level `stringUnit`. Do not collapse C11-265's separate `.one` and `.other` keys into one string, and do not split a single `%lld` string into variations the feature PR did not create.

The em dash "—" stays "—". Product token `c11` stays `c11`. Do not leave any other English sentence in place as a shortcut. No translator notes, no `TODO`, no bracketed commentary, no empty value.

`%%` is an escaped percent and must survive. Count every printf token in the English value, including `%@`, `%lld`, `%ld`, `%d`, and positional forms such as `%1$@` and `%2$@`. The translation's multiset must match. Order may follow the target language. A dropped or added token fails that locale's pass.

## Check

`scripts/check-locale-tokens.py` reads the catalog as JSON, takes the freeze list on stdin, and exits non-zero on a missing locale, an empty value, a note marker, or a token mismatch. It prints the key, the locale, and the token counts. It does not assert that a Swift call site exists.

Then:

```bash
jq . Resources/Localizable.xcstrings > /dev/null
python3 scripts/check-locale-tokens.py < freeze-keys.txt
```

Both must exit 0. This is an artifact check, not an XCTest that greps source or the project file. Do not add a test whose only job is to prove a key string exists in the catalog.

## Acceptance

| AC | Incident / question | Proof |
|---|---|---|
| 1 | A dropped `%@` or `%lld` crashes at format time. The question is the freeze list against the last release. | The token script exits 0. Every new/changed-English freeze key is reviewed in all six locales even when old translations were already present. Every required variant has a non-empty translation and matching interpolation references. Include a changed-English/unchanged-non-English fixture in the script's own checks so inventory selection cannot omit it. |
| 2 | `plutil -lint` on this JSON catalog is a known false failure. | `jq . Resources/Localizable.xcstrings > /dev/null` exits 0. The PR does not cite `plutil`. |
| 3 | A non-English operator would otherwise see the new English. | One Atlas tagged build after C11-216, with verified display, a hard 20-minute stop, synthesized dismissal and readable-area check. Record the exact frozen source/candidate app SHA and checked key/locale. Set `AppleLanguages` for that tagged bundle only, to `ja`. Show one merged 1.0 string (a workspace-group header if C11-260 is on the build, otherwise History or Feed). Screenshot shows the Japanese value, not the English. Restore the tagged bundle's language afterward. Do not change the operator's global language. The other five locales are proved by the script, not by five more UI passes. |
| 4 | Reviewers need the boundary, or skill prose and socket codes look forgotten. | The PR lists what stayed English on purpose: skill markdown, docs, changelog, log lines, socket and protocol codes, and the CLI prose the feature plans left unlocalized (history lines, journal query text, launch-stats text). |
| 5 | An empty unit or a translator note can ship while `jq` is green. | The script rejects empty values and note markers. A manual skim of the diff confirms no English `stringUnit` changed. |

Hot path: none. No main-thread work, no soak, no `dlog`, no submodule, no tenant config. A longer translation that clips a control is filed on the feature ticket. This PR does not change layout.

Public catalog only. No hostnames, account names, prompts, or incident text in a string.

## Cut line

No new product copy. No rewrite of strings a 1.0 feature did not add. No skill-body translation (`c11 guide` stays English). No marketing-site locales (C11-254). No Swift call-site edits. If a planned key never landed, do not add the call site here. No C11-257 send/mailbox files.

## Dependencies and handoff

Start after the English freeze commit is on `origin/main`. Linked already: C11-279, C11-280, C11-281, C11-283, C11-260, C11-263, C11-266, C11-216. The same freeze rule covers the other named tickets above. They do not each need a new link for this pass to include their merged keys. C11-292 and C11-293 do not sign off until this pass has covered every admitted new string on that commit. A later string edit reopens the pass. C11-261's locale screenshots are a consumer, not this ticket's proof.

Open human decisions: none. Review cap: three cycles, then Atin. Do not merge and do not mark done.

Atlas builds only, through C11-216, under the build lock. No Hyperion `xcodebuild`. The catalog script itself does not need a build.

## Codex takeover verification

Audit finding 6's mandatory six-locale gate was already repaired. Verified catalog shape/source-language on `0ff8887e5e965400b01645ef40b85fd0b2605cf2`; corrected the remaining inventory rule that omitted changed English when a stale translation was non-empty/non-English. Translate every admitted changed/new key; independent worker patches merge serially; variant leaves receive real token validation. Exact freeze/baseline identities and tagged UI proof remain pending build mode. No new human decision; no catalog edits/builds/tests.
