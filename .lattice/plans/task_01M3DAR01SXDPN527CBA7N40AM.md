# C11-237: c11: do not guess branch and worktree from the local cwd for a surface whose host metadata is remote

A surface with host metadata naming a remote box (e.g. prime:<id>) still gets branch and worktree inferred from the launcher's local cwd (showed branch=main while the seat was on handson-1). Expected: when the host key is non-local, branch and worktree are left unset or taken from metadata. Relates to C11-229. Found by the Overwatch seat launcher (2026-09-25).
