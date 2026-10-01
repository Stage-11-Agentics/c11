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
