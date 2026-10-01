# vocab-rename (C11-248)

Compiler-checked Swift identifier renames for the workspace / area / tab vocabulary.
`rename.py` lexes Swift (skips strings and comments, renames inside `\( )` interpolations),
applies a TSV symbol table by exact token match, and does file/pbxproj renames.

Re-run a pass on fresh main (never hand-merge):

    python3 scripts/vocab-rename/gen-pass1.py        # only if new identifiers need table rows
    scripts/vocab-rename/run-pass.sh 1               # table, then pass-1.manual.patch (hand edits)
    git add -A && git commit
    # compile: scripts/with-build-lock.sh xcodebuild ... -scheme c11-unit build-for-testing

Passes in order: 0 (typealias), 1 (workspace-meaning Tab*), 1b (bonsplit TabID names),
2a/2b (Surface/Panel -> Tab), 3 (Pane -> Area). `rename.py` prints COLLISION (a renamed local
would shadow an existing name; left alone) and CODABLE (a Codable property that needs a
`CodingKeys` pin to its old key) lines: resolve those in the pass's manual patch.
`idents.py --match REGEX --files` lists identifiers to build tables from.

## Leaf classification (pass 1)

A generic `tab`/`tabs`/`tabId`/`selectedTab` is a workspace or a Bonsplit leaf tab depending on the
binding, not the file. `gen-pass1.py` emits `@taint` rules (binding types and initializers that are
Bonsplit values: `tabs(inPane:)`, `selectedTab(inPane:)`, `allTabIds`, `TabID`, `Bonsplit.Tab`,
`TabInfo`, ...); `rename.py` applies them before the generic renames, closed under iteration, so
`for t in tabs` follows. After pass 1, require zero hits:

    python3 scripts/vocab-rename/rename.py check-leaf scripts/vocab-rename/pass-1.tsv

## Tests

    python3 scripts/vocab-rename/test_rename.py

Plain `unittest`, no dependencies. One fixture per leaf-source alternative in `gen-pass1.py`
(`LEAF_SOURCES`), each in a chained-closure, `let`, `for`, and `guard let` / `if let` shape: the binding
must be tainted, renamed to its bonsplit spelling, and flagged by `check-leaf` when mis-renamed to
`workspace` or the `ws` fallback. Add a `LEAF_SOURCES` entry (with an example) for every new leaf source.
