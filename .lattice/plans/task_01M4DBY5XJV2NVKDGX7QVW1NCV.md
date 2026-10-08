# C11-364: c11 mailbox send silently drops positional text and sends an empty body

Found 2026-10-08 during the markdown viewer build: three agents (the scoping agent twice, the build orchestrator once) wrote `c11 mailbox send --to <x> "<text>"`, the same shape as `c11 send`, `set-status` and `log`, which take their text as a trailing positional. The envelope went out with `body: ""`, the command printed a message id and exited 0, and the recipient got an empty message.

Cause: runMailboxSendCommand in CLI/c11.swift reads `optionValue(subArgs, name: "--body") ?? ""` and ignores leftover positionals; an empty body with no --body-ref is accepted.

Fix: accept a single trailing positional as the body when --body is absent (consistent with c11 send), and reject an envelope whose body is empty with no --body-ref, with a clear error. Unknown flags and extra positionals should error, not vanish (same class as C11-334). Update skills/c11 and docs/c11-mailbox-guide.md if the accepted shape changes, then sync.

Evidence: envelope 01M4DBWC6KSBD5ZABEY2V80861 (dispatch log shows bytes:134, body empty), plus 01M4DBA499NBC77D0HKFBQJTRD and 01M4DBB2FX6M5H332PY3GWPB8G.
