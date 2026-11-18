# c11 show: showing the operator what an agent made, from any machine

**Status:** Design agreed with Atin, 2026-11-06. Reviewed by Fable (`docs/c11-show-review-fable.md`; finding numbers below refer to it). One ticket on the c11h board (C11H-228) carries the whole build. <!-- c11-2.0:keep -->

## The problem

An agent in a c11 terminal can run on the laptop or on a linked machine (the build host, the Linux host). Atin sits at one c11 on one Mac. Today an agent on the build host cannot show him anything:

1. The relay refuses browser and markdown commands (`relay_not_allowed`, `Sources/Relay/C11RelayPolicy.swift`), so the relay never becomes remote control of the operator's Mac.
2. Even if it allowed them, `file:///Users/...` names a path on the build host, and `localhost:5173` means the operator's own Mac.

Found live on 2026-11-06: the Flag Lanes design agent (panel 1004, Claude on the build host) built HTML prototypes Atin could not see in his c11.

Atin works heavily in HTML clickable prototypes and markdown. Showing them must be first class, and which machine the agent runs on must not matter.

## The insight: two jobs on one browser

| | Showing the operator something | The agent's own instrument |
|---|---|---|
| Who looks | Atin | The agent |
| Share of use | Most of it | Less; alternatives exist (Playwright, headless Chrome, the sandbox guest) |
| Where it runs | Where Atin sits | Where the agent runs |
| Crosses machines | Yes, content only | Never |

Rule: **content crosses the link, control never does.**

## Design

### `c11 show`

One command, the same from any machine. The agent never needs to know where the operator sits: every c11 terminal belongs to exactly one c11, and `c11` reaches it (local socket or relay).

- `c11 show <path>` shows a file in a viewer beside the caller. `--dir <folder>` lets the page fetch sibling assets from that folder.
- `c11 show <url>` shows something the agent hosts itself (a dev server).
- `c11 show close [<path|url>]` closes viewers the caller showed.
- `.html` and other web content open in a browser viewer; `.md` opens in c11's markdown viewer.
- Display only. The agent can show, re-show and close what it showed; it cannot eval, click, snapshot, fill or navigate a viewer.

### Content is pulled by reference, never served

hc's machine link is a JSON-RPC pipe over ssh. It forwards no port, but it already carries file bytes: `file.read` (text, 8 MB) and `machine.exec` (any program's stdout, base64, 8 MB), each with `on` naming a linked machine. c11 already calls `file.read` over it (`relayFileRead`, `Sources/Relay/C11RelayHC.swift`).

So `show <path>` records the source (machine, absolute path, caller panel), and the operator's c11 fetches the bytes through hc. Nothing listens anywhere; nothing is installed on the far machine beyond the hc core already there. A local agent uses the same command with a direct file read: one code path, two content sources (`ShownSource`: local file, or machine plus path).

- **HTML** loads under a c11-owned scheme, `c11-show://<machine>/<home-relative path>`, served by a `WKURLSchemeHandler` (the pattern of the markdown viewer's `c11md://`). Relative assets under `--dir` resolve through the same handler, scoped by `MarkdownAssetPolicy` (no `..`, pinned root, resolved symlinks, MIME allowlist plus `js`, `css`, `json`, `woff2`; `svg` stays excluded). Binary assets come through `machine.exec`, since `file.read` answers `not_text`. First check in a tagged build: `localStorage`, relative `fetch()` and secure-context APIs under the custom scheme. If a real prototype needs something the scheme lacks, fall back to the loopback proxy c11 already has for remote workspaces (`WorkspaceRemoteProxyBroker`). (Findings 1, 3, 11.)
- **Markdown** feeds the existing reader: the remote source supplies a string to `MarkdownPanel.applyExternalContent`, as the local `DispatchSource` watcher does today. Markdown stays markdown.
- **Live reload without touching the page.** While a viewer is visible, c11 checks the file's size and mtime through the link every 1 to 2 s (one tiny RPC) and fetches only on change. Hidden viewer, no check; on reveal, one check. Hash and scroll survive the reload. Nothing is injected into the page. (Findings 2, 14.)
- **Size.** Over 8 MB, `show` refuses: "too large to show; host it and `show <url>`."

### Names

The address is the path: `<machine>/<home-relative path>`, for example `studio/Projects/c11/docs/flag-lanes.html`. Unique with no registry, stable, readable, and it matches the `~/Projects/x` here to `~/Projects/x` there mapping the c11 skill teaches for `--on`. The viewer's tab shows the page's `<title>`; the bar shows the source. (Finding 8.)

### The viewer and its agent

The viewer is a child panel of the caller (existing lineage: `parent_panel_id`, `c11 family`) with one metadata key, `show.source`. (caller, source) is the dedupe key: a re-show refreshes the same viewer. A viewer the operator closed stays closed until the agent shows again; a save never reopens it. The bar reads "Shown by <agent title>, updated 12 s ago". This fits the companion-browsers plan: a viewer is a browser with a durable link to the agent that made it. (Findings 6, 16.)

### Load check

`c11 show` waits until the operator's c11 has loaded the content, then answers the agent: status, loaded or failed and why, the count of script errors, and whether the page rendered blank (body text length plus element count). A failure exits nonzero with the reason. A viewer in a hidden workspace keeps itself live for the check so WebKit paints it. Existing signals cover most of this (`didFailProvisionalNavigation`, `browser.errors.list`, the markdown renderer's `renderFailed`); "blank" is new. (Finding 10.)

### When the operator's Mac is away

Relayed writes are never queued, so an agent on the build host showing a page at 03:00 with the lid closed would fail. Instead `show` from a linked machine writes a durable record, `c11h.show.<panel>`, into that machine's hc document store (well under its 1 MiB cap; the relay already keeps its slots and spool there). c11 reads those records at link-up and on hc's `doc` events. While c11 is away, `show` exits 0 with "recorded; c11 is away; it will load when the Mac wakes". A show that landed while Atin was away appears as one Feed row with an open action, not a panel that popped open unasked. The record is also the dedupe key and survives a c11 restart. (Finding 5.)

### Safety (the relay gains its first panel-creating verb)

- New relay methods `show.open` and `show.close` only. Everything under `browser.` and `markdown.` stays refused, with a hint: test with a browser on your own machine, then `c11 show` the result.
- Placement only beside the verified caller's own panel; no panel, area, workspace or window parameter is accepted.
- For the path form, the machine is always the caller's verified machine, never a parameter.
- For the URL form from a remote caller: refuse `file:`, loopback, and every address of the operator's own machine (hostname, tailnet name, IPs).
- At most eight live viewers per caller; a re-show replaces.
- Shown content loads in a non-persistent browser profile, so a shown page never rides the operator's cookies.
- Stated limit, not solved here: a shown page's own script can still send requests to services on the operator's Mac, as any page a local agent opens can today. (Findings 4, 7.)

### Linux-host containers

An agent inside a Linux-host container writes to `/home/agent/x.html`, which `machine.exec --on linuxbox` on the host cannot see directly. The fetch is `incus file pull <container>/home/agent/x.html -` through `machine.exec`, and `linux-relay-proxy`'s allowlist gains the `c11.show.*` document name. (Finding 12.)

### The URL form

`show http://localhost:5173` from the build host names the build host's loopback, which c11 cannot reach over hc. v1 states the limit: the URL must be reachable from the operator's Mac (on Atin's network, bind the tailnet address and show `http://studio:5173`). The insecure-HTTP consent c11 requires for plain `http://` to a non-loopback host still applies. A later ticket may let c11 open its own ssh forward for a shown loopback port, as VS Code Remote does; the operator's side opens it, never the agent. (Finding 15.)

### Point and say

The operator clicks an element in a shown page (a comment mode in the viewer's bar, or Option-click), types one line, and it arrives as mail to the showing agent with the element's selector and text, a cropped screenshot and the page's hash. c11 already computes selectors, has the mailbox and the lineage; the agent gets the mail as its next turn. The agent never gets control; it gets the operator's words with a pointer. This closes the prototype loop: look, point, say.

Who and where, always (C11H-247, from the live test on 1.8.1-h12, where two notes went to a closed panel and nothing said so):

- **The composer names its recipient** above the field, for as long as the operator types: `To <panel title> · <machine>`, the machine as the roster names it.
- **Never into the void.** A send confirms in place (`Sent to <title>`) only when the dispatcher's own record for that note shows a copy in the showing panel's inbox (what `c11 mailbox status` reads), or says why not (`Not sent: …`: rejected, or the inbox could not be written) and keeps the text for a retry. A note with no answer yet is still on its way: c11 keeps watching until the dispatcher answers (closely for two minutes, slowly for an hour, then every 30 seconds while c11 runs), says it is written but not delivered yet, and never offers it again, so a note is never doubled; if the operator closed the composer meanwhile, the answer is said on the page: a delivery briefly, a failure with the note's own words until clicked. Closing the viewer ends that watch: a note whose viewer closed before any answer is not reported further (it was written once, and the dispatcher's own record, `_rejected/` for a refusal, still holds it). A showing panel that closed, or whose terminal ended and is not resumed, is gone: the composer says so before anything is typed and offers no field, and the viewer's bar says its agent has closed. A resume, or a re-show from that panel, restores both; a viewer restored at launch is not a show and proves nothing. A lost link is never an end. Mail goes to the workspace that holds the showing panel now.
- **Only the agent's own pages.** Point and say is offered on the shown page and on other pages of the same source (the same `c11-show://<machine>` host, or the same origin as a shown URL). The mail's `page:` is the address the element was read from; on another page of the source a `note:` line says it is not the shown page and names it. On a page the viewer wandered to (a search, another site) the Option-click is the page's: no element is read, no screenshot is taken, nothing is pushed onto the agent's machine. A note is bound to the document it was read from: a new load or another address ends it ("The page changed"), and the page is checked again before and after the screenshot, so a navigation never puts another page's pixels in the mail. Embedded documents are never the source's own: a page with any embedded content gets no screenshot, and the mail says `screenshot: omitted (the page has embedded content)` (text, selector and page lines stay). The viewer learns this from WebKit, not the page: a subframe navigation or response for the document, or c11's own probe (a user script in c11's content world, unreachable from page scripts) reporting from a non-main frame for frames that never navigate. A frame in a closed shadow root still navigates, so WebKit reports it. The mark belongs to the displayed document, not its address: a History API change of path, query or hash keeps it, and only a fresh main-frame commit starts a document clean. Where c11 cannot tell the document from an earlier framed one (a back/forward restore, an address that moved without a commit, no commit seen), it omits the screenshot once any document in the viewer had frames. Immediately before each capture a fresh check of the whole page (open shadow roots included) is a second guard, and the WebKit mark is checked again after the capture.
- **The viewer keeps its own address.** Return on its `c11-show://` address in the address bar reloads the shown page as a re-show does; any other `c11-show:` input, in any browser panel, is refused with a notice and is never a search or a search suggestion.

### Skill text

> `c11 show <path>` shows a file to the operator from any machine; `c11 show <url>` for anything you host yourself. Anything you show, assume the operator sees. `show` answers whether it loaded; fix a nonzero before you tell the operator it is ready. Keep prototype UI state in the URL hash so it survives live reload.

### What stays as it is

- `c11 browser` stays the agent's instrument on its own machine, refused through the relay. `c11 browser open` and `c11 markdown open` stay local-file commands and do not grow `--on`.

## Constellation Bus

Constellation Bus (`../constellation-bus`) will ship on every host c11 links (its D41). The durable show record is a natural bus message ("agent X showed Y"), so when the bus lands, the record may move there from hc's document store. Bulk content still comes through hc's `file.read`. Keep the record behind one small seam so that move is a swap, and build nothing for the bus now.

## Build order (one ticket)

1. Local `show` on the operator's Mac: viewer beside the caller, lineage plus `show.source`, dedupe, load check, markdown through the existing reader, skill text.
2. Remote content source through hc: the `c11-show://` scheme handler (custom-scheme check first), `stat` polling while visible, `--dir` through `MarkdownAssetPolicy`, Linux-host container fetch.
3. The relay verbs `show.open` / `show.close` with the safety rules, and the durable record drained at link-up.
4. Point and say.

## Acceptance test

The Flag Lanes agent on the build host runs `c11 show <its prototype>.html`. A panel opens beside it in Atin's c11 on the laptop; the page is clickable; a save on the build host appears without anyone re-running anything; a deliberately broken path makes `show` exit nonzero with the reason. The lid closes, the agent shows a second page at night, and the morning window has it waiting. A click in point-and-say mode reaches the agent as mail with the element.

## Deferred

- Phone (the phone): Tailscale Serve of the shown set from the laptop, when other screens come (M9).
- The client-side ssh forward for `show <url>` to a loopback port.
- Version flipping in the viewer, device-width buttons, `show --wait` until the operator has looked, a gallery (`c11 show list`).

## Considered and dropped

- **Relaying browser commands as they are:** makes the relay a remote control for the operator's Mac.
- **Sending the file's bytes through the relay on each show:** a stale copy, plus size limits and chunking.
- **A show server on every machine:** a second product (server, symlink folder, reload injector, port, tailnet rule, naming registry, install everywhere); refused by c11's own insecure-HTTP gate; no answer for a friend without a tailnet. hc already carries the bytes.
- **A c11 artifact store** (IDs, homes, routed edits, versions, multi-writer data): rebuilds a document-sync product inside a multiplexer. Several agents feeding one page use a convention instead: one agent owns the page, the others mail it updates.
- **Each agent runs its own server, guided by AGENTS.md:** port sprawl, whole trees exposed, no load check.
- **Renaming `c11 browser`:** once `show` exists beside it, the split explains itself.
