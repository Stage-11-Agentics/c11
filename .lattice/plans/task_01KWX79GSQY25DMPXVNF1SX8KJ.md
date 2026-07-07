# C11-156: Extract socket dispatch from TerminalController into per-domain handlers

Wave 1 keystone, mechanical relocation with zero behavior change. SPEC IDs: DX-1..DX-5. Dispatch switch leaves TerminalController.swift for per-domain handler units; threading/focus policy preserved verbatim; baseline tests_v2 parity run recorded before and after. Deeper router redesign out of scope. Contract: docs/cycles/2026-07-truth-and-stability/ (SPEC.md, EVALUATION.md, BUILDPLAN.md). Validation bar: tagged build + recorded scenario proof.
