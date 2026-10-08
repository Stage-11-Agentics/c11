# C11-359 verify 2: `75abca4256fca5544f7d130c870afc31a6694c87` (V1 only)

Needs you: nothing.

- Seat: `agent:claude-md-synth-359`.
- Head attested: `75abca4256fca5544f7d130c870afc31a6694c87`, one commit on `c3d4d0867d` ("Fix nested list markdown description grouping").
- Owner handoff: `ev_01M4DSDHZQJXZG93Q3YK091D08` (owner red `c9805fd7…`, green `e1d29719…`).

## Verdict: PASS

## Scope

`git diff --stat c3d4d0867d 75abca4256`: only `Sources/PanelTitleBarView.swift` (+32/−12) and `c11Tests/DescriptionSanitizerTests.swift` (+34). Nothing else changed.

## The fix

All in `titleBarDescriptionBlockKey` and its caller, in `PanelTitleBarView.swift`:
- A list item now takes the **innermost** item (`firstIndex(where: listItem)`). Its ordinal comes from that component, and its marker from the first list kind after it.
- A list item keys by its own identity, and a quote by the innermost quote's identity. Paragraph changes inside one item or quote join with `"\n"`.
- Other block kinds are unchanged.

## Evidence

- **Atlas `4b0235e5054e4f7c864518a6ab1ae65e`**, exact head, `dirty=false`: 8-class slice **94/94 PASS** (69 logic + 25 host), `** TEST SUCCEEDED **`. That includes my four nested-list probes, shipped verbatim (`testSynthNestedOrderedListNumbersItsOwnItems`, `…OrderedListNestedUnderBulletKeepsNumbers`, `…BulletsNestedUnderOrderedItemStayBullets`, `…LooseItemSecondParagraphStaysInItem`), plus the owner's two additions (loose-item `\n` join, multi-paragraph quote). The same four probes were red at `c3d4d0867d` (verify-1 run `37114e1e…`).
- **Local compile of the exact production parser, 34 cases:**
  - Nested ordered under ordered: `1.` `1.` `2.` `2.`. Ordered under bullet: `•` `1.` `2.`. Bullets under ordered: `1.` `•` `•` `2.`. Three-level bullets: depths 0/1/2.
  - Loose item: one row, `item one\nsecond para`. Multi-paragraph quote: one block.
  - Every B1 case from the synthesis gives the same output as verify 1: setext, closing hashes, wrapped item, `1. 1.`, reference link, hard break, start number, rule, quote soft break, indented code, `Step\n2. two`, and the plain description with its `Lineage:` line. No regression.

## Hardening additions (non-blocking; verify 1 behaved the same, so this fix did not introduce them)

- A paragraph that follows a nested list inside the same item (`1. a\n   - x\n\n   c\n2. b`) renders as a separate row that repeats `1.`.
- Nested quotes (`> outer\n> > inner`) render as two flat quote blocks with no nesting indent.

Both are rare in descriptions. They go on the hardening ticket with H1–H8 and the mailto encoded-newline note.

## State of the earlier items

B1, R1-REBASE (interior line within 1 px, packaged pair matched to this tree), F1, F2 and mailto were verified at `c3d4d0867d` (verify 1). This commit touches none of their files.
