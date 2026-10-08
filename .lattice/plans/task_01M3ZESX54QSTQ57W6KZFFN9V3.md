# C11-325: Internal sidebar telemetry commands still fall back to the selected workspace

## Why
C11-251's round-2 review found that internal v1 sidebar telemetry still falls back to the operator's selected workspace (and focused tab) when no target is supplied: report_git_branch / clear_git_branch, report_ports / clear_ports, report_pr / report_review / clear_pr (schedulePanelMetadataMutation), set_agent_pid / clear_agent_pid, report_pwd, report_shell_state, report_agent_activity, report_tty, agent_kick / ports_kick. A targetless clear_git_branch, clear_ports or clear_pr removes the selected workspace's sidebar context. Evidence: C11-251 review ev_01M3ZER8HW69M89JVSMY6T0S7E (finding 3, with file and line references).

## Scope
Audit which callers (shell integration hooks, wrappers, agents) send these without refs. Require explicit workspace context where no legitimate caller depends on the fallback; keep off-main telemetry threading and explicit-scope worker routing. Behavioral sentinel tests for representative branch, port and PR cases.

## Out
The operator-facing sidebar status/progress/log/meta/markdown commands, reset_sidebar and workspace metadata (C11-251).
