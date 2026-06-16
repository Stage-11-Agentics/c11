# C11-148: Mailbox: renaming a surface orphans undrained mail in the old-name inbox dir

Discovered during v0.53.0 release smoke (mailbox feature set, shipped as C11-143 stable addressing + C11-144 delivery safety).

What happens: mailbox inbox STORAGE is keyed by the surface's current title/name, e.g. mailboxes/<surface-name>/<id>.msg. When a surface is renamed, recv reads the new-name dir and any messages delivered under the OLD name are stranded.

Repro (verified on rel-v0.53.0 source): surface 'bravo' receives a message (lands in mailboxes/bravo/); set mailbox.address=bravo-stable; rename the tab to 'bravo-renamed-xyz'; 'c11 mailbox recv --drain' reads mailboxes/bravo-renamed-xyz/ and never sees the earlier message. On disk: mailboxes/bravo/<id>.msg persists, orphaned.

Context: C11-143 decoupled mailbox ROUTING (send --to resolution via mailbox.address/role) from the mutable title, but inbox STORAGE keying was not migrated — still title-keyed. Routing is stable across rename; storage is not.

Scope: edge case — only bites when a surface is renamed while it has UNDRAINED mail. Steady-state drain-each-turn avoids it. Not a v0.53.0 blocker.

Acceptance: a message delivered to a surface stays retrievable by that surface after a tab rename (key inbox storage by a stable surface id / mailbox.address, or migrate the dir on rename, or have recv union old+new name dirs). Add a tests_v2 regression for rename-with-undrained-mail.
