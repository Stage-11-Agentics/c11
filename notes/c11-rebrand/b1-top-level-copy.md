# B1 — Top-level copy rebrand

You are one of four parallel agents executing a fork-level rebrand from `c11mux` → `c11` on the Stage 11 fork of cmux. **Read `notes/c11-rebrand/00-shared-rules.md` before starting — it carries the scope heuristic, hard rules, brand casing, and branch hygiene that apply to every bucket.**

Your bucket handles the root-level prose files. These are small but highly visible.

## Mission

Rebrand the product name from `c11mux` to `c11` in root-level user-facing copy. Do not touch anything else.

## Files in scope (exclusive ownership)

- `README.md`
- `README.ja.md`
- `CLAUDE.md` (root only — nested CLAUDE.mds do not exist in this repo)
- `PHILOSOPHY.md`
- `CHANGELOG.md`
- `C11MUX_TODO.md` → rename to `C11_TODO.md` (git mv), then rebrand prose inside
- `Resources/welcome.md`

## Files out of scope (do NOT touch)

- Anything under `docs/` — that is B2's territory.
- Anything under `skills/` — that is B3.
- Anything under `Resources/` except `welcome.md` — that is B4.
- Any `Sources/`, `cmuxTests/`, `.lattice/`, `vendor/`, `ghostty/`, `cmuxd/`, `scripts/`, `tests_v2/`.
- The `.github/` directory, `package.json`, `Package.swift`, `GhosttyTabs.xcodeproj/`, `*.pbxproj`, `*.xcconfig`, `*.xcstrings`.

## Hard rules (bucket-specific on top of shared)

1. **Code fences are untouchable.** Every `cmux <command>`, `./scripts/reload.sh --tag`, `CMUX_*` env var, `/tmp/cmux-*.sock`, `cmux-debug-<tag>.log` example in a fenced block stays byte-identical. Only rebrand prose outside fences.
2. **`CLAUDE.md` has recent live edits** (a `prune-tags.sh` paragraph added by the operator). Do not restructure the file. Only in-place `c11mux` → `c11` substitutions in prose. Diff must be clean.
3. **Filenames in link text rebrand; link targets stay unchanged** unless explicitly renamed here. Example: `[c11mux theming plan](docs/c11mux-theming-plan.md)` becomes `[c11 theming plan](docs/c11mux-theming-plan.md)` — visible text rebrands, path stays. B2 decides whether `docs/c11mux-theming-plan.md` itself gets renamed.
4. **Watch for compound forms in prose:** "c11mux's", "c11mux-native", "c11mux workspace", "inside c11mux", "c11mux pane". All of these become `c11's`, `c11-native`, `c11 workspace`, `inside c11`, `c11 pane`.
5. **`C11MUX_TODO.md` → `C11_TODO.md`:** use `git mv` (not `mv`) so history follows. Also update any internal references to the old filename inside the file.

## Branch + commit

```bash
git checkout c11/rebrand
git pull
git checkout -b c11/rebrand-b1
# do the work
git add <only your files>
git commit -m "c11 rebrand: top-level copy (C11-1)"
git push -u origin c11/rebrand-b1
```

## Definition of done

1. `rg -n '\bc11mux\b' README.md README.ja.md CLAUDE.md PHILOSOPHY.md CHANGELOG.md C11_TODO.md Resources/welcome.md` returns zero matches (code fences excepted — you may need to spot-check manually).
2. `git diff c11/rebrand..HEAD --stat` shows only the 7 files in scope.
3. `git log c11/rebrand..HEAD` shows 1–3 commits, all prefixed `c11 rebrand:` and tagged `(C11-1)`.
4. Final report includes: file list, diff stat, any rebrand opportunities spotted outside scope, any prose-vs-fence judgment calls.
