# Installing c11 on your Mac

c11 is a test build of c11, Stage 11's terminal multiplexer for running many AI agents side by side. In c11, your terminals and the agents in them keep running when you quit the app, when it crashes and when you update it. Reopen c11 and every terminal is still there, with the same programs on the same screens.

This page is all you need. You don't need an account, another computer or anything from GitHub.

## What you need

- **A Mac with Apple Silicon** (M1 or later) on macOS 14 Sonoma or later. This build doesn't run on Intel Macs.
- **An administrator account** on that Mac. The installer puts c11 in `/Applications`.
- **Apple's Command Line Tools.** The installer needs them. If you have Xcode or have used `git` in Terminal, you already have them. If not, run `xcode-select --install` in Terminal and wait for it to finish.
- **The zip**, `c11-macos.zip`, from the c11 download page: open the link the sender gave you and sign in with the email address the sender has for you. Cloudflare emails that address a one-time code to sign in. The page has the Download button and, above it, the zip's SHA-256 checksum.

c11 installs beside c11 if you have c11, and it doesn't change c11.

## Install

1. **Check the zip** against the SHA-256 on the download page. In Terminal:

   ```bash
   shasum -a 256 ~/Downloads/c11-macos.zip
   ```

   The long number it prints must match the checksum on the page. If it doesn't match, download the zip again, and if it still doesn't match, stop and email hello@stage11.ai. If Safari already unzipped it and moved the zip to the Trash, drag the zip from the Trash back to Downloads and check it there.

2. **Unzip it.** Double-click `c11-macos.zip` in Finder, unless your browser already did. You get a folder named `c11` that holds `c11.app`, `c11-install.sh` and this page.

3. **Run the installer** in Terminal, not in a c11 terminal (an update quits c11). Change the path if your zip unzipped somewhere other than Downloads:

   ```bash
   ~/Downloads/c11/c11-install.sh
   ```

   It prints a line that starts `installed /Applications/c11.app`. If you use c11, the first install copies your c11 settings into c11 once: themes, keys, sidebar and agent configs. If the installer says it needs the Command Line Tools, run `xcode-select --install`, then run the installer again. It hasn't changed anything.

4. **Open c11** from Applications, Spotlight or Launchpad. macOS asks whether to open an app downloaded from the internet. Choose **Open**. The app is signed and notarized by Apple.

On the first launch, macOS asks whether c11 may send notifications. If you have never used c11, c11 also opens a welcome workspace: a welcome terminal, a browser showing stage11.ai, a notes panel, and a fourth terminal that starts Claude Code when it is installed. That Claude session asks your permission as normal before it acts. If you don't want it, type `/exit` in it.

## Try it

1. Open a terminal in c11 and start something that keeps printing, such as `top`. You can also start an agent you use, such as Claude Code or Codex.
2. Quit c11 with Cmd-Q, and choose **Quit**.
3. Open c11 again. The same terminal comes back, and `top` is still running in it.

Each terminal's subtitle shows your Mac's network name (for example `Alexs-MacBook-Pro`), which is where that terminal runs. If a terminal shows **not kept**, it ends when you quit c11 or restart your Mac, so don't leave your only copy of work in it.

## What works differently from c11

- **Closing a panel ends everything it started**, including `nohup` and background jobs. The close button says **End Session**.
- **Quitting c11 ends only terminals marked not kept.** Every other terminal and agent keeps running, and reopening c11 brings them back.
- **Restarting your Mac ends the terminals.** After a restart, c11 starts each agent conversation it saved in a fresh terminal.
- **To end every terminal on purpose**, choose **End All Sessions…** from the c11 menu.
- **Terminals on another machine.** Settings > Herder Topography > **Add Machine…** links a second Mac with Apple silicon, or an x86-64 Linux machine with systemd, that you already reach over SSH with your keys. c11 installs what it needs there (for Linux, downloaded once from c11's release) and checks the link, and **New Terminal** then asks which machine to run on. A program running as you on the linked machine could act as one of its c11 terminals, so link only machines you trust. **Remove…** under the gear beside the machine ends c11's terminals there and unlinks it.
- **For your agents:** agents started in c11 are told to run `c11 guide`, which prints how to drive c11. To give Claude Code or Codex the same notes permanently, install the `c11` skill in Settings > Agents, under c11 skills (the row appears once that agent is installed). Nothing installs unless you ask.

## Updates

c11 doesn't update itself yet.

The download page (the link the sender gave you) always shows the newest build, with its version and the date and time it was published (Pacific time). Look there for a new build; c11 doesn't tell you about one.

When there's a new build, download it from the page, check it and unzip it the same way, and run its `c11-install.sh` from Terminal. The installer quits c11 with a clean quit, swaps in the new app and leaves your terminals running. Open c11 again and they're all still there.

The first time you update, macOS may ask whether your terminal app (Terminal, or iTerm if you use it) may control System Events. The installer uses that to find a running c11. Choose **Allow**. If you choose **Don't Allow**, the installer stops with `could not query processes for com.stage11.c11` and changes nothing; macOS won't ask again. To fix it, turn on System Events under your terminal app in System Settings > Privacy & Security > Automation, then run the installer again.

## Privacy

c11 sends no telemetry and no crash reports. Nothing leaves your Mac unless an agent you run sends it. Like any terminal, c11 trusts every program that runs under your user account on this Mac.

## Something wrong?

Quit c11 and email hello@stage11.ai: what you did, what you expected and what happened.

c11 keeps its logs in `~/Library/Logs/c11`. Attach them if you're asked to.

## Uninstall

1. In c11, choose **End All Sessions…** from the c11 menu, then quit c11.
2. Delete the app and its data. The app's helper folder is read-only on purpose, so make it writable first:

   ```bash
   pkill -f '/Applications/(c11\.app|\.c11\.app-helpers/[^/]+)/Contents/Helpers/herdr-core'
   chmod -R u+w /Applications/c11.app /Applications/.c11.app-helpers 2>/dev/null
   rm -rf /Applications/c11.app /Applications/.c11.app-helpers \
     "$HOME/Library/Application Support/c11" "$HOME/Library/Application Support/com.stage11.c11" \
     "$HOME/Library/Logs/c11" "$HOME/.local/share/c11" \
     "$HOME/.config/c11" "$HOME/.c11" "$HOME/.c11-snapshots"
   find "$HOME/.local/state/herdr-core" -maxdepth 1 -name 'c11*' -exec rm -rf {} + 2>/dev/null
   defaults delete com.stage11.c11 2>/dev/null
   security delete-generic-password -s com.stage11.c11.socket-control >/dev/null 2>&1
   ```

   If you installed the `c11` skill, also remove it from your agents' skills folders, for example `~/.claude/skills/c11`.

c11, if you have it, is not affected.
