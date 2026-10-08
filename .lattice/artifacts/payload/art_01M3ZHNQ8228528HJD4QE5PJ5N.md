MERGED; reviewed runtime/validation evidence accepted
C11-323 / PR #564: https://github.com/Stage-11-Agentics/c11/pull/564
Landing head: e12a7b9962068d65805a6c79d0319ae2a7912b38
Squash merge: 32bb08b8ec3a100939006a007be18b3f5d07fb75
Base immediately before merge: ac221b97918c021cfbe0cfdcb08ef3f42f705c71
GitHub MERGED verified; fetched origin/main contains the merge. Dependencies done; intended diff has 32 files, no Lattice noise. No behind-only Captain rebase.
Review: Astra round-3 PASS ev_01M3ZFSXBMWRC2PFBD81V79PCH at d204a33abe; Orchestrator attestation ev_01M3ZGR1644DDN9CZFZB2QYSDP for the main merge e12a7b9962 (schema description union only)
Validation: Owner risk-list runtime proof at e12a7b9962: ev_01M3ZGQHC9HR3GSN7GGHTRJ3EJ (build worker tests 3a932afa47f249efa340a14bbc74c611, tagged guest tests_v2 replay PASS, real Cmd+P palette switch PASS)
C11-315 authorized landing policy: exact-head Debug compile/full logic build worker gate 67442703bfa842a6b6457cdc4272f943 passed; every non-skipped fast/other required exact-head PR check SUCCESS. Native hosted jobs are hourly/manual or legacy pre-policy jobs, not per-PR landing gates; no hosted native pass is inferred. Draft Drawbridge SKIPPED. Snapshot and URLs: /tmp/c11-pr564-before-merge.json.
Scope: 32 files. Socket-, CLI- and palette-originated requests can no longer change the operator's visible workspace. The selection setter refuses with workspace_switch_blocked and emits a workspace.switch_blocked event naming the caller tab, while operator input keeps working. Socket close cannot remove the visible workspace, close picks the next workspace from seen history, workspace.selected gains cause/method fields, and the c11 skill, spec and tests are updated.
Head e12a7b9962 merges d204a33abe (Astra round-3 PASS ev_01M3ZFSXBMWRC2PFBD81V79PCH) with main 37fbd0ecbf. The Captain verified that its remerge-diff touches only spec/event-envelope.v1.schema.json (the two description strings, an exact union of workspace.switch_blocked and lifecycle.changed), and that its tree f936032bb7 is identical to the Captain's independent local trial merge f2015ad3e4. Orchestrator attestation ev_01M3ZGR1644DDN9CZFZB2QYSDP: "Approved to land". Bonsplit follows main (d769def2ea); Ghostty unchanged.
Risk-list runtime proof at this exact head (owner ev_01M3ZGQHC9HR3GSN7GGHTRJ3EJ, id corrected in ev_01M3ZGQQRABHWEF4JJRATBY6B8): build worker tests 3a932afa47f249efa340a14bbc74c611 (AgentWorkspaceSelectionTests 8/8, TerminalControllerSocketSecurityTests 6/6, EventLogTests 21/21). Tagged build worker guest replay: tests_v2/test_agent_workspace_selection.py passed 1, failed 0. A real Cmd+P operator palette switch passed with cause=palette, and the frontmost app was unchanged.
Captain actor agent:sonnet-captain.
Captain gate history:
- The trial merge f2015ad3e4 (tree-identical to e12a7b9962) first ran ee9552415cdb43ae8ebce855db07e197 with 29 test-process restarts, all on the same fatal: GhosttyTerminalView.swift:1322, an implicitly unwrapped nil (NSApp.isActive in GhosttyApp init in the hostless logic bundle). The Captain reported a block.
- The exact-head gate 67442703bfa842a6b6457cdc4272f943 on e12a7b9962 (clean, no overlay) then compiled ok and passed full logic plus AgentWorkspaceSelectionTests and TerminalControllerSocketSecurityTests: 2469 tests, 3 skips, 0 failures, 0 restarts. Main 37fbd0ecbf also passed 2468/0/0 restarts (8819529b49d24feab493a1f690638e0e).
- The crash is therefore intermittent and not attributable to this PR; the block was withdrawn and the Orchestrator is filing it as its own ticket.
- Main then moved by C11-251 (#563, a related workspace-targeting seam). The Captain ran full logic on the exact post-squash tree (local unpushed merge 6d259df902 = e12a7b9962 + 4994d7fce3; tree identical to merge-tree) as invocation 217fb0b153df4073a6acb77236f7c9e8: 2469 tests, 3 skips, 0 failures, 0 restarts. AgentWorkspaceSelectionTests 8/8, TerminalControllerSocketSecurityTests 6/6, SocketTabRefRejectionWiringTests 6/6 and EventLogTests 21/21 passed. #567, merged afterwards, touches only sandbox scripts and docs and does not overlap this diff.
The landing head e12a7b9962 is unchanged; no Captain rebase.
Control fast-forwarded to merged main. Installed skill sync:
sync  c11 → $HOME/.claude/skills/c11
done: 1 synced, 0 skipped
All installed source files byte-equal for c11; install marker preserved.
No Captain local build/test/app launch, release, tagging or publication.