# Codex two-panes-same-cwd fixture

This fixture documents the **2026-04-27 staging-QA failure** that motivated
the C11-24 conversation store: two Codex panes opened in the same project
both restored to the most-recent global Codex session ("B") instead of
their own. The merge-blocker fixture-driven regression test
(`testTwoPanesSameTuiSameCwd_2026_04_27` in
`c11Tests/ConversationStoreFailureModeTests.swift`) reproduces that shape
and asserts the new behaviour: under ambiguous multi-candidate conditions,
**neither pane resumes auto-magically** and the ambiguity advisory
surfaces via `c11 conversation get`.

## Layout

The test uses an in-memory mock filesystem layout that mirrors what
`~/.codex/sessions/2026/04/27/` would contain on the day of the failure:

```
.codex/sessions/2026/04/27/
├── ddd11111-2222-3333-4444-555566667777.jsonl   ← session A (cwd=/work/proj, mtime=T+60)
└── eee22222-3333-4444-5555-666677778888.jsonl   ← session B (cwd=/work/proj, mtime=T+120)
```

Two Codex panes, both with `cwd=/work/proj` and a wrapper-claim from
`T-300`. Both candidates pass the surface filter (cwd match + mtime ≥
claim time). With the old `codex resume --last` strategy, both panes
resumed session B — the bug. With the new strategy:

- `state = .unknown`
- `id = eee22222-…` (most plausible, newest mtime)
- `diagnosticReason = "ambiguous: 2 candidates; chose newest"`
- `resume()` returns `.skip(reason: "ambiguous")`

Operator clears via `c11 conversation clear --surface <id>` to force a
fresh launch on either pane.

## Why no real session file content

The privacy contract (architecture doc § "Privacy contract for scrape")
forbids transcript bytes from entering c11 snapshots, the conversation
store, the global derived index, diagnostics, or telemetry. The scraper
reads metadata only — filename, mtime, size. The fixture mirrors that:
no content; the test asserts behaviour against a metadata-only mock
filesystem.
