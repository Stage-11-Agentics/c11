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

Plain `unittest`, no dependencies. Fixtures cover every evidence class, the Ghostty and leaf shapes the reviews found, and the gates; plus one fixture per leaf-source alternative in `gen-pass1.py`
(`LEAF_SOURCES`), each in a chained-closure, `let`, `for`, and `guard let` / `if let` shape: the binding
must be tainted, renamed to its bonsplit spelling, and flagged by `check-leaf` when mis-renamed to
`workspace` or the `ws` fallback. Add a `LEAF_SOURCES` entry (with an example) for every new leaf source.

## Passes 1c to 2b (PR B): rename only with positive evidence

An identifier is renamed only when something in the code proves it belongs to the c11 tab domain; an ambiguous
name keeps its old spelling (an old word is acceptable debt, a misleading name is not). The Ghostty wrapper
domain (`ghostty_surface_t`, `TerminalSurface`, `GhosttySurface*`, `IOSurface`, `layer.contents`, the raw handle
read out of a wrapper, readiness flags such as `hasSurface`, `surfaceLog`, `sendTextToSurface`) always keeps
its names.

Order: 1c (hand-written table, workspace leftovers), 1d (`gen-pass1d.py`: Bonsplit leaf values become
`bonsplitTab*`, including functions that return `[TabID]` and labels in front of a `TabID` parameter),
2a (`gen-evidence.py 2a`: Surface* to Tab*), 2b (`gen-evidence.py 2b`: Panel* to Tab*, `Sources/Panels` to
`Sources/Tabs`). Each runs on the tree as the previous pass left it and is compile-checked.

Evidence classes (each table row carries `ev:<class>`, each applied rename is logged with its class and site
in `evidence-<pass>.tsv`):

- `T`: a type c11 declares in the tab domain, and its file.
- `M`: a member declared on such a type, or on `Workspace`/`WorkspaceManager` with a tab-domain signature, with
  every use. Every declaration of the name must agree, and a signature that also names a Bonsplit leaf or a
  Ghostty value keeps the name.
- `L`: a local or parameter annotated with a c11 tab type or bound directly from a c11 tab API (at most one hop).
- `Leaf`: explicit `TabID`/`Bonsplit.Tab`/`[TabID]` annotations and Bonsplit API sources become `bonsplitTab*`.
- `F`/`X`: curated one-off rows written in the table itself (`@fix`, `@regionrename`, explicit rows).

Gates, after each pass (all must report zero):

    python3 scripts/vocab-rename/rename.py check-evidence scripts/vocab-rename/evidence-2a.tsv <base> WORKTREE scripts/vocab-rename/pass-2a.tsv
    python3 scripts/vocab-rename/rename.py check-domains
    python3 scripts/vocab-rename/rename.py check-literals

`check-literals` finds string literals (Sources, CLI, c11Tests, c11UITests) that still contain, as a whole identifier,
the old spelling of anything a pass table or evidence log renamed (camel/Pascal-case names of 6+ characters). A name
that is looked up at runtime must follow the rename (reflection such as `String(describing: type(of:))`,
`NSClassFromString`, accessibility ids read by UI tests, debug-menu titles naming a type). Deliberate wire, persisted
and settings keys, localization and command ids, log text and message text stay, and are recorded in
`literals-reviewed.tsv` (file, name, class, reason); an unlisted hit fails the run.

`check-evidence` diffs the pass against its base and requires every changed identifier token to be in the log
with a class, then re-derives each class from the tree (a type declaration, a member declaration on a tab
owner, a binding statement that names a tab-domain type or API, a Bonsplit leaf type). `check-domains`
judges the result by itself: a tab-named binding sourced from Ghostty or a Bonsplit leaf, a Ghostty-named or
`bonsplitTab*` binding sourced from a c11 tab, `[TabID]`-returning functions and `TabID` labels with c11
names, wrapper lifecycle names, readiness flags.

Table directives: `@taint ... <region regex> <exclude regex> <opts>` (opts `props`, `keep`, `funcs`, `bindonly`,
`onehop`, `noextra`, `noleaftype`, `relabel`, `ev:<class>`), `@regionrename`, `@novendor`, `@callee name keep:label`,
`@fixall`; flags `memberonly`, `nomember`, `noprop`, `nolabel`. Colliding locals take the row's fallback name
consistently within a member. `sync-docs.py` brings the paths and type names in CLAUDE.md and the developer docs
along.

## Pass 3 (PR C): Pane -> Area

`gen-evidence.py 3` renames c11-owned panes only: the types c11 declares (`PaneMetadataStore`, `PaneInteraction*`,
`PaneSizePolicy`, `BrowserPane*`, `V2Pane*`, `SessionPaneLayoutSnapshot`, `AreaSpec`, ... and their files), members
declared on them, and locals or parameters annotated with one of those types. Bonsplit's panes stay panes:
`PaneID`, `inPane:`, `focusedPaneId` and every identifier the vendored Bonsplit declares or uses are never renamed
as types or members, and a local that holds a `PaneID` keeps its `pane*` name. A name that already exists is left
alone (the pass lists it as a CLASH), so a geometry `area` can never be merged with a c11 area.

`check-domains` adds two probes for it: D (an area-named binding that holds a Bonsplit `PaneID`) and E (one name bound
to a geometry measure and to a c11 area in the same member). Persisted keys are untouched: layout leaves are still
persisted as `"pane"`, `paneMetadata` keeps its key, and renamed Codable properties get automatic `CodingKeys` pins.
