# herdr-app read, for c11v on herdr-core

Needs you: nothing.

Written 2026-10-30 03:30 PDT. Read-only pass over herdr-app 3e32d75 (0.1.9) and herdr-core dbcdcff (0.1.14). Times are Pacific.

Path key. Bare paths are `herdr-app/src/`. `core/x.rs` is `herdr-core/crates/herdr-core/src/x.rs`. `core-vt/lib.rs` is `herdr-core/crates/ghostty-vt/src/lib.rs`. `docs/`, `defaults/`, `scripts/`, `distribution/`, `README.md`, `CHANGELOG.md` are the herdr-app root. `schema/` is `herdr-core/schema/`.
VERIFIED means I read that code end to end. INFERRED means deduced from code I read plus a grep, not run.

## Summary

Copy

1. Client plumbing: a reader thread and a writer thread around one connection, credit returned per DATA frame only after the VT consumed it, a fresh VT on every attach, an events snapshot plus `seq` deltas, and a `hello` gate on generation, minimum core version and required methods before the window opens (`hc.rs:30-143, 154-212, 271-330`; `terminal.rs:181-211, 299-300`; `main.rs:124-137`).
2. Viewer duties: route the VT's write-backs to the channel (kitty graphics acks), send the mode-2048 in-band resize report as the first input after each RESIZE, and encode keys with Ghostty from the viewer VT's own modes, pinned by a table test (`terminal.rs:1287-1296, 1527-1578`; `core/relay.rs:1-6, 33-51`).
3. Placement by labels: a terminal opts into the UI with `herdr.space` and `herdr.tab`; every listing re-reads the live record, sets `keep`, then adopts it; unlabelled workers stay hidden; park clears the labels (`window.rs:1948-2048, 2384-2422, 4356-4362`).
4. State split: one CAS document per machine core for structure (newest accepted write wins, toast on conflict) and a private `view.json` per screen for focus, zoom and seen-attention. Labels rebuild a lost layout (`mirror.rs:9-59`; `mirror_sync.rs:76-102`; `window.rs:1786-1788`).

Avoid

5. Bundling `hc` in a signed c11.app without a plan for `hc update`, which swaps the running binary in place (`core/cli/update.rs:50-74`). herdr-app bundles nothing: it finds `hc` on PATH or runs the core installer into `~/.local/bin` after a consent screen (`core_bin.rs:1-8, 164-192`; `setup.rs:136-159`).
6. The app's loose ends: FACTS only at attach, no cell size, no refresh on theme change; FOCUS follows the pane handle, not OS window activation, and is not re-sent after reattach; core `size` events ignored; hidden panes and peeks attach as typing viewers, never `observe`; `USES` omits four methods the app calls (`terminal.rs:115-119, 1175-1181`; `hc.rs:157, 392-396`; `window.rs:1364-1367`).
7. Reading the pace as stability: 113 app commits since 10-23 (42 on 10-29), 6 releases, 101 of 114 commits by one author. App and core build libghostty-vt from different Ghostty commits (291fd05 vs 1e5cdb8). Pin the core and test against `schema/released.openrpc.json`.

Not in the sketch (`docs/c11v-herdr-core.md`)

8. The viewer is part of the protocol: it owns replies and in-band resize, is the source of the colors and cell size the core answers OSC 10/11, DSR 996 and `CSI 16 t` with (herdr-app sends colors only), and the last active viewer sets the size (`core/viewers.rs:254-274`). Two clients on one session, or a panel plus a peek, fight over size. Every viewer byte, replies included, counts as a person typing (`core/input.rs:42-52`). Kitty images are not in a repaint (`window.rs:1348-1349`).
9. hc documents are a poor home for live metadata (sketch decision 3): no list call, 1 MiB each, change events carry no value, and every `doc.set` rewrites and fsyncs all documents while holding the lock that typing also takes (`core/api/doc.rs:9-37`; `core/paths.rs:70-75`; `core/viewers.rs:199`). herdr-app writes its one document only on structural change.
10. The update and recovery choreography: a minimum-core file bumped per app release, generation equality, `hc update` after every app update, package-managed cores refused, a setup screen per mismatch (`hc.rs:189-212`; `update.rs:566-593`; `setup.rs:143-157`). A crashed core rebuilds each screen from a ~1 MB holder tail, marks it inexact, and wiggles the size so TUIs repaint (`core/runtime.rs:396-461`; `core/holder.rs:2-4`).

## Corrections to the brief

- `place.rs` is window geometry only (`window.json`: size, display, maximized). It places no terminals (`place.rs:1-4, 56-74`). Terminals made from the CLI are placed by label adoption in `window.rs` (answer 4.6).
- `layout_sync.rs` is layout-file "clicks" kept in `layouts/.state/`, not cross-screen sync (`layout_sync.rs:1`). Cross-screen sync is `mirror.rs` plus `mirror_sync.rs`.
- `macos.rs` is the menu bar and Quit/Hide/Settings actions (`macos.rs:1-33`). The macOS facts are in `core_bin.rs`, `update.rs`, `scripts/mac-sign` and the installers.
- hc has a FACTS frame (kind 5, `core/wire.rs:21`; `schema/README.md:57`). herdr-app never sends it. Its frame constants stop at FOCUS (`hc.rs:14-19`).
- `vendor/ghostty` is an empty directory in this checkout (submodule not initialised), so I could read the pin but not Ghostty's source or its date.

## 1. The render path

### 1.1 A second parser beside the holder's

- VERIFIED. Yes. "libghostty-vt fed with the relayed bytes" (`vt.rs:1-2`). One `Vt` per terminal view (`terminal.rs:45-47, 71-99`).
- VERIFIED. The core keeps its own libghostty-vt screen per terminal and relays bytes to viewers (`core/viewers.rs:86-117`; `core/relay.rs:1-6`).
- VERIFIED. Every tab's terminals stay attached, drawn or not. Tab switches are instant and kitty images survive, which "a repaint can't bring back" (`window.rs:1348-1358`). Output for an unseen pane is parsed but triggers no redraw (`terminal.rs:328-333`).
- VERIFIED. The parse runs on the UI thread. The reader thread only `try_send`s into an unbounded `async_channel` (`hc.rs:313, 383, 398`; `terminal.rs:195-209`).

### 1.2 Ghostty commit and API

- VERIFIED. `vendor/ghostty` is a submodule of `https://github.com/ghostty-org/ghostty` (`.gitmodules:1-3`), pinned at `291fd050b9e9c293c8adb6a140742649b7e42d3a` (`git ls-tree HEAD vendor/ghostty`; `licenses/inventory.json:49`). Untouched since the initial commit b975f5b (2026-10-23 08:48).
- VERIFIED. The core pins a different commit, `1e5cdb865807abc990181efb8ebfa9122955cce2` (herdr-core gitlink; `distribution/notices/README.md:7`). The two VTs share no binary state. They share only the VT byte stream.
- VERIFIED. API: upstream's headless `libghostty-vt` C API (`include/ghostty/vt.h`), built with `zig build -Demit-lib-vt -Doptimize=ReleaseFast -Dtarget=<triple>` and bound by bindgen over `ghostty_*`, `Ghostty*`, `GHOSTTY_*` (`crates/ghostty-sys/build.rs:35-46, 83-93`). It is not the `ghostty_surface_*` app API and there is no custom Zig shim.
- VERIFIED. Families used: `ghostty_terminal_*` (new, set, get, vt_write, resize, grid_ref, scroll_viewport, selection format), `ghostty_render_state_*` with row iterator and row cells, `ghostty_key_encoder_*` and `key_event_*`, `ghostty_mouse_encoder_*` and `mouse_event_*`, `ghostty_selection_gesture_*`, `ghostty_kitty_graphics_*`, `ghostty_grid_ref_*`, and `ghostty_sys_set` for a PNG decoder hook (`vt.rs:223-229, 323-404`).
- VERIFIED. Callbacks installed: userdata, render-hold, title-changed, write-pty, clipboard-write plus its byte cap (`vt.rs:342-358`). No bell, clipboard-read, size or device-attribute hooks. The core answers those.

### 1.3 First paint

- VERIFIED. Every (re)attach builds a new `Vt` and resizes it: "The core repaints the whole screen (and history) on attach" (`terminal.rs:181-191`). Attach asks `history: 2000` and passes `display` (`hc.rs:392-396`).
- VERIFIED. The core's paint opens with a soft reset `CSI ! p`, an explicit "off" for 2026, 9, 1000-1006, 1015, 1016, 1004, 2004, DECCKM, 66, 2031, 2048, kitty `CSI = 0;1 u` and the alternate-screen modes, then home and clear (`core-vt/lib.rs:660-663`). The same bytes therefore work as a repaint into a dirty VT (test `core-vt/lib.rs:751`).
- VERIFIED. History (main screen only) is emitted as VT text, pushed up into the viewer's scrollback with newlines, then the screen is cleared (`core-vt/lib.rs:664-673`). Then `CSI ?1049h` if on the alternate screen (674-676). Then the active screen with cursor, style, hyperlink, charsets, kitty keyboard flags, modes, scroll region, tab stops and pwd, with `2026h`, `47h`, `1047h`, `1049h` stripped because sync output "would freeze a new one" (605-632, 677-683). Then the title as OSC 2 (684-687).
- VERIFIED. After the paint the core appends `CSI ?9001h/l` and every stored OSC 7501 report (`core/viewers.rs:281-290`).
- VERIFIED. The app does nothing special with it. It feeds DATA as it comes (`terminal.rs:286-304`).

### 1.4 RESIZE ordering

- VERIFIED. In the canvas prepaint, when the computed grid differs from the VT's: (1) `vt.resize(cols, rows, cell_w, cell_h)`, (2) `core.resize` sends the RESIZE frame, (3) `vt.take_replies()` goes out as input. Step 3 is the mode-2048 in-band report: "Mode 2048 programs wait for this report, not SIGWINCH" (`terminal.rs:1280-1296`).
- VERIFIED. No debounce, timer or barrier. Each layout change that alters cols or rows resizes at once. Cell size is the font's own advance (`terminal.rs:842-854`).
- VERIFIED. The fix for "nvim and other full-screen programs redraw right after you resize their pane" (CHANGELOG 0.1.5) is commit 074142c, which added step 3 (test `vt.rs:1155-1167`). It pairs with core 7c08833: the core drops its own `CSI 48;…t` replies because "In-band resize belongs to the viewer, which knows the pixel geometry" (`core/relay.rs:33-51`; test 180-189).
- VERIFIED. The core resizes its own screen first, then sends RESIZE to the holder (PTY) (`core/viewers.rs:262-271`). The core handles one connection's frames in order, RESIZE then DATA, so the PTY is resized before the report arrives (`core/server.rs:334-342`).
- INFERRED. The residual race is unguarded. Bytes the program wrote before it saw the resize can arrive after the app already resized its VT and land on the new grid until the program's redraw arrives. No marker is injected into the stream.
- VERIFIED. A resize that happens while the attach RPC is in flight is replayed right after the reply (`terminal.rs:225-230`). Hidden terminals attach at the record's current size so attaching does not resize the program (`terminal.rs:122-123`; `window.rs:1364-1367`).

### 1.5 FOCUS

- VERIFIED. `render()` sends a FOCUS frame whenever the pane's focus handle flips (`terminal.rs:1175-1181`; `hc.rs:423-425`). The core turns it into `CSI I`/`CSI O` when DEC 1004 is on, and a focus-gain makes that viewer "active" (`core/viewers.rs:219-232`).
- VERIFIED. GPUI's `is_focused` is `window.focus == Some(id)` and OS window activation does not clear it (`vendor/gpui-pre/src/window.rs:507-509, 1947`). So FOCUS follows pane focus, not window activation.
- INFERRED. `was_focused` is not reset by `connect()`, so a reattached focused pane does not re-send FOCUS(1) until the next flip (`terminal.rs:152, 181-211`).

### 1.6 FACTS and why

- VERIFIED. At attach only: `{"fg","bg","cursor"}` as `#rrggbb` from the active theme (`terminal.rs:115-119, 193-196`). No cell size. No FACTS frame is ever sent, so a theme change does not reach the core (`hc.rs:14-19`).
- VERIFIED. The core accepts `cell` too (`core/viewers.rs:15-26`). Its screen answers from these facts: OSC 10/11, DSR 996 light/dark from background luminance, `CSI 16 t` and `CSI 18 t`, with a default cell of 10x20 (`core-vt/lib.rs:259, 337-352, 530-545`; test 891-910).
- VERIFIED. The leader viewer's facts are the ones applied (`core/viewers.rs:254-260`). So with the app's facts, `CSI 16 t` answers 10x20 pixels unless another viewer reported its cell.

### 1.7 Terminal queries

- VERIFIED. The app's VT does answer. `on_write_pty` appends to `Shared.replies` (`vt.rs:140-145`). `ingest` drains them to the channel after every DATA frame (`terminal.rs:301-303`) and after a resize (1293-1294).
- VERIFIED. The app does not know whether a query was stripped. It relies on the contract. The core's relay holds each CSI/OSC/DCS candidate, writes it to its screen, and removes it from the viewer stream only if the screen produced a reply (`core/relay.rs:55-97`; test 160-178). A reply-less query, such as XTGETTCAP, passes through.
- VERIFIED. Kitty graphics (APC) are the deliberate exception. The core's screen takes the bytes for cursor motion and drops its reply: "a viewer that can answers" (`core/relay.rs:1-6, 79-88`; test 191-210). The app's VT then produces `i=7 … OK` (`vt.rs:1317-1330`).
- VERIFIED. OSC 52 read gets no reply (`vt.rs:356, 1380-1384`).
- INFERRED. Exactly-once answering holds only while the two Ghostty builds agree on what is answerable.

### 1.8 Kitty keyboard flags

- VERIFIED. Tracked by the app's VT from the stream. `kitty_keyboard_flags()` (`vt.rs:755-759`) feeds the win32 precedence rule (`terminal.rs:736`). The encoder reads modes with `ghostty_key_encoder_setopt_from_terminal` (`vt.rs:996`). The first paint replays the flags (`core-vt/lib.rs:605-632`).

### 1.9 Mouse

- VERIFIED. `mouse_tracking()` comes from the VT. Shift keeps the mouse for the app (selection, menu) (`terminal.rs:520-551`). Encoding uses `ghostty_mouse_encoder_setopt_from_terminal` and remaps fractional cell widths so columns do not drift at zoom (`vt.rs:1027-1074`).
- VERIFIED. Wheel: tracking on sends buttons 4/5; alternate screen sends arrow keys; otherwise the local viewport scrolls (`terminal.rs:481-518`). Right-click opens the app menu unless the terminal carries label `herdr.right-click=program` (`window.rs:1828`; `terminal.rs:1240-1247`).

### 1.10 IME and preedit

- VERIFIED. `EntityInputHandler` (`terminal.rs:1116-1169`). Preedit text is held in `Grid.marked` and drawn underlined at the cursor cell (1095-1112). The candidate window anchors on `cursor_at` (1160-1164). Finished text goes to the program raw (1142-1146).

### 1.11 Bell

- VERIFIED. None. No bell callback is installed (`vt.rs:342-358`) and nothing in `src/` handles BEL. The only sounds are agent alerts (`sound.rs:1-49`).

### 1.12 OSC 52

- VERIFIED. Write works. `on_clipboard_write` accepts `text/plain` only, at most 1 MiB, to the clipboard (`c`) or, on Linux only, the primary selection (`p`), last write per batch wins (`vt.rs:147-194`). Gated by setting `clipboard_write`, default true (`settings.rs:448`), applied per DATA frame (`terminal.rs:287-298`).
- VERIFIED. Read never works: "No read callback: programs can never read the local clipboard" (`vt.rs:356`; test 1380-1384).

### 1.13 OSC 7 and title

- INFERRED. OSC 7 is unused. The app never reads the VT's pwd. Folders come from the core's `foreground.cwd` (read about twice a second), else `process_cwd::read(pid)` for local shells, else the record's `cwd` (`window.rs:2051-2064`; `process_cwd.rs:8-29`).
- VERIFIED. Title uses the title-changed callback (`vt.rs:308-311, 742-753`), plus the record's title at attach (`terminal.rs:232-234`). Agent spinner glyphs are stripped before display (`terminal.rs:598-610`).

### 1.14 Kitty graphics and sixel

- VERIFIED. Kitty graphics work. 128 MiB image storage per terminal (`vt.rs:357-358`). PNG decoded by the `png` crate through libghostty's hook (`vt.rs:196-229`). Placements read from the VT and drawn with z-order (`vt.rs:439-482`; `terminal.rs:969-985`).
- VERIFIED. Images are not part of the core's paint. A repaint or reattach loses them (`window.rs:1348-1349`; `core/relay.rs:1-6`).
- INFERRED. Sixel is unsupported: no mention in either repo outside vendor.

### 1.15 `CSI ?9001`

- VERIFIED. Ghostty does not track mode 9001, so `Win32Input::watch` scans the byte stream, including a request split across two writes (`win32_keys.rs:1-39`; `vt.rs:258-259, 721`). The core tracks it per terminal and replays it in every first paint (`core/relay.rs:76-78, 134-143`; `core/viewers.rs:281-284`). The app uses it only for modified Enter when no kitty flags are set (`terminal.rs:736-738`).

### 1.16 Synchronized output (2026)

- VERIFIED. The render-hold callback snapshots the finished frame when the program starts a sync update, and `frame()` stops updating render state while held. After `MAX_HOLD` of 1 s the app clears mode 2026 in its VT (`vt.rs:297-306, 313-315, 844-856`). `shows_change()` stays true while held so the cap can fire (806-809).

### 1.17 Credit and flow control

- VERIFIED. Core: each stream starts with 256 KiB of credit. The viewer returns credit for bytes consumed. More than 4 MiB behind gets a fresh repaint instead of the backlog (`schema/README.md:73-76`; `core/wire.rs:24-26`; `core/viewers.rs:111-130`).
- VERIFIED. App: `credit(ch, bytes.len())` per DATA frame right after `vt.write` (`terminal.rs:299-300`). The events channel gets 1 MiB once at subscribe, then per batch (`hc.rs:388`; `window.rs:641`).
- VERIFIED. On a repaint after falling behind the app does nothing special. It is ordinary DATA (`terminal.rs:286-304`). The repaint carries no history (`core/viewers.rs:126`), so older scrollback in the app's VT stays.

### 1.18 Reattach after lost, restarted, core restart

- VERIFIED. Connection lost (the `hc connect` child's stdout closes): the reader marks every stream `Lost` and fails pending calls (`hc.rs:321-329`). Views show "[reconnecting to core…]" (`terminal.rs:311-316, 1191`).
- VERIFIED. A loop retries `Core::connect()` every second, bumps `core_generation`, resets document slots and calls `reattach` on every view (`window.rs:669-687, 765-783`). Each reattach builds a new `Vt` and attaches again with `history: 2000`.
- VERIFIED. The core closes a stream with a reason when the program ends or is lost. `exited`, `killed` and `finished` remove the pane. Anything else waits for the `restarted` event and the record's new `pid`, then `reattach_if_needed` (`terminal.rs:163-176, 306-310`; `window.rs:1890-1893, 2112-2142`).
- VERIFIED. Attach errors: `unavailable`, "lost the core" or "no reply" mean retry later. `finished` closes the pane. Other errors show the text in the corner (`terminal.rs:237-256`).

## 2. Input

- VERIFIED. Keys are encoded by Ghostty's key encoder from the viewer VT's current modes, never raw. `key_bytes` maps the GPUI key to `GhosttyKey`, mods, consumed mods, UTF-8 text and unshifted codepoint (`terminal.rs:725-773`; `vt.rs:994-1023`). Unmapped keys fall back to the typed text bytes (`terminal.rs:739-741`).
- VERIFIED. Consumed-modifier handling exists because without it "the kitty keyboard protocol reports shift+; and Neovim never sees ':'" (`vt.rs:990-993`). macOS Option-as-Alt is passed to the encoder (`vt.rs:997-1001`; `terminal.rs:759-771`).
- VERIFIED. A table test pins "what Ghostty sends" per key in plain, kitty `>1u` and `>9u` modes (`terminal.rs:1527-1578`).
- VERIFIED. Paste is bracketed when mode 2004 is on, with `ESC[201~` stripped; otherwise LF becomes CR (`vt.rs:795-802`). IME text goes raw (`terminal.rs:1142-1146`). Files dropped become quoted paths, copied to the remote first for remote terminals (`terminal.rs:379-421`).
- VERIFIED. Path: UI thread encodes, hands bytes to an `mpsc` channel, the `hc-writer` thread writes the frame to the stdin of `hc connect`, which pumps it to the core socket (`hc.rs:216-218, 271-278, 339-341`; `core/cli.rs:808-826`). The core takes its global lock, passes the bytes through the human/agent gate, and sends them to the holder and PTY (`core/viewers.rs:198-206`).
- VERIFIED. Latency measures: a dedicated writer thread so a stalled core never blocks the UI (`hc.rs:216-218`); output within 200 ms of typing draws at once, otherwise on a shared 33 ms clock (`terminal.rs:337-361`); typing scrolls to the bottom (`terminal.rs:374`); input is not batched, one frame per key event (`terminal.rs:368-377`); redraw is skipped when output changed nothing visible (`vt.rs:806-817`); only changed rows are rebuilt (`vt.rs:863-904`).
- VERIFIED. No keystroke-latency test. `bench.rs` and `scripts/bench.py` count draws, not echo time (`bench.rs:1-2`; `README.md:129-137`).
- VERIFIED (core side). Input from any viewer is "human". The gate holds a person's keys while an agent's input goes in, and an agent's send waits for 3 s of quiet (`core/input.rs:1-52, 64-67`). Viewer auto-replies count as a person typing.
- INFERRED. The extra `hc connect` process is one more hop than a direct socket. The sketch's direct-socket plan avoids it.

## 3. Core management

### 3.1 Finding, installing, updating, stopping

- VERIFIED. Not bundled: "The app doesn't carry one: it uses the core people installed, or installs the core's own release" (`core_bin.rs:1-2`).
- VERIFIED. Lookup order: `core` in settings.json; PATH; the login shell's PATH (3 s limit); then `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, mise shims, nix profile, cargo (`core_bin.rs:83-98, 116-132, 134-162`). A candidate counts only if `--version` starts with `hc ` (76-81). Dock launches merge in the login-shell PATH (52-64; `main.rs:105-106`).
- VERIFIED. Install: the setup window shows "Install it for me" and the exact command. It runs `curl -fsSL https://releases.herdr.dev/core/install.sh | sh` into `~/.local/bin` (`core_bin.rs:164-192`; `setup.rs:20-27, 136-142`). "I have it somewhere…" saves a path in settings.json (`setup.rs:113-133`). The app's own installer also installs the core when none exists (`distribution/install.sh:135-138`).
- VERIFIED. Start: the app never starts the core itself. `hc connect` autostarts it (`core/cli.rs:808-810`; `core/client.rs:81-95, 167-186`). The core is a `setsid`-detached `herdr-core serve` with stderr to `core.log` (`core/platform/unix.rs:120-136`). On Linux with systemd it becomes a user service (`core/client.rs:181-184`). There is no LaunchAgent, login item or SMAppService in either repo (grep).
- VERIFIED. Session: the default one. The app never sets `HC_SESSION` or passes `--session`; only `scripts/bench.py:86` and `scripts/bench_compare.py:73` do. It shares the core with the user's own `hc` and every other client. Spaces live in that core's document, not in the app home (`docs/security.md:22-24`).
- VERIFIED. Quit: the core and terminals stay up. Nothing stops the core. Dropping `Core` kills only the `hc connect` child (`hc.rs:433-440`). On macOS the red button hides the app so alerts keep ringing (`window.rs:526-533`). Cmd+Q runs `on_app_quit`: flush layout documents (10 s local, 2 s remote), save `window.json`, apply a staged update (`main.rs:161-178`; `window.rs:1695-1732`; `README.md:53-55`).

### 3.2 Version mismatch

- VERIFIED. Three checks on the `hello` reply: generation equals 1; version is at least `distribution/core-version` (0.1.11 today, core is 0.1.14); every method in `USES` is present (`hc.rs:154-212`). A failure opens a setup window instead of the main one. "Update herdr-core" runs `hc update --json`, terminals kept. A newer generation says "Update Herdr" and offers Quit (`setup.rs:143-157, 188-196`; `core_bin.rs:194-217`).
- VERIFIED. Releases name their floor: "release 0.1.4, needs core 0.1.10" (baa6471), "0.1.5 release notes, needs core 0.1.11" (df71fd9).
- VERIFIED. `USES` lists `terminal.list`, which the app never calls, and omits `terminal.get`, `terminal.read`, `server.status` and `machine.list`, which it does (`window.rs:647, 758, 1983, 2152-2154, 2326`). A core missing those would pass the gate.
- VERIFIED. After an app update, the next start runs `hc update --version <latest of this generation, else the minimum>` (`update.rs:221-229, 566-593`). The hourly core check skips a core a package manager owns (195-208). `hc update` refuses paths under `/Cellar/`, `/nix/store/`, `/mise/installs/` (`core/cli/update.rs:57-65`; `core/client.rs:30-35`).
- VERIFIED. `hc update` swaps its own running binary in place, then restarts the core with terminals kept. Its doc comment: "One swap path, for people and for apps that bundle hc" (`core/cli/update.rs:50-74`).

### 3.3 App updates

- VERIFIED. 10 s after start, then hourly (30 min retry): fetch `releases.herdr.dev/app/latest.json`, download with curl, check SHA-256, unpack to `Herdr.app.new.noindex`, swap at quit or restart or after a crash, write `.updated` (`update.rs:23-25, 155-192, 260-316, 469-488, 556-559`). Only release builds update (119-126). `docs/security.md:30-43` says the checksum is not an independent signature.
- VERIFIED. macOS: a Developer ID bundle gets `codesign --verify --deep --strict` and is otherwise untouched. An ad-hoc or unsigned dev build gets `LSEnvironment:PATH` added and an ad-hoc re-sign (`update.rs:318-342`; `distribution/install.sh:107-131`).

### 3.4 macOS specifics

- VERIFIED. `macos.rs` is menus only (`macos.rs:1-33`).
- VERIFIED. Bundle at `~/Applications/Herdr.app`. `~/.local/bin/herdr-app` links to its binary. `lsregister -f` runs (`distribution/install.sh:125-131`). From a DMG the app makes that link itself, only for an installed bundle (not /Volumes, AppTranslocation, target/), and never over a foreign file (`core_bin.rs:20-30`; `core_bin/cli_link.rs:6-39`).
- VERIFIED. Developer ID signing with the hardened runtime and one entitlement, `com.apple.security.cs.allow-jit`, for the QuickJS mod runtime; a notarized DMG per commit 1988a87 (`scripts/mac-sign`; `scripts/macos-entitlements.plist`). `docs/security.md:39-43` hedges: signing depends on configured credentials and notarization is not required to publish.
- VERIFIED. CHANGELOG: "macOS stops forgetting the permissions you gave Herdr" (0.1.9) and "keeps the permissions you gave it across updates" (0.1.5). The fixes keep the Developer ID signature through updates and installs (f268ccc, 9c3b43a).
- INFERRED. Those are TCC grants to the app bundle. The repo does nothing else about TCC.
- INFERRED. Core and holders are plain `setsid` children of whichever `hc` ran first, so who macOS holds responsible for them depends on that first caller. Neither repo addresses it. This bears on sketch decision 4.
- VERIFIED. `process_cwd.rs` reads a shell's folder with `proc_pidinfo` (`process_cwd.rs:8-29`).

### 3.5 Writes outside the app's own state

- VERIFIED. `~/.local/bin/herdr-core` and the `hc` symlink, through the core installer, on the person's click or from the app installer (`herdr-core/distribution/install.sh:81`; `distribution/install.sh:135-138`). Both installers print "Add $bin to your PATH" and edit no rc file (`herdr-core/distribution/install.sh:84-87`; `distribution/install.sh:143`).
- VERIFIED. `~/.local/bin/herdr-app` symlink; `~/Applications/Herdr.app` and its `.new.noindex` and `.old.noindex` neighbours.
- VERIFIED. Temp files: `herdr-paste-<ns>.png` (`terminal.rs:626-644`), `herdr-app-<pid>-done.mp3` (`sound.rs:63-71`).
- VERIFIED. `~/.config/herdr-app`: shipped mods, layouts, icons, `AGENTS.md` and `.d.ts` files are rewritten on every start (`AGENTS.md:34-42`).
- VERIFIED. Nothing under `~/.claude`, `~/.codex` or shell rc files: grep finds no write there in either repo. Terminals get `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=herdr` (`hc.rs:370`).
- VERIFIED. The app serves `$HERDR_APP_HOME/herdr-app.sock` for `herdr-app do/ls/status/shot`. A second launch raises the first window (`control.rs:15-37, 56-70`). Whoever can reach that home controls the window (`docs/security.md:26-28`).

## 4. Layout and state model

### 4.1 Where it is stored

- VERIFIED. One document per machine core, named `herdr-app`. Read with `doc.get {name, on}`, written with `doc.set {name, on, version, value}` (`mirror_sync.rs:76, 94`). Local: `on` omitted. Other machines: `on: "<machine>"` through the local core's federation. The screen keeps one `Slot` per machine, the empty key being this core (`window.rs:414-415`; `mirror_sync.rs:9-49`).
- VERIFIED. Schema: `{ spaces: [ { id, name, folder, tabs: [ { id, name, root: Node } ] } ] }`. `Node` is the layout-file tree type. `type` is `row`, `column`, `stack` or `block`. A pane is a `block` with `content: {terminal: "t7"}` or `{mod, props}`. `size` is `{weight}` or `{px}` (`mirror.rs:9-36`; `layout.rs:9-31, 272-291, 315-381`). Ids in the document are machine-local; the screen qualifies them as `machine/id` (`mirror.rs:61-87`).
- VERIFIED. Ids are a prefix plus 32 hex digits: `sp` space, `tb` tab, `p` pane, `s` split (`model.rs:157-165, 278`; `window.rs:2247`).
- VERIFIED. Core side: documents persist atomically in `docs.json`, survive restart and handover, 1 MiB each (`schema/README.md:149-164`; `core/api/doc.rs:11-13`).
- VERIFIED. Each terminal carries labels `herdr.space` and `herdr.tab` (the ids), set at `terminal.run` with `keep: true` (`window.rs:2194-2209`; `hc.rs:369-376`). The app also writes a human `where` label, `<space> / <tab>`, so `hc ls` shows it (`window.rs:1603-1655`).

### 4.2 Two screens, one core

- VERIFIED. "Connected screens share that structure and the live terminals, but keep their own focus and zoom" (`README.md:63-64`). Shared: `Document`. Private, in `~/.config/herdr-app/view.json`: active space, each space's active tab, each tab's focus history, zoom and settled flag, recent spaces, per-terminal seen-attention (`mirror.rs:38-59`; `window.rs:1049-1058`; `defaults/AGENTS.md:82`).
- VERIFIED. Sync: the app subscribes to events. A `doc` event (it carries no value), a `missed`, a reconnect or a machine reconnect marks each slot dirty and re-reads it (`hc.rs:80-93`; `window.rs:628-664`; `schema/README.md:165-182`). It writes `Document::capture(model)` only if it differs from the last read, never mid-drag, one request per machine (`window.rs:1657-1687`; `mirror_sync.rs:1`).
- VERIFIED. Conflict: a stale `doc.set` fails `conflict`; the app re-reads and replaces its model with the other screen's document, with the toast "Layout changed elsewhere. The other screen's layout is shown." Newest accepted wins; no merge (`mirror_sync.rs:99-102`; `window.rs:1786-1788`; `defaults/AGENTS.md:93-96`).
- VERIFIED. A machine that disconnects loses its spaces from the list. Its saved view is kept for its return (`window.rs:1790-1815`; `mirror.rs:189-194`).

### 4.3 Persistence and restore

- VERIFIED. App restart: load `view.json` as `initial_view`, read each machine's document, then `apply_machine` restores that machine's view when its first document arrives (`window.rs:500, 1780-1784`; `mirror.rs:155-187`). Quit drains pending terminal changes and layout writes, bounded (`window.rs:1695-1732`).
- VERIFIED. Core restart or crash: documents are on disk in the core. Streams close, the app reconnects, re-subscribes, re-reads documents and reattaches every pane (`window.rs:586-687, 765-783`). Kept terminals that were lost get a fresh shell in their last folder under the same address, "not their old programs" (`README.md:55`; `schema/README.md:118-133`).
- VERIFIED. If the document is lost the screen starts empty ("No space open", `window.rs:3765-3775`), but live labelled terminals are re-adopted. Spaces and tabs return under their label ids, unnamed and without splits (`window.rs:2008-2048`).

### 4.4 Pane to terminal, and when the terminal ends

- VERIFIED. A pane is a leaf `block` whose content names an address, `t7` or `vps/t7` (`layout.rs:13-14, 461-466`; `model.rs:530-532`). The pane id is separate from the terminal address (`SKILL.md:7`).
- VERIFIED. The terminal finishes or is killed from the CLI: the stream closes with `exited`, `killed` or `finished` and the pane goes at once. A tab or space goes with its last pane (`window.rs:2112-2142`; `model.rs:323-342`). If the app was closed meanwhile, the next listing asks `terminal.get` and removes panes whose reason is `exited` or `killed`, or that are `not_found`. Other reasons, such as `holder_lost`, keep the pane: "Core owns restarting it" (`window.rs:2320-2345`).
- VERIFIED. Closing a pane, tab or space kills its terminals and their un-kept sub-agent tree. Sub-agents with a `herdr.space` label are spared (`window.rs:2464-2485, 2751-2763`).

### 4.5 Peek

- VERIFIED. `terminal.peek` opens a dialog overlay, 80% by 80%, holding a `peek` mod bar and a terminal block for the address (`window.rs:3302-3316`; `defaults/mods/peek/main.js:1-5`). It is a second `TerminalView`: a second attach channel and a second VT for the same terminal.
- VERIFIED. The bar offers go-to-pane, or "keep as tab" when the terminal has no pane, and close. Keep sets labels and `keep` (`window.rs:2356-2422`). Ctrl-click, Cmd-click on macOS, on a live address in terminal text peeks (`terminal.rs:558-579, 1220-1231`). `terminal.show` swaps what a pane displays without changing its saved terminal (`window.rs:2866-2890`).
- INFERRED. The peek attaches at the record's size, then its prepaint resizes to the dialog's grid and sends RESIZE. As the newest active viewer it can resize a PTY whose own pane still shows the old grid, until that pane is touched. Core `size` events are ignored (`hc.rs:137`; the only consumer of cols and rows is `window.rs:1364-1367`).

### 4.6 Terminals made by agents or the CLI (what `place.rs` was guessed to do)

- VERIFIED. The contract: `hc run --keep --label herdr.space=<id> --label herdr.tab=<id> -- claude`. Without `herdr.tab` the app makes a tab. An unknown id becomes a new unnamed space or tab. "Unlabeled workers stay hidden" (`defaults/AGENTS.md:130-146`; `SKILL.md:63-66`).
- VERIFIED. Mechanism: every listing runs `reconcile()`. It finds live terminals with a `herdr.space` label, no pane, no change in flight, and an available document for their machine (`window.rs:1959-1968`). `start_adoption` re-reads the record, checks `adoptable` (state live, labels still equal), sets `keep` if needed, then `adopt` splits beside the tab's last pane without moving focus, or adds a tab without selecting it, or creates the space (`window.rs:1976-2048, 4356-4362`).
- VERIFIED. Why the re-check: "labels outlive the program: putting it back would show a dead pane" (`window.rs:4353-4355`). A 5 s `just_born` window stops a fresh pane being read as closed (`window.rs:2347-2352`).
- VERIFIED. Sub-agents, children by `parent`, get no pane unless labelled. They belong to the parent's tab without a pane and appear in the agents list. A parent's rollup takes its most urgent child (`defaults/AGENTS.md:149-153`; `defaults/mods/agents/main.js:43-47`).

## 5. Agent status

- VERIFIED. Status is the program's own OSC 7501 word and nothing else. The core "never infers status from the screen" and has "no screen detection, no agent registry" (`schema/README.md:184-189`; `herdr-core/AGENTS.md:34-36`). The app has no heuristics either. Its status comes from the record (`window.rs:1835-1860`) fed by `status` events (`hc.rs:132`).
- VERIFIED. Mapping: `working` is working; `blocked` and `error` are blocked; anything else is done if unseen, else idle (`model.rs:496-505`). "Done" is the app's own idea, a finish you did not watch. It is held per terminal in `seen` and persisted in `view.json` (`model.rs:437-456, 482-494`; `mirror.rs:47-59`). `seen` is set for what is visible while the window is active (`window.rs:1443-1446`).
- VERIFIED. Rollup priority is blocked, done, working, idle (`model.rs:86-95, 523-525`). A space's and tab's status is the most urgent of its terminals (`model.rs:567-603`).
- VERIFIED. Brand detection is cosmetic. `programs.rs` maps the 7501 `app` (with aliases such as `claude-code`), else the foreground argv, to a name, icon and tile from `defaults/programs.json` (`programs.rs:170-195, 261-310`). The `agent` flag is true only when the program reported an `app` (262-266). The one logic use is `busy()`, which decides when to re-run `git` for the branch (`window.rs:4187-4198`).
- VERIFIED. An agent shows in the sidebar only if it reports status. The empty state says: "Agents show up here when they report their status. Older versions and agents inside tmux may not." (`defaults/mods/agents/main.js:427`; commit 9b3c6a5). The app installs no hooks and writes no agent config (grep).
- VERIFIED. Notifications: per listing, `tend_terminals` compares each record's word with the last (`window.rs:1866-1902`). Becoming blocked or error always alerts. Going from busy to not busy alerts only if you were not looking (`model.rs:458-470`). `alert_for` drops sub-agents, terminals in no space, and other machines' unlabelled ones (`model.rs:472-480`). The first listing after start is silent (`window.rs:1884`).
- VERIFIED. An alert plays an MP3 (`afplay` on macOS; else paplay, pw-play, ffplay, mpg123, mpv; Windows MCI), unsettles a tab, and shows an in-window toast unless you are looking at that terminal. The toast action is `agent.focus` (`window.rs:1907-1942`; `sound.rs:16-49`). There is no native notification, dock badge or bounce in the app's source (grep). Hiding instead of closing keeps alerts ringing (`window.rs:526-533`).

## 6. Telemetry and network

- VERIFIED. A daily report, POST `https://telemetry.herdr.dev/v1/report` through curl. One per UTC day, frozen into `telemetry/queue/`, kept at most 7 days (`telemetry.rs:1-16, 28-31, 546-577, 672-697`).
- VERIFIED. Contents, exactly (`telemetry.rs:235-269`): `v`; a random `install` id of 32 hex digits made on first use; `day`; `app {version, os, arch, channel:"stable"}`; `core {version}`; `usage {open, foreground, startups, startup, unclean_exits}` as time buckets and counts capped at 99; `agents` (names from the shipped list, else `other` or `unknown`); `agents_open`, `agents_working`, `spaces`, `tabs`, `terminals` as buckets 0, 1, 2-5, 6-20, 21+; `layouts` (built-in names, else `custom`); `mods {builtin, builtin_edited, custom}` counts; `commands` (app command names); `custom {keys, theme}` booleans; `welcome`; `events` (fixed names: `core_lost`, `app_update_failed`, `core_update_ok`, `core_update_failed`).
- VERIFIED. Not sent: terminal text, prompts, file contents, folder paths, free-text names, custom mod or layout names (`docs/security.md:45-50`).
- VERIFIED. Opt-out: Settings > Privacy, or `"telemetry": false` in settings.json, which also deletes the install id and unsent reports. Per run: `DO_NOT_TRACK`, `HERDR_TELEMETRY=0/false/off/no`, or any CI variable (`telemetry.rs:82-98, 437-444`; `docs/security.md:52-63`). On by default (`settings.rs:447`).
- VERIFIED. Source builds collect locally but never send unless `HERDR_TELEMETRY_URL` is set. Only builds made with `HERDR_APP_RELEASE` send (`telemetry.rs:12-16, 101-106`). The first send waits 20 to 120 s. Failures back off 2, 4, 8, 16, 24 h (371, 600-604). Settings shows the draft, the queue and the last sent report (611-639).
- VERIFIED. Other network calls:
  - `releases.herdr.dev`: `app/latest.json`, the tarball, `app/<ver>/changelog.md`, `core/latest.json`, hourly, release builds only (`update.rs:23, 195-219, 260-298`).
  - `media.herdr.dev/<ver>/<file>`: release-note clips, https only, one path shape, 16 MB cap (`update_notes.rs:156-160, 178-197`).
  - The core installer and `hc update`, user-triggered (`core_bin.rs:164-217`).
  - Feedback POST to `https://telemetry.herdr.dev/v1/feedback`, only after the person reviews and sends: message up to 4,000 characters, optional email, version, os, arch, core version, layout name (shipped or `other`), up to 3 screenshots, no install id (`feedback.rs:1-32, 84-150`).
  - Mods, which are trusted JS and can fetch any URL (`docs/security.md:3-10`). The shipped mods make no network calls (grep of `defaults/mods` and `defaults/frame`).
- VERIFIED. Installers tag downloads `?src=install|reinstall` (app) and `?src=install|update` (core) so the release server can count them (`distribution/install.sh:62-71`; `herdr-core/distribution/install.sh:57-61`).
- VERIFIED. The core has no telemetry. Its only network code is `hc update` and the installers, through curl against `releases.herdr.dev` (`core/releases.rs:1-30`). Remote machines use SSH.
- `docs/security.md:65-66`: telemetry off "does not stop update checks, mod network requests or feedback you choose to send".

## 7. Fidelity gaps they document

Fixed, and where the fix lives:
- Resize in full-screen programs: viewer-side mode-2048 report (CHANGELOG 0.1.5; `terminal.rs:1292-1294`; `core/relay.rs:33-51`).
- Alternate screen on late attach: "late viewers follow the screen a program is actually on, not stale alternate-screen flags" (core f5e58a2; `core-vt/lib.rs:674-683`, test 815-848). The paint strips aliases 47, 1047, 1049.
- Scrollback: "Scroll back through thousands of lines instead of a few hundred" (CHANGELOG 0.1.6). The VT now sets 10,000 lines and 10 MB (`vt.rs:316-318, 364-365`). Attach pulls 2,000 lines; the core keeps 5 MB per screen (`hc.rs:395`; `core/config.rs:43-45`). A full-screen program's history, which "the app keeps to itself", is gone once it exits (`core/terminals.rs:101-103`).
- Flicker and idle cost: sync-output hold with a 1 s cap (`vt.rs:297-315`); no redraw for unseen panes or title-only output (`terminal.rs:328-333`); spinner glyphs stripped from titles so mods do not redraw ten times a second (`terminal.rs:598-601`); row reuse (a636e6c); the display link parks when idle (7f71313; `Cargo.toml:72`).
- Colors: "Terminal colors show exactly as programs set them, so powerline prompts look right" (0.1.8). Minimum contrast is opt-in, default 1.0, and box, powerline and block glyphs keep their colors (`vt.rs:35-40, 971-974`; `settings.rs:449`).
- Nerd Font icons the app cannot draw froze it (0.1.7): "every path must make progress" (`terminal.rs:885-887`, tests 1373-1392).
- Keys: dead keys, Caps Lock, Option-as-Alt, AltGr, an ibus crash, kitty consumed modifiers (CHANGELOG 0.1.5, 0.1.8; `vt.rs:990-993`; `terminal.rs:759-771`).
- Selection: double and triple click; fractional cell widths at zoom (`vt.rs:539-543, 1038-1045`, tests 1262-1302).
- Windows ConPTY: win32-input-mode for modified Enter, kitty taking precedence (`win32_keys.rs:1-5`; `terminal.rs:1580-1635`; CHANGELOG 0.1.5). The core replays the mode to every new viewer (core 6a2938d).
- OSC 52 copy from programs and from remote machines (0.1.8; `vt.rs:147-194`).

Open or accepted:
- Kitty images are lost on repaint or reattach, hence "every tab stays attached" (`window.rs:1348-1349`).
- Sixel: nothing. Bell and OSC 7: ignored by the app.
- Reboot or core crash: panes come back as fresh shells in their last folders, not their old programs (`README.md:55`). After a crash the core rebuilds each screen from a ~1 MB holder tail and marks it `inexact`; older history may be missing (`core/terminals.rs:49`; `core/holder.rs:2-4, 14`; `core/runtime.rs:396-437`). It then resizes each terminal down one row and back after 50 ms so TUIs repaint (`core/runtime.rs:447-461`).
- Agents inside tmux, and older agent versions, may not report status (`defaults/mods/agents/main.js:427`).
- FOCUS is pane focus, not window activation (1.5). FACTS never refresh (1.6).
- Windows reports no signals, so a kept terminal that dies by signal is not seen as lost there (`schema/README.md:123-125`).

## 8. Velocity and shape

- VERIFIED. herdr-app: 114 commits, first 2026-10-23 08:48, last 2026-10-29 18:51 (Pacific, author dates). Per day from 10-23: 4, 10, 32, 18, 6, 1, 42. One commit carries an author date of 10-22, before the initial commit. Authors: 101 Ogulcan Celik, 10 JJ Liebig, 3 others. herdr-core: 39 commits, 36 by Ogulcan Celik.
- VERIFIED. Releases: app 0.1.4 (10-23), 0.1.5 (10-26), 0.1.6, 0.1.7, 0.1.8, 0.1.9 (all 10-29). Core 0.1.10 (10-23), 0.1.11 and 0.1.12 (10-26), 0.1.13 and 0.1.14 (10-29).
- VERIFIED. 18 distinct commits touch `hc.rs`, `vt.rs` or `terminal.rs` after the initial one: 3 on 10-24, 6 on 10-25, 1 on 10-26, 8 on 10-29. By file: `hc.rs` 2 (perf c88c20a, comments 2b0c0ba), `vt.rs` 11, `terminal.rs` 15. The wire client has been stable. The churn is in fidelity fixes.
- VERIFIED. Coupling is a floor, not an exact pin: core at least 0.1.11, generation equal to 1, nine methods present (`hc.rs:154-212`). An app update lifts the core to the latest of the same generation (`update.rs:221-229`). The core promises "The API only grows" and tests that against `released.openrpc.json` (`schema/README.md:12-19`). It is marked "preview (protocol generation 1, version 0.x)".
- VERIFIED. Shape: 20,730 lines of Rust in `src/` and `crates/`, 8,143 lines of JS in `defaults/` (mods), and about 462,000 lines of vendored Rust: GPUI and its platform forks 167k, gpui-kit 207k, quickjs-jit 58k, taffy 25k (line counts of `vendor/`). `Cargo.toml:65-88` swaps eleven crates for vendored copies, most with a "HERDR:" note.
- VERIFIED. Policy: the app's core stays small and everything else is mods; anything added to it needs the maintainer's go (`AGENTS.md:15-29`). "Preserve compatibility with released versions and installed user data" (`AGENTS.md:9-13`). Only the maintainer releases (`AGENTS.md:86`).

## Against the sketch (`docs/c11v-herdr-core.md`)

1. Lines 39-40 ("exactly what Ghostty's manual IO mode consumes") hold. herdr-app has the same shape: a second libghostty-vt fed the attach stream. Add the viewer duties of 1.4 to 1.7 to the spike checklist: the write-back path, the mode-2048 report after RESIZE, FACTS with cell size and refresh on theme change, FOCUS on reattach, the 1 s sync-output cap, and a flood test (`yes`) that exercises the 4 MiB repaint.
2. Line 42: the VTs are Ghostty but from different commits, and they share no binary state (1.2). Pin one core build.
3. Line 52 (`c11.place=` labels): herdr-app's adoption needs a re-read of the live record, `keep`, an in-flight guard and a settle window to avoid dead panes and double adoption (4.6). Labels set at `run` time are the right opt-in. Copy the guards.
4. Line 55 (status through OSC 7501 from c11's wrappers): herdr-app has no fallback and says so in the empty state (5). How a c11 wrapper would emit 7501 for agents that do not is open.
5. Line 56 and decision 3: item 9 of the summary.
6. Line 58 (`terminal.send ... if: idle`): the core gate holds a person's keys while an agent's input goes in, and waits for 3 s of quiet (`core/input.rs:42-67`). Viewer auto-replies count as a person. Resize reports and image acks reset the quiet clock.
7. Line 61 (`history: N` for find): only the main screen has history in a paint, the app asks 2,000 lines, and the core stores 5 MB (7). It is not full scrollback.
8. Decision 1 (bundle): herdr-app does not bundle, and the maintainers expect apps that bundle hc to use `hc update --from` (`core/cli/update.rs:50-74`). INFERRED: that rewrites the binary in place, which breaks a signed bundle's seal. Agents inside terminals also need `hc` on PATH; herdr-app relies on `~/.local/bin`. `core_bin.rs` already accepts a pinned path in settings.json (`core_bin.rs:83-98`).
9. Decision 2 (own session): herdr-app uses the default session. With a shared session, any `hc update` from herdr-app restarts c11's core, and the last active viewer wins size between the two apps. An own session (`HC_SESSION`, or `hc connect --session`, `core/cli.rs:101-107`) removes both. Sessions are not a security boundary (`herdr-core/docs/security.md:33-45`).
10. Decision 4 (TCC): see 3.4. herdr-app has only signature stability.
11. Decision 5 (relationship): see 8. One author wrote 89% of the app commits; the protocol client has barely moved; fidelity work is where the churn is.

## Not read, or read partly

- `window.rs` (4,736 lines) was read for terminals, attach, resize, focus, documents, adoption, reconnect, peek, alerts and quit. I skipped overlay, mod-host, layout-file and rendering code. `mods.rs`, `settings.rs`, `links.rs`, `files.rs`, `commands.rs`, `sprites.rs`, `update_notes.rs` and `window/*.rs` were opened by grep only.
- `update.rs` and `telemetry.rs` tests (the last 150 and 40 lines) were skimmed by grep.
- `vendor/` was measured, not read, apart from GPUI's focus code. `vendor/ghostty` is empty here.
- Core files read for cross-reference: `schema/README.md`, `viewers.rs`, `relay.rs`, `input.rs`, `wire.rs` (header), `api/doc.rs`, `cli/update.rs`, `ghostty-vt/lib.rs` (paint, hooks, tests), and parts of `runtime.rs`, `holder.rs`, `client.rs`, `cli.rs`, `platform/unix.rs`, `terminals.rs`, `releases.rs`.
- Nothing was built or run. No checkout was modified.
