MERGED; reviewed runtime/validation evidence accepted
C11-267 / PR #565: https://github.com/Stage-11-Agentics/c11/pull/565
Landing head: d9a6566f6c67ceb73b7b0860737eb238dedab32d
Squash merge: 82d74f3370cb5a1e0c49db853b7884bebbd69350
Base immediately before merge: 32bb08b8ec3a100939006a007be18b3f5d07fb75
GitHub MERGED verified; fetched origin/main contains the merge. Dependencies done; intended diff has 25 files, no Lattice noise. No behind-only Captain rebase.
Review: Astra round-2 PASS ev_01M3ZHYHRY5CB442N3AA7CD3KD at 12b7da08dd; Orchestrator attestation ev_01M3ZJDT9N1S7SZX9B1N72PZYV for the Captain's mechanical merge d9a6566f6c (orchestrator.md doc hunk only)
Validation: Owner risk-list runtime proof ev_01M3ZHN68P9FJ1VYFSY6N95WSA (repair round 1, real Codex 0.160.0 and real Claude) at 12b7da08dd; product code identical at the landing head
C11-315 authorized landing policy: exact-head Debug compile/full logic build worker gate 4cfc34e81300435898aea0f348c2a66b passed; every non-skipped fast/other required exact-head PR check SUCCESS. Native hosted jobs are hourly/manual or legacy pre-policy jobs, not per-PR landing gates; no hosted native pass is inferred. Draft Drawbridge SKIPPED. Snapshot and URLs: /tmp/c11-pr565-before-merge.json.
Scope: 25 files. c11 send refuses input into a tab that shows an operator draft or a question/plan dialog (input_guard_refused; nothing typed). It adds an input-state query, a PromptInputClassifier with a Ghostty prompt-state export, capability registry entries, CLI flags, the c11 and lattice-orchestrator skill text and tests_v2. A typing-adjacent risk-list ticket.
Ghostty bump: 5830d1976e (main) to e6999ae7adc7c584d6bbda415aa59a6a8c3a2470. The Captain verified that the pin is identical to Stage-11-Agentics/ghostty main and is 1 ahead of and 0 behind main's pin, and that the checksum line is present at the head, written by github-actions[bot] in c0945f9e62 (Build GhosttyKit). The build worker gate built with this pin.
Landing head d9a6566f6c is the Captain's mechanical merge of PR head 12b7da08dd (Astra round-2 PASS ev_01M3ZHYHRY5CB442N3AA7CD3KD) with main 32bb08b8ec, authorized by the Orchestrator. Its remerge-diff touches only skills/lattice-orchestrator/references/orchestrator.md: main's new-tab line plus the PR's chained send && send-key. Orchestrator attestation ev_01M3ZJDT9N1S7SZX9B1N72PZYV.
Risk-list runtime proof: owner repair round 1 ev_01M3ZHN68P9FJ1VYFSY6N95WSA at 12b7da08dd, with real Codex 0.160.0 and real Claude; product code is identical at the landing head.
Captain actor agent:sonnet-captain.
Captain gate 4cfc34e81300435898aea0f348c2a66b at d9a6566f6c (clean, no overlay, ghostty e6999ae7 and bonsplit d769def2 as pinned): Debug compile ok; full c11LogicTests: 2487 tests, 3 skips, 0 failures, 0 restarts. PromptInputClassifierTests 14/14, SendInputGuardTests 4/4, SendTextParseTests 7/7 and CapabilityFeaturesTests 3/3 passed, as did both retained WorkspaceRemoteConnectionTests; only SocketControlPasswordStoreTests skipped (SSH Keychain). Fast PR checks are SUCCESS at this head.
Control fast-forwarded to merged main. Installed skill sync:
sync  c11 → $HOME/.claude/skills/c11
done: 1 synced, 0 skipped
All installed source files byte-equal for c11; install marker preserved.
sync  lattice-orchestrator → $HOME/.claude/skills/lattice-orchestrator
done: 1 synced, 0 skipped
All installed source files byte-equal for lattice-orchestrator; install marker preserved.
No Captain local build/test/app launch, release, tagging or publication.