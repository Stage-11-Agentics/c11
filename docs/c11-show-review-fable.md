# Review of `c11 show` (Fable, fresh context)

**Written:** 2026-11-06 12:48. Reviewer: Fable 5.1, no prior context on this design. Under review: `docs/c11-show-design.md`. Read to test it: `Sources/Relay/C11RelayPolicy.swift`, `Sources/Relay/C11RelayHC.swift`, `Sources/HC/HCManagedSession.swift`, `docs/c11-relay.md`, `docs/c11-remote-core.md`, `docs/c11-remote-status.md`, `docs/remote-daemon-spec.md`, `docs/c11-agent-linked-companion-browsers-plan.md`, `docs/markdown-viewer-design.md`, `Sources/Panels/MarkdownPanel.swift`, `Sources/Panels/MarkdownWebRenderer.swift`, `Sources/MarkdownAssetPolicy.swift`, `Sources/Panels/BrowserPanel.swift`, `Sources/SocketHandlers/BrowserHandlers.swift`, `Sources/PanelLinkActivation.swift`, the bundled `herdr-core` 0.1.16 help and its `schema` output, and `~/.local/share/c11/atlas-via.sh`. No source edited, nothing built, no server started.

## Verdict

The verb is right. The server is the wrong half.

`c11 show <path>` as one location-blind word, the viewer always on the operator's side, markdown staying markdown, display only through the relay, a load check that answers the agent: keep all of it. The piece that does not survive contact with the code is "a tiny static server in the relay kit on every machine". The operator's c11 can already read any file on any linked machine through the link it already trusts. Pull the content; do not serve it. That removes the server, the symlink folder, the reload injector, the port, the tailnet rule, the naming scheme and the kit install, and it makes the friend's case free.

## The fact that settles the biggest unknown

hc's machine link is an ssh session running `herdr-core connect` over stdin and stdout (`~/.local/share/c11/atlas-via.sh`). It is a JSON-RPC pipe. It forwards no port and proxies no HTTP. The 32-method API (`herdr-core schema`) has no forward, proxy or tunnel method.

But the pipe already carries content, both ways, with the `on` parameter naming a linked machine:

| Method | What it carries | Cap |
|---|---|---|
| `file.read` | a text file, line ends kept, `on` any machine | 8 MB; `not_text` for binary |
| `machine.exec` | any program's stdout as base64, `on` any machine, no shell | 8 MB stdout, 60 s default |
| `terminal.put` | bytes pushed to a file beside a terminal, on its machine | 8 MB |
| `doc.get` / `doc.set` | an opaque JSON document with a version, `on` any machine | 1 MiB |

And c11 already calls `file.read` with `on` today: `C11RelaySessionHost.relayFileRead` in `Sources/Relay/C11RelayHC.swift`, through `HCManagedSession.relayMethods`. The relay itself rides `doc.get` and `doc.set`. So "c11 fetches the shown file through hc" is not a new transport. It is a new caller of an existing one.

## Findings and ideas

Each ends with a recommendation. Severity is in the order listed.

### 1. The show server is a second product

The draft's server needs: a static file server in the kit, installed on every Mac and Linux machine and inside Linux-host containers; a symlink folder with its own lifecycle; an HTML rewriter that injects a reload script; a port; a bind rule; a Tailscale ACL; a public naming scheme with collision handling; a dotfile and traversal policy; and a kit reinstall on every machine when any of that changes. That is a file host with a product surface, built to move one file at a time to one reader.

Recommendation: delete it. `c11 show <path>` records what was shown (machine, absolute path, caller panel, time). The operator's c11 fetches the bytes through hc on demand and re-fetches when they change. Nothing listens anywhere. Nothing is installed on the far machine beyond the hc core that is already there.

### 2. Live reload without touching the page

Injecting a reload script changes the content, which breaks the draft's own "one copy, as it is" rule, and fails on any page with a `Content-Security-Policy` that forbids inline script (c11's own markdown viewer ships exactly such a policy). The viewer should decide when to reload, not the page.

Recommendation: while the viewer is visible, c11 polls the file's size and mtime through the link every 1 to 2 s (`machine.exec` with `stat`, one tiny RPC) and fetches only on change. Hidden viewer, no poll; reveal, one poll. Keep the hash and scroll across the reload. For markdown this is already the shape of the code: `MarkdownPanel.applyExternalContent` takes a string from a local `DispatchSource` watcher today, so a remote document is a second content source feeding the same reader, not a second reader.

### 3. The browser needs a c11-owned origin, not a remote one

For HTML, c11 has two existing ways to serve fetched bytes to its own WKWebView, and both avoid the problems in finding 4:

- A `WKURLSchemeHandler`, the way the markdown viewer serves itself under `c11md://` (`MarkdownSchemeHandler`). The shown page would load as `c11-show://studio/Projects/.../flag-lanes.html`; relative assets resolve under the same scheme and the handler fetches each one through hc, scoped by the rule in finding 11. No port, nothing another process can reach, and `PanelLinkOriginPolicy.allows` (a ten-line allowlist) can grant `c11://` panel links to shown pages deliberately, so a prototype's panel links work the same whether its agent sat on the laptop or the build host.
- The loopback listener pattern c11 inherited for remote workspaces (`WorkspaceRemoteProxyBroker` in `Sources/Workspace.swift`, `docs/remote-daemon-spec.md`: "one local proxy endpoint", "no port mirroring"), if the custom scheme turns out to lack something a prototype needs.

Recommendation: the scheme handler first. One check before committing, in a tagged build: `localStorage`, `fetch()` of a relative asset, and secure-context APIs under a custom scheme in WKWebView. If a real prototype needs one that the scheme lacks, fall back to the loopback listener; the code is there.

### 4. The draft's address is refused by c11's own browser

`http://studio:4870/...` is plain HTTP to a non-loopback host. c11 refuses that navigation unless a human consents, per host (`browserInsecureHTTPOptInHint`, `browserShouldBlockInsecureHTTPURL`). The draft does not mention it. Under the server design every machine needs a consent, or `show` needs a carve-out that could be aimed at other plain-HTTP hosts. Under finding 3 the question does not arise.

Recommendation: finding 3. If the server stays, the carve-out must be limited to addresses c11 itself derived from the machine roster, never to an address the agent typed.

### 5. Sleep and wake are missing, and they are the overnight case

The relay serves only while the operator's Mac is awake, and relayed writes are never queued or replayed (`docs/c11-relay.md`, "Bounded reconnect wait"). An agent on the build host that finishes a prototype at 03:00 runs `c11 show` and gets `relay_unreachable`. The morning window has nothing. This is the case Atin will hit most: the lid closes, the build host keeps working.

Recommendation: make show a durable intent on the agent's machine, not an RPC to the operator. `c11 show` writes a small record into that machine's hc document store (`c11h.show.<panel>`, well under the 1 MiB cap; the relay already keeps its slots, spool and heartbeat as docs there). c11 reads those records at link-up and whenever hc reports a `doc` event, exactly as it drains the spool. While the operator is away, `show` exits 0 with a distinct line ("recorded; c11 is away; it will load when the Mac wakes"). When the operator is present, the record is also the live request, and the load check answers as the draft says. The record is the dedupe key for re-show, and it survives a c11 restart. In Feed, a show that landed while the operator was away is one row with an open action, not a panel that popped open unasked.

### 6. "The same viewer refreshes" needs a link the code already has

The draft wants a re-show from the same panel to refresh the same viewer. That needs the viewer to know its source and its caller. c11 already records creation lineage (`parent_panel_id`, `c11 family`, "Child of" in the panel sheet), and the companion-browsers plan designed the durable browser-to-agent link in detail. Reuse both.

Recommendation: the viewer is a child panel of the caller, with one metadata key, `show.source` = (machine, path | url). (caller, source) is the dedupe key. A viewer the operator closed stays closed until the agent shows again; a save never reopens it. `show close` closes only viewers whose caller is the calling panel.

### 7. The relay policy gains one panel-creating verb; keep it narrow and honest

`show` is the first relayed call that creates a panel. The policy's comment says the relay never becomes a remote shell; this stays true only if the new methods are narrow.

Recommendation:
- New methods `show.open` and `show.close`, not `browser.*` or `markdown.*`. The relay keeps refusing everything under `browser.` with the draft's hint.
- Placement only beside the verified caller's own panel. No panel, area, workspace or window parameter is accepted (the `isOtherTargetKey` refusal already exists).
- For the path form, the machine is always the caller's verified machine. It is never a parameter.
- For the URL form from a remote caller: refuse `file:`, loopback, and every address of the operator's own machine (its hostname, tailnet name and IPs), not only `localhost`. The draft refuses loopback only.
- A cap per caller (eight live viewers; a re-show replaces). A remote agent must not be able to fill the window.
- Shown URLs load in a dedicated non-persistent browser profile (`BrowserProfileStore` already has profiles; `WKWebsiteDataStore.nonPersistent()` is one call). A prompt-injected remote agent must not be able to show `https://admin.example.com/delete` and ride the operator's cookies. Display-only stops the agent's hands, not the page's.
- State the limit that remains: a shown page's own script can still send requests to services on the operator's Mac (a `no-cors` POST to Gaffer on `:8737`, for instance). That is true of every page a local agent opens today. Say it in the design; do not solve it here.

### 8. Names (question 1)

The readable scheme `/<repo>/<path within repo>` breaks on this machine today: `c11/`, `c11-wt-191/`, `c11-wt-221/` and the worktrees under `c11-worktrees/` are all "c11", so the numeric suffix decides, and which file gets `-2` depends on who showed first. The address is then neither stable nor bookmarkable.

Recommendation: the address is the path. `<machine>/<home-relative path>`: `studio/Projects/c11/docs/flag-lanes.html`. It is unique with no registry, stable across restarts, readable, and it mirrors the `~/Projects/x` here to `~/Projects/x` there mapping the c11 skill already teaches for `--on`. Length does not matter: the tab shows the page's `<title>`, the panel bar shows the source. Under finding 3 there is no public name at all; the viewer's address bar shows `c11-show://studio/Projects/...`.

### 9. The phone pulls the transport in the wrong direction (question 2, part)

"The same address opens on the phone" is in the acceptance test. It is the only line that needs a network listener, a name and an access rule. It is also M9 ("Other screens") in the vision, not M6.

Recommendation: take the phone out of v1's acceptance test. When it comes, the answer is `tailscale serve` on the machine that already has the content, which gives HTTPS, a stable MagicDNS name for the machine and tailnet identity for free, rather than a hand-written ACL. Under finding 1 that machine can be the laptop serving c11's shown set, so the phone sees the same thing the operator sees.

### 10. The load check is mostly there; "blank" is the new part

Existing: `didFailProvisionalNavigation` renders an error page and reports the reason; `decidePolicyFor navigationResponse` sees the HTTP status; `browser.wait --load-state`, `browser.errors.list` and `browser.console.list` are socket methods; the markdown renderer has `renderFailed`. New: "rendered blank". Cheap test after load: body text length plus element count, or a screenshot's share of non-background pixels. One trap: a viewer in a hidden workspace is throttled by WebKit (`document.hidden`, no timers, possibly no paint), so a load check there may need `keep-live` for the first paint. The verb exists.

Recommendation: implement the check as the draft says, on top of the existing signals, with the hidden-workspace case covered by `keep-live` during the check only.

### 11. `--dir` is a fetch scope, and the scoping code exists

Under finding 1, `--dir` means "assets under this folder may be fetched on demand", resolved per request. `MarkdownAssetPolicy.resource(for:)` already does exactly this for the markdown viewer: decode once, refuse `..` and backslashes, pin the root, resolve symlinks, allow a short list of MIME types, cap size. Reuse it. Binary assets (images, fonts) go through `machine.exec` with `base64` or `cat`, since `file.read` answers `not_text`.

Recommendation: reuse the policy; add the few MIME types prototypes need (`svg` deliberately excluded, as it is today; `woff2`, `js`, `css`, `json`).

### 12. Linux-host containers need one line either way

An agent inside an Incus container writes to `/home/agent/x.html`. Neither design reaches that path from the Linux host without the seat's help: the draft's server would run inside the container's network, and `machine.exec --on linuxbox` runs on the host. `linux-relay-proxy` passes only `doc.get` and `doc.set` on the relay slots and the heartbeat.

Recommendation: the seat answers it: `machine.exec --on linuxbox incus file pull <container>/home/agent/x.html -` is the fetch, and the proxy allowlist gains the `c11.show.*` document name. Say so in the design; the container case is not free.

### 13. The friend's c11 is free under pull, and expensive under serve

A friend links a second Mac over ssh with keys and no tailnet. Under the server design, their c11 must reach a port on that Mac over whatever network they have, with plain HTTP (finding 4). Under finding 1, `show` works the moment the link works, because it uses nothing but the link.

Recommendation: finding 1. This is the strongest argument for it beyond simplicity.

### 14. Size and rate

`file.read` and `machine.exec` cap at 8 MB, which covers every self-contained Stage 11 page and most prototypes. hc has one parse thread per core, and heavy traffic has slowed typing in other terminals (c11 plan, risk 2). A `stat` every 2 s per visible viewer is nothing. Fetching 5 MB every 2 s is not.

Recommendation: poll metadata, fetch on change only, nothing while hidden, and refuse to show a file over 8 MB with a clear line ("too large to show; host it and `show <url>`").

### 15. The URL form needs the tailnet, and that is a stated limit, not a bug

`c11 show http://localhost:5173` from the build host names the build host's loopback. The operator's c11 cannot reach it over hc. On Atin's network the agent can bind the tailnet address instead and show `http://studio:5173`. A friend has no tailnet. VS Code Remote and Codespaces solve exactly this with port forwarding owned by the client side. c11 owns the ssh target for every linked Mac (it renders the via script), so it could open an `ssh -L` for a shown port itself later. That is the one place a forward is ever needed, and the operator's c11 would open it, never the agent.

Recommendation: v1 states the limit (URL form needs a reachable address; on Atin's network, bind the tailnet). A later ticket may add the client-side forward for `show <url>` to a loopback port on a linked machine.

### 16. Small things

- A local agent runs the same `show`, with no hc call and a direct file read. One word in the skill, one code path with two content sources.
- Skill text: add a third line. "`show` answers whether it loaded; fix a nonzero before you tell the operator it is ready."
- `c11 markdown open` and `c11 browser open` stay as they are. Do not grow them `--on`.
- The panel sheet row for a viewer should read "shown by <agent title>, updated 12 s ago". Lineage gives the first half.

## Prior art

- **Jupyter `display_data`.** The kernel emits a MIME bundle on a message channel; the front end renders it; the kernel never drives the front end. This is the closest ancestor of `c11 show`: content crosses, control never does. Jupyter never tells the kernel whether the render worked. The draft's load check is new.
- **VS Code Remote and Codespaces.** Ports are forwarded by the client side when it sees `localhost:` in output, shown in a Ports view, opened in a Simple Browser inside the editor, with private, org and public visibility behind auth. Borrow: the client opens the forward, never the remote; a visibility level per shown thing. Applies to finding 15.
- **Claude artifacts.** Content in a side panel beside the conversation, a version switcher, iterate by editing in place, and in some flows the console errors go back to the model. Borrow: the version scrub (idea 3 below) and feeding load errors back to the agent (the draft already does).
- **iTerm2 `imgcat` and the Kitty graphics protocol.** Content travels inline in the terminal stream as an escape sequence, so it works over any ssh with no second channel. hc's attach stream carries the program's raw bytes (contract row C5), so c11 could in principle receive a small file this way from a machine hc does not even know, through a plain `ssh` inside a c11 terminal. It is a stale copy, it lands in scrollback, and hc replays up to 5 MB of history on reattach. Not for v1, but it is the one route that reaches a machine with no link at all.
- **Tailscale Serve.** The standard way to put a local port or folder on a tailnet with HTTPS and identity. The phone answer (finding 9).
- **Live Server and Vite.** Reload that keeps state. Borrow: keep hash and scroll; tell prototypes to keep UI state in the hash.
- **c11's own remote daemon** (`docs/remote-daemon-spec.md`). A single loopback proxy endpoint on the operator's Mac tunnelling browser traffic over ssh RPC streams, after an explicit decision against per-port `-L` mirroring. The same shape as finding 3's fallback, already in the tree.

**Genuinely new in the draft:** one verb that is blind to location because the viewer always lives on the operator's side and the content is reached by reference; live-by-reference across machines (a link, not a copy); a display primitive that reports back whether it rendered; and an asymmetry (content crosses, control never) enforced by the relay policy rather than by convention. I found no tool that has all four. The companion-browsers plan found the same for its own composition; the two designs fit together, since a shown viewer is exactly a browser with a durable link to the agent that made it.

## The four questions

**1. Names.** The path, under the machine: `<machine>/<home-relative path>`. No registry, no suffixes, stable forever. See finding 8. Under the pull design the name is only what the address bar shows.

**2. Reachability.** hc's link, by pulling the content through `file.read` and `machine.exec`, which c11 already calls over that link. Not a port, because hc has none to give; not the tailnet, because the friend has none and the phone belongs to M9. The tailnet remains the answer for the URL form on Atin's network, and Tailscale Serve is the later phone answer. See findings 1, 2, 9, 13, 15.

**3. Clickable prototypes as a first-class experience.** Beyond showing, in the order I would build them:

1. **Point and say.** A comment mode in the viewer's bar (or Option-click): the operator clicks an element, types one line, and it lands as mail to the showing agent with the element's selector and text, a cropped screenshot and the page's hash. c11 already computes selectors (`find`, `snapshot --interactive`), already has the mailbox and the lineage, and the agent already gets mail as its next turn. This is the missing half of the loop: look, point, say, without the operator leaving the page or typing a description of where. The agent never gets control; it gets the operator's words with a pointer.
2. **The bar tells the story.** "Shown by Flag Lanes, updated 12 s ago", a gold pulse on each change (the panel-link pulse exists), and the agent's own panel row saying "showing 2". The operator arriving cold sees whose page this is and whether it is fresh.
3. **Before and after.** The viewer keeps the last few fetched versions in memory and flips between them with one key. Nothing on disk, no store; it is what Claude artifacts' version switch gives, at the cost of a small array.
4. **Device widths.** Phone, tablet and desktop buttons in the viewer's bar (`browser viewport` exists), since every prototype ends up judged on the phone.
5. **State survives reload.** The viewer keeps hash and scroll; the skill tells prototypes to keep UI state in the hash. A clickable prototype that resets to its first screen on every save is the thing that makes live reload feel broken.
6. **`show --wait`.** The agent blocks until the operator has looked (`last_seen_at` and `being_seen` exist per panel). "Tell me when you have seen it" without polling.
7. **A gallery.** `c11 show list` and a sidebar badge; the Chaos Wizard's `gallery.html` is the pattern. Later.

**4. Missing, wrong, or still too complex.** Missing: sleep and wake (finding 5), the plain-HTTP consent (4), the Linux-host seat line (12), the operator's own non-loopback addresses in the URL refusal and a non-persistent profile for shown URLs (7), the 8 MB line (14). Wrong: the naming scheme on this machine's worktrees (8). Too complex: the server and everything it drags in (1, 2, 11, 13), and the phone in v1's acceptance test (9).

## If I were building this

1. **Local `show` first.** `c11 show <path|url>` on the operator's own Mac: a viewer beside the caller, child lineage plus `show.source`, dedupe on (caller, source), the load check, markdown through the existing reader. The skill's three lines. One ticket, and already useful today.
2. **A remote content source.** `ShownSource` is a local file or (machine, path). The remote one reads through `file.read` and `machine.exec`, serves under `c11-show://` through a scheme handler, polls `stat` while visible, reuses `MarkdownAssetPolicy` for `--dir`. Half a day first in a tagged build to confirm the custom scheme carries what a prototype needs; the loopback listener is the fallback. One ticket.
3. **The relay verb as a durable record.** `show.open` and `show.close`, caller-scoped, with the record in the agent machine's hc document store and a drain at link-up. The friend's second Mac and the build host with the lid closed both work at the end of this ticket. One ticket.
4. **Point and say.** The comment mode that mails the showing agent. One ticket. This is where it starts to feel like nothing else.
5. **Phone, later,** by Tailscale Serve of the shown set from the laptop, opt-in, when M9 comes.

Acceptance test, amended: the Flag Lanes agent on the build host runs `c11 show <its prototype>.html`; a panel opens beside it on the laptop; the page is clickable; a save on the build host appears without anyone re-running anything; a deliberately broken path makes `show` exit nonzero with the reason; the lid closes, the agent shows a second page at night, and the morning window has it waiting. The phone line moves to M9.
