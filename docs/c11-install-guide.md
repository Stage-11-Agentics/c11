# Installing c11 on the laptop

This page is Atin's install on the laptop, with the build host. Anyone else installs from `docs/c11-friend-install.md`, which also ships in the zip as `README.md`. This page is for the first install of c11, the phase 1 build. c11 is c11 with every terminal held by hc, so quitting, crashing or updating the app doesn't end your work. It installs beside c11 and doesn't touch c11. What it promises: `docs/c11-plan.md`, "When M1 is done".

## What you need

- The signed zip from the build host, `<run-folder>/artifacts/c11/final/c11-macos.zip`. Its `c11-macos.zip.identity.txt` lists the commit and the zip's `zip_sha256`; the `.sha256` file holds the same hash.
- The c11 repo on the laptop, at current `main`: `cd ~/src/c11 && git pull`.
- A terminal in your own logged-in session. Any c11 terminal works. Don't install over ssh: the installer asks macOS which c11 is running, that question fails over ssh, and an update then stops and leaves the old app in place.

## Install, in this order

1. **hc ships inside the app** (C11H-66, `Contents/Helpers/herdr-core`), so this Mac needs no separate hc install. An app without that file needs the pinned hc first: run the build-host section's step 1 here on the laptop.

   **Before any pin bump** (the bundled core and the build host's alike): upstream herdr-core after 0.1.16 (from 44cb360) starts the macOS core through a launchd job, which breaks c11's TCC attribution (the core as c11.app's child) unless c11's launcher sets `HC_LAUNCHD_DIRECT=<launcher pid>`. 0.1.16 is unaffected. See c11-to-hc.md, item C7, in the hc repo (docs/): "**The core is a direct child of c11.app**, so TCC grants attribute to c11" … "**Breaks on upstream `master`**: macOS cores now start through a launchd job unless `HC_LAUNCHD_DIRECT=<launcher pid>`". 0.1.21 was evaluated on 2026-11-15 and not adopted; what it changes, its security fixes and what adopting it would take: [hc-0.1.21-evaluation.md](hc-0.1.21-evaluation.md).

2. **The app.** Check the zip, then install it:

   ```bash
   zip=~/Downloads/c11-macos.zip    # wherever the zip landed
   shasum -a 256 "$zip"              # must match zip_sha256 in the .identity.txt
   scripts/c11-install.sh "$zip"
   ```

   It prints `installed /Applications/c11.app imported=yes`. The first install copies your c11 settings into c11 once: themes, keys, sidebar, flag kinds and agent configs. Then open c11 from Finder, Spotlight or the Dock. A build made with `c11-release.sh --notarize` opens normally; one without it needs Open Anyway in System Settings > Privacy & Security.

## Updating to a build with relay credentials (C11H-176)

From that build on, c11 serves a build-host terminal's `c11` only with the credential it gives each terminal it opens there. **Build-host terminals opened by an earlier build go quiet:** their agents keep running, but their `c11` can no longer name the panel, set status, raise flags, or send or read mail, and each refusal says `relay_auth_missing`. They talk back again once reopened, and reopening a panel ends its session, so choose when. c11 writes one `relay_refused` line per such panel to `~/Library/Logs/c11/hc-diagnostics.log`. Reinstall the relay on the build host from the new app as well (the build-host section's relay step); until then the build host's `c11` says `relay_kit_outdated`.

## Try these first

With two or three agents working in c11:

1. **Quit** (Cmd-Q, then Quit), and open c11 again. Every panel shows the same process and screen. Within 10 seconds, the sidebar again shows who is working, flagged or waiting.
2. **Force-quit** c11 (Option-Cmd-Esc), and open it again. You should get the same result.
3. **Mail.** Send an agent mail with `c11 mailbox send --to <agent> "<text>"`, including to a Claude agent. It arrives just as it does in c11.
4. **An update.** When a newer zip arrives, run `scripts/c11-install.sh <new zip>` while the agents work. It quits only c11, the same clean quit as Cmd-Q, and swaps in the new app; the agents keep running, and the next launch doesn't treat the update as a crash. Open c11 again: the same shells are still there, and they keep their file access.

Each terminal's subtitle shows where its session runs, and marks one that won't survive a restart.

## Build host

For a build that bundles its hc helper, use [the remote bundled-core installation](c11-remote-core.md). The version-only external-pin steps below describe the earlier transition.

Build-host terminals open in the same c11 window, through c11's own hc core on the build host.

**The short way, for a Mac with Apple silicon or an x86-64 Linux machine:** Settings > Herder Topography > **Add Machine…**, or `c11 machine link --host <ssh-target>` in a c11 terminal. Give the SSH host you already use (`studio`, `me@studio.local`); c11 signs in with your SSH keys, installs its pinned hc and the relay there, links the machine and checks the link. Each step that fails says what to fix (host key not yet accepted, key not authorized, Command Line Tools missing there). A Linux machine needs systemd, `/usr/bin/python3`, `sha256sum` or `shasum`, `tar` (a Mac needs it too, and every Mac has it), linger for your user (`sudo loginctl enable-linger <user>`: hc runs its core there as a user service, which otherwise stops at your last logout) and a user-service file limit of at least 8192 (`DefaultLimitNOFILE=524288` under `[Manager]` in `/etc/systemd/user.conf.d/`); Add Machine checks each before it writes anything there. Its hc and c11 for Linux come from the c11 release the first time (about 75 MB, cached in `~/Library/Application Support/c11/remote-artifacts/`), or from `c11 machine link --artifacts <folder>`, and each must hash to what this build names; a Linux machine's terminals start bash. **Remove…** under the gear beside the machine (or `c11 machine unlink --id <machine>`) ends c11's terminals on it, after listing them, and unlinks it. When this c11's hc is newer than a machine's, its gear says so and offers **Update…**. After switching from c11h, a machine c11h linked offers **Link Again…** instead: it links the machine in c11's own session, beside c11h's old link, whose terminals keep running ([the cutover guide](c11-2.0-cutover.md#linked-machines-the-build-host-the-linux-host)).

1. **On the build host: the pinned hc (0.1.16).** c11's core on the build host runs only this exact binary. From the c11 repo on the build host:

   ```bash
   mkdir -p <staging>/hc/0.1.16 && cd <staging>/hc
   curl -fsSLo herdr-core-macos-aarch64.tar.gz https://releases.herdr.dev/core/0.1.16/herdr-core-macos-aarch64.tar.gz
   shasum -a 256 herdr-core-macos-aarch64.tar.gz   # must be 698d8f0c44f4e4b15fec174d52a39d57a014cfd71added44b53a0753b469d0fd
   tar xzf herdr-core-macos-aarch64.tar.gz -C 0.1.16
   cd ~/src/c11
   scripts/c11-atlas-link.sh install --pin 0.1.16 --sha c617feeb4d1b5f59b30e4ab6b4e9e7f7ac114d0681d207d9f41efa12c813b922 < <staging>/hc/0.1.16/herdr-core
   ```

   If that binary is already at `~/.local/share/c11/hc/0.1.16/herdr-core` with this hash, the command changes nothing.

   It prints `installed …/.local/share/c11/hc/0.1.16/herdr-core`. A wrong binary is refused. herdr-app's own `herdr-core` and its `default` session are not touched.

2. **Legacy external-pin link script (transition only).** New bundled links require a build that includes its hc helper and the hash-keyed path from [the remote bundled-core guide](c11-remote-core.md). Keep an existing live link's script until its operator-approved transition. For the legacy version-only setup, run from the c11 repo on the local Mac:

   ```bash
   scripts/c11-atlas-link.sh render --mode ssh --out ~/.local/share/c11/atlas-via.sh --session c11 \
     --socket /Users/demo/.local/share/c11/run/c11.sock \
     --hc /Users/demo/.local/share/c11/hc/0.1.16/herdr-core \
     --sha c617feeb4d1b5f59b30e4ab6b4e9e7f7ac114d0681d207d9f41efa12c813b922 \
     --home /Users/demo --user demo
   ```

   The `--socket`, `--hc`, `--home` and `--user` values are the build host's, and they must be full paths. `/Users/demo` and `demo` are examples: use the remote account's home and user. The script ssh's to `--target <user@host>`, else `C11_REMOTE_HOST` from the environment, else a `C11_REMOTE_HOST=<ssh host>` line in `~/.config/c11/dev-hosts`; with none of them it names the variable and exits 2. The script runs c11's pinned binary on the build host by its full path, never herdr-app's.
3. **In a c11 panel: add the machine.**

   ```bash
   hc machine add --name <machine> --session c11 --via ~/.local/share/c11/atlas-via.sh
   ```

4. **Check it.**
   - In the c11 panel, `hc machine ls` should show the machine (`<machine>`) as connected, version 0.1.16.
   - On the build host, `ps -axo pid,command | grep '[h]erdr-core'` should show c11's binary (`~/.local/share/c11/hc/0.1.16/herdr-core`) serving session `c11`.
   - herdr-app's `default` session should be untouched: its core has the same pid as before step 3, and its terminals are unchanged.
5. **Open build-host terminals** from File > New Terminal on that machine. The CLI's `--on <machine>` route needs C11H-33's update first.

### Shard pairs (C11H-78)

With shards (C11H-67), c11 runs up to eight hc sessions here, `c11-s1` to `c11-s8`. Each local shard links to the remote session of the same name, so a flood on the remote machine stays inside one shard. Steps 2 and 3 above set up only the legacy `c11` session; shards pair through one file instead.

1. **On the remote Mac: the relay, once per shard.**

   ```bash
   scripts/c11-atlas-relay.sh install --session c11 --shards 8 --cli <c11.app>/Contents/Resources/bin/c11
   ```

2. **On the local Mac: pair the shards.**

   ```bash
   scripts/c11-atlas-link.sh pair --mode ssh --session c11 --shards 8 \
     --hc /Users/remote/.local/share/c11/hc/0.1.16/herdr-core \
     --sha <the pinned hc's executable SHA-256> \
     --home /Users/remote --user remote
   ```

   Replace the example home and user with the remote account; the ssh host is `--target <ssh-host>`, else `C11_REMOTE_HOST` (environment or `~/.config/c11/dev-hosts`), and the machine name is `--machine <name>`, else that host without any `user@` (never `default` or `local`, which c11 reads as this Mac). `--sha` is the pinned hc's executable SHA-256: c11 adds a paired via only when it carries this build's pin, so after updating c11, run `pair` again with the new build's `--sha` (an older pairing logs `unsafe_via reason=no_pin` in the pairing log and is not added).

   For an x86-64 Linux machine, add `--platform linux` and give the Linux hc's SHA-256 (`herdr-core` for `linux-x86_64` in this build's `Contents/Resources/remote-artifacts.json`) as `--sha`, with `--hc` and `--home` naming its files there (Add Machine installs that hc at `~/.local/share/c11/hc/<version>/herdr-core`). Step 1 there passes c11's Linux CLI as `--cli`. Each via is then rendered as Add Machine renders a Linux link, with bash and the C locale for its terminals; the machine needs what Add Machine checks for a Linux machine (above). c11 adds a via only when it checks this build's pin for its own platform; one that checks the other platform's logs `unsafe_via reason=other_platform_pin` and is audited `via_other_platform`.

   `pair` first asks in the terminal, naming the machine, the shard count and the ssh target, and writes nothing without a typed yes; `--yes` skips the question and is refused inside a c11 terminal. The pairing file records that answer (`"acknowledged": 1`), and c11 adds a machine only from a file that has it: one from an older `pair` keeps machines already added, adds no new one (`unacknowledged` in the pairing log, `pairing_unacknowledged` in `c11 machine audit`), and is fixed by running `pair` again.

   This renders one via per shard, `~/.local/share/c11/atlas-via-c11-sN.sh`, each running the remote Mac's `c11-sN` session only. It also writes `~/.local/share/c11/atlas-pair.json` listing those vias. Each via turns ssh connection sharing off (`ControlMaster=no`, `ControlPath=none`), so one shard's dropped line never takes another's down.
3. **No `hc machine add` by hand.** When a shard's core connects, c11 adds the paired machine (the pairing file's `machine`) to that core with the shard's own via and session. An unused shard has no remote core. Without the pairing file, c11 adds no machine. The debug log records each add as an `hc.pair` line. The first remote terminal waits for its shard's registration and reads that session's relay manifest before `terminal.run`. A missing or invalid manifest refuses creation before sending the terminal request.
4. **Check it.** On the remote Mac, `ps -axo command | grep '[h]erdr-core'` shows only `c11-sN` sessions that a local shard is using, each from the pinned binary.

To unpair, run `scripts/c11-atlas-link.sh unpair`. It removes only unchanged vias whose hashes match the self-hashed pairing manifest, then the manifest. Re-pair refuses changed or unowned vias before writing; unpair preserves them. Symlinked files and parent directories are never followed. Edited manifests and old manifests without ownership hashes authorize no writes or removal; preserve any custom vias before replacing such a manifest. A machine already added to a running shard stays until `hc machine rm <machine>` in that shard.

## The c11 skill

c11's skills (`c11`, and the bundled ones `skills/MANIFEST.json` lists) install only when you ask, from Settings > Agents, under c11 skills, or with `c11 skill install` (Claude Code by default; `--tool` names another). Nothing installs on its own. `c11 skill remove` removes the copies c11 installed. The old `c11h` skill is part of `c11` now: installing retires a `c11h` copy c11 stamped. <!-- c11-2.0:keep -->

## What works differently from c11

- **Closing a panel ends everything it started**, `nohup` and background jobs included. In c11 those jobs outlive the panel. The close button says **End Session** and names what ends.
- **A reboot or a holder loss ends the terminals.** One hc process holds them all. After a reboot, or if that process dies, c11 resumes each conversation once, into a fresh terminal. Tell the Lead about any holder loss; we count them this week.
- **Clear-history isn't durable on hc 0.1.16.** It clears what you see. hc keeps the history, and it comes back after c11 restarts or reconnects. The command says so.
- **Small terminal-query differences.** hc answers three terminal queries itself, a little differently from c11. A program that asks may turn off clipboard writes.
- **The first launch after installing an unnotarized build can take a few minutes**, while macOS checks the app. Your terminals keep running meanwhile.
- **After the hc core is killed, a hidden panel reads blank until you show it.** It reconnects, and its processes keep running.
- **A status, flag or delegation set in the last seconds before a force-quit or crash can be lost**, as in c11. A normal Quit keeps it.
- **`c11 hc-diagnostics` shows no tty yet**, and it can miss a panel in a hidden workspace.
- **Check these by hand on day one:**
  - Bell: `printf '\a'` in a panel should sound and badge.
  - IME: a Japanese IME composition.
  - Mouse in vim: with `:set mouse=a`, a click should move the cursor.
  - Data & Privacy: in Settings, the page should say c11 sends no telemetry.
  - Codex agents (the test guests have no Codex): force-quit and reopen with a Codex agent working, and its conversation should stay live. Mail to a Codex agent waiting at an empty prompt should arrive.
  - File access (TCC): from a c11 shell, read a file in Desktop, Documents and Downloads, and grant access if macOS asks. Quit, reopen, and read again from the same shell. Do it once more after the first update. There should be no new prompt.
- **Your c11 settings are copied once**, at the first install. Later changes in c11 don't carry over, and a later install doesn't import again.
- **c11 stays untouched.** c11 keeps running beside c11, with its own socket, settings and terminals. Installing, updating or quitting c11 never quits c11 or writes its settings.
- **Reopening c11 from one of its terminals is safe.** `open` hands the app that terminal's environment, hc's `HC_SCOPE` token included, and hc ends every process carrying the token when that panel closes. c11 removes the terminal's identity from its own environment at launch, so closing the panel leaves it running, and it holds the end of a panel whose token another c11 app still carries. A build without this (c11h 1.8.1-h21 and earlier) quits when that panel closes, and also when that terminal's program exits by itself, since hc ends what the terminal started either way: open it from Finder, Spotlight or the Dock, or with a clean environment (`env -i HOME="$HOME" USER="$USER" PATH=/usr/bin:/bin open -a <app>`).
- **Run hc commands for c11 only inside a c11 panel.** There, `hc` and `HC_SOCKET` point at c11's own core. Your separate herdr-core daemon on the laptop (`herdr-core-try`, the `default` session, with its own ssh link) is a different core. Outside c11, a bare `herdr-core` or `hc` could reach that one instead.
- **Typing in a build-host terminal is slower than in a local one.** On 2026-10-31, over the tailnet's relayed path, a keystroke round trip measured about 72 ms typical (p50). A direct path should cut that; the fix to the network comes later (Settled 17).

## Trust boundary

This prototype trusts your user account, as c11 does. That boundary gets tightened before any public release.

- **Socket calls from inside c11 terminals** are admitted by process ancestry: the caller must run under a c11 terminal (C11H-33).
- **The raw mailbox file protocol trusts any process running as you**, as in c11: anything of yours can write an outbox file, and the inbox drain at each turn's end reads it.
- **The build-host link serves only c11's own terminals there:** each call must be signed with the credential c11 gave that terminal, and runs as that terminal's panel (C11H-176). A process of yours on the build host that reads a c11 terminal's environment, or types into it through hc, can still act as that terminal: hc gives your user every terminal on that machine (`docs/c11-relay.md`).
- **Terminal labels are readable by any process of yours:** c11 keeps `c11.panel`, `c11.workspace` and `c11.title` on each hc terminal, so it can put a terminal back in its own workspace with its title (C11H-103). Anything running as you can read them through hc, on that terminal's machine too. They carry no secrets: `c11.title` is the panel's custom title, clipped to 120 characters, so don't put a secret in a panel title.

If something is wrong, quit c11 and keep working in c11. The c11 Lead takes the report.

c11 sends no telemetry and no crash reports; tell the c11 Lead what happened.
