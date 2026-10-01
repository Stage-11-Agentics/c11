# Sandboxed c11 instances for computer-use validation

C11-244, phase 1 research. 2026-09-30. No VM was installed and no image was downloaded. Phase 2 (the scripts and the `skills/c11-computer-use` update) waits for the orchestrator's go.

The failure this has to remove: synthesized clicks and drags against a tagged c11 build run in the operator's Aqua session, so they move the operator's cursor and key window. That happened on Hyperion on 2026-09-29. The sandbox has to give the validation run a different cursor and a different key window. Screenshots already have a safe path (`screencapture -l <windowid>`); the unsolved part is pointer and focus.

## Recommendation

Use a headless Tart macOS guest on this Mac. One APFS clone per run, deleted afterward. The host never opens a VM window. The agent drives the guest over SSH with the same `cliclick` / `osascript` / `screencapture` tools the computer-use skill already uses, posted into the guest's Aqua session. Copy a prebuilt tagged `.app` in. Do not build inside the guest.

Keep a second local user, reached through Screen Sharing's virtual display, as the fallback if the phase-2 Ghostty probe cannot allocate a GPU surface in the guest. Do not use an in-session virtual display. Do not move this to Atlas by default.

## This machine

Probed locally on 2026-09-30. Nothing below required sudo.

| Probe | Result |
|---|---|
| Host | Hyperion, `Mac16,6`, Apple M4 Max, 12 performance + 4 efficiency cores, 128 GiB RAM |
| OS | macOS 26.6.2 (build 25G83), Darwin 25.6.0 |
| Disk | APFS. `df` reports 637 GiB available on `/System/Volumes/Data`. Container free space 683.9 GB |
| Virtualization.framework | Present at `/System/Library/Frameworks/Virtualization.framework` |
| `tart`, `lume`, `utmctl`, `qemu-system-aarch64` | Not on `PATH`, not installed via Homebrew, no matching app in `/Applications` |
| `cliclick` | `/opt/homebrew/bin/cliclick` 5.1 |
| `vncdotool` | `/opt/homebrew/bin/vncdotool` |
| Local users | `atin` only (plus system accounts) |
| Screen Sharing | `com.apple.screensharing` is not registered in the system launchd domain |
| Tagged c11 app size | 105 MB for `c11 DEV c11-212.app`. `/Applications/c11.app` is 135 MB |

A 25 GB base image fits. An 8 GB guest is a small slice of 128 GB. Capacity is not the constraint. The constraint is Apple's two-guest cap, and whether Ghostty's renderer accepts the guest GPU.

## Options

| | Tart macOS VM | Second login + virtual display | In-session virtual display |
|---|---|---|---|
| Isolation | Own kernel, WindowServer, cursor, `/tmp`, TCC | Own Aqua session and cursor. Shared kernel, GPU, and `/tmp` | Same session. Same cursor, same key window |
| Solves the 2026-09-29 collision | Yes, if the host runs the VM with `--no-graphics` | Yes, if input is posted in the other session and the console user is never switched | No |
| Boot / clone | Cold boot not measured (image not pulled). Clone is an APFS copy-on-write | Session comes up on VNC login. No multi-GB image | Instant. No image |
| GPU for Ghostty | Paravirtualized Metal, reduced capability. Unproven for Ghostty until the probe | Host GPU, full capability | Host GPU, full capability |
| License | Two running macOS guests per Mac, enforced by the framework | No extra macOS license | No extra license |
| Disk | ~25 GB golden, clones cheap until they diverge | A second home directory | None |
| Operator setup | Install Tart, pull one image, bake the golden once | Create a user, turn on Screen Sharing, grant TCC once | None, and it still fails the requirement |
| Agent can drive it from a script | Yes: SSH plus guest-side tools | Yes, with care: VNC or a process inside that session | Yes, and it steals the operator's cursor while it does |

Lume and UTM are the same Virtualization.framework substrate as Tart. They are covered under the VM column, not as a third isolation model. A hand-rolled `VZVirtualMachine` wrapper would reimplement Tart.

## 1. Virtualization.framework guest

Tart is the CLI in front of Apple's framework. Current docs: [tart.run quick start](https://tart.run/quick-start/). The GitHub project page currently resolves as [openai/tart](https://github.com/openai/tart) and its README says `brew install openai/tools/tart`. tart.run still says `brew install cirruslabs/cli/tart` and still publishes releases and images under `cirruslabs`. Phase 2 confirms which tap answers before anything is installed. Neither is installed here.

### What Tart already does that this ticket needs

- `tart run --no-graphics` does not open a host window. The flag's help text is "Don't open a UI window," for integrating VMs into other tools, and CI configs use it that way (`screen -d -m tart run … --no-graphics`). The guest still boots a full Aqua session. A third-party agent skill ([jonnyzzz/tart-skills](https://github.com/jonnyzzz/tart-skills)) already drives that session with `screencapture` and `cliclick` over SSH. That is the shape we want. It is someone else's skill, not a measurement on Hyperion.
- `tart run --dir=name:hostpath[:ro]` exposes a host directory over virtiofs. macOS guests mount it at `/Volumes/My Shared Files/<name>` (host and guest both need macOS 13 or newer; this host is 26).
- `tart clone` is an APFS copy-on-write. Tart's own clone command says a clone does not claim the full disk until the guest writes. Deleting the clone throws the run away.
- Default VM shape is 2 CPUs, 4 GB, and a 1024×768 display. That display is too small for the computer-use skill's readability bar. `tart set --cpu 4 --memory 8192 --display 1440x900` is the phase-2 default (display values are points for a macOS guest; the parser lives in Tart's `Set` command).
- `tart set --random-mac` and `tart set --random-serial` issue a new MAC and a new `VZMacMachineIdentifier`. Apple treats two running guests that share a machine identifier as undefined. The script runs both flags on every clone before boot. The golden image stays stopped, so the default of one running clone never has two live copies of one identity anyway.
- Base image: `ghcr.io/cirruslabs/macos-tahoe-base:latest`. tart.run says the pull is 25 GB. Credentials on the published images are `admin` / `admin`, and SSH works via `ssh admin@$(tart ip <name>)`. The golden image should replace password login with a key before any agent uses it. NAT is the default, so the guest is reachable from the host.
- `tart exec` (guest agent, user launch agent) can run a command without SSH. Confirm the Tahoe base image actually ships that agent during golden-image setup. SSH is the documented path and the one the scripts should depend on.

`tart run --suspendable` has existed since the Sonoma-era Tart 2.0 notes: resume a host-local encrypted snapshot instead of a cold boot, and `tart push` does not upload that snapshot. Cold-boot duration was not measured here. Disposable clones of a stopped golden are the right default, because a resumed snapshot is a dirty machine. If phase 2 times a cold boot and it is too slow, suspend becomes an optimization on top of the clone, not the source of truth.

UTM (`utmctl`) uses the same framework for macOS guests, with the same two-guest cap and the same GPU. It is a GUI app and it is not installed. Lume ([trycua/cua](https://github.com/trycua/cua)) is the same framework plus an unattended Tahoe preset (user, SSH, auto-login, sleep and lock disabled) and an HTTP API for screenshots and clicks. Lume's own limits page states the two-guest cap. Its installer is a curl pipe, telemetry is on unless disabled, and the CLI moves quickly. The computer-use skill already speaks `cliclick` and `screencapture`, so Tart plus SSH matches it with less new surface. Use Lume's unattended checklist as the golden-image contents. Switch to Lume only if `tart exec` and SSH both fail to reach the Aqua session.

### Metal, and why Ghostty might still fail

A macOS guest gets a paravirtualized GPU: the guest submits Metal, the host runs it on the real GPU. Cua measured a stock Tahoe guest (macOS 26.5.2, Lume 0.5.1, M1 Ultra host on macOS 26.6.1) and the device reported an Apple 5-era family, 32 KB maximum threadgroup memory, and no SIMD-group matrix support ([Cua, 2026-08-11](https://cua.ai/blog/gpu-passthrough-macos-vms)). Lume's docs describe the same limit as GPU Family 5. That is enough for ordinary terminal compositing. It is not a passthrough of the M4 Max.

c11's renderer does not have a software fallback that matters here. With the host screen locked, WindowServer refuses the GPU-backed surface and `ghostty_surface_new` returns `error.OutOfMemory` (repo note in `CLAUDE.md`, from the C11-238 run). The guest must present an unlocked virtual display whose WindowServer will allocate those surfaces. Auto-login and a disabled lock screen, which Tart's own from-scratch guide already requires, are part of the golden image for that reason.

This was not booted on Hyperion. Phase 2's first real action is the probe below, before the skill starts sending agents into the VM. Family 5 is evidence the GPU exists, not evidence Ghostty's shaders accept it.

### Getting the tagged app in, and driving it

Copy, don't build. A tagged debug app is about 105 MB. Mount the host's DerivedData product directory read-only, copy the `.app` onto the guest disk, clear `com.apple.quarantine`, and launch it inside the guest. Building inside the guest would put an `xcodebuild` on Hyperion, which this run is not allowed to do, and it would still be the host's CPUs.

Launch with the same contract as `scripts/launch-tagged-automation.sh`: strip inherited `C11_*` / `CMUX_*`, set `C11_SOCKET_MODE=automation`, `C11_QA_LAUNCH=fresh`, and a guest-local socket under the guest's `/tmp`. The host does not talk to that socket. The host SSHs `c11` commands so they hit the guest CLI. `open -g` on the host must never be pointed at a guest path.

Input and screenshots:

1. Preferred: SSH, then `launchctl asuser <guest-uid>` so `cliclick`, `osascript`, and `screencapture` run in the guest Aqua session. That session is the guest's console, which is a virtual display. Nothing in that path posts a host `CGEvent`.
2. Fallback: `tart run --vnc` (or the guest's own Screen Sharing on 5900) and the host's existing `vncdotool`. Do not open Screen Sharing.app on the host. That would be a host window.

### License, and the two-guest cap

The license installed on this Mac (`Setup Assistant.app/.../en.lproj/OSXSoftwareLicense.html`, macOS 26.6.2) section 2B(iii) allows up to two additional copies or instances of macOS in virtual operating systems on each Apple-branded computer, for software development, testing during software development, macOS Server, or personal non-commercial use. Validation of c11 is the testing purpose. The same section bars service-bureau and time-sharing use. This is not that.

The framework enforces the count. A third macOS guest fails with `VZErrorDomain` code 6, `VZError.virtualMachineLimitExceeded` ("The maximum supported number of active virtual machines has been reached"). Howard Oakley documented that as a license limit rather than a hardware limit in 2022, on a 128 GB Ultra that still stopped at two ([Eclectic Light Company](https://eclecticlight.co/2022/08/04/virtualisation-on-apple-silicon-macs-8-how-apple-limits-vms/)). Apple's current `VZError.virtualMachineLimitExceeded` docs still describe the same code. A June 2026 Apple Developer Forums report (macOS 26.5, M4 Max) says a guest-initiated shutdown sometimes does not return the slot until the host reboots. The script must count running guests before clone-and-boot, and a stuck slot is an operator-visible failure, not something to route around with a boot-arg.

Disk images on disk are not the cap. Running guests are. Default the script to one running clone. Allow a second only when two validations genuinely overlap. Never start a third.

### Host footgun

Tart's FAQ: from macOS 15 on, Virtualization.framework wants the host's login keychain unlocked while a guest starts, and a locked keychain fails with a Security Server / key-generation error. Hyperion is normally logged in and unlocked. A locked screen can fail the VM start the same evening it already fails host-side Ghostty. The script should report that error as "host keychain locked," not retry in a loop.

## 2. Second login session

Fast user switching is the wrong control. It makes the other user the console user, which puts their desktop on the built-in display and attaches the keyboard and pointer. That steals the operator's screen instead of protecting it. The script must not call a session switch.

The supported off-console path is a virtual display for a different user:

- Apple Remote Desktop's control-and-observe settings distinguish "share the display" from "connect to a virtual display." In the virtual-display case you see the desktop of the account you authenticated as, and the person at the console keeps working. [Apple's Remote Desktop guide](https://support.apple.com/guide/remote-desktop/apd4f46319e/mac).
- Built-in Screen Sharing has offered a concurrent login ("Log In" rather than "Share Display") since OS X Lion. The current macOS 26 help page for turning Screen Sharing on does not restate that dialog. Phase 2 has to confirm, on 26.6, that a localhost VNC login as the sandbox user does not raise a permission dialog on the console and does not move the console cursor.

On this Mac that path is not set up: one human user, Screen Sharing off.

What it costs:

- Create `c11sandbox`, log it in once, turn on Screen Sharing for that user only, and click through Accessibility (and Screen Recording, if the screenshot helper needs it). TCC is per user and the first grant is a GUI click. The same grant exists inside a VM golden image. Cua's driver guide says the same thing: SIP does not pre-grant Accessibility or Screen Recording.
- The driver must run as that user, inside that session (`launchctl asuser` there, or VNC into that session). `cliclick` from the operator's shell posts into the operator's session. That is the bug again.
- The session is headless only from the console's point of view. It is still an Aqua session with a virtual framebuffer. A pure SSH login is not Aqua, and Ghostty will not create a surface there.
- `/tmp` is shared with the operator. Tagged sockets (`/tmp/c11-debug-<tag>.sock`) and `/tmp/c11-build.lock` live there. A VM has its own `/tmp`.
- A runaway validation can still fill the disk and peg the GPU. The kernel is the operator's kernel.
- Screen Sharing is a network service. Restrict it to the sandbox user. Prefer a localhost client (`vncdotool` is already installed) over opening a window.

Use this path if, and only if, the Ghostty probe fails in the VM. It is the option most likely to satisfy the renderer, because the GPU is the real one, and it is the option with the weakest blast-radius isolation.

## 3. In-session virtual display

`CGVirtualDisplay` (private) adds a display to the current Aqua session. It does not add a session. This session has one cursor and one key window. A drag on the extra display moves the cursor the operator is holding, and activating the validation window takes key focus. That is the 2026-09-29 collision with an extra monitor attached. The computer-use skill already says a synthesized drag owns the pointer for its whole duration.

Window-id screenshots stay the right tool for "look without touching." They do not need a virtual display. This option is out.

## Atlas

The operator's steer was a sandbox per c11 instance, probably not Atlas. Atlas is also one Apple-silicon Mac, so it has the same two-guest cap. Hyperion has the RAM and the free disk to run one 8 GB guest. The cursor that got stolen is Hyperion's, and a local VM fixes that without moving the run. Do not build in the guest, so this does not become the kind of Hyperion load the machine rules forbid.

## Proposed scripts

Four scripts, all refusing to download an image or install Tart. If `tart` is missing or the golden VM `c11-sandbox-golden` is missing, they exit with the operator setup below and do nothing else.

`scripts/sandbox-up.sh <run-id> <path-to-tagged.app>`

- Refuse if another macOS guest is already running, unless `--allow-second` is passed, and refuse always if two are already running.
- `tart clone c11-sandbox-golden c11-sb-<run-id>`
- `tart set c11-sb-<run-id> --cpu 4 --memory 8192 --display 1440x900 --random-mac --random-serial`
- `tart run --no-graphics --no-audio --dir=app:<app-dir>:ro --dir=out:<host-artifact-dir> c11-sb-<run-id>`, supervised in the background so the shell can return.
- Wait until `tart ip` answers and SSH accepts the golden image's key.
- Copy the `.app` from `/Volumes/My Shared Files/app` onto the guest disk, strip quarantine, launch with the `launch-tagged-automation.sh` environment (`C11_QA_LAUNCH=fresh`, automation socket, inherited `C11_*` removed).
- Print the run id, the guest IP, and the guest socket path. Do not print the SSH private key.

`scripts/sandbox-exec.sh <run-id> <command…>`

- SSH as the guest user, `launchctl asuser` into the Aqua session, run the command. This is how `cliclick` and menu `osascript` are supposed to be invoked. Exit status is the remote status.

`scripts/sandbox-shot.sh <run-id> <guest-window-or-display> <host-png>`

- `screencapture` in the guest Aqua session, write into the shared `out` directory, so the file lands on the host without a second copy tool.

`scripts/sandbox-down.sh <run-id>`

- Shut the guest down, then `tart delete c11-sb-<run-id>`. Refuse to delete `c11-sandbox-golden`.

The skill update, in phase 2 only, tells computer-use to prefer these scripts for any click or drag, and to keep using the host socket and `screencapture -l` only against the operator's own session when no pointer is involved. Unrestricted driving on the operator's session stays forbidden.

### Phase-2 probe, before the skill change ships

One clone, one tagged build (build slot granted separately if the app does not already exist), `C11_QA_LAUNCH=fresh`. Success is a guest screenshot that shows the tagged window, plus a `c11` CLI over SSH reporting an attached terminal surface. Failure is `ghostty_surface_new` / `error.OutOfMemory` or a window that never attaches. On failure, stop and switch the scripts to the second-user design. Do not paper over a dead renderer.

## Operator setup, once

Not done in this phase. The pull is about 25 GB.

1. Install Tart from the tap that actually resolves (`cirruslabs/cli/tart` per tart.run, or `openai/tools/tart` per the current GitHub README). Confirm `tart run --help` still has `--no-graphics`.
2. `tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest c11-sandbox-golden` while the host keychain is unlocked.
3. Boot it once with a display. Confirm auto-login, Remote Login, lock screen off, screen saver off. Install `cliclick`. Grant Accessibility to the helper that will post events. Add an SSH key and disable password login. Install the Tart guest agent if `tart exec` is how we want Aqua-session commands.
4. `tart set c11-sandbox-golden --cpu 4 --memory 8192 --display 1440x900`, shut it down, and leave it stopped. Runs clone it. Nobody boots the golden image to do validation.
5. Expect roughly 25 GB for the golden image plus a small per-run divergence (the 105 MB app and whatever the guest writes). 637 GiB is free today.

## Open risks

- Ghostty on Family 5 Metal is untested here. The probe is the gate.
- Two running guests is a hard cap. A stuck `VZError` slot after shutdown has been reported on macOS 26.5 on an M4 Max and is only cleared by rebooting the host.
- `tart run` can fail while the host login keychain is locked.
- The published base image's `admin`/`admin` password has to be removed before agents use the golden image.
- Duplicate machine identifiers if a future change runs two clones without `--random-serial`.
- Second-user fallback is unverified on 26.6: localhost VNC as another user must not prompt or steal the console. Screen Sharing would be a new network service on the operator's Mac.
- Guest macOS will drift from the host. Rebuild the golden image deliberately. Do not let a run update it.
- Lightweight macOS guests still have App Store and some Apple-ID limits. c11 dev builds do not need those. iCloud sign-in is out of scope.
