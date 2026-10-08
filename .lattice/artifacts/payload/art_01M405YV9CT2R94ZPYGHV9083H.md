C11-291 validation: reopened two-key refresh (batch fast rule)

Merged: PR #578, squash 9c9cf4ba444c05ba9d82a85ea9bcb3323487b920 (the sign-off build base), landing head ce30ead111732016f9b6e051e9662b197e48436b, catalog only. Merge Captain receipt ev_01M405XMXB23DPEKPQG485Y2DZ: jq parses; both English values equal their call-site defaultValue; scripts/check-locale-tokens.py OK for 2 keys x 6 locales; exact-head gate d1cb071b39504ba1adb4fc84c83a8ebd, Debug compile ok. Review: Orchestrator attestation ev_01M405ET3G5RVKDBHK1WQY32K3 (all 14 values read, meaning matches, %@ preserved). Owner validation ev_01M405BWRESXQ1J23GZ4Y1FF6G (exactly two keys changed; sourceLanguage and catalog version unchanged).

Scope: feed.answer.multilineUnsupported (added in English by C11-268) and socket.send.guard_refused (referenced since C11-267 with no catalog entry, now added with English equal to the call-site default), each in ja, uk, ko, zh-Hans, zh-Hant and ru.

Validator re-check on merged main now:
- `jq` parses the catalog.
- 1,595 keys, with 0 missing, 0 empty and 0 non-translated target-locale units.
- Both keys are marked translated in all six locales, and their token sets match English: none for multilineUnsupported, `%@` for guard_refused.

Criteria 1, 2, 4 and 5 hold for the 1.0 catalog as merged (the earlier freeze evidence is in the previous validation comment). Criterion 3's earlier Japanese render stands; these two messages have not been seen on screen, so they are added to the sign-off locale spot check.

Routed to C11-292 sign-off (signoff-additions.md): both messages in ru, uk and ja on the sign-off build at 9c9cf4ba44.

No check contradicts a criterion.

Verdict: COMPLETE.