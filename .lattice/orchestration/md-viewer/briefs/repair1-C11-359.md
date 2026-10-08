# Repair brief 1: C11-359 (PR #621, head b4f6a62ee5)

The large-track synthesis (Claude Opus, reproduced on Atlas) is a FAIL. Read `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/synthesis-C11-359.md` in full; its "Repair brief for the owner" section is your list:

1. **B1 (blocking):** replace `titleBarDescriptionBlocks`' line classifier with one Foundation full-syntax parse (`AttributedString(markdown:options: .init(interpretedSyntax: .full))`) mapped to the existing native blocks. Add Astra's six probes plus the start-number, rule and quote soft-break cases. Keep the sanitizer, inert links and height cap; no new dependency, no web view.
2. **R1-REBASE:** see the base note below. Add the multi-line interior-line eviction test (line and ±1 px text row, before eviction and after restore), re-run your 8-class slice at the rebased head, and repeat the packaged eviction screenshot pair there.
3. **F1:** in-flight-query and capture-epoch witnesses with a held bridge promise.
4. **F2:** navigation, `window.open` and ⌘= witnesses in the real-WebKit test.
5. **Plus, my ruling on the synthesis's Q1:** base opened `mailto:` links and this PR refuses them. Restore `mailto:` only, opened through `NSWorkspace` after native validation; nothing else widens. One test.
6. Show each new test red with its guard removed, then green; record the Atlas invocation IDs in the validation comment. Correct the earlier "genuine in-flight query witness" claim.

H1–H8 go to the hardening ticket; don't do them here.

## Base
C11-358 (#620) passed both reviews at `8ad5469bef` and is with the Merge Captain now. Don't rebase onto R1's branch tip. Do B1, F1, F2 and the mailto change now on your branch. When I send `GO <merge-sha>` (#620 merged), rebase onto `origin/main`: `git rebase --onto origin/main 2c97338c4c` drops R1's pre-squash commits, and your duplicate offset commit `b4f6a62ee5` drops as already applied. Retarget #621's base to `main` (`gh pr edit 621 --base main`), add the interior-line eviction test and re-proof, push once, and send `HANDOFF C11-359 REVIEW <head> …`. The synthesis seat verifies.
