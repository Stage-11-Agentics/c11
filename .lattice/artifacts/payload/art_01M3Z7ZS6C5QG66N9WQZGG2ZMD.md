C11-282 validation summary (batch validation, existing runtime evidence)

Merged: PR #529 (squash 04458a8b0a, landing head f3192aae0a). Evidence is the owner's pre-merge tagged-build native run, the reviewer chain, the Merge Captain exact-head gate, and the parked validator's batch-4 checks at main 12d4f21a.

Acceptance criteria -> evidence -> result
1. Mouse-select a known word, `c11 read-selection --workspace <ws> --tab <t> --json` returns `has_selection: true`, `kind: terminal`, `text` equal to the word, `base64` decodes to the same text -> ev_01M3Y3JKQMCM59MTBM0C81KBCN (tagged Atlas Debug artifact: real mouse select/read/read/built-CLI cycles returned exactly the fixture word; CLI JSON text/base64 byte parity on 30 large native reads), art_01M3Y3QQXY4R2FKSJNS49R5ZKB (real terminal word selection), art_01M3Y3QR0B3BAX5V52WS7AVT8P (native Unicode selection); the exact acceptance argv (trailing `--json`) fixed in ev_01M3Y4SC6WW8KTD3161RYVYJNF and confirmed by review ev_01M3Y4YNKJA5MXGWS9GPKRZE5W -> PASS (pre-merge tagged build)
2. No selection: exit 0, `has_selection: false`, empty `text`, terminal unchanged -> ev_01M3Y3JKQMCM59MTBM0C81KBCN (no-selection, human and JSON output), ev_01M3YVAV19W2V6T7Q6ACRA54X2 (100 actual empty-selection reads under streaming load, all succeeded with zero selected bytes) -> PASS
3. Browser tab returns a clear not-a-terminal error, no script injected -> ev_01M3Y3JKQMCM59MTBM0C81KBCN (browser/markdown rejection; browser getSelection call counter stayed zero) -> PASS
4. Policy test asserts socket-worker execution; live DEBUG log shows `isMain=false` for response construction -> ev_01M3Y3JKQMCM59MTBM0C81KBCN (SelectionReadTests plus CapabilityFeaturesTests, 10 pass, worker/alias dispatch included; DEBUG worker diagnostics isMain=false), ev_01M3Y64E2M0J3XZMDVJ738DSZ8 (8 SelectionReadTests + 2 CapabilityFeaturesTests pass at the merged head), ev_01M3YVAV19W2V6T7Q6ACRA54X2 (100 capture and 100 worker-encode logs, all encode records isMain=false; the single main copy hop is documented) -> PASS
5. Twenty select/read/clear repetitions leave the process up, no malloc or double-free diagnostic -> ev_01M3Y3JKQMCM59MTBM0C81KBCN (twenty real mouse select/read/read/CLI/clear cycles, process alive), ev_01M3YVAV19W2V6T7Q6ACRA54X2 (120 s ownership fixture: 3,807,394 buffers acquired and exactly as many freed, outstanding bytes zero; 50 read/close race rounds with stale targets rejected; matched stock workload 30 PTYs, 0 missed probes) -> PASS

Supporting gates
- Reviewer: ev_01M3Y49VSTDRRYTJC2TSPRDYGG (FAIL on trailing `--json`, repaired), ev_01M3Y4YNKJA5MXGWS9GPKRZE5W (PASS), ev_01M3Y6AGQ2JS4DD416C1FWT0W8 (PASS on the C11-295 merge). Orchestrator attestation ev_01M3Y5J5C0DKFF7KZQCXEDTGJB.
- Merge Captain exact-head gate: ev_01M3Y6SRD7YCBBDEX3K9H5MCRZ (all hosted checks SUCCESS).
- Parked validator batch-4 checks: ev_01M3YVAV19W2V6T7Q6ACRA54X2 / art_01M3YVAE9H2KM07Y4TCVJ5BCWF.
- The foreground flag (ev_01M3YPG6AMW6AHDMFS940FAPS0) was a harness/foreground limitation (external window activity refused further native input), not a failing check. No evidence on the ticket shows a failing selection result.

Routed to C11-292 sign-off
- Native mouse-word selection and `read-selection` on the merged build (criteria 1, 2 and 5 were proven on the pre-merge tagged artifact, not re-driven by a human-visible run at the merged head).
- Native selection above 1 MiB: retained selection above the cap and `truncated: true` on the real reader (recorded runtime samples were 1,045,175 bytes, below the cap; clipping is covered by logic tests only).

Verdict: COMPLETE+SIGNOFF. All five criteria are covered by existing runtime and test evidence; two native visible gaps are routed to C11-292.