# c11mux spec integration review

**Date:** 2026-04-16
**Reviewer:** cross-cutting integration agent (read all 6 specs + charter + M2 + CLAUDE.md + socket-api-reference)
**Specs reviewed:** M1, M3+6, M4, M5, M7, M8 (written in parallel by 6 blind agents)

## Verdict: fix-then-commit

All six specs are well-researched and coherent with charter/M2. No fundamental breakage. Must-fix items are 1–2 sentence amendments; no architectural rewrites.

## Must-fix (before commit)

1. **M3+6 — TabItemView equatability approach not decided.** Spec describes both approaches (precomputed `let` param vs. avoid new observers) but defers. Pick one. (M3+6 spec lines 233–241)
2. **M1/M3 `terminal_type` mismatch on `unknown`.** M3's icon table omits `unknown`; rendering for that case is undefined. Add `unknown` to M3's icon table or explicitly say no chip. (M3 line 71 vs. M1 lines 56–65)
3. **M4 `claude-code` marker placement risk.** Marker currently embedded as sibling on hook entry; relies on Claude Code tolerating unknown keys. Move to parallel top-level `x-cmux` key (parallels OpenCode pattern) for all three TUIs. Don't defer to "Open question #3". (M4 lines 119–161)
4. **M7 M2-amendment procedure unclear.** M7 introduces `title`/`description` canonical keys but doesn't state whether M2 is amended in the same commit or later. Clarify. (M7 lines 39–56, 87)
5. **M5 icon 16px readability unverified.** Concept A (spike) recommended, but 16×16 legibility not shown. Add explicit approval gate (pixel render test or human review). (M5 lines 51–68, 88)
6. **M8 `split_path` mutability not specified.** Is it current-layout (recomputed per call) or persistent? State: computed on every `cmux tree` call, not a persistent identifier. (M8 lines 54, 141–147, 299)

## Should-fix (before implementation starts)

1. **M1 `cmux set-agent` prose** — two paragraphs could be one sentence on `CMUX_SURFACE_ID` resolution. (M1 lines 147–154)
2. **M6 `markdown.get_content` soft-result convention.** Listed under Error codes but should follow M2's `applied: false, reason:` pattern or explicitly name a new pattern. (M6 lines 410–417)
3. **M4 depends on M1's CLI.** Note that if M4 lands before M1, hooks must use raw `surface.set_metadata`.
4. **M5 `BrandColors` API surface.** Clarify: internal to c11mux, not public Swift module interface; tests access via `system.brand` socket method.
5. **M7 "25 UTF-8 characters (count grapheme clusters)"** — terms conflated. Should read: "25 grapheme clusters (Swift `String.Character` units)". (M7 lines 204–215)
6. **M3 `model_label` status.** Not a canonical key but readable via `surface.get_metadata`. State validation (≤16 chars string) and that it's consumer-opted, not emitted by c11mux. (M3 line 92)

## Nice-to-have

1. M1 TUI matrix — add note that model heuristic constraint may revisit if TUIs adopt stable env markers.
2. M4 — note that bundled-wrapper hooks + installer hooks can coexist; Claude Code dedupes by command-string equality.
3. M8 — clarify floor-plan fallback to `displayTitle` (`v2TreeWorkspaceNode`) when no M7 title set.
4. Parking-lot naming — M3+6, M4, M7 each mention future work. Consider central "Charter Amendments" doc.
5. Summary table in charter listing which modules amend M2.

## Per-spec verdicts

- **M1 (TUI Detection)** — Ready as-is.
- **M3+6 (Sidebar & Markdown)** — Needs minor fixes (equatability, `unknown` icon).
- **M4 (Integration Installers)** — Needs marker safety + M1-dependency note.
- **M5 (Brand Identity)** — Ready pending icon validation.
- **M7 (Title Bar)** — Ready with copy edits.
- **M8 (Tree Overhaul)** — Ready pending one clarification on `split_path`.
