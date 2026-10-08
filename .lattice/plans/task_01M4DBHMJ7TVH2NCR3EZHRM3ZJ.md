# C11-361 review repair plan

Rebased local branch onto `origin/main` at `fd263426f9d98a4c6306a9d3e5f771aa1b5c8b8c`. Current local `HEAD` is `bf5d53c373e0b011d8bdc04385a3598d74294930`. Do not push until the Grok addendum arrives; reconcile that addendum before the single push.

## B1 design: create the reader invisibly (option a)

On the main hop, call `ensureRenderer()` without creating or showing a host view, using the panel's last known area width. Pin the reader through the existing retention cache only for the bounded query. Wait off-main, with a deadline and cancellation, for `ready` and the first `rendered`, then run the WebKit call. This keeps heading matching in the existing renderer and respects the reader-cache cap. A watch does not hold a reader pin: it streams model state while evicted and resumes renderer-derived state when a query recreates the reader or the panel is shown. The gold heading flash is only expected once the panel is shown; document that behavior.

## B2 focus-safe external open

Use `NSWorkspace.shared.open(url, configuration:)` with `configuration.activates = false`. Resolve success from the asynchronous completion, waiting only off-main and with a bound. Prove the synthetic file opens while c11 remains the frontmost process. Update the skill to say the file opens behind c11.

## Tests and acceptance mapping

- Add socket-level coverage for `scroll`, `visible`, and `visible --watch` on a reader that has no renderer, plus delayed `ready`/first `rendered`; assert workspace and in-app panel selection stay unchanged.
- Reproduce unmounted hidden-workspace behavior and cache eviction after more than four hidden readers in the Atlas guest. Keep a running watch unpinned; prove model-state delivery continues and renderer state resumes after recreation/showing.
- Add tests that go red when M4 removes theme validation, M5 removes observer completion on close, and M3 removes `finish()`'s broadcast. Park the waiter before finish using an explicit event handshake.
- Bound the watch's initial state, prefer the fresh `visible()` result over cached state, and make disconnect cancellation wait for its cancel handler before the descriptor closes. Document or tolerate peer bytes and half-close.
- Make the stream path call `startupNotReadyResponse`, honor `shouldContinue()`, and check auth before routing-key validation.
- Reject bare integer `--panel N` for these commands with guidance to use `panel:N`; reject non-decimal scale forms as well as out-of-range values.
- Close skill gaps: document unmounted/`not_ready` recovery boundaries, `open-external` opening behind c11, the `markdown.agent_cli` feature id in both markdown and API references, and the flash-on-show behavior.
- Atlas proof: from the selected workspace's terminal, use a never-shown markdown panel in an unselected workspace for `scroll`, `visible`, and `visible --watch`; repeat after exceeding the four-reader cache cap; verify selection/focus is unchanged. With c11 frontmost, run `open-external`, verify the file opens and c11 stays frontmost. Capture the scroll flash after showing the reader.
- Run focused Atlas logic/socket tests, the CLI behavioral suite, parse/lint checks appropriate to changed files, then the tagged Atlas build and sandbox proof. Refresh the validation comment with each reviewer-requested demonstration and a numbered replay scenario.

## Reset 2026-10-08 by agent:codex-md-r4
