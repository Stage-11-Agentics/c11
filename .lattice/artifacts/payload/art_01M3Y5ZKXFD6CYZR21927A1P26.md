C11-273 exact-head guest runtime gate FAILED
Head: b33c93dba7ee3b9dd492bc5f6135a046333bad73
Build invocation: f040b5471550405c94ef8f7a1c69b9ab; clean tagged Debug compile=ok, empty overlay. Owner merged-head47tests are a separate PASS; this new guest gate is not PASS.
Guest executable SHA256: dcd6b5a168e51ab218fb50449b09229fa10aa0e9688a271cd5acf47854ede860
Three scripts ran once through sandbox-tests-v2.sh. Test log SHA256: 27d55b4bac622dc6563c11d770419a8618de22388b564b80c10d73566f988363
No rerun. The restart test failed before checking the restored journal state: tab.get_metadata returned not_ready while session restoration was in progress. Its eventually helper propagates the transient socket exception rather than waiting. This establishes a failed gate, not a lost-replay assertion or an attribution of product regression.
The complete sanitized execution transcript follows:
== launch tests_v2/test_journal_append_replay.py ==
RUN  tests_v2/test_journal_append_replay.py
PASS seen/sibling/legacy/different-turn tool and Stop preserve blocked request
PASS correlated answer resumes work and same-turn completion returns idle
PASS delayed PreToolUse cannot reopen terminal barrier
PASS recorded ExitPlanMode hook shape reaches plan-review journal projection
PASS lost acknowledgement dedupes and changed draft conflicts
PASS child and stale session cannot change current owner
PASS disconnected journal retains attention and releases legacy activity writes
PASS offline spool preserves event identity and structural privacy (18.7 ms)
PASS tests_v2/test_journal_append_replay.py
== launch tests_v2/test_journal_restart.py ==
RUN  tests_v2/test_journal_restart.py
Traceback (most recent call last):
  File "$HOME/c11-sandbox/suite/tests_v2/test_journal_restart.py", line 118, in <module>
    main()
  File "$HOME/c11-sandbox/suite/tests_v2/test_journal_restart.py", line 92, in main
    eventually(lambda: state(0)['phase'] == 'blocked', 'restored open ask', timeout=15)
  File "$HOME/c11-sandbox/suite/tests_v2/test_claude_attention_batch.py", line 26, in eventually
    if predicate():
  File "$HOME/c11-sandbox/suite/tests_v2/test_journal_restart.py", line 92, in <lambda>
    eventually(lambda: state(0)['phase'] == 'blocked', 'restored open ask', timeout=15)
  File "$HOME/c11-sandbox/suite/tests_v2/test_journal_restart.py", line 89, in state
    return client._call('tab.get_metadata', {'tab_id': tabs[index]})['metadata']['journal']
  File "$HOME/c11-sandbox/suite/tests_v2/cmux.py", line 332, in _call
    raise cmuxError(f"{code}: {msg}")
cmux.cmuxError: not_ready: Session restoration is still in progress. Try again shortly.
== launch tests_v2/test_claude_attention_batch.py ==
FAIL tests_v2/test_journal_restart.py
RUN  tests_v2/test_claude_attention_batch.py
PASS: prompt-submit preserves sibling waiting
PASS: pre-tool-use preserves sibling waiting
PASS: session-end preserves sibling waiting
PASS: AskUserQuestion in bypassPermissions enters waiting without a Notification hook
PASS: ExitPlanMode in bypassPermissions enters waiting without a Notification hook
PASS: ExitPlanMode in plan enters waiting without a Notification hook
PASS: normal-mode follow-up retains one attention item
PASS: absent, empty, invalid and stale tab attribution preserve notices
PASS: stale PID with attribution=True
PASS: stale PID with attribution=False
PASS tests_v2/test_claude_attention_batch.py
summary passed=2 failed=1
failed: tests_v2/test_journal_restart.py

Owned guest deleted via sandbox-down exit0 after the bounded run; total elapsed 204.49 seconds. No screenshots captured or human screen driven by Captain. No merge/completion. Native formatting/performance residual remains C11-270 soak, separate from this failed restart gate.
