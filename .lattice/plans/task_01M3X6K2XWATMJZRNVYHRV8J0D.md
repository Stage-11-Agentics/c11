# C11-308: Encode send-key ctrl+letter so a Kitty TUI can be interrupted

## Incident
`c11 send-key ctrl-c` does not interrupt Claude Code or Codex. Those TUIs speak the Kitty keyboard protocol. The event they receive is a press, a virtual keycode, Ctrl, `unshifted_codepoint` 0, and no text, and nothing sends the release. Ghostty's Kitty encoder then emits no bytes (`ghostty/src/input/key_encode.zig:132-141` and the empty-entry return at `:217-222`). Backlog B002, upstream cmux #15928 (`ca92cbbe2e`). Base `0ff8887e5e`.

Second incident, same command. `c11 send-key ctrl-c enter` keeps `keyArgs.first` and succeeds after pressing only ctrl-c. `send-key-tab` does the same. Backlog B266, upstream #15980 (`f627d1fb`). A caller who needs two keys sends twice.

## Confirm against C11-257
Send-key encoding is outside C11-257's mailbox and event files. C11-257 Lane A (`task_01M3WPMYYQBP8VJN6X48RTV1TD`) emits `tab.input_sent` from the socket send path, including `send_key`, in `EventEnvelope.swift` and the `SocketHandlers` / TerminalController send path. Audit finding 5 imposes a file/merge barrier: a different hunk is not authorization. Read the actual C11-257 merged state before implementation and preserve its attribution and event emission.

C11-257 must merge its owned send/logging changes to origin/main before this ticket edits TerminalController.swift or SurfaceHandlers.swift. Record the integrated merge SHA on C11-308 and refresh these line numbers/call sites. Both tickets touch TerminalController.swift, serialized at that merge barrier. This ticket only changes the key-event fields, the press, the release, and the surface-still-live guard inside `sendKeyEvent` (`:6584`) and `namedKeyEvent` (`:6819`), plus the call sites that must pass the guard. It does not emit `tab.input_sent`. It does not edit `deliverSocketSendText` (`:6703`), `socketTextIsPasteDeliverable` (`:6662-6673`), the `submitted` / `queued` / `delivered` assignment (`SurfaceHandlers.swift:977-979`), mailbox bodies, or `EventEnvelope.swift`.

`v2SurfaceSendKey` (`SurfaceHandlers.swift:987-1051`) calls `sendNamedKey` and then the existing `forceRefresh`. Leave that refresh. Do not add an emit there. If C11-257 adds one after `sendNamedKey` returns, that hunk stays C11-257's.

## What is already true
- `sendKeyEvent` (`TerminalController.swift:6584-6606`) sets `action` to `GHOSTTY_ACTION_PRESS` and `unshifted_codepoint` to 0 (`:6595`), then calls `ghostty_surface_key` once.
- `NamedKeyEvent` (`:6795-6813`) has keycode, mods, and text. No codepoint field. The comment at `:6798-6802` says ctrl keys encode from the keycode alone.
- `namedKeyEvent` (`:6819-6871`) maps `ctrl-c` / `ctrl-d` / `ctrl-z` / `ctrl-\` (`:6829-6832`) and the generic `ctrl-<letter>` fallthrough (`:6863-6868`) to a keycode plus `GHOSTTY_MODS_CTRL` and no text. `space` is `printable(kVK_Space, " ")` (`:6839`). `sendNamedKey` (`:6874-6877`) forwards text and does not pass a codepoint.
- `sendTextEvent` (`:6608-6610`) and `handleControlScalar` (`:6739-6755`) also call `sendKeyEvent`. Those are the `c11 send` path. A release there is wrong: a Kitty release of an unidentified key with UTF-8 and codepoint 0 writes that UTF-8 again (`key_encode.zig:217-221`). Leave both press-only.
- Four `sendNamedKey` call sites, all on the main actor: `v2SurfaceSendKey` (`SurfaceHandlers.swift:1034`), the v1 key arm (`TerminalController.swift:3372`), `sendKey` (`:7090`), `sendKeyToSurface` (`:7115`). Each already holds the panel or the tab whose `surface.surface` is the live pointer. Phase B of `v2SurfaceSendKey` already re-reads that pointer before the press (`:1027-1033`).
- CLI `send-key` (`CLI/c11.swift:2992-2993`) and `send-key-tab` (`:3035-3037`) take `.first` and drop the rest. `send-key-panel` rewrites to `send-key-tab` (`:11772`), so one fix covers it. Help is `:9675-9688` and `:9702-9715`.
- `c11Tests/SendKeyVocabularyTests.swift` is in c11LogicTests (phase `37DDE3B0A6A70E75A7B2BEDF`). `testControlKeysCarryNoText` (`:120-126`) asserts `ctrl-c` has nil text. That assertion is the bug. `testSpaceCarriesItsText` (`:114`) stays.

Ghostty, read-only, do not patch. `ghostty_input_key_s` is `ghostty/include/ghostty.h:322-330` (`action`, `mods`, `keycode`, `text`, `unshifted_codepoint`). Actions are `:120-124`. `embedded.zig:92-114` copies `text` into `utf8` and `unshifted_codepoint` into the core event, and maps the native keycode to a physical key. `key_encode.zig:105-117` drops a release unless `report_events`. `ctrlSeq` (`:669-693`) turns a one-byte UTF-8 letter plus Ctrl into the C0 byte, which is why the text has to be the letter `"c"`, not `"\u{03}"`. Enter, tab, escape, and backspace with UTF-8 are treated as an IME commit (`:154-166` and the legacy twin `:351-364`). Do not attach text to those keys.

## Stale citations
Ledger B002 and `verdicts/input-b.md:10` cite `TerminalController.swift:6502-6523`, `:6747-6785`, and a comment at `:6716`. On this SHA those are `sendKeyEvent` `:6584-6606`, `namedKeyEvent` `:6819-6871`, and the comment at `:6798-6802`. Ledger B266 cites `CLI/c11.swift:2848` and `send-key-panel` near `:2890`. Those are `:2992-2993` and `:3035-3037`. The ticket's own CLI cite (`:2992-2993`) and `sendKeyEvent` cite (`:6584`, `:6595`) are current.

## Change
`NamedKeyEvent` gains `unshiftedCodepoint: UInt32`, default 0. `Equatable` includes it.

Ctrl letters set the canonical letter and that letter's Unicode scalar:

- `ctrl-c` / `ctrl+c` / `sigint`: text `"c"`, codepoint of `c`, keycode `kVK_ANSI_C`, `GHOSTTY_MODS_CTRL`.
- `ctrl-d`, `ctrl-z`, and the generic one-letter fallthrough: the same shape for that letter. `ctrl-k` is the fallthrough, not a dedicated case.
- `ctrl-\` / `sigquit`: text `"\\"`, codepoint `U+005C`, keycode `kVK_ANSI_Backslash`.

Enter, return, tab, escape, backspace, delete, arrows, home, end, page up/down, and f1–f12 stay text nil and codepoint 0. `space` stays `" "` and now carries codepoint 32. The previous plan citation at key_encode.zig:2025 was a legacy Ctrl+space test, not a Kitty table entry. ghostty/src/input/kitty.zig has no space entry; key_encode.zig:217-221 writes UTF-8 again for a release lacking an entry/codepoint. Supplying U+0020 gives the real space press/release pair, preventing duplicate spaces in Kitty event-reporting modes.

`sendKeyEvent` copies `unshiftedCodepoint` onto the C struct. It still sends `GHOSTTY_ACTION_PRESS`. A new `releaseAfterPress` argument defaults to false. When it is true, and only then, it sends a second event with `GHOSTTY_ACTION_RELEASE` and the same keycode, mods, text, and codepoint. `sendTextEvent` and `handleControlScalar` keep the default, so `c11 send` stays press-only.

`sendNamedKey` asks for the release. It takes `stillLive: () -> ghostty_surface_t?`. Capture the pointer used for the press. After the press returns, release only if `stillLive()` is the same pointer. Nil, or a different pointer, skips the release. Do not deliver the release into the replacement. Do not add a generation counter. `portalBindingGeneration` lives on `GhosttyTerminalView`; do not edit that file. The four call sites pass the panel or tab `surface.surface` they already re-read. The press and the check run on the main actor, back to back.

A pure helper, so the guard is testable without a live surface:

```swift
enum SendKeyRelease {
    static func target<ID: Equatable>(pressed: ID, current: ID?) -> ID?
}
```

Same value returns it. Nil or a different value returns nil. `sendNamedKey` uses it. Put it in `Sources/SendKeyArgs.swift` with the CLI parser below.

Extra arguments. `SendKeyArgs.single(_ args: [String]) throws -> String`. One element returns it. Empty throws the existing "requires a key" failure. Two or more throws, and the message names `args[1]`. The caller does not send `args[0]`. `send-key` and `send-key-tab` both call it, including the path that strips a leading `--`. Help for both commands (`:9675`, `:9702`) gains one line: one key per call; a second key is an error; send the next key as its own call.

## Files
- `Sources/TerminalController.swift` — `sendKeyEvent`, `NamedKeyEvent`, `namedKeyEvent`, `sendNamedKey`, and the three in-file call sites (`:3372`, `:7090`, `:7115`). Not `deliverSocketSendText`. Not `handleControlScalar`'s press-only calls.
- `Sources/SocketHandlers/SurfaceHandlers.swift` — the `stillLive` closure at the `sendNamedKey` call (`:1034`) only. The existing `forceRefresh` stays. No emit.
- `Sources/SendKeyArgs.swift` — `single` and `SendKeyRelease`. One `PBXFileReference`. Two `PBXBuildFile` rows, same pattern as `CLIResolutionSnapshot.swift`: app phase `A5001051` and CLI phase `B9000006`. Hand-edit `project.pbxproj`. Do not use the xcodeproj gem.
- `CLI/c11.swift` — both arms and both help strings. No other command.
- `c11Tests/SendKeyVocabularyTests.swift` — already in c11LogicTests. No new test file. No pbxproj change for the test.
- `tests_v2/test_send_key_ctrl.py` — CLI reject, and the interrupt check against a tagged socket.
- `skills/c11/references/api.md` — one sentence under the send-key vocabulary (`:288-294`). Not the ordinal paragraph at `:31` (C11-309).

## Tests
Update `testControlKeysCarryNoText` so `ctrl-c` is not in the nil-text list. The comment stays true for enter, tab, escape, backspace, and arrows: text on those keys is an IME commit.

New assertions, incident named in the comment (Kitty TUI dropped the chord, cmux #15928):

- `ctrl-c`, `ctrl+d`, `ctrl-z`, `sigint`, and `ctrl-k` carry the lowercase letter and `unshiftedCodepoint` equal to that letter's scalar.
- `ctrl-\` carries `"\\"` and codepoint `0x5C`.
- enter, tab, escape, backspace, up, and down still have nil text and codepoint 0.
- `space` is still `" "`, with codepoint 32 so its release does not duplicate the text.

`SendKeyRelease`: a matching id releases; nil and a different id do not. Incident: a stale release must not land in the next tab.

`SendKeyArgs.single`: `["ctrl-c"]` returns `ctrl-c`. `["ctrl-c", "enter"]` throws and the message contains `enter`. `[]` throws. Incident: cmux #15980 dropped the extra key.

No test that greps source. No test that needs a Ghostty surface for the vocabulary. The closed-tab case cannot be interleaved from the CLI, because press and release happen inside one main-actor call. The pure guard supplements the tagged production path. Add a gated native-send dependency seam around the production press/check/release sequence: observe actual event values/order through that seam, invalidate/replace the current target after press, and require no release to the stale or replacement pointer. Text-only send calls remain press-only; enabled Kitty PTY fixture checks one press/release pair and no duplicated prose. This is execution of the production sequence, not merely an equality-helper test. Do not add a fake socket test that only closes a tab before `send-key` (that is already "tab not ready").

## Acceptance
1. Tagged build, on Atlas after C11-216, not on Hyperion. `c11 send-key ctrl-c` in a Claude Code tab and in a Codex tab interrupts the running turn. The TUI shows the interrupt. A following `c11 send` still runs. `read-screen` is the record.
2. `c11 send-key enter` still submits. `c11 send-key space` still inserts one space, not two. A shell that is not a Kitty TUI still gets a real SIGINT from `send-key ctrl-c` (legacy `ctrlSeq` writes the C0 byte from the one-byte letter).
3. `c11 send-key ctrl-c enter` exits non-zero, stderr contains `enter`, and the tab does not receive ctrl-c. Same for `send-key-tab` and for `send-key -- ctrl-c enter`.
4. The release is skipped when `stillLive()` is nil or a different pointer. Reviewed on the four call sites. No delivery of that release to a replaced tab.

## Hot path
Socket key encoding only. Do not touch `WindowTerminalHostView.hitTest`, human `keyDown`, or add a display link or a `ghostty_surface_draw` loop. Do not add a second forceRefresh. The existing v2SurfaceSendKey refresh stays. Measure paired command-to-PTY interruption/input latency against tagged origin/main with the same workload and recorded load; C11-270 fleet soak is deferred by the Orchestrator; no new per-keystroke instrumentation or full soak by this seat.

## Strings
One new error, English, wrapped because it is a new user-facing CLI error. C11-291 translates it. `%@` must survive.

- `cli.send_key.extra` = "takes one key; extra argument '%@'. Send the next key in a second call."

Both commands use it. The help lines stay in the existing raw help strings. No SwiftUI string. No other key.

## Skill
In `skills/c11/references/api.md`, next to the send-key vocabulary (`:288-294`), one sentence: `ctrl-c`, `ctrl-d`, `ctrl-z`, and `ctrl-<letter>` are real key events, so a Kitty TUI such as Claude Code or Codex can be interrupted; pass one key; a second key is an error, and the next key is a second call. Do not rewrite the section. The c11 skill is installable (`skills/MANIFEST.json`). Only the Merge Captain syncs installed skills from merged main. This owner and reviewer never run sync-installed-skills.sh or edit installed skills; review the source documentation only (Orchestrator ruling).

## Cut
No Ghostty patch. No `GhosttyTerminalView.swift` edit. No bracketed paste (B013). No human `keyDown` (B148). No IME, layout, or clipboard rows. No menu-shortcut change. No `c11 send` wording, `--raw`, or stdin (C11-281). No mailbox, no `tab.input_sent`. No key sequence. No soak. No new generation counter.

## Dependencies
C11-281 does not edit `send-key`. This PR does not edit `send`. Shared file `skills/c11/references/api.md`: this PR touches the send-key vocabulary; C11-309 touches the ordinal paragraph at `:31`. Either order. Shared TerminalController.swift/SurfaceHandlers.swift: C11-257 must merge before these hunks are edited, despite separate regions. Preserve its emit and prove a successful send-key records one event, while an extra-argument rejection records none. The key encoding implementation remains independent of C11-281 and the Ghostty bump.

## Branch
Build mode, from `origin/main`, not from this worktree's current branch: `c11-1.0/C11-308-control-keys`.

## Decisions
None. Reject-with-usage is the ticket's choice.

## Codex takeover verification
Owner: agent:codex-fixtures, authorized BUILD MODE and reassigned C11-308 by the Orchestrator after C11-263 passed. Intake HEAD/base 9eb8fdc9172fc048180f6f89799af05a07afc92c on branch c11-1.0/C11-308-control-keys. C11-257 merged Lane A 3a38d8a23b (PR #492), Lane C 2b3c67ede3 (#493), Lane D 9b1380e08f (#494), Lane E 0bc4b61779 (#497); all are ancestors of this base. The Orchestrator explicitly lifted the send-key file barrier. Existing event attribution/emission and input transactions remain intact. Builds and native runtime validation use Atlas through remote-build.sh and a disposable owned sandbox guest. No Hyperion app driving. The C11-259 capacity reservation may delay admission; waiting is not a blocker. No PR until handoff; no installed-skill sync by owner. The architecture and executable-sequence/runtime gates above remain binding. All C11-308 behavioral checks are currently unperformed.

## Implementation review repairs
Executable-sequence review on the current Ghostty sources found the space assumption above incorrect; this correction is within go-owner.md's authorization to fix real plan errors. The extra-key preflight runs before SocketClient connect/auth/window.focus, preserving rejection without wire side effects even with a dead socket. Ctrl encoder text does not update lastOperatorKeyAt: it is metadata for a chord, not a draft in the composer; actual unmodified text/space retains the existing timestamp behavior. No Mailbox or event-logging implementation edits. These behaviors are covered by executable unit/CLI/PTY tests.

## Final main integration

Before handoff, merge origin/main 43529df178a9cd8817fc092896efd2f3fcd63df5 into the lane without discarding its three implementation commits. The single CLI preflight conflict keeps both C11-308 cardinality rejection and main feature admission before SocketClient construction. Main imports Ghostty 5830d1976eecca0d7dee202aef8fb2338d99ed6d; this owner makes no Ghostty changes. Merged head b09a7a697aca74dd5541b7664438e5a558af14c9 requires fresh Atlas targeted tests, tagged artifact, native/PTY proof, and paired comparison against the same main base. Earlier a277 runtime evidence is retained as earlier-head evidence, not used to attest this merged head. VM validation uses bounded leases under 30 minutes and deletes each owned guest at the end of its run.
