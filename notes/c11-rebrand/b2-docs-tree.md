# B2 — docs/ tree rebrand (largest bucket)

You are one of four parallel agents executing a fork-level rebrand from `c11mux` → `c11` on the Stage 11 fork of cmux. **Read `notes/c11-rebrand/00-shared-rules.md` before starting — it carries the scope heuristic, hard rules, brand casing, and branch hygiene that apply to every bucket.**

Your bucket handles the `docs/` tree. This is the largest bucket by volume. You will rebrand prose in active docs and rename a subset of filenames. Historical/frozen docs stay untouched.

## Mission

1. Rebrand product-name prose inside active docs.
2. Rename filenames for docs that are still being actively edited.
3. Freeze historical specs and review artifacts — do not touch their filenames or contents.

## Three-tier classification

**Tier A — active authoring docs: rebrand prose AND rename file** (`git mv`, update inbound links in B1/B2's files)

- `docs/c11mux-charter.md` → `docs/c11-charter.md`
- `docs/c11mux-voice.md` → `docs/c11-voice.md`
- `docs/c11mux-theming-plan.md` → `docs/c11-theming-plan.md`
- `docs/c11mux-pane-dialog-primitive-plan.md` → `docs/c11-pane-dialog-primitive-plan.md`
- `docs/c11mux-pane-dialog-primitive-validation.md` → `docs/c11-pane-dialog-primitive-validation.md`
- `docs/c11mux-pane-naming-plan.md` → `docs/c11-pane-naming-plan.md`
- `docs/c11mux-pane-title-bar-plan.md` → `docs/c11-pane-title-bar-plan.md`
- `docs/c11mux-snapshot-restore-plan.md` → `docs/c11-snapshot-restore-plan.md`
- `docs/c11mux-textbox-port-plan.md` → `docs/c11-textbox-port-plan.md`
- `docs/c11mux-tier1-persistence-plan.md` → `docs/c11-tier1-persistence-plan.md`
- `docs/c11mux-workspace-metadata-persistence-plan.md` → `docs/c11-workspace-metadata-persistence-plan.md`
- `docs/c11mux-consolidation-notes.md` → `docs/c11-consolidation-notes.md`
- `docs/c11mux-integration-review.md` → `docs/c11-integration-review.md`

**Tier B — frozen historical: DO NOT rename, DO NOT edit prose inside**

- `docs/c11mux-module-1-tui-detection-spec.md`
- `docs/c11mux-module-1-impl-notes.md`
- `docs/c11mux-module-2-metadata-spec.md`
- `docs/c11mux-module-3-and-6-sidebar-and-markdown-spec.md`
- `docs/c11mux-module-4-integration-installers-spec.md`
- `docs/c11mux-module-5-brand-identity-spec.md`
- `docs/c11mux-module-7-title-bar-spec.md`
- `docs/c11mux-module-7-expandable-title-bar-amendment.md`
- `docs/c11mux-module-8-tree-overhaul-spec.md`
- `docs/binary-rename-considered.md`

**Tier C — non-c11mux-prefixed docs: rebrand prose, do NOT rename file**

- `docs/agent-browser-port-spec.md`
- `docs/browser-automation-reference.md`
- `docs/ghostty-fork.md`
- `docs/notifications.md`
- `docs/remote-daemon-spec.md`
- `docs/socket-api-reference.md`
- `docs/socket-focus-steal-audit.todo.md`
- `docs/upstream-sync.md`
- `docs/v2-api-migration.md`

## Files out of scope (do NOT touch)

- Everything outside `docs/`.
- Tier B filenames and contents.
- Any source code referenced by relative path from a doc (e.g., don't edit `Sources/Foo.swift` even if a doc links to it).

## Hard rules (bucket-specific on top of shared)

1. **Code fences are untouchable.** Shell commands, socket paths, env vars, binary names, filenames in paths inside fences all stay.
2. **`git mv` for Tier A renames, not `mv`.** History must follow the file.
3. **After renaming Tier A files, update inbound Markdown links** inside the rebranded docs themselves. Links from other files (README, CLAUDE.md, etc.) are B1's responsibility — flag them in your report; do not edit.
4. **Module-N references in prose stay.** The `c11mux-module-1` etc. nomenclature is historical shorthand used in commit messages and Lattice tickets — if a Tier A doc references `c11mux-module-4-integration-installers-spec.md`, keep the filename in the link target and rebrand only the surrounding prose.
5. **Do not modify Tier B contents** even to fix typos or update broken links. They are frozen.
6. **Compound forms:** "c11mux's", "c11mux-native", "c11mux workspace", "inside c11mux", "c11mux pane" → `c11's`, `c11-native`, `c11 workspace`, `inside c11`, `c11 pane`.
7. **The product was called `c11mux`.** When writing historical prose that says "previously called c11mux", leave that phrasing. Historical references to the old name are fine when they're explicitly historical.

## Branch + commit

```bash
git checkout c11/rebrand
git pull
git checkout -b c11/rebrand-b2
# suggested commit sequence (keep commits reviewable):
#  1. git mv Tier A filenames
#  2. rebrand prose in Tier A
#  3. rebrand prose in Tier C
# each as a separate commit
git push -u origin c11/rebrand-b2
```

## Definition of done

1. All Tier A files renamed via `git mv`, prose rebranded.
2. All Tier C files prose rebranded, filenames untouched.
3. All Tier B files byte-identical to `c11/rebrand` baseline.
4. `rg -n '\bc11mux\b' docs/ | rg -v '^docs/(c11mux-module|binary-rename-considered)'` returns zero matches outside code fences and explicitly-historical phrasing.
5. `git diff --stat c11/rebrand..HEAD` shows only files under `docs/`.
6. Final report includes: (a) Tier A renames completed, (b) broken inbound links from other buckets (README, CLAUDE.md, skill files, etc.) that the operator or B1/B3 agents need to fix, (c) any judgment calls on Tier A vs Tier B (e.g., a doc that felt ambiguous).
