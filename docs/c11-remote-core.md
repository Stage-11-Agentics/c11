# Installing the bundled core on another Mac

The operator installs the same signed c11 app's helper on the remote Mac. A new bundled link requires a local c11 build containing `Contents/Helpers/herdr-core` and `Contents/Resources/hc-pin.json`; an external-pin build cannot create that link. Installation does not start hc, restart a core, change a machine link, or end a terminal. Existing cores keep serving from their current binary until an operator-approved transition; keep the previous binary and via script for rollback.

Before staging, record the existing helper directories and whether the owned config file below exists. Save a copy of any existing config before installation changes it. The unused-install undo removes only paths that were absent beforehand.

On the remote Mac, from the c11 checkout:

```sh
scripts/c11-atlas-link.sh install --from /absolute/path/to/c11.app
```

The app must be a c11 release signed by its expected Apple-anchored signing team. The helper must match `Contents/Resources/hc-pin.json` and pass c11's retained-helper trust rule: a shipped helper hash, or the expected helper identifier and signing team. An unsigned or ad hoc development bundle is refused. The command prints the installed path and full SHA-256. It installs to:

```text
<remote home>/.local/share/c11/hc/<version>-<sha12>/herdr-core
```

The helper and its directory have mode `0555`. A matching install preserves the file's inode and modification time. A different file at the same hash-keyed path is refused and never replaced, whether or not it is serving. Symlinked input or destination paths are refused; use absolute physical paths.

Installation also writes `<remote home>/.local/share/c11/config/herdr-core/config.toml`, privately and atomically, with `headless = "200x120"`. Matching content is not rewritten. This config belongs to c11, and the remote user's shared hc config is untouched.

Render the link with the exact path printed by install:

```sh
scripts/c11-atlas-link.sh render --mode ssh --out /absolute/path/to/remote-via.sh \
  --session c11-s1 --socket /Users/remote/.local/share/c11/run/c11-s1.sock \
  --hc /Users/remote/.local/share/c11/hc/<version>-<sha12>/herdr-core \
  --sha <the bundle's executableSHA256> --machine buildbox \
  --home /Users/remote --user remote --target remote@buildbox
```

`--sha` is required by `render`, `serve` and `pair`, and c11 refuses to add a via that lacks this build's pin before the hc it runs. Before it starts hc, the via's remote line hashes that hc and refuses a different file (exit 5, `hc_hash_mismatch`); makes hc's socket folder, state root and session state folder `0700`, each opened without following a symlink, and refuses a symlinked, non-folder or foreign-owned one, which stops the walk (exit 6, `hc_dir_refused`); and, when a core already serves the session's socket, identifies that process from the kernel and refuses one that isn't this pin, without signalling it (exit 8, `hc_serving_mismatch`). On a Linux machine (`render --platform linux`), before it starts a core, it also refuses when no systemd user manager runs for the user (exit 10, `hc_needs_user_manager`), when linger is off (exit 9, `hc_needs_linger`) and when the user manager's default NOFILE soft limit is under 8192 (exit 4, `hc_fd_limit`). The via names each refusal in `link-ssh.log` with its machine, host and session, and c11 turns those lines into audit records (`c11 machine audit`, one per cause every 10 minutes, with a count). `c11-atlas-link.sh secure --session S --socket SOCK --hc BIN --sha HEX` runs the same checks on the remote Mac and prints a report instead of starting hc. `c11-atlas-link.sh stop --session S --socket SOCK --hc BIN --sha HEX [--allow HEX,...]` is the only stop c11 uses (Remove and Update): it sends `server stop` only after the client hashes to `--sha` and the serving core is identified from the kernel as an hc in `--allow` (default the pin); a foreign or unknown core is left running (exit 8), never signalled. Every via is an ssh via; there is no bridge mode. `c11-atlas-link.sh migrate --via FILE --sha HEX [--machine NAME]` re-renders a pinless via that an older c11 wrote, from its own values, with the pin, and updates a pairing manifest that owns it; c11 runs it before using such a link, and treats the link as unusable when it fails (exit 3: not one of c11's own vias; 4: unreadable, or another pair, unpair or migrate held the pairing lock for 15 s; 5: a manifest lists it without owning its bytes). `pair`, `unpair` and `migrate` share one lock, `.atlas-pair.lock` beside `atlas-pair.json`, so shards migrating at once keep every ownership hash.

Replace the example remote home, username, host, pin and session with that pair's actual values. Supply `--home` without a trailing slash. Each local shard links to the same session name remotely. The rendered command supplies only the remote core's owned `XDG_CONFIG_HOME`; it passes none of the local app's config or launchd-parent setting. The via's ssh turns every forwarding off whatever `~/.ssh/config` says for that host (`ForwardAgent=no`, `ForwardX11=no`, `ClearAllForwardings=yes`, `PermitLocalCommand=no`, `-k`), as it turns connection sharing off; ssh uses the local `SSH_AUTH_SOCK` only to sign in. A stored via without these switches is re-rendered by `c11-atlas-link.sh migrate`: a pinned one keeps its own pin, a pinless one takes this build's. The core utility checks that the via script names its expected hash-keyed pin, session, and matching remote config home before adding a link. An already-linked machine keeps its existing via script and core.

Remote terminals get their explicit panel `XDG_CONFIG_HOME`, including an explicitly empty value. Without a panel value, `/usr/bin/env -u XDG_CONFIG_HOME` removes the core's config variable. In either case, `/bin/sh -c 'exec "${SHELL:-/bin/sh}" -l'` starts the shell named by the far core's `SHELL`, falling back to `/bin/sh`. A remote terminal never takes the local app's inherited XDG path or shell choice.

The older `install --pin <version> --sha <sha256> < binary` command remains available for an external-pin transition. It uses the legacy version-only location and does not provide the bundled-helper signature check or owned-config installation. A new bundle link expects the hash-keyed location.

To check an install, compare `shasum -a 256 <installed helper>` with the bundle's `executableSHA256`, inspect the file and directory modes, and repeat `install --from` to confirm it reports `unchanged`. Then check the remote core's session and executable path through its diagnostics. Installing a file alone does not prove an already-running core adopted it.

Rollback restores the saved via script and remote pairing under the operator's approved procedure. Keep both binary directories while any core or holder uses them. Do not delete a serving binary or restart a live session merely to make its path match the latest install.

## Undo an unused staging install

On the remote Mac, remove a helper directory only if it was absent before staging, its helper still matches the recorded hash, and no machine link, pairing, core or holder uses it. Substitute the parent directory of the helper path printed by install; preserve every pre-existing binary. If use is uncertain, keep the files.

```sh
helper_dir="/Users/remote/.local/share/c11/hc/<version>-<sha12>"
if [ -d "$helper_dir" ] && [ ! -L "$helper_dir" ]; then
  chmod u+w "$helper_dir" &&
    /bin/rm -f "$helper_dir/herdr-core" &&
    rmdir "$helper_dir"
fi
```

Remove the owned config only if that file was also absent before staging, still contains `headless = "200x120"`, and no c11 core or holder uses that config home. Preserve pre-existing config, including any file the installer updated.

```sh
/bin/rm -f /Users/remote/.local/share/c11/config/herdr-core/config.toml
```

If the config existed before staging, restore its saved copy instead of deleting it, once the same unused-config checks hold:

```sh
/bin/cp -p /absolute/path/to/saved-config.toml /Users/remote/.local/share/c11/config/herdr-core/config.toml
```

These commands leave the config directories in place and do not restart anything. Repeating the removal commands after removal changes nothing.
