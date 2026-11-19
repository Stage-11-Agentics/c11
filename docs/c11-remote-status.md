# Remote terminal status

Build-host panels consume foreground program and root OSC 7501 status from the single
hc inventory. Foreground classification uses c11's existing agent detector. Status
uses the existing journal, sidebar attention and Feed projections; flags and
delegation continue to apply there.

`working`, `blocked`, `idle`, `done` and `error` are observations reported by the
program. A blocked word alone does not identify a permission request or its text.
No remote PID is inspected as a local process. `tree --json` includes a remote
panel's `foreground` object with its retained `name` and remote `pid`.

A lost link, pending inventory or missing remote mirror shows Reconnecting while
preserving the agent's last known phase and program. It does not mean the agent
became idle or ended. A fresh connected record confirms the current state.

The pinned hc status event omits `status_ms`; a remote mirror can therefore
retain the preceding word's time. The inventory clears unverified mirror times
and verifies them through `terminal.get` routed by the owning core's stable ID.
That request has a two-second deadline, coalesces duplicate callers, and admits
at most 16 terminals at once. A reply installs only if the live route, terminal,
status and turn still match. Failure leaves the time unknown and the reported
phase intact; a later inventory observation may retry.

On return, a retained `done` record with verified `status_ms` appears in Feed Turns with
that timestamp from the owning host. Host clocks may differ. No end time is
invented when hc has none. hc retains the current status, not a complete turn
history: its counter increases on every departure from working, including blocked,
idle and cleared status. Counter gaps never create synthetic completion rows.

The journal's `hc_status` adapter uses an opaque `hc-` terminal evidence identity
when no exact provider conversation owner is available. This is not a conversation
resume ID and never enters the conversation store. A reported provider owner
takes precedence. Status drafts received through the generic socket or spool
cannot assert the inventory adapter's provenance.
