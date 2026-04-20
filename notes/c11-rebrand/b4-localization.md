# B4 — Localization rebrand (xcstrings)

You are one of four parallel agents executing a fork-level rebrand from `c11mux` → `c11` on the Stage 11 fork of cmux. **Read `notes/c11-rebrand/00-shared-rules.md` before starting — it carries the scope heuristic, hard rules, brand casing, and branch hygiene that apply to every bucket.**

Your bucket handles localized user-facing strings. The bucket is small but requires care — `.xcstrings` is a structured JSON format and Xcode parses it strictly.

## Mission

Audit `Resources/Localizable.xcstrings` for English and Japanese strings that carry the product name `c11mux`, and rebrand them to `c11`. Do not touch any other file.

## Files in scope (exclusive ownership)

- `Resources/Localizable.xcstrings` — single file, JSON.

## Files out of scope (do NOT touch)

- `Resources/welcome.md` — owned by B1.
- `Resources/bin/*` — not in any bucket (CLI symlink deferred to follow-up ticket; see end of this brief).
- Anything outside `Resources/`.
- Any string key that does not carry the product name in its English or Japanese value. Keys stay; you only edit values that literally contain "c11mux" or localized equivalents.

## Hard rules (bucket-specific on top of shared)

1. **xcstrings is JSON.** Preserve exact formatting. No reordering keys, no whitespace changes, no comment edits. Only change the `value` fields that contain the product name.
2. **String keys (the dict keys on the left) stay.** If a key is `welcome.title` with value `"Welcome to c11mux"`, the key stays and only the value rebrands to `"Welcome to c11"`. If a key is literally `c11mux.something`, **leave the key alone** — code references it by that key. Only rebrand values.
3. **Check Japanese translations too.** Japanese localization may render the product name as `c11mux` in Latin characters inside Japanese strings (Stage 11 style is to keep the product name Latin even in Japanese). Rebrand `c11mux` → `c11` in Japanese values the same way.
4. **Do not add new keys or new locales.** Only edit existing values.
5. **Do not edit strings that reference the binary or env vars.** A string like `"Run cmux help for options"` refers to the CLI binary — leave it. A string like `"Welcome to c11mux"` refers to the product brand — rebrand it. When in doubt, lean toward not editing and flag for review.
6. **Compound forms:** "c11mux's", "inside c11mux", "c11mux workspace" → `c11's`, `inside c11`, `c11 workspace`.

## Validate the JSON before committing

After editing:
```bash
python3 -c "import json; json.load(open('Resources/Localizable.xcstrings'))"
```
Must exit 0.

## Branch + commit

```bash
git checkout c11/rebrand
git pull
git checkout -b c11/rebrand-b4
# edit Resources/Localizable.xcstrings
# validate JSON parses
git add Resources/Localizable.xcstrings
git commit -m "c11 rebrand: localized product-name strings (C11-1)"
git push -u origin c11/rebrand-b4
```

## Definition of done

1. `Resources/Localizable.xcstrings` parses as valid JSON.
2. `rg -n 'c11mux' Resources/Localizable.xcstrings` returns only entries where (a) the key itself contains `c11mux` (intentionally left), or (b) explicitly-historical phrasing.
3. `git diff --stat c11/rebrand..HEAD` shows only `Resources/Localizable.xcstrings`.
4. Final report lists every value changed (before/after) and every string you decided NOT to change with the reason (binary reference, env var reference, intentional key, etc.).

## Out of scope (deferred, do NOT do here)

- **`c11` CLI symlink in `Resources/bin/`:** the `cmux` binary is not checked into the source tree — it ships inside the built `.app` bundle at runtime. Adding a `c11` symlink requires runtime install logic (similar to the `Resources/bin/claude` wrapper), which is a code change, not a rename. Deferred to follow-up ticket. Do not add anything to `Resources/bin/`.
