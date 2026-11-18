# How c11 trusts a linked machine

Print this page with `c11 guide trust`. Add Machine links to it before it links anything. It says what linking grants, what c11 checks, and what nothing in c11 can check.

## What linking grants

Linking gives c11 a shell on that machine as you.

- c11 signs in over SSH with your keys and installs its own copy of hc there, the program that holds c11's terminals, under `~/.local/share/c11`. It starts that hc whenever this Mac connects.
- The SSH c11 opens for a link (the line hc holds, and Add Machine, Update and Remove) never forwards anything, whatever your SSH config says for that host: not your SSH agent, not X11, and no local, remote or dynamic port forward. Your SSH agent signs only c11's own sign-ins, here on this Mac. hc holds that connection for as long as the machine stays linked, so a forwarded agent would lend this Mac's keys to the other machine for that long.
- Every c11 terminal there is a shell running as you, with your files, keys and network on that machine. An agent in one can do anything you can do there.
- This Mac's hc can run programs and read and write files on a linked machine. The other direction is narrower: a linked machine types into only the terminals on this Mac that started work on it, and reads only the workspace here that holds its caller's panel: that workspace's panels with their titles and metadata, and its sidebar status and log. Mail an agent there sends can still reach agents in any workspace, so naming or resolving a recipient also tells it that panel's name and workspace.
- Agents there reach c11 on this Mac through the relay. c11 serves a relayed call only when it is signed with that terminal's own credential, and only as that terminal's panel. Typing into other panels, creating or closing panels and launching agents are refused from there; the one exception is `c11 show`, which opens and closes a viewer beside the caller's own panel.
- A viewer a linked machine opens is display only. A page c11 serves from its files runs script, but its fetches, sockets and loads reach only those files, and it has no WebRTC. Any other page in that viewer (a URL shown from there, or one it navigates to) runs no script. No navigation or popup in the viewer may name this Mac. Reopen Closed Browser Panel, Duplicate and Open in Default Browser never take its page out of the viewer. What still leaves, with no way to read an answer: a page can send a GET to any address this Mac answers on (an image, a link, its icon), a POST when you click a link, and an empty connection through `<link rel=preconnect>`.

## Same account, same trust

hc trusts every program that runs as your user on its machine. It has no per-program check.

- Any program running as you on a machine can list, read, type into and end every c11 terminal on that machine.
- Such a program on a linked machine can read a c11 terminal's environment there, including its relay credential, and so act as that terminal's panel toward c11. That is the gap on a linked machine: the relay can't be stronger than your own account there.
- The same holds on this Mac for its own terminals.
- Root on either machine is outside anything c11 or hc can check.

## Shards separate failure, not people

c11 runs its terminals across several hc processes (shards), so one crash ends fewer of them. Every shard runs as you. A shard is not a boundary between users or agents.

## What stays on disk

hc keeps each terminal's screen on disk in its state folder, and recent output in memory, so a terminal survives an app restart. Text that reached a screen, a secret included, stays there until the terminal ends; clearing the screen does not remove it.

## What c11 checks

- **hc's hash, on every path.** Every link c11 makes carries this build's hc hash (the pin), and a link without it is refused. Before linking, c11 checks the hc there against the pin and replaces a different file only while nothing runs it. Each time the link starts hc there, it hashes the file first and refuses a different one (`hc_hash_mismatch`). This catches a stale or damaged hc. It can't stop a program running as you that swaps the file between the check and the start.
- **The core already serving.** When an hc is already serving c11's session on the other machine, c11 finds that process from the kernel (the socket's peer process, its executable and the file it runs), never from its own reply, and refuses one that isn't this build's hc (`hc_serving_mismatch`). It never signals or stops that process. Remove and Update stop a core there only when it is identified the same way as the hc that link started (this build's, or the one the link was made with), through a client that passed the hash check; any other core is left running and you are told.
- **A Linux machine's hc and c11.** c11.app carries neither. Its signed `remote-artifacts.json` names each by SHA-256, and each comes from c11's cache on this Mac, a folder you name (`c11 machine link --artifacts <folder>`, which is then the only source), or the release download (redirects followed only to https). Both are hashed against those pins on this Mac before anything is written on the machine; a file that doesn't match is never used or sent (`remote_artifact_hash_mismatch`). An hc already there that hashes to the pin is kept, as on a Mac, and the link checks it at every start like any other.
- **Private folders.** hc's socket folder, state folder and session folder are made `0700`, on this Mac and on linked machines, whenever c11 starts, connects to or restores an hc and each time the link starts. Each is opened without following a symlink. A folder that is a symlink, not a folder, or another user's is refused (`dir_refused`), nothing under it is touched, and c11 does not use that hc. A read-only shard's folders are only inspected: a loose one is refused, not changed.
- **Consent.** c11's own ways to link ask first: Add Machine shows what linking grants before it does anything, and `c11 machine link` prints the same and waits for an answer. Inside a c11 terminal, `--yes` is refused. Update keeps the host a machine was linked through; linking it through another host is a new link and asks again. These checks are how c11 asks the operator, not a barrier against your own account: a program running as you can clear those terminal variables, give itself a terminal, or link with hc or SSH directly.
- **Machines linked by an older c11.** A link whose via doesn't check a pin is updated before c11 uses it: c11 re-renders that via with this build's pin, from the link's own host, session and hc, exactly as Update would, and records it (`link migrated`). That grants nothing new: you consented when the link was made. A via that checks a pin but still lets SSH forward is updated the same way, keeping its own pin, and recorded as `link migrated` (`forwarding_off`); the connection hc already holds keeps what it was opened with until hc dials again (after a sleep, a network change or an hc restart, or at once when you Update the machine). Where c11 can't do that (a read-only shard, a via outside c11's own folder such as one added by hand or by c11h, or a folder it can't write), c11 won't use this link; hc may still redial it until you Update or Remove it. c11 opens nothing on that machine and serves no relayed call from it, records why (`link unusable`), tries again later, and Settings > Herder Topography says so beside the machine.
- **Files you drop.** A file dropped from Finder onto a terminal on a linked machine is sent there only after you answer Send. A file dragged from inside c11 (the titlebar's folder icon, a web view) is never sent there. A directory a linked machine reports is never offered as a folder on this Mac, and its programs' Kitty graphics can't name a file on this Mac.
- **An audit log** of every cross-machine action.

## Read the audit log

`c11 machine audit` prints c11's audit log on this Mac with local times: every link, update and unlink, every older link migrated or found unusable, every terminal started on another machine, every relayed call (served, refused or failed), every file dropped onto a terminal on another machine (sent, cancelled, refused or failed), each hc hash and serving-core check, each folder made private or refused, and the starts the link refused, one record per cause every 10 minutes counting the refused starts it stands for. Repeated relayed calls of one kind within a minute are folded into one line with a count. `--json`, `--limit <n>` (0 for all), `--machine <machine>` and `--kind <kind>` narrow it. It works with c11 closed.

The log is in `~/Library/Application Support/c11/audit/` (folder `0700`, files `0600`): `audit.jsonl` for links, machines, terminals and the hc checks, and `relay.jsonl` for relayed calls, so relay traffic never rotates the others out. One JSON line per record; each file rotates at 2 MiB into its `.1.jsonl`. It records who, what, where and the outcome as codes and checked names. It never records command lines, prompts, terminal text, a relayed call's parameters or reply, a rejected input, or another program's output. Like every file you own, any program running as you can change it.
