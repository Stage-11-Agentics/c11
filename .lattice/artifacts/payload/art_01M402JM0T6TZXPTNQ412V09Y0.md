C11-291 validation: catalog checks across the review rounds (batch fast rule)

Merged: final freeze refresh PR #577, squash b46cf452b6cf69f7f9b3cf5f89d57ba98ffcfb4c, landing head 1d6c79d220516d5ee195c80d22eecdbb13331117, catalog only. Earlier passes: PR #534 (cef86bc2bb, pass 1) and PR #554 (18c1226ea5, incremental refresh). Merge Captain receipt ev_01M402GZ0VND633PQQNP6F12AH: jq parses the catalog at the head and on the merged tree; scripts/check-locale-tokens.py reports OK for 36 changed keys x 6 locales; exact-head gate 6477aec10dda4504941357edb5d0be2f, Debug compile ok, full c11LogicTests 2,496 tests, 3 skips, 0 failures. Review: freeze-refresh round 1 FAIL ev_01M400F4DRRS6FKHCNXKCYNQ2D (12 needs_review units; ru/uk fixed plurals), round 2 FAIL ev_01M401FSGNRE5SD2X0ZZ5X1V1K (positional %1$lld plurals missed), round 3 PASS ev_01M4021TWKEBWPGPWVQDJXYQ63; pass 1 PASS ev_01M3YKMHP2W9ENB0PKWH7PY376.

Criterion -> evidence -> result
1. Every key whose English changed since v0.67.0 has all six locales with matching tokens -> owner freeze validation ev_01M4004F674A7F5EPFKXH1CKYC: 81 release-delta keys OK across six locales (2 removed keys not reintroduced); repair heads re-checked (ev_01M4019W787VSGJSASJKKXZHHP, ev_01M401XGJ9BYG98YGEV3CJCSV8); round-3 reviewer independent semantic check: zero format-argument position, type, multiplicity or escaped-percent mismatches across 1,593 keys and 9,558 units; Captain token check 36/36 -> PASS.
2. `jq . Resources/Localizable.xcstrings` exits 0 -> owner, reviewer and Captain at the head; Validator re-check on merged main now: exit 0 -> PASS.
3. On a tagged build in one of the six languages, a new 1.0 string shows translated -> pass-1 validation ev_01M3YK9VEN3TP9RYY5MPNY30S5: tagged build fe452ab603c04336a79c5e72532d76e8 in an isolated Atlas sandbox with AppleLanguages=ja showed the 1.0 History strings as 履歴 (window) and 戻る / 進む (menu); PID-scoped Escape dismissed the menu (art_01M3YK9V9NKDTH6PQ5W3EWDXZQ, art_01M3YK9VC7HWV6F9A5F92DKB9X, reviewer-inspected). Keys: the History title and Back/Forward items; language: Japanese -> PASS. Later keys from the freeze refresh were not rendered natively; that spot check is routed to sign-off.
4. The PR lists keys left English on purpose -> skill/docs/log/CLI prose and protocol codes are named as the intentional boundary in PR #534 (reviewed ev_01M3YKMHP2W9ENB0PKWH7PY376) -> PASS.
5. No empty values and no leftover translator notes -> round-3 review: zero missing, empty or non-translated units, and the translator-note result carried forward; Validator re-check on merged main now: 1,593 keys, 0 missing, 0 empty, 0 non-translated target-locale units -> PASS.

Open follow-up, by the Orchestrator rule: C11-268 currently adds no catalog keys (Captain check of its branch at 89b6a8d92f). If it lands new strings, a small follow-up refresh covers them; this ticket is complete for the 1.0 freeze as merged.

Routed to C11-292 sign-off (signoff-additions.md): a six-locale spot check on a tagged build, including the ru/uk close-tabs and close-workspaces confirmation dialogs with 1, 2 and 5 items. The earlier Japanese UI step (step 20) stands.

No check contradicts a criterion.

Verdict: COMPLETE.