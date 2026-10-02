# C11-281: Document send delivery and add --raw, stdin, and unknown-flag errors

## Incident
`c11 send` rewrites `\n`, `\r`, and `\t` before the socket call (`CLI/c11.swift:2965`, `unescapeSendText` at `:11935-11939`). An unknown flag stays in the remainder and is typed into the terminal. There is no stdin form and no `paste` command. Human output mentions a queue only as `queued=1` (`sendTextSummary`, `:5224-5228`). The skill never defines `delivered`, `queued`, or `submitted`. Backlog C3. The C11-140 unknown-flag bullet (`c11 send --text "hi"` types `--text hi`) is this ticket. Base `0ff8887e5e`.

## What is already true
- `send` (`:2947-2976`) parses `--workspace`, `--surface` (the `--tab` alias), and `--no-submit`, joins the rest, and unescapes. `send-tab` (`:3002-3024`) does the same. `send-key` does not send prose. Help at `:9661` omits `--no-submit` and `--raw`.
- The server already returns the three booleans. `v2SurfaceSendText` sets `submitted`, `queued`, and `delivered = !queued` (`SurfaceHandlers.swift:977-979`). `queued` means the PTY was not attached. `submitted` means the Return was dispatched (`:932`, `:963`), not that an agent read it. `deliverSocketSendText` is `TerminalController.swift:6703`. The paste-versus-key choice and the C0-byte rule are the comment and `socketTextIsPasteDeliverable` at `:6643-6673`. Ghostty's paste encoder replaces those control bytes with spaces. Do not promise byte-exact delivery for them.
- `tab.send_text` is already a socket-worker method (`SocketDispatch.swift:64-65`). Leave it there.
- `new-workspace --command` still calls `unescapeSendText` and then `tab.send_text` (`CLI/c11.swift:2242`). C11-280 removes that follow-up. This PR does not touch `:2242` and does not put the send back.
- C11-257 (in progress, `task_01M3WPMYYQBP8VJN6X48RTV1TD`) owns send recording and mailbox delivery. Its plan's Lane A emits `tab.input_sent` from the socket send path. Lanes B–D own mailbox push, hooks, and the messages page.

## Merge barrier: C11-257
Audit finding 5 is binding. The board already records C11-281 depends_on C11-257; current C11-257 is in_progress. Before implementing this ticket, verify that all its delivery/logging/mailbox changes are actually merged to origin/main, record the integrated merge SHA on this ticket, and refresh/rebase the send contract against those bytes. Planned status, a reviewed PR, or different hunks is not the barrier. Do not edit its owned TerminalController/SurfaceHandlers/send-logging/mailbox paths until that merge. This ticket's own PR opens only against that integrated state.

These hunks specifically wait, even if another diff appears disjoint:

- `deliverSocketSendText` (`TerminalController.swift:6703`) and `socketTextIsPasteDeliverable` (`:6662-6673`). `--raw` skips escape decoding in the CLI; the server receives the explicit preserve_newlines policy with that string. The optional native/queued-paste policy below is edited only after C11-257 merges.
- The boolean assignment at SurfaceHandlers.swift:977-979. Preserve its meanings; only the explicit raw/paste newline policy changes whether a synthetic submit is requested. This hunk stays gated on the C11-257 merge.
- `tab.input_sent`, `mailbox.accepted`, and `mailbox.delivered` (C11-257 C1 and C2). No event body, no caller id, no truncation change.
- A ctrl+enter submit, if acceptance 5 shows Claude Code swallowed the Return. That change would be inside `deliverSocketSendText`. Record the run in the PR. Do not land it until C11-257 merges. If the multi-line send is already one turn, do not port it at all.

## Change
Add `SendTextParse` in `Sources/SendTextParse.swift`. It does not open a socket or read the real stdin.

Known flags: `--workspace`, `--tab` / `--surface` / `--panel`, `--no-submit`, `--raw`, `--json`. Parsing stops at `--`. Any other token that starts with `--` before that is an error naming the token. `--text` is not known. That is the C11-140 case.

- `--raw` skips `unescapeSendText`. A backslash followed by `n` stays those two characters. Default `send` still rewrites `\n` and `\r` to CR and `\t` to a tab.
- Corrected citation/behavior: SurfaceHandlers.swift:893 sets wantsReturn from a trailing newline even with submit:false, and TerminalController.swift:6710-6711 strips that newline. GhosttyTerminalView.swift:4000-4010 trims leading and trailing newlines in sendSubmitFormText. Therefore the original stdin --no-submit acceptance would submit and strip content. After C11-257 merges, add an opt-in socket parameter `preserve_newlines: true` for raw/paste mode. Only that mode treats leading/interior/trailing newlines as paste content and derives synthetic Return solely from explicit submit. Default/omitted parameter retains the existing trailing-newline submission contract. Add the same optional policy to deliverSocketSendText and sendSubmitFormText, defaulting to legacy behavior; both live and pending-queue paths use it. Keep C0 key-path limitations documented, so this is literal escape/newline handling, not a byte-exact guarantee for arbitrary controls. Newline-only raw input must remain content and not be dropped by an empty-trim guard. Ghostty input/paste.zig:94-107 preserves newline bytes only in bracketed mode; unbracketed paste maps LF to CR. Document --no-submit as suppressing c11's additional Return, not changing a receiving program's treatment of newline content. No Ghostty paste-mode rewrite.
- The CLI checks the connected server's `send.raw` capability before promising this new raw/paste contract; an older server lacking that flag returns a clear unsupported-feature error, rather than ignoring preserve_newlines and falsely claiming no-submit. Default send remains compatible. The server dispatch consults the same typed feature entry, which is enabled only with this implementation.
- The only positional `-` means "read stdin". Any other text beside it is an error. `send` with no text and no `-` still errors.
- `paste` is `send --raw`. With no positional text it reads stdin. `paste -- <text>` sends that text raw. Same targeting flags, including `--no-submit`.

`send` and `send-tab` both call this parser, then `tab.send_text` params (`text`, `submit`, `preserve_newlines` for raw/paste, plus `workspace_id` / `tab_id` as today). Preserve post-C11-257 caller attribution/logging fields; do not drop them when consolidating the CLI arms. `paste` is a new switch arm on that same path. Do not change `send-key`.

Human line, from the booleans already in the JSON:

- `queued`: `queued, not delivered (tab not attached; the agent has not seen it)`
- delivered and submitted: `delivered, return scheduled`
- delivered and not submitted: `delivered, not submitted`

Never say the agent saw the text. JSON keeps the booleans. C11-283 precedes this PR; preserve its window_id stamping and explicit-target guard on send/send-tab/paste.

Help for `send`, `send-tab`, and `paste` (`:9661` and a new case). Short usage near `:17941`. `paste --help` says it is `send --raw`.

Skill: in `skills/c11/references/api.md` under Reading & sending, define the three words with the meanings above, plus --raw, -, paste, unknown-flag rejection, default trailing-newline-as-submit versus raw/paste newline content, and the bracketed/unbracketed no-submit boundary described above. One sentence in `skills/c11/SKILL.md` next to the send rules (`:157-159`). C11-284 merges first. Enable send.raw in Sources/CapabilityFeatures.swift with this implementation, using its typed entry in raw/paste dispatch. On the integrated tagged artifact capabilities must advertise send.raw and the raw/stdin/no-submit scenarios must all pass; no optional PR-only note (audit finding 8).

When the PR opens, comment on C11-140 that the unknown-flag bullet is this contract. That comment is build mode.

## Files
- `Sources/SendTextParse.swift`. App sources phase A5001051 and CLI phase B9000006A1B2C3D4E5F60719, since both parser tests and standalone CLI use it. Hand-edit project.pbxproj following CLIResolutionSnapshot.swift two-target membership; no xcodeproj gem.
- `CLI/c11.swift` — `send` (`:2947`), `send-tab` (`:3002`), new `paste` arm, `sendTextSummary` (`:5224`), help (`:9661`), usage (`:17941`). Not `:2242`. Not `unescapeSendText`'s replacement table.
- `c11Tests/SendTextParseTests.swift` in c11LogicTests phase `37DDE3B0A6A70E75A7B2BEDF`. Hand-edit.
- `tests_v2/test_send_raw_and_flags.py`.
- `skills/c11/SKILL.md`, `skills/c11/references/api.md`.

- After the C11-257 merge only: Sources/SocketHandlers/SurfaceHandlers.swift::v2SurfaceSendText policy parse and live/pending call sites; Sources/TerminalController.swift::deliverSocketSendText optional newline policy; Sources/GhosttyTerminalView.swift::sendSubmitFormText optional newline-preservation policy. Preserve C11-257 event emission/body/attribution and boolean meanings; these are the explicit gated hunks necessary for stdin/no-submit acceptance, not a mailbox rewrite.
- Sources/CapabilityFeatures.swift enables send.raw. No SocketDispatch restructuring or EventEnvelope/mailbox file edit.

## Acceptance
1. Tagged build. A raw-mode PTY collector with bracketed-paste enabled records actual delivered bytes (do not rely on shell echo/printf reinterpreting backslashes). Raw mode preserves backslash+n and leading/interior/trailing LF/CR as documented; default mode still rewrites the escape and applies legacy trailing-submit semantics. Logic test exercises the production parser and delivery policy. Require CLI/server send.raw feature parity on this artifact.
2. `c11 send --tab <t> --bogus hello` exits non-zero, stderr contains `--bogus`, and `read-screen` does not contain `--bogus`. Same for `send --text hi`.
3. `printf 'line1\nline2\n' | c11 paste --tab <t> --no-submit` preserves both lines including the final newline, returns submitted:false, and schedules no Return outside the paste envelope. The raw PTY collector checks that boundary; in a real Claude Code composer the draft remains unsubmitted, then explicit send-key enter submits once. Repeat queued-before-attach and attached paths, leading/newline-only inputs, and default-send trailing-newline legacy behavior. A following command running does not itself prove no submission. `c11 paste --help` contains send --raw; parser unit exercises stdin mode without reading the real stdin. A legacy server lacking send.raw must reject the raw/paste invocation without delivering any bytes.
4. Create a terminal that is not attached (do not focus it). JSON has `queued: true` and `delivered: false`. The human line does not say the agent saw it. After the tab is shown, `read-screen` contains the text. An attached shell returns `delivered: true`. With submit, `submitted: true`. The skill says that means the Return was scheduled.
5. One multi-line `c11 send` into a Claude Code tab on the tagged build. `read-screen` records whether it became one turn. If it did, stop. If the Return was swallowed, record it and report the smallest follow-up to the Orchestrator; the ctrl+enter port remains outside this PR. This whole implementation already waits for the C11-257 merge. Do not claim the agent understood the text.

## Hot path
CLI parser plus opt-in socket/queued-paste newline policy. No work on the human keystroke path, hitTest, or forceRefresh. tab.send_text stays on the socket worker. Compare command-to-input/submit latency on the C11-270 paired baseline/candidate workload and registered budgets; no full soak from this seat. Extra capability discovery is a CLI operation, not per-key work.

## Strings
English only.

- `cli.send.unknown_flag` = "Unknown flag '%@'."
- `cli.send.stdin_conflict` = "'-' reads stdin and takes no other text."
- `cli.send.queued` = "queued, not delivered (tab not attached; the agent has not seen it)"
- `cli.send.delivered_submitted` = "delivered, return scheduled"
- `cli.send.delivered` = "delivered, not submitted"
- `cli.send.raw_unavailable` = "This server does not support raw/paste delivery. Use a build advertising send.raw."

`%@` must survive in the six-locale pass. C11-291 translates these. The skill prose is English source.

## Cut
No draft guard. No `launch-agent` prompt work (C11-258). No Ghostty bracketed-paste change. No byte-exact C0 promise. No ctrl+enter port in this PR. Do not reopen C11-173. Do not restore the `new-workspace` follow-up send.

## Dependencies
CLI arms `:2947-3024` sit beside C11-282's `read-selection` (inserted at `:2910`) and away from the `new-*` arms (C11-280, C11-283). C11-283's scoped-window route stays. C11-284 is the mandatory registry foundation. C11-257 must MERGE before any delivery/logging/mailbox-adjacent implementation; different hunks do not permit work. Refresh its actual booleans/event fields before implementing the listed newline hunks, then prove exactly one tab.input_sent event with preserved full text/caller attribution in live and queued paths. Shared skill files are one paragraph each. C11-294/280 touch GhosttyTerminalView lifetime/create regions; rebase their merged state without changing those mechanisms.

## Decisions
None for operator. The additive preserve_newlines policy is needed to satisfy existing stdin/no-submit acceptance; default send keeps its legacy trailing-submit rule. `paste` with no positional reads stdin. `send` reads stdin only for a lone `-`. `--json` on `send` / `paste` is accepted so it is not typed into the terminal. `--text` is rejected.

## Build
Branch `c11-1.0/C11-281-send-contract` from origin/main. remote build host: c11-logic for `SendTextParseTests`, then a tagged build with `C11_QA_LAUNCH` for the script and the one Claude Code check. Attribute any implementation commit to its actual author/model, not the previous planning owner. Sync the skill on the landing machine. Comment on C11-140 when the PR opens. Do not merge.

## Codex takeover verification
Owner: agent:codex-cli. Verified ticket, stored plan and cited code on intake origin/main 0ff8887e5e965400b01645ef40b85fd0b2605cf2. All behavioral checks above are planned, unperformed. Planning hold remains: no builds, tests, product-code commits or pushes until explicit BUILD MODE. Branch from current origin/main when this ticket starts, retaining predecessor merges and previous local commits.


## Build-mode authority (2026-10-01)
Orchestrator NEXT C11-281 authorizes implementation from fetched origin/main aa292e8f1c4ee95def5b3d9341a58d1a5553037c. C11-257 all lanes, including final teaching merge 0bc4b61779, are ancestors of this main; its barrier is lifted. Source inspection confirms the integrated sender still strips trailing newlines and implicitly requests Return, and it emits one tab.input_sent with text, caller attribution and delivery booleans after its attached/queued paths. Preserve that event and mailbox transaction code. C11-283 has not preceded this branch: preserve existing window targeting guard and incorporate its merge if it lands. C11-284 registry remains mandatory for raw activation/advertisement; implement independent parser and opt-in delivery policy first, then merge its landed main before feature wiring. Do not duplicate or emulate an absent registry.

ATLAS BUILDS LIVE is received and C11-216 remote-build scripts are on this base. Provision submodules without local compilation, use remote-build.sh --mode test for the parser/policy test class, and tagged remote build host validation for the send path. User permits --launch on local machine with its UI slot, but prefer retained tagged remote build host app for isolated socket proof. No local builds. New rule supersedes all owner-sync steps: only Merge Captain syncs installed skills from merged main. Never run sync-installed-skills.sh or edit ~/.claude/skills. PR opens only at handoff. Any 284 repair takes priority; 279 remains parked until explicit landing notification.


## Runtime seams and targeted evidence
The parser is executed before socket resolution, so unknown flags cannot become text and can fail even without a listener. Send-specific help respects the -- boundary; --help after -- is literal text. Sources/SendTextParse.swift also owns the attached/queued newline decision and delivery-state wording. Sources/GhosttyTerminalView.swift adds sendQueuedSocketText, used by both queue fallbacks, preserving raw newline-only content and stamping an unsubmitted newline-ending raw draft for existing mailbox admission. The default path retains its existing queue trim/submit behavior. EventEmitter calls, bodies and caller fields remain unchanged.

Add c11Tests/TerminalAndGhosttyTests.swift to the test files: two host-bound queue tests execute that actual queue helper and assert bytes, pending Return and raw-draft timestamp. SendTextParseTests includes a built-CLI protocol fixture scenario (synthetic listener, not live PTY proof). tests_v2/test_send_raw_and_flags.py --offline checks parser/output/request bytes, caller attribution, reachable unsupported-feature rejection with no send, and -- terminator handling. Default live mode requires deliberately named C11_281_SOCKET and uses a raw bracketed-paste-enabled PTY collector to check actual paste content and the separate Return, including leading/trailing/newline-only input. Never default to operator socket environment.

remote build host invocation a0929dea60d246639a54d59264f1c3dc at ba5824df22d35c88f125ee44e77e047eb72b93de compiled and passed six pure parser/policy tests. Invocation b9febaeca8e14625832d2cb102b7f6a1 at ba880d1fd66db2572b3d949b0693b04e7ff0f00d compiled, passed those six plus two host queue tests, but built-CLI fixture failed because it incorrectly assumed there was no existing C11-248 vocabulary capability probe. Corrected the fixture to allow that existing probe and preserve one send request. Added literal-help coverage and queued raw-draft handling; current exact-head repeat is queued/running. None of these is a complete live acceptance gate yet.

Additional localized keys: cli.send.target_required, cli.send.text_required, cli.send.stdin_utf8, cli.send.help. C11-291 owns translations. Existing cli.send.raw_unavailable remains the connected-server gate message. Final typed registry activation awaits C11-284 landed main. remote build host C11-259 capacity reservation is expected scheduling, never a BLOCKED reason.


## Registry integration (2026-10-02)
C11-284 merged as 2d2440ac65425b0041aad2b3117f6c1c5e612768. Ordinary merge fafeaff744 preserves offline guide admission before socket discovery and the send parser before socket resolution. Enable only rawSend version 1 in this ticket; canonicalRoutingKeys, initialInput, terminalSelection and windowRouteWithoutFocus remain disabled. CLI paste joins explicitTab admission. Raw CLI checks the local typed entry and connected server feature/version; the server checks that same typed entry off-main before target resolution and rejects empty raw text (newline-only remains valid). Additional localization key socket.send.raw_unavailable. No installed skill sync.
remote build host invocation 79183a578c634f88a34123aedfebff62 at 9edc960b6a0d0460f0209c5d87f1f5164ca18bd2 passed compilation and all nine targeted tests, including built CLI protocol fixtures and two actual pending-queue helper tests. This preceded registry integration and is not final-head or live-product proof. Repeat the checks on the integrated head and run tagged PTY/composer scenarios before handoff.


## Deterministic queue proof fixture
Current main starts hidden cold terminals on socket demand, so an ordinary background workspace does not guarantee queued:true. To complete acceptance 4 through the actual handler, add a DEBUG-only per-tab runtime-start hold in GhosttyTerminalView and DebugHandlers, listed with existing debug methods in SystemHandlers. The hold rejects a live attached runtime, never tears one down, releases automatically after ten seconds, and adds no Release or keystroke-path work. The tagged tests_v2 scenario uses one new, never-selected terminal, holds its background start, requires actual queued:true/delivered:false/ submitted:false JSON plus queued human text and one full attributed event per request, releases the hold and shows the tab to check the exact draft flushed. Ordinary attached byte/composer proof remains free of this fixture. Additional debug error localization key socket.debug.runtime_hold_attached. No permanent app/tool settings change.
On ad067f3699, all 17 selected tests and tagged attached PTY/event proof passed. Claude Code 2.1.284 recorded raw no-submit as a draft until explicit Return, and a default multi-line send as exactly one user turn. Its login was expired: no model response/agent acknowledgment is claimed. No Ctrl+Enter port is needed to submit the composer.

Queue fixture correction: both workspace.create and tab.create eager-load in the integrated product, so applying a hold in a later socket call races attachment. debug.terminal.runtime_start_hold now accepts create:true beside an existing anchor tab, creates one unfocused fixture tab and sets its per-tab hold within the same main-thread turn. The DEBUG-only hold is checked at createSurface's single runtime creation seam and releases after ten seconds. No global reservation or teardown of a live surface. The fixture then exercises ordinary raw send handler requests and releases via the same tab id. Additional key socket.debug.runtime_hold_create. Production Release code does not include the fixture.


## Repair round 1 (2026-10-02)
Orchestrator review ev_01M3XT05X0BD50W1B5M3B33RYW: finding 1 is waived. Preserve the planned contract: default submit; --no-submit suppresses Return. Fix findings 2/3 in one owner repair commit, then push/HANDOFF; C11-279 is parked at clean f28885d135.

Change only TerminalController.serveCommandLines framing storage from String chunks to raw Data. Retain bytes until newline, decode the complete frame once, leave per-read autoreleasepool and response/auth dispatch unchanged. The existing SocketClientCommandLoopTests socketpair harness gets a large multibyte request whose first maximum-size read bisects a UTF-8 character, followed by a second request on the same connection; retain its framing/blank-line/autorelease tests.

Extend the remote build host built-CLI live scenario with large ASCII stdin and multibyte UTF-8 stdin. A transparent fixture proxy pauses inside a UTF-8 sequence near the 4095-byte read limit, forwards the same CLI request without rewriting, and captures the deliberate fragmentation; compare the complete bracketed-paste bytes at the raw PTY collector and assert one full attributed event. No production transport protocol rewrite or new size cap.

For required queued byte proof, extend the existing bounded, per-tab DEBUG fixture with a ten-second pending-flush hold. Queue through the ordinary pre-attach send timeout, then attach the runtime and launch a raw PTY collector while that queue is held. Explicit release invokes the actual production flush, including the synthetic Return outside the paste; automatic release is bounded and this rail is absent from Release. Retain the original unmodified automatic-attach/read-screen case as separate evidence. Cases: leading/interior/trailing newlines, newline-only positional raw, raw stdin multibyte/newlines, newline-only paste stdin, and default-submit raw stdin. Assert queued/delivered/submitted responses, exact PTY paste body and zero/one external Return, and one full attributed queued event per input. This additional DEBUG guard is only at flush, not human keystrokes/forceRefresh/hitTest.

Correct prior evidence's observed Claude version to 2.1.287 per retained screens (the old driver constant 2.1.284 was wrong). No new model response is required; this repair verifies transport and queue bytes. No tenant config writes, local machine build/launch, or installed-skill sync. remote build host targeted actual test action and tagged artifact must identify the clean new repair head. Captain retains the CI landing gate.


Repair validation checkpoint: initial clean 0d2de4f397 passed 12 remote build host tests and large ASCII/fragmented UTF-8 PTY equality (74029-byte wire request split at byte 4001). Automatic queue attach and the first 27-byte queued newline/Return oracle passed. The second queue case exposed the harness reusing a visible workspace, where new terminals eager-attach; use a new inactive disposable workspace for each case and guard its final cleanup. Amended the unpublished repair, preserving one commit from c8c04ea982, to final aabd639e92e3a4776f288ef86415f76c8fee4e57. Repeat the targeted test action and tagged runtime at this exact head. Superseded pre-admission test 38556f491b3c4f48baa2c760e223cd93 was cancelled without touching other jobs. remote build host disk-full admission failed once before compilation; the Orchestrator freed capacity and the retry succeeded. Retain final artifacts locally and delete owned remote build host tag/DerivedData dirs after validation, per new cleanup instruction; no Tart guests were used.


## Fresh review after current-main merge
The Orchestrator requested an ordinary merge after C11-280 landed as 1334615d98b1a58a0bc93862a6e7b7b03ac12cbc. Parked C11-279 at clean 603a4d91e4 and merged main into this branch, preserving all history. Only two conflicts: CapabilityFeatures keeps both create.initial_input and send.raw enabled at version 1; CLI subcommand-help detection keeps the send terminator-aware guard and uses createArgs after --command value extraction. Guide's offline early return stays intact. Merge head 945d90eaac3794d27e24952e112cbff30a25d9fa; no new product behavior beyond the union. Inherited Ghostty main pointer 5830d1976eecca0d7dee202aef8fb2338d99ed6d, no engine edits.

Rerun the commissioned 14 tests (send parser/protocol, registry, command-loop framing/autorelease, two host queue tests) on remote build host. Build and launch the same clean merged source as tagged Debug for both send raw/queue fixture and the existing C11-280 create-initial-input script, preserving both CLI paths and feature discovery. Review handoff is FRESH, CI pending, one push after validation. Retain local private evidence, publish sanitized prose only, stop owned tag, and remove its remote tag/DerivedData cache after validation. Then resume 279 and union its registry entry with current main. Captain handles installed-skill sync and landing.

## Reset 2026-10-02 by agent:codex-cli
