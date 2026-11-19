# Remote machines: terminals elsewhere, SSH and the relay

Print this page with `c11 guide remote`. Terminals on another machine, machine chips, `c11 ssh`, what `c11` can do from a linked machine, and remote status. A link to `<page>.md` names another page: `c11 guide <page>`.

## Machine chips

Each terminal's title bar carries a where-it-runs chip naming its machine. `c11 machine list|set|rm` (or Settings ▸ Herder Topography) sets a display name and any hex color per machine (`--id <machine>` as `c11 machine list` names it, or `local` for this Mac); open chips repaint at once, and every chip keeps one width. When another machine is connected, the operator's New Terminal and agent launches ask which machine; your CLI calls never ask, so pass `--on <machine>` to place a terminal elsewhere. Details: [the API reference](api.md#the-machine-roster-c11-machine).

## Terminals on other machines

`c11 new-panel --on <machine>` (a name from `c11 machine list`; also `new-area`, `launch-agent`) opens a terminal on another machine c11's hc has added; splits of it stay on that machine and browsers stay local. Errors, `--cwd` rules and link loss: [API reference](api.md#terminals-on-another-machine---on).

## SSH workspaces

`c11 ssh <host>` opens a remote shell in a workspace. Remote-to-local c11 commands
are disabled in this version as a hardening change. Running `c11 <cmd>` or the
`cmux` alias inside that shell fails with "c11 commands are not available over
c11 ssh in this version". Use the local CLI to operate the workspace.

## c11: agents on another machine

In a c11 terminal on a linked machine, `c11` is c11's relay: it reaches c11 on the operator's Mac through hc's link while that Mac is awake, with your identity from the terminal's environment. Name your panel, set your description and status, raise and lower flags, `mailbox send` to agents on the operator's Mac and `mailbox recv --ack` work as they do locally; typing into panels, creating or closing them, launching agents and browser commands are refused (`relay_not_allowed`). `c11 show` works through the relay: the viewer opens beside your panel on the operator's Mac. **Link down:** a relayed command may wait up to about 10 s while the link reconnects, because its first call can be a read probe. After an unanswered probe it fails at once; after an answered one, writes (flags, `mailbox send`, the ack, metadata) are sent at most once and never replayed, and after `relay_outcome_unknown` you check before repeating. Only `set-status`, `set-progress`, `log` and journal appends are spooled for the link's return. Writes name only your own panel (`--panel "$C11_PANEL_ID"`, a UUID, never `panel:N`) and its workspace; anything else is refused `relay_target_refused`. Reads see only the workspace that holds your panel: naming another workspace, or a panel, area or window outside yours, answers `not_found`, and `tree --all` is your workspace. Mail still reaches agents in any workspace. Address mail by `mailbox.address` or `id:<uuid>`, never with a host prefix (`<host>/x` is refused). Your mail reaches agents on the operator's Mac marked `via="<your machine>"`; you can't take or send as `operator` or `c11` (`relay_identity_reserved`), set or clear the workspace's `captain` or `c11h.recovered`, replace or clear the whole workspace object, or write `remote.*` status or a log source c11 uses for the link (`remote`, or any `remote-…` source such as `remote-proxy`) (`relay_key_reserved`). A name a panel on the operator's Mac answers to stays that panel's: your title or address never takes its mail. c11 serves only calls signed with the terminal's own relay credential (`C11_RELAY_AUTH`, set before the shell starts), as that terminal's panel; `relay_auth_missing` or `relay_auth_refused` means the terminal needs reopening, `relay_kit_outdated` that the relay on that machine needs updating. Don't unset or copy the credential. Any process of the same user on that machine can still type into your terminal through hc, so keep secrets out of status and mail.

- **`c11 conversation capture-runtime` is refused here** (`relay_not_allowed`) until per-host resume exists; carry on without it.
- **A Claude started through the relay's `claude` entry** gets c11's hooks and launch note as locally, and `c11 fleet` on the operator's Mac sees it as a local seat: its login, final message and a usage-limit stop arrive through the relay (`agent.report`, your own panel only, never spooled), and its prompt and dialogs are read from the screen c11 already shows. Its turn ends ring waiting mail only once that machine's hc also reads it idle, done or in an error; until then mail is held (`mailbox status` shows `core_working`). A Claude started any other way reads mail with `mailbox recv --ack` when the doorbell rings.
- **On a Linux machine** your terminal's shell is bash, started with the relay kit's `bash/rc` (what a login bash reads, then the relay `bin/` first on PATH), so `c11` and the `claude` and `codex` entries are the relay's. A terminal opened before its machine's kit had `bash/rc` keeps the machine's own PATH: `command -v c11` tells.
- **Inside a workspace container** (an Incus container on a Linux machine, home `/home/agent`) the same holds through the container's own relay socket, except that telemetry fails instead of spooling while the link is down.
- **A `quiet` launch watch** on another machine (the launch line was typed, the agent drew nothing): a harness binary there that still carries `com.apple.quarantine` hangs before it starts when nobody is at that screen. Tell the operator; clearing it is theirs.
- For a panel on another machine, `c11 tree --json` carries `foreground` (program name and remote pid). That pid is not a local process: never `kill`, `ps` or `lsof` it from here.

## Linking a machine

`c11 machine link --host <ssh-target>` and `c11 machine unlink --id <machine>` are the operator's Add Machine and Remove (Settings ▸ Herder Topography). Never run them on your own: link gives c11 a shell on the other machine (a Mac with Apple silicon, or an x86-64 Linux machine with systemd, Python 3 and linger) as the operator and installs c11's relay kit and hc there, unlink ends every c11 terminal there; they ask first and need `--yes` outside a terminal (inside a c11 terminal, link refuses `--yes`), and `unlink --dry-run --json` lists what would end. What linking grants, the hash and folder checks, and what no check covers: `c11 guide trust`. Every cross-machine action (link, update, unlink, a terminal started there, each relayed call) is a line in `c11 machine audit`. Remote terminals get their panel's own `XDG_CONFIG_HOME` (or none) and start that machine's login shell (on a Linux machine, bash with the relay kit's `bash/rc`, whatever the login shell is); nothing of the local Mac's environment is forwarded.

After the switch from c11h, while c11 still runs c11h's adopted sessions, a new link lands in c11's own session, beside c11h's old link of the same name. c11h's terminals there keep running, but c11 opens nothing new through c11h's link: `--on <machine>`, the picker and splits use c11's link, and `--on`, `new-area` and `new-split` are refused `machine_link_unusable` only when no link of that name is usable (the keyboard and panel-bar splits beep and say why over the terminal; `workspace apply` and `restore` leave out each terminal there, reporting it as `machine_link_unusable`, and make every other panel; a plan with nothing else fails before any workspace exists). Dragging a panel beside one of that machine's terminals still moves it. For a few seconds after launch, before c11's own session reports, `--on` to a machine it lists answers `hc_unavailable` where it would otherwise be refused: retry. Removing c11h's link ends only c11h's terminals there; c11's keep running and keep their relay (mail, status). `c11 machine list --json` lists each link of a name under `links` (`session`, `connected`, `usable`, `c11h_link`), and `c11 machine unlink --id <machine> --session <session>` says which one to remove (without it, a name linked twice is refused `machine_link_ambiguous`).


## c11 remote status

Remote panels show hc's foreground program and root OSC 7501
status through the existing sidebar and attention model. `tree --json` includes
their `foreground` name and remote PID. Reconnecting preserves the last known
agent state; it never proves idle or ended. Feed Turns can recover a retained
`done` report with its owning host's timestamp, not a complete away-time history.
hc's turn counter also advances on blocked and idle, so do not count its delta as
completed turns. Details: [remote status](../../../docs/c11-remote-status.md).
