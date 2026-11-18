# Troubleshooting

Print this page with `c11 guide troubleshooting`. `c11 doctor`, the portal snapshot for a stray line or stale portal, reading a terminal selection, and slow workspace switches. A link to `<page>.md` names another page: `c11 guide <page>`.

If `c11` on PATH isn't the active bundle's CLI, run `c11 doctor` (`--json` for machine-readable). It reports the bundled CLI path, how `c11` resolves on PATH, and a `status` of `ok | mismatch | missing | no_bundle`.

Working Lattice tickets inside c11? Also load the `lattice` skill for the integration patterns.

### Capture a stray line or stale portal before touching it

Leave the affected workspace, focus, dividers and window size alone. First use the affected window ref from `c11 identify --json` (run from a panel in that window), then capture its current portal state with that explicit UUID/ref; replace `window:1` below:

```bash
c11 rpc debug.portal.snapshot '{"window_id":"window:1"}' > /tmp/c11-portal-snapshot.json
```

Available in Release through `system.capabilities`. Attach this JSON and a screenshot of the undisturbed artifact to C11-527. It contains portal identities, frames, native dividers and overlay guard decisions, not terminal text or browser content. Geometry is **current calculated geometry**, not a record of the last paint. Check truncation flags and `main_copy_duration_ms`; incomplete geometry cannot rule out a source. Do not refresh, switch workspaces or run a session round-trip before capturing. See [snapshot contract](api.md#portal-snapshot).

### Read a terminal selection

Use `c11 read-selection --panel panel:2 --json` to read what the operator highlighted, without changing the selection. No selection is a successful empty result; browser/markdown panels are unsupported. Discovery feature: `read_selection.terminal` version 1. Response cap: 1 MiB on a UTF-8 boundary; `truncated` reports clipping. Retry `busy` later; worker wait is limited to five seconds. Native capture/formatting/allocation and copy/free stay on main, so that wait limit is not a native time/allocation bound. See [API reference](api.md#terminal-selection).

### Read how long workspace switches take

Every completed workspace switch appends one JSON line to `~/Library/Logs/c11/workspace-switch.jsonl`. A dev build launched with `C11_TAG` writes `/tmp/c11-workspace-switch-<tag>.jsonl` instead, and `C11_SWITCH_LOG` overrides either path. The log stays on the machine and is written off the main thread. At 2 MB the file moves to `workspace-switch.jsonl.1` and a new one starts. An empty `workspace-switch.jsonl.lock` beside it is the lock that lets two c11 processes share the file; leave it. Each line has these fields:

- `hold_ms`: how long main was held, from the selection to the start of the switch's queued main-thread block. It includes the layout pass that mounts the shown workspace.
- `dt_ms`: the `workspace.switch.complete` breadcrumb's duration. It starts a little after the selection, once the selection's notifications have run, and ends after that block's focus, title and mark-read work. Subtracting `hold_ms` from it is not a measure of anything.
- `panels`: panels in the workspace shown. `workspaces`: workspaces in the window.
- `hidden_s` and `warmth`: awake seconds since this window last showed that workspace (the clock pauses while the Mac sleeps). `first` means this window had not shown it before in this launch; `warm` is under 30 s (its terminals still hold a frame); `cold` is 30 s or more.
- `cause`: `shortcut`, `sidebar`, `palette`, `socket`, `create`, `restore`, `close_fallback` and so on. `menu` is also the label for any selection that names no cause, so it mixes the menu with programmatic selections.
- `build` (`release` or `debug`), `version`, `bundle_id` and `at` (local time).

```bash
# median hold of the last 200 operator switches (shortcut, sidebar, palette)
tail -n 2000 ~/Library/Logs/c11/workspace-switch.jsonl | jq -s '[.[] | select(.cause | IN("shortcut","sidebar","palette")) | .hold_ms] | .[-200:] | sort | .[length/2|floor]'
```

Stalls over 2 s also reach `hang.log`, with a stack ([persistence.md](persistence.md)).
