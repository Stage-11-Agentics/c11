## C11-143 live validation — tagged build c11-143 (worktree)

Driven over the tagged instance's socket (/tmp/c11-debug-c11-143.sock); operator's prod c11 untouched. Recipient = a terminal surface with mailbox.address=addr-stable-143, mailbox.delivery=stdin.

ACCEPTANCE: 'send to a stable address survives a recipient tab-rename' — PASS.

1. Before rename (title=recipient-orig): send --to surface:addr-stable-143
   trace: resolved recipients=[recipient-orig] -> copied -> handler stdin ok. Framed <c11-msg> block delivered to recipient PTY (body 'msg-before-rename').
2. Rename title recipient-orig -> recipient-renamed, then send --to surface:addr-stable-143 (SAME stable handle):
   trace: resolved recipients=[recipient-renamed] -> handler stdin ok. Framed block delivered ('msg-after-rename'). Stable address survived the rename.
3. Negative control: send --to recipient-orig (old title) -> 'No live surface named "recipient-orig"', exit 1. Confirms the title moved (the silent-repartition this feature fixes).
4. Title fallback: send --to recipient-renamed (new bare title) -> resolved=[recipient-renamed]. Bare-name title fallback intact (back-compat).
5. role: addressing: set mailbox.role=delegator; send --to role:delegator -> resolved=[recipient-renamed]. send --to role:nonexistent -> unresolved, exit 1.

All framed blocks observed in the recipient PTY via read-screen. Unit: 44 mailbox logic tests green (c11-logic). CLI target builds clean. Headless code-review: PASS (art_01KV79T9Y7B4ZNPXZ4ZR2MRPXB).