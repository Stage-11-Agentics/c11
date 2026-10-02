# Review: C11-291 (translate new 1.0 strings into the six locales), pass 1

Follow `/Users/atin/Projects/Stage11/code/c11/.lattice/orchestration/c11-1.0/briefs/reviewer-common.md`; it is your contract.

- Ticket **C11-291**. PR https://github.com/Stage-11-Agentics/c11/pull/534, head `7378162477ec7256ddef509d53cfcee46c82c12a`, base = merge-base with origin/main.
- Title `C11-291 Review Astra`. Actor `agent:astra-review-291`. Owner was Codex Luna.
- Validation artifacts `art_01M3YK9V9NKDTH6PQ5W3EWDXZQ`, `art_01M3YK9VC7HWV6F9A5F92DKB9X`.
- This is pass 1 (strings already on main); a refresh pass covers strings added before the freeze. Focus: `Resources/Localizable.xcstrings` is well-formed (`jq .`); every new 1.0 key on main has ja, uk, ko, zh-Hans, zh-Hant and ru values with state translated; every interpolation token (`%@`, `%lld`, `%1$@`...) in the English value appears in each translation, in a valid position; command names, flags, socket method names and machine error codes stay verbatim; no English left untranslated in a translated slot; no existing key or translation removed or changed beyond the new keys. Spot-check translation sense on a sample per locale (you read these languages well enough to catch nonsense or wrong-register UI text).
- When done, send VERDICT and wait.
