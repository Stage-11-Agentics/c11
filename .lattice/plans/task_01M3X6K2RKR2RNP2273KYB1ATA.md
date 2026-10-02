# C11-306 plan

## Citations (base `0ff8887e`)

Match, except one stale ledger line. `CMUXCLI.summarizeClaudeHookStop` is `CLI/c11.swift:17320`. It calls `readTranscriptSummary` at `:17335`. That function (`:17364-17393`) loads the whole transcript with `Data(contentsOf:)`, builds one `String`, and splits every line before it walks for the last `message.role == assistant`. `extractMessageText` (`:17395`) accepts a string or content-array text blocks joined by a space, then keeps `truncate(normalizedSingleLine(text), maxLength: 120)`. The Stop body truncates that again to 200 (`:17342`). The only caller is the Stop path at `:16793`. Ledger B028's `CLI/c11.swift:16884` is not this function. The ticket's "near 17340 / :17366" is this code. Upstream cmux #5202 (`3601aa007673`) reads a bounded tail. Sparkle packaging in that PR stays out.

A missing file makes `try?` return nil, and the session-record fallback at `:17345-17357` runs. `summarizeClaudeHookStop` returns nil only when there is no cwd and no last message. It does not throw, so a missing transcript does not fail the hook.

## Read

Add `Sources/ClaudeStopTranscript.swift`, public, and compile it into the same two targets as `Sources/CLIAdvisoryConnectivity.swift` (the app target and the c11-cli target). `CMUXCLI.readTranscriptSummary` calls it and does nothing else. No second reader, no `Data(contentsOf:)` of the transcript, no subprocess.

`ClaudeStopTranscript.read(path:maxTailBytes:)` opens the file, seeks to `max(0, size - maxTailBytes)`, and reads at most `maxTailBytes`. The default cap is 256 KiB. When the start offset is not 0, drop bytes before the first `\n` before UTF-8 decoding, so a line split by the cap is not parsed. A tail with no newline is entirely partial: return no assistant message. Walk only the remaining complete lines with today's JSON rules and the same 120-character single-line truncate. Return that message and `bytesRead`, the count the read actually returned.

The production path uses one seam, `(fileSize, maxTailBytes, read: (offset, length) -> Data)`, and asks that closure only for the tail. The path wrapper is what `readTranscriptSummary` calls.

`ClaudeStopTranscript.summary(cwd:lastAssistantMessage:fallbackBody:fallbackSubtitle:)` holds today's subtitle and body rules. `summarizeClaudeHookStop` passes the session record's `lastBody` and `lastSubtitle` through and returns that result. Only absent (nil) cwd and absent fallback return nil. Preserve the current nil-versus-empty distinction: an empty but present cwd supplies context and produces the generic completion fallback. Empty-but-present lastBody also continues to take precedence over lastSubtitle, as it does today.

A missing path, an unreadable path, or a tail that is not valid UTF-8 after the partial-line drop returns no message and does not throw.

## Cap

256 KiB. A normal assistant JSONL line fits, and so does a long one. A single line longer than the cap is dropped and the session fallback runs. That is the miss the ticket's risk names. Not an Atin decision.

## Acceptance → incident → test

1. A few-megabyte fixture whose last assistant message is in the tail still produces today's subtitle and body. Incident: B028, the full-file read. Test: `c11LogicTests` writes a temp JSONL of a few MB of non-assistant lines plus a final assistant line with known text. `read` returns that text truncated to 120. `summary` with a cwd returns subtitle `Completed in <directory>` and a body equal to that 120-character string. A fixture with no cwd returns subtitle `Completed`.
2. The only assistant message is older than the tail, so the read falls back, and it does not ask for the whole file. Incident: the same full-file read. Test: the injected reader fails the test if `length` exceeds the cap or `offset` is not `fileSize - maxTailBytes`, on a multi-megabyte size. `read` returns no message. `summary` then returns subtitle `Completed` and body `Claude session completed in <project>. Last: <session body>` from the fallback strings. A path-wrapper temp file asserts `bytesRead <= 256 KiB`.
3. A missing transcript still takes the existing fallback, and Stop does not fail. Incident: the hook has to finish when the file is gone. Test: a path that is not on disk. `read` returns no message and does not throw. `summary` with a session fallback returns that fallback. `summary` with no cwd and no fallback returns nil. `summarizeClaudeHookStop` stays non-throwing, so the Stop path's existing `try?` around the session upsert gains no new failure.

No host app or GUI validation. Use the built tagged CLI for the isolated Stop wiring check below; no soak. The logic class lives in `c11LogicTests` and does not touch `NSApp`. Atlas runs that class. Do not build on Hyperion.

## Hot path, threading, persistence

Stop runs in the short-lived `c11 claude-hook` process, off the typing path. The read is one seek and one bounded read in that process. No app snapshot, no socket-thread change, and no write under `~/.claude` or anywhere else. No new UI strings and no xcstrings keys. The existing "Completed" and "Claude session completed" literals move with the formatter. Do not localize them here.

## Cut

Journal append, fold, and replay (C11-273 / J2). Widening Claude hooks (C11-274 / J3). Do not link this ticket behind them. If they read a transcript later, they should call this reader rather than copy `Data(contentsOf:)`. No status change on those tickets. The wrapper exec loop (B064, `Resources/bin/claude`). Hook routing fallbacks and attention edge cases. Sparkle from upstream #5202. A helper process to do the read. Printing the transcript.

## Dependencies

C11-216 provides the built tagged CLI for the isolated Stop wiring check; C11-306 does not wait on the journal. All test execution waits for BUILD MODE and the Atlas route.

## Decisions

None. Owner call: the tail cap is 256 KiB.

## Codex takeover corrections (base 0ff8887e5e)

No test/build/product change performed. The read/formatter citations match. The inherited empty-context assertion contradicted `hasContext = cwd != nil || lastMessage != nil` at `CLI/c11.swift:17346`; corrected above. Add behavioral cases distinguishing nil cwd/fallback, empty-but-present cwd, and empty lastBody with nonempty lastSubtitle. Preserve today's strings and fallback precedence.

Bound the actual file read, not merely an injected seam: `FileHandle` closes on every outcome, determines size/seeks, and requests at most the validated positive cap. Keep memory proportional to the 256 KiB tail. Drop the leading partial record before UTF-8 decoding; fixtures cover a cutoff inside a multibyte scalar, a long assistant record within the cap, a record larger than the cap, malformed/truncated final JSON, string content and text-block-array content. A malformed final record must not discard an earlier complete assistant record in the bounded tail. Missing/unreadable paths retain fallback.

The planned logic tests remain host-free on Atlas. Additionally run the actual built tagged CLI's Stop route against an isolated socket fixture with a synthetic multi-megabyte transcript/session record and assert the emitted subtitle/body, proving the CLI calls the new reader rather than just testing a standalone helper. This is packaged executable wiring proof; no agent app/UI is required by this bounded CLI ticket. Use the tagged CLI from C11-216, with explicit fixture socket and temporary state paths; never the operator's session. Report a real-session Stop as unperformed unless separately observed.

C11-257's CLI/dispatch barrier applies. Land the bounded Stop reader before C11-273/C11-274 integrate hook changes; neighbors consume this reader and must not add another whole-transcript pass. This order is a shared-file integration prerequisite, not a dependency on journal completion. Project-file membership changes refresh against other seats. No Atin decisions or new UI/localization keys.

## Build-mode authorization and validation route

The Orchestrator explicitly cleared edits only to summarizeClaudeHookStop/readTranscriptSummary/extractMessageText in CLI/c11.swift, preserving readTranscriptSummary's signature and the Stop call site. It subsequently authorized ten hand-added project.pbxproj membership lines for the app/CLI helper and c11LogicTests, with no gem rewrite. New isolated executable fixture: tests/test_claude_stop_bounded_transcript.py. No send/mailbox/SocketClient changes.

Until ATLAS BUILDS LIVE, the existing draft-PR CI build job compiles app/CLI and runs the 12 host-free logic tests. No CI workflow step is added. The new isolated Stop fixture runs on Atlas against the exact built CLI after that signal. All fixture sockets, sessions and transcripts are synthetic and temporary. No Hyperion builds, tests or DEV app launches. Hold the review handoff until CI and isolated executable evidence are recorded.

## Adopted batch validation (Orchestrator, Atin-approved)

C11-306 is low risk under the revised go-owner.md Validation flow. The prior per-ticket Atlas executable gate above is superseded: hand off once exact-head GitHub CI and the targeted logic tests pass. The Atlas Validator builds merged main in batches and runs the numbered Validator scenario in the final validation comment. tests/test_claude_stop_bounded_transcript.py remains the executable acceptance fixture; it has not yet run. Any batch failure is repaired forward on this same ticket. No separate runtime proof is required before merge.
