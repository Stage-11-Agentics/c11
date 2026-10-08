# Repair brief 1: C11-362 (PR #626, head 6148809111)

Review 1 (Claude Opus) is a FAIL. The full review is at `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/md-viewer/review1-C11-362.md`; follow its "Repair checklist". Grok's Review 2 is running on the same head, and its blocking findings come as an addendum. **Start now; push once, after the addendum.**

- **B1:** a filename containing `#` must open again, as on main. Split the fragment only when the whole string isn't an existing file.
- **B2:** in-document anchors always scroll in place, in either mode, with no duplicate panel and a correct history entry. ⌘-click on an anchor does the same.
- **B3:** ⌘-click inverts the default (`meta != defaultIsNewPanel`), and the skill sentence matches.
- **Repair in place (the review's N list):** N1 test gaps; N2 repeated navigation after scrolling away; N3 a panel that moves after its caller was told it timed out; N4 bounded reads and payloads; N5 skill and schema precision; N6 FIFO `.md` targets (refuse non-regular files before reading); N7 in-repo symlinks must pass the extension check on the resolved path; N8 the breadcrumb shows the file name; N9 the peek popover offset. Each blocking fix needs a test that goes red without it.

Then push once, refresh the validation comment, and send `HANDOFF C11-362 REVIEW <head> …`.
