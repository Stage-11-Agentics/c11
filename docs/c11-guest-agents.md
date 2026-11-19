# c11 guests with agent CLIs

c11's build-host guests clone two c11 images instead of c11's bare goldens. The images hold node and the agent CLIs and no credential. A proof run that needs Claude passes the build host's Bravo setup token to one guest process as an environment variable, over the ssh session's stdin. The guest is a clone, and `sandbox-down.sh` deletes it.

## What is in the image

| Image | Made from | Serial slot |
|---|---|---|
| `c11h-sandbox-golden` | `c11-sandbox-golden` | A |
| `c11h-sandbox-golden-b` | `c11-sandbox-golden-b` | B |

Each image is a `tart clone` of c11's golden for the same slot, so it keeps that golden's serial (`ecid` in `config.json`) and its finished Setup Assistant. Added to it:

- node v24.22.2 (LTS), the official `node-v24.22.2-darwin-arm64.tar.gz`. Its SHA-256 `aa9549349e47dffaa42dcf95d6e06ade8c4bdafc980979883b88767670df385a` is pinned in `scripts/c11-guest-image.sh` and checked against nodejs.org's `SHASUMS256.txt` over HTTPS. The build host has no gpg, so the signature on that file is not checked. Installed at `/opt/c11h/node`.
- `@anthropic-ai/claude-code@2.1.316` (the version the build host runs) and `opencode-ai@1.15.13` (the version c11's OpenCode proofs run), installed with `npm install -g --prefix /opt/c11h/npm`. npm checks every tarball against the registry's sha512 integrity, which is recorded below. Only these two packages may run install scripts (`--allow-scripts`); each one places its native binary.
- `/usr/local/bin/{node,npm,npx,claude,opencode}` links. `/usr/local/bin` is on the guest's login PATH, behind c11's wrappers.
- First-run answers that need no credential, in `~admin/.claude.json`: onboarding done, dark theme, auto-update off, bypass mode accepted, and folder trust for `~admin`, `~admin/c11-sandbox`, `~admin/c11-sandbox/work`, `/tmp` and `/private/tmp`. There is no account, token or key.
- `/opt/c11h` is owned by root and not writable by `admin`, so neither CLI can update itself in a clone.
- `/opt/c11h/VERSIONS`, copied on the build host to `~/.c11-sandbox/c11-images/<image>.versions` (`scripts/c11-guest-image.sh status` prints both images):

```
macos=26.6.2
node=v24.22.2 tarball=node-v24.22.2-darwin-arm64.tar.gz sha256=aa9549349e47dffaa42dcf95d6e06ade8c4bdafc980979883b88767670df385a
claude_code=2.1.316 (Claude Code)
opencode=1.15.13
npm @anthropic-ai/claude-code@2.1.316 sha512-i3BpzyDkcCPnsa0CSkWgxGPs7WMsyqDkxkqT0SDxyEC5XMIxEmcUmluWRHG9VSeBY8Vyv+l9X34JvJ/Bj54nBQ==
npm @anthropic-ai/claude-code-darwin-arm64@2.1.316 sha512-wJiLVMzg2atF7C/a+0wt+yQShWIePsMNL86gIoIJanURY2fxrwHIxrYuxoTW8sWqfj7ai+otV/ik2r7m5aPy1g==
npm opencode-ai@1.15.13 sha512-9LvgcILITiYPsKrBYSHQYR4ur/WBQYMHN5jEnboa/NVboPyl+WBGgvDHQ2SJasPpBmCAd2YTTorz2uMbcF7Hhw==
npm opencode-darwin-arm64@1.15.13 sha512-/6LSBPUdhNdev0JwOOZePOS8QSrH5XPj2bCkZUeoSyab3i0VMFlbW1hyi93pvsyEFd68OwThoAcy9I4f6TGslQ==
sha256 64c327e92b2c5e0f78c0a980c5a518121e1f0d140ca771ca5dd4488d1a2dcb3f  .../@anthropic-ai/claude-code/bin/claude.exe
sha256 1cdcb7e426a863528a41ae8f9f6b65470b8395ddd48937229b01299ddc1085f0  .../opencode-ai/bin/opencode.exe
credentials=none
```

**Which agents run in a guest.** Claude Code runs on the injected Bravo token. OpenCode runs with no credential at all, against the synthetic local provider c11's OpenCode proofs use (`scripts/stage-opencode-mail-proof.sh`); it never receives the Bravo token, which is a Claude Code OAuth token. omp is not in the image: its no-credential mode needs a bundle built on the host plus Bun, which `scripts/sandbox-agent.sh <run> stage omp` still stages into these guests. Codex rows do not run in guests. They run on the laptop through the Lead.

## How a guest is leased from it

`scripts/sandbox-common.sh` separates a serial slot from what the slot clones:

- `C11_SANDBOX_GOLDEN` / `C11_SANDBOX_GOLDEN_B` name the slots (c11's goldens). `sandbox-up` records the slot it took in `~/.c11-sandbox/runs/<id>/golden`. Every copy of the scripts, including c11's unchanged ones, reads that record and keeps two running guests off one serial.
- `C11_SANDBOX_IMAGE` / `C11_SANDBOX_IMAGE_B` name the clone source for each slot. Unset, a slot clones its golden, as before. The run records the source in `runs/<id>/image` and in the meta file as `IMAGE=`. A named image must exist and be stopped, like the goldens. `refuse_protected` refuses to operate on it.

Integration step, done once both images exist (not part of this change): `<run-folder>/bin/guest-up` exports `C11_SANDBOX_IMAGE=c11h-sandbox-golden C11_SANDBOX_IMAGE_B=c11h-sandbox-golden-b`. Until then, guests clone c11's goldens as before. `--allow-second` works as before: when slot A is in use, slot B clones `c11h-sandbox-golden-b`. `sandbox-agent.sh`'s disk checks read the run's image, not the slot's golden. `tests/test_sandbox_image_select.py` covers selection with a stand-in tart (`C11_SANDBOX_TART_BIN`, a test seam).

## How a proof gets Claude

`tools/c11-guest/claude-env.sh`, host side. The proposed kit aliases are `claude-sh` and `claude-aqua-sh` in C11H-17's `g.sh`, dispatching to this script. Until that kit change lands, call the script directly.

```bash
C11_GUEST=<run> tools/c11-guest/claude-env.sh sh 'claude -p "reply OK"'          # plain ssh session
C11_GUEST=<run> tools/c11-guest/claude-env.sh aqua-sh '<zsh that launches the app>' # Aqua session
C11_GUEST=<run> tools/c11-guest/claude-env.sh smoke                               # claude -p + argv sampling
C11_GUEST=<run> tools/c11-guest/claude-env.sh verify-clean [more host paths...]
```

- On the build host, the token is the first line of `~/.config/stage11/claude/bravo.token` (override `C11_CLAUDE_TOKEN_FILE`) that is not blank or a `#` comment. It must start `sk-ant-oat01-`. It is read into a bash variable and written to ssh's stdin with the `printf` builtin, so no process gets it as an argument.
- In the guest, `zsh -c` `read`s that line into `CLAUDE_CODE_OAUTH_TOKEN`, which Claude Code reads for a setup token. The snippet then runs with stdin at `/dev/null`, `DISABLE_AUTOUPDATER=1` and the image's PATH. The remote command line carries only code. The snippet's output passes through unchanged, so a snippet must not print its environment.
- `aqua-sh` goes through `launchctl asuser` and `sudo -u admin`, which pass stdin through. Use it to start the c11 app with the token in its environment, so the app's terminals inherit it. The kit's `launch` passes variables as `open --env K=V`, which is an argument list, so do not pass the token that way.
- `smoke` runs `claude -p 'reply OK'`. It reports `smoke=PASS` only when Claude exits 0, its reply is `OK`, and no sampled argv on either machine holds the token. The process tables are sampled every 0.5 s for a 12-character token slice. The guest takes the slice from its own environment and feeds it to `grep` by process substitution, so the check adds nothing to any argument list.

## What is never stored

The token is never in the image, in a file in the guest, in an argument list on the build host or in the guest, in a log, in an evidence file, in a screenshot, in a commit, a PR or a mailbox message, or in a seat's transcript. It lives in the guest only in the memory of the process tree the verb started, and that tree goes away with the clone.

`verify-clean` checks this after a run. Before `sandbox-down`, it searches the guest's `~admin`, `/private/tmp` and `/opt/c11h`. On the build host it searches the evidence tree, `~/.c11-sandbox/{runs,out}/<run>`, `<run-folder>/{logs,state}` and any paths you add (a seat's transcript directory, for example). The search is for characters 14 to 25 of the token, a slice of the secret body. The literal first 12 characters are `sk-ant-oat01`, which every setup token shares and Claude's own bundle contains, so they would prove nothing. The slice goes to `grep -F -f` on a pipe and is never printed. The guest search runs as root through the image's passwordless sudo, so no guest file is unreadable. On the build host, the default run paths are each reported as present or absent, and paths named on the command line must exist. A fresh canary must be found. Any grep error, an unreadable file, a missing required root or a lost canary makes the verdict `ERROR` and `verify_clean=FAIL`, never an absence. `tests/test_claude_env_injection.py` covers the verb through a stand-in ssh.

## How to rebuild the image

On the build host, with a guest lease from the Orchestrator (a build boots one guest), at one-minute load under 30 and at least 60 GB free:

```bash
C11_SANDBOX_HOST=local scripts/c11-guest-image.sh build a    # then: build b
C11_SANDBOX_HOST=local scripts/c11-guest-image.sh status
```

To move a version, edit the pins at the top of the script: `NODE_VERSION` with `NODE_SHA256` from nodejs.org's `SHASUMS256.txt`, `CLAUDE_CODE_VERSION`, `OPENCODE_VERSION`. Then rebuild both slots. The script refuses when the slot's serial is in use by a running guest (build the other slot first), and when two guests are already running. It clones the slot's golden as `c11-sb-c11-img-<slot>`, recorded under that slot so every `sandbox-up` keeps the serial free while the build runs, and boots it headless without `--random-serial`. It installs over ssh and shuts the clone down cleanly. Then it checks that the clone carries the golden's `ecid`, replaces the old image with `tart rename`, and confirms that the golden's `disk.img` mtime did not change. c11's goldens are only read by `tart clone`. They are never booted, written or deleted. A failed build deletes its clone. A rebuilt image takes effect for the next lease. Running clones keep their own disks.
