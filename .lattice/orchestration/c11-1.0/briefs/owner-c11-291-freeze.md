# Owner: C11-291 freeze refresh (translate the final 1.0 English strings)

Read `luna-owner.md`, then `owner-common.md` and `go-owner.md` in this directory (Codex GPT-6-Luna max, fast mode off). Actor `agent:luna-291`; tab title `C11-291 Luna`.

- Worktree from current origin/main (fetch first): `git -C /Users/atin/Projects/Stage11/code/c11 worktree add -b c11-1.0/C11-291-freeze /Users/atin/Projects/Stage11/code/c11-worktrees/c11-1.0-C11-291-freeze origin/main`.
- Translate every key in `Resources/Localizable.xcstrings` that is missing in any of ja, uk, ko, zh-Hans, zh-Hant, ru, and every key whose English changed since its translation (C11-249 changed an Undo string; C11-266 added about 24 quick-view keys; check the others). English stays unchanged. Preserve every format token; `jq` must parse; mark values translated. Natural UI copy; count labels use count-neutral forms where plurals would be wrong (the C11-291 review rule for ru/uk).
- C11-268 may add a few more strings after it lands; if so, a tiny follow-up pass handles them. Do not wait for it.
- Run the catalog-wide checks the earlier reviews used (zero missing, tokens intact) and post them as a validation comment. One PR; `HANDOFF C11-291 REVIEW <head> <PR> <validation>` to tab:210. 45-minute box.
