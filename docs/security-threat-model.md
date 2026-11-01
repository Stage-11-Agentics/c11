# c11 security threat model

This document is the canonical, indexable surface for c11's security
posture: the trust boundaries, hardened-runtime exceptions, URL handler,
WKWebView surface, AppleScript / Apple Events, camera and microphone
access, JIT and unsigned-executable-memory entitlements, and the socket
control protocol. It is a *snapshot of current posture*, not an
aspiration. Each section ends with a code-fenced `Evidence:` list of file
paths (and line ranges where useful) so a reviewer touching that area
can confirm what's true today.

The doc is referenced from `skills/release/SKILL.md` as the
release-time recheck target. When the diff signals listed in section 9
fire, the release agent reads this doc and updates it if scope
changed.

---

## 1. Trust boundaries

c11 operates with four trust tiers. Every other section refers back to
this taxonomy:

- **Operator (trusted).** The human running c11 on their own machine.
  Has full filesystem access via the OS, full control over c11's
  configuration, full ability to launch / kill / reconfigure agents.
  c11 does not try to defend against the operator.

- **Agents inside c11 terminals (semi-trusted).** Processes spawned
  inside a c11 panel — typically Claude Code, Codex, shell sessions.
  Treated as semi-trusted by default: the socket-control mode
  (`cmuxOnly`) limits commands to processes that are descendants of the
  c11 app, but those processes can run arbitrary code in the operator's
  environment. The trust delegation is "the operator put this agent
  here on purpose" — c11 doesn't sandbox agents beyond what macOS
  hardened runtime gives it.

- **Web content in WKWebView (untrusted).** Any page loaded into a c11
  browser panel. Cannot reach the c11 socket (no JS bridge from web
  content to socket). Can request camera / microphone / location via
  the standard WKWebView UI delegate prompts the operator approves
  per-origin.

- **External local processes (gated).** Other processes on the same
  machine (not descended from c11) attempting to talk to the c11
  socket. Default `cmuxOnly` rejects them via an ancestor-PID gate.
  `automation` opens to any same-uid process. `password` requires the
  shared secret. `allowAll` removes all gates and widens socket
  permissions to `0o666`.

Evidence:

```
Sources/SocketControlSettings.swift                   (mode definitions)
Sources/TerminalController.swift:2228-2233            (c11Only ancestry check)
```

---

## 2. Hardened-runtime entitlements

The app declares six hardened-runtime exceptions in
`c11.entitlements`. Each is required by a specific subsystem; removing
any of them breaks first-launch or feature-class behavior. Diffs to
this file are a high-risk signal — see section 9.

| Entitlement                                                    | Why it's there                                                                       |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `com.apple.security.cs.disable-library-validation`             | Required by Sparkle (loads update-helper bundle), WebKit, and the embedded Ghostty Zig dylib. |
| `com.apple.security.cs.allow-unsigned-executable-memory`       | Required by WebKit's JS JIT and Ghostty's renderer.                                   |
| `com.apple.security.cs.allow-jit`                              | WebKit JS JIT (paired with `allow-unsigned-executable-memory`).                       |
| `com.apple.security.device.camera`                             | WKWebView delegates to the OS prompt; camera consumed by web content only.            |
| `com.apple.security.device.audio-input`                        | Same as above for microphone.                                                         |
| `com.apple.security.automation.apple-events`                   | Required because c11 ships an AppleScript scripting dictionary (see section 5).       |

c11 does **not** hold any of these entitlements as a "convenience"; each
is load-bearing for a specific feature class. If a future commit appears
to need a new entitlement, treat that as a structural change worth
reviewing here, not a routine addition.

Evidence:

```
c11.entitlements                                       (the six declarations)
```

---

## 3. URL handler

c11 declares itself a `Default` handler for `http`, `https` and, since
1.7.6 (C11-552), `c11` in `Resources/Info.plist`. The macOS URL handler is
an **untrusted-input vector**. Any local app or process, any web page via
a link, and documents authored by other users can send `c11:` URLs. This
includes agents inside c11 terminals invoking `/usr/bin/open c11://...`.
Launch Services does not authenticate their authors or prove a human
clicked. No caller-provided title, origin or permission is trusted.

An outside link can request only selection of an **existing** panel or
workspace by exact UUID, after a fresh operator confirmation. It cannot
create a workspace or panel, launch an agent or command, type, run, close,
open a path, answer an ask, or carry any parameter. The app uses the same
canonical parser as in-app links: at most 128 UTF-8 bytes; only
`c11://panel/<uuid>` or `c11://workspace/<uuid>`; no short refs, userinfo,
port, escaping, query, fragment or extra path segment. Malformed,
oversized and unavailable targets produce a bounded notice and are
consumed, never passed to another application or treated as paths.

Every admitted outside request shows a nonmodal, nonactivating confirmation
window above the frontmost app, on the pointer's display and active Space.
It names the live destination panel (when applicable) and workspace,
and shows the canonical UUID URL. Titles are bounded plain text with control
and bidirectional override characters removed. **Cancel is the default**;
Confirm has no keyboard shortcut. It stays disabled for at least the system
double-click interval or 0.75 seconds, whichever is longer, after presentation and requires a new plain mouse-down/up
sequence begun after arming. Carried-over multi-clicks are refused. A pointer
already over Confirm must leave and re-enter before it arms. Moving or hiding
the prompt or changing Spaces cancels it, so a stale action cannot authorize
a different presentation. This mitigates surprise-overlay consent, not arbitrary
hostile desktop overlays or already-authorized OS input automation. The window does not become key or main,
does not capture terminal typing, and never calls `runModal` or starts a
sheet. Only an explicit Confirm click can select the destination. Cancel,
close and the 60-second expiry select nothing. Confirm resolves the exact
UUID again; a closed target is refused, and a panel moved to another workspace
gets a distinct notice requesting a new click. Live panel/workspace titles are
display-only and may change without invalidating the same UUID/workspace binding.
An agent-written title stays within a fixed "Panel:" prefix and one collapsed
line; it is never instructions or authority.

There is one process-wide pending confirmation or notice, no request queue,
and a two-second cooldown after dismissal. Further outside requests during
that interval or while a window is present are dropped, never queued or
auto-confirmed. On cold launch only, one bounded URL may wait for initial
session readiness. Its original 60-second deadline survives restore; subsequent
requests are dropped and an expired held URL is discarded. A multi-URL event containing any `c11:` URL is c11-only: at most its first
c11 request is considered, even when refused or rate-limited, and every folder
in that event is ignored. File-only events retain the existing folder route. A burst
cannot replace the destination under the Confirm button or pile up windows.
The handler never activates the app or restores focus on receipt. macOS
may independently launch or activate a URL's registered handler on each send,
as `open -a c11` already can; this existing OS behavior is not authority to
navigate. A hostile local app's ability to overlay desktop windows is the
operator-tier boundary in section 1, outside this confirmation's guarantee. Logs use bounded result codes and canonical
targets, not rejected URL payloads.

Confirm is the only outside-originated path allowed to switch workspaces:
the operator's explicit consent calls the existing native navigation route,
while the external sender gains no reusable authority.

In-app terminal, browser and markdown link rules remain unchanged (section
4). CLI/browser automation still refuses c11 URLs and socket commands still
cannot switch the selected workspace. Outside-link handling adds no socket,
script, command or agent permission, and confirmation is never cached.

Only the production Release bundle (`com.stage11.c11`) claims `c11:`.
The build generates its Info.plist with that identity/configuration policy;
Debug products omit only `c11`, preserving their existing web schemes. The
nightly rebrand also removes only `c11`. c11 does not set Launch Services
preferences or appoint itself as the default handler.

Staging copies use the C11-536 isolation procedure: remove the entire
`CFBundleURLTypes` entry before ad hoc signing and launch, so they claim
neither `c11` nor web schemes. Inspect the **built** release and isolated
staging, tagged Debug and nightly-style bundles to verify registration and
its absence; source-plist checks
do not prove this boundary.

Separately, incoming file URLs go through `externalOpenDirectories(from:)`
and open folders as new c11 workspaces. Only `file://` URLs enter that route;
a URL resolving through symlinks into c11's own app bundle is dropped, so
Launch Services handing c11 itself to c11 does not suppress session restore.
A `c11:` event never invokes the folder route. The Services menu and folder
Apple Events retain their existing behavior (section 5).

Evidence:

```
Resources/Info.plist                                   (CFBundleURLTypes)
Sources/AppDelegate.swift                              (application(_:open:), exact live target resolution)
Sources/PanelLinkActivation.swift                      (strict parser and outside confirmation)
scripts/prepare-info-plist.py                         (production identity and Release configuration only)
GhosttyTabs.xcodeproj/project.pbxproj                  (generated Info.plist is the build input)
scripts/reload.sh                                     (tagged Debug rebrand)
scripts/reloads.sh                                    (staging removes URL types before signing)
.github/workflows/nightly.yml                         (nightly rebrand removes c11 only)
Sources/AppDelegate.swift                              (externalOpenDirectories, FinderServicePathResolver)
```

---

## 4. WKWebView and web content

c11 hosts web content via WKWebView. The substrate is shared between
the embedded browser panel and any markdown / preview panel that
renders HTML. The relevant ATS posture:

- `NSAllowsArbitraryLoadsInWebContent = true` — required by the
  embedded browser to allow non-https sites the operator points at.
  This relaxation is scoped to web content; it does not relax the
  app's own networking.
- One `NSExceptionDomains` entry: `c11-loopback.localtest.me` allows
  `http://` for the loopback subdomain c11 uses to render local
  developer servers.

The browser exposes no page-reachable bridge to the c11 socket. Markdown
uses a separate, allowlisted `c11md` script-message channel described below;
its controller is never shared with browser content. As of 1.6 there are
two `WKScriptMessageHandler`s: `c11md` (markdown only) and `c11PanelLink`
(Panel links, below), which is registered only in the isolated
`c11.panel-links` content world. New handlers must be recorded here when
introduced. The ATS relaxation applies to markdown too,
so its CSP and native navigation policy enforce the offline boundary.

Terminal and markdown link clicks share one router (`openC11WebLink`,
1.1). It accepts only `http` / `https` URLs with a host. It opens a c11
browser panel when the operator's link settings and host allowlist say
so, and otherwise hands the URL to `NSWorkspace`; Option-click forces the
external browser. It never changes the selected workspace.

Panel links (1.6, C11-515, C11-525, C11-532). A `c11://panel/<uuid>` or
`c11://workspace/<uuid>` link selects the destination workspace and window,
focuses the panel and flashes it. This is the one path by which something
other than an operator's sidebar, shortcut or menu action changes the
selected workspace, so it is gated on native operator input:

- Web views (browser panels and the markdown renderer) get a document-start
  listener in the isolated `c11.panel-links` content world. Page scripts and
  socket browser automation run in the page world and cannot call its
  `c11PanelLink` handler or replace the prototypes it reads. The listener
  reports only the clicked anchor's `href` and the event's trust bits. Native
  code then requires all of: a trusted event, the main frame, no socket
  command in flight, a key and visible window, the same document, a plain
  left click or Return with no modifiers and no `target` other than `_self`,
  and a matching native mouse-up (within 2 points) or Return recorded by the
  web view within one second. A recent input alone never grants navigation.
- Browser origins are limited to main-frame `file://` pages and HTTP(S) on
  exactly `localhost`, `127.0.0.1` or `::1`; the markdown renderer only from
  its own entry page. Other origins, iframes, scripts, redirects, forms,
  popups, `window.open`, Cmd/middle/modified clicks and `target=_blank` are
  refused, and every `c11:` navigation that reaches `decidePolicyFor` is
  cancelled, as is a popup to one. The omnibar refuses a typed `c11://` URL
  with a notice; `browser open|goto` and the CLI return
  `operator_activation_required`.
- Terminals act only on a native Cmd-click on a bare `c11://` URL (Ghostty's
  `link-url` matcher, pinned in the Ghostty fork) or an OSC 8 link, in a key,
  visible window. The OSC 8 label is untrusted: the Cmd-hover preview shows
  the destination's live panel title and workspace, never the label. A
  malformed `c11:` string is consumed so it never reaches Ghostty's external
  opener.
- The parser accepts only the exact canonical spelling (at most 128 bytes,
  a UUID path, no user, port, query or fragment). Unknown, stale or malformed
  targets resolve nothing and show a non-modal notice. Each activation logs
  one structured `panel_link` line (target, origin, activation, result).
- A link grants navigation only. It answers no asks, lowers no flags, and
  grants no page-to-agent message, structure read or socket capability.
  `c11 link` formats links from live inventory and has no activation power.
  The markdown sanitizer allows `c11:` in `href` so these links survive
  rendering; activation still goes through the gate above.

Local-file and profile isolation (1.6):

- Download Image and Download Linked File save a `file:` link only when the
  panel itself shows a local page, only for a regular file in that page's
  folder, and copy it off the main thread (C11-495). The context menu reads
  the element under the cursor (C11-497) and no longer falls back to the
  first image or an iframe's page (C11-504).
- Open Link in New Panel, Cmd-click, `target=_blank` and `window.open` open
  a `file:` link only when a local page initiated it; a sandboxed frame's
  opaque origin is refused, and a popup never hands a `file:` URL to the
  system opener (C11-505).
- Favicon fetches and omnibar search suggestions use per-profile ephemeral
  `URLSession`s with no cookie storage and no disk cache, so neither can link
  one browser profile to another (C11-496, C11-507).

Browser-triggered modals (the `http://` navigation warning, JavaScript
`alert`/`confirm`/`prompt`) are raised by page content or by
socket-driven navigation, neither of which implies a human is present.
They are presented only as sheets, via `browserPresentModalAlert`, and
never with `NSAlert.runModal()` — a nested main-thread run loop is a
denial-of-service against the whole app, not a security control. When
no window exists to host the sheet, the decision resolves with its
**safe default rather than prompting**: for the insecure-HTTP prompt
that is Cancel, so the navigation is denied and the host is *not*
added to the allowlist. An unattended app therefore cannot be walked
into an `http://` allowlist entry by a page that raises a prompt
nobody can answer.

A socket caller may instead consent explicitly (0.65.1, C11-207):
`browser open|goto --allow-insecure-http` (socket field
`allow_insecure_http: true`) grants exactly one navigation to exactly
one host and is released when that navigation settles or is superseded.
It never writes the persistent allowlist, and the outcome is reported
structurally (`proceeded` / `prompted` / `insecure_http_blocked`) rather
than by a silent no-op. This widens nothing beyond the socket's existing
trust boundary: anyone who can issue `browser open` could already point
the panel at any https site, and the loopback hosts agents actually
validate against (`localhost`, `127.0.0.1`, `::1`, `*.localtest.me`)
were allowed by default before this change. Page content cannot set the
flag; only the socket caller can.

Browser profiles (1.0, C11-289/C11-311): each non-default profile has
its own `WKWebsiteDataStore(forIdentifier:)`, so cookies and storage do
not cross profiles. `browser profiles clear|delete` wipe that profile's
website data and history and require confirmation; an empty, malformed
or unknown `--profile` fails instead of falling back to the default
profile. `browser cookies clear` honors host, domain, path and secure
scope and needs an explicit `all: true` to clear a whole profile.
`browser state load` restores every cookie row in the state file under that
cookie's own domain, and writes local and session storage only after navigation
settles on the expected origin; a wrong-origin redirect returns
`navigation_failed`. State files are written with mode `0600`, and load refuses
files not owned by the current user, writable by group or others, or carrying
an allow ACL.

Context-menu downloads (Download Image, Download Linked File; 1.5.1,
C11-487) of http(s) URLs go through `WKWebView.startDownload(using:)`, so
WebKit attaches only the cookies it would send for that URL and matches them
again on each redirect. c11 never copies the profile's cookie jar into a
request of its own. `data:` and `file:` downloads do not send cookies.

Every socket-driven browser wait, eval and script injection runs off the
main thread (1.0, C11-311 B006). `browser addinitscript|addscript|addstyle`
still install `WKUserScript`s through the panel's `userContentController`;
they are socket-caller features, not a page-reachable bridge, and no
`WKScriptMessageHandler` was added.

The messages page (`c11 messages view`, 1.0) is a local HTML file
c11 writes (mode `0600`) and opens in a browser panel. It embeds message
bodies as JSON inside a `<script type="application/json">` block with
`<`, `>`, `&`, U+2028 and U+2029 escaped, renders them with
`textContent` only, and carries a CSP of `default-src 'none'` with
inline script and style only, no images, `base-uri 'none'` and
`form-action 'none'`. A hostile message body therefore renders as text.

Outbound hand-off: the browser toolbar's "Open in Default Browser"
button (v0.51.0) passes the panel's current URL to
`NSWorkspace.shared.open(_:)`. It is operator-gesture-gated (explicit
click, never script-triggered) and refuses empty/`about:` schemes; a
page can influence *which* URL is handed off only by navigating itself,
which the operator sees in the address bar before clicking.

Evidence:

```
Resources/Info.plist:204-218                           (NSAppTransportSecurity)
Sources/Panels/BrowserPanel.swift                      (browser substrate; websiteDataStore(for:) per profile)
Sources/Panels/BrowserPanel.swift:17-38                (openC11WebLink, shared terminal/markdown link router)
Sources/PanelLinkActivation.swift                      (c11:// parser, origin and native-intent policy, isolated-world listener, terminal policy and preview)
Sources/AppDelegate.swift                              (openPanelLink: the only link-driven workspace selection)
Sources/Panels/MarkdownWebRenderer.swift               (installs the panel-link listener for the markdown entry page)
Resources/markdown-viewer/viewer.js                    (sanitizer ALLOWED_URI_REGEXP admits c11:)
Sources/SocketHandlers/BrowserQueryHandlers.swift      (cookies, state load, profiles, init scripts and styles)
Sources/PrivateFileWriter.swift                        (private state file read/write)
Sources/Messages/MessagesPage.swift                    (messages page renderer, CSP, JSON escaping)
Sources/Panels/BrowserPanelView.swift                  (panel host)
Sources/BrowserWindowPortal.swift                      (popout / portal layer)
Sources/BrowserSnapshotStore.swift                     (snapshot capture)
```

---

## Markdown document renderer (1.1: C11-358, C11-359 and follow-ups)

Markdown panels load a bundled, offline WKWebView renderer through
`c11md://bundle/index.html`. They never receive `file://` read access.
1.1 replaces the 1.0 renderer; the `mmdc` subprocess 1.0 ran on Mermaid
blocks is gone, and diagrams render inside the page.
Each panel gets its own content controller and directory capabilities; the
process pool and nonpersistent website data store are shared. A panel that
has never been visible does not allocate a web view until a socket query
needs one. Every visible reader stays
live; a process-wide LRU retains at most four hidden readers. Eviction captures
source line/offset, mode and find query, then removes the message handler and
releases WebKit. Queries pin their renderer until completion. Recreation restores
transient reading state before revealing the reader; raw content queries remain
model-only even when no web view exists.

The native scheme handler sends a restrictive CSP response header and injects
the same policy before the bundled
page's scripts: scripts and fonts come only from `c11md:`, images only from
`c11md-asset:`, and inline script, connections, frames, objects, forms and
base URLs are denied. Document text enters `c11md.load` as a JSON argument,
never interpolated JavaScript or a page URL. markdown-it runs with raw HTML
off. Every rendered block passes DOMPurify, which forbids script, style,
frame, object, embed, form and media elements and limits URLs to `http(s)`,
`mailto`, `file`, `c11md-asset` and relative references. KaTeX runs with
`trust: false`. Mermaid runs at `securityLevel: 'strict'`. The viewer
refuses any diagram carrying an `init` or `initialize` directive in any form
Mermaid's own grammar accepts, anywhere in the source, and any frontmatter
line other than a blank, a comment, `title:` or `displayMode:` (1.5.1,
C11-498), so a diagram cannot change the renderer's configuration. Its SVG is sanitized again without links,
images, event attributes or external `url()`. HTML labels stay off, and
`foreignObject` is removed, except in a diagram whose labels contain `$$`
math (1.3: C11-456). There KaTeX renders each formula to MathML (`trust:
false`, `output: 'mathml'`) before Mermaid measures it, labels become HTML,
and each `foreignObject` body is sanitized separately against a fixed
allowlist of text and MathML elements and presentation attributes
(`mathLabelTags` / `mathLabelAttrs`), with no data or ARIA attributes and a
filtered `style`. Because the CSP allows no inline script, a sanitizer
bypass still cannot run script: the only page script is the bundled
renderer.

Local raster images use `c11md-asset://doc/`. The handler percent-decodes
paths exactly once, treats remaining percent sequences as literal names,
rejects traversal, checks the resolved real path against the image root,
and opens each component relative to a pinned
directory descriptor without following symlinks. A symlink resolving within
that tree is allowed; one escaping it is denied. HTML, SVG and script files
are not image resources, and the bytes must decode as a raster image. Reads
are bounded to 20 MiB per image and run off
main; stopped scheme requests receive no late callbacks. This capability
permits the document to display images in its directory tree, including
subdirectories, and grants no arbitrary file-read bridge. The image root is
the directory of the document the reader currently shows. In-panel
navigation (links, palette, backlinks, history, `markdown.navigate`) moves
the root to the new document's directory, pinned by a fresh descriptor the
same way (1.3: C11-387). The scope never widens: each root is exactly one
document's directory, retargeting to the directory already pinned keeps the
existing descriptor (so a directory swapped in underneath is still ignored),
in-flight requests finish under the root they started with, reads stay
image-typed and bounded, and the page has no channel to send bytes out.

Only the initial bundled main-frame navigation is allowed. Document links,
redirects, frames, downloads and new windows cannot navigate the reader,
and the context menu drops WebKit's open, download, reload and copy-link
items. The page posts ten message types on `c11md`: `ready`, `state`,
`rendered`, `error`, `link`, `peek`, `corpusNavigate`, `copy`,
`outlineDismiss` and `escapeUnhandled`. Native drops any message that does
not come from the current web view's main frame loaded from
`c11md://bundle`, or whose body is not a typed dictionary. It drops an
href or path over 16 KiB and copied text over 1 MiB, and cuts a corpus
fragment to 512 characters. What a message can cause:

- `link`: native re-resolves the raw href and never trusts the page's
  resolved URL or kind. Anchors stay in the document. A relative link (no
  scheme, not absolute) to a `.md`, `.markdown` or `.mdown` file navigates
  the panel in place, or opens a new markdown panel with ⌘ or the
  open-in-new-panel setting, only if the target is still a markdown file
  after symlink resolution and lies inside the source document's scope:
  the nearest ancestor directory containing `.git` (directory or file),
  else the document's own directory. Reads use the pinned descriptor walk
  with a 20 MiB cap. HTTP(S) links with a host and no userinfo go through
  `openC11WebLink` (section 4). Mail links accept recipients, cc, bcc,
  subject and body only; hosts, ports, fragments, other fields and control
  characters are refused, and the link opens through `NSWorkspace`.
  `file:` URLs, absolute paths, other schemes and non-markdown files are
  refused. A document link never hands a local file to Launch Services.
- `peek`: after a 280 ms hover on an anchor or relative link, native
  resolves the href as for `link`, reads the target markdown under the same
  scope with a 256 KiB cap, and returns the text for an inert preview that
  loads no images or assets. This is the only file content a page message
  can make native read, and it stays in the page.
- `corpusNavigate`: navigates the panel only to a document in native's
  latest corpus snapshot, only to one of its known heading slugs, and, for
  a backlink, only when the snapshot records a link from that document to
  the current one.
- `copy` writes the text to the general pasteboard. `state`, `rendered`,
  `error`, `ready`, `outlineDismiss` and `escapeUnhandled` update transient
  reader state and the persisted outline choice. Content-state messages
  remain transient; durable presentation fields use the session snapshot.

No message reaches the socket, a shell, an evaluator or a disk write.
Native does not verify a user gesture for `link`, `peek` or `copy`; those
rest on the page running only bundled script, which the CSP and sanitizers
above enforce.

Corpus index (⌘K palette, Referenced by, ticket cards). Every markdown
panel with a file, visible or hidden and including panels restored at
launch, indexes its scope root on a utility queue. In a git checkout it
lists files with `/usr/bin/git ls-files --cached --others
--exclude-standard`; otherwise it walks the directory without following
symlinks, skipping `.git`, `.claude`, `.lattice`, `node_modules`, build
output and similar directories. It reads only markdown files that resolve
inside the root, through the pinned descriptor walk, within fixed bounds
(5,000 documents, 50,000 visited entries, 1 MiB per file, 64 MiB total,
plus heading, link and ticket caps). Ticket cards read `.lattice/ids.json`,
`config.json` and `tasks/<id>.json` read-only through the same pinned root
(4 MiB per board file, 256 KiB per task). An FSEvents watcher refreshes the
index and runs `git check-ignore` on changed paths. The page receives the
snapshot (absolute and relative paths, titles, headings, link edges, ticket
title and status) as one JSON string and renders it with `textContent`.

Both git invocations run in the corpus root through
`UntrustedRepositoryGit`, because that repository's own `.git/config` is
untrusted: an extracted archive can ship a hostile `.git/` owned by the
operator, although `git clone` does not copy a remote's config. Two keys
there would otherwise start a program with no click, on open, on restore
and on file changes. `core.fsmonitor` runs its hook on every index read. A
promisor remote (`extensions.partialClone`) lazily fetches a missing
object over a transport such as `ext::<command>`. Every invocation passes
`--no-pager -c core.fsmonitor=false -c core.hooksPath=/dev/null -c
core.untrackedCache=false -c protocol.allow=never -c
safe.bareRepository=explicit`. It runs with inherited `GIT_*` variables
removed (except `GIT_CONFIG_GLOBAL`), an empty `GIT_ALLOW_PROTOCOL` (no
transport, whatever `protocol.*` config says), `GIT_NO_LAZY_FETCH=1`,
`GIT_WORK_TREE` set to the corpus root, `GIT_CONFIG_NOSYSTEM=1`,
`GIT_TERMINAL_PROMPT=0`, an empty `GIT_ASKPASS`, `GIT_PAGER=cat`,
`GIT_OPTIONAL_LOCKS=0`, and `GIT_CEILING_DIRECTORIES` at the root's
parent. git's ownership check (`safe.directory`) stays on, so a repository
owned by another account falls back to the directory walk. Each call is
killed at a timeout, so a FIFO in place of `.gitignore` or the index
cannot wedge the indexer. For an ordinary repository the output is
unchanged. `MarkdownCorpusIndexTests` proves that a repository configured
with both programs runs neither, including on git that predates
`GIT_NO_LAZY_FETCH`. A git-aware shell prompt has the same exposure on
`cd`.

Repository blueprint files under `.c11/blueprints` and `.cmux/blueprints`
are untrusted. Starter ids, aliases and built-in names ignore case and
surrounding whitespace and always resolve to the app bundle before any
path lookup; other names prefer user and built-in blueprints over a repo
file. A repo blueprint applies only when chosen by its own non-reserved
name, `saved:<path>` or an explicit path, and then its commands run as
written. An unknown bare word is never looked up as a file in the cwd;
pass a path containing `/`, starting with `~` or `.`, or ending in `.json`
or `.md`. The remembered default accepts only known starter ids, and
exports reject reserved names and names that look like paths.

The workspace git probes (#650) run through the same helper, automatically
and with no click: when a workspace opens or is restored in a directory,
when a terminal's directory changes, and when an agent launches there.
They are `branch --show-current`, `status --porcelain -uno` and `remote
get-url origin` for the sidebar's branch and dirty state, and the
`rev-parse`, `symbolic-ref` and `config -f .gitmodules` calls behind the
worktree and submodule chips. They take the same arguments and
environment, except that git discovers the repository upward from the
working directory, as a shell does, with no `GIT_WORK_TREE` pin or
ceiling, and honors `core.worktree`, which submodules need. `status` adds
a third route to a program: it hashes every stat-dirty file, which is
every tracked file in a fresh extraction, through the
`filter.<driver>.clean` or `.process` command that `.gitattributes`
selects, and its submodule check starts a `git status` child in each
populated gitlink under that submodule's own config. Before `status` runs,
the helper visits the repository and every populated gitlink below it,
from the same directory and with the same discovery as the command, lists
`filter.*` keys with `git config --show-scope`, and empties with `-c`
every key the operator's global config does not set. A key the operator
also sets globally gets its global value back, so a globally installed Git
LFS still runs, and git hands `-c` to its submodule children. A driver
name containing `=`, a listing that fails, or more than 64 repositories
refuses the dirty check instead of running it, and one deadline bounds the
scan and the command. Output matches plain git.
`WorkspaceGitProbeHardeningTests` proves that a superproject with an
fsmonitor hook and a required clean filter, over a submodule with its own
clean filter, runs none of the three, from a subdirectory or from inside
the submodule, and still reports the branch and dirty state. Two git
callers stay unhardened: the c11 CLI's version probe, which runs only in
c11's own dev checkout, and the shell integration's `git branch` and `git
remote` calls, which run in the operator's shell like any prompt.

Agent and socket control (1.1). `markdown.scroll`, `navigate`, `history`,
`links`, `backlinks`, `visible` (with a `watch` stream), `theme`,
`typeface`, `font` and `open_external` join `markdown.open` and
`markdown.get_content`. They pass the same connection gate, password check
and explicit-target rules as every other method (section 8); the
`visible --watch` stream runs the password check itself because it bypasses
the ordinary dispatcher. `markdown.navigate`, like `markdown.open`, accepts
any readable regular file by absolute path, with no markdown or scope check,
and the history entries it creates keep that exemption for back and
forward. `markdown.open_external` hands the panel's current file to Launch
Services. Neither crosses the socket tier: a caller the mode admits can
already read or open those files itself. `markdown.visible` reports reading
state, including the find query and up to 120 characters of the operator's
selection in the reader. `markdown.links` reads up to 16 in-scope link
targets (256 KiB each, 4 MiB total) to check fragments.

Evidence:

```
Sources/MarkdownAssetPolicy.swift:19-55               (pinned descriptor reads)
Sources/MarkdownAssetPolicy.swift:58-74               (scope root: nearest .git ancestor)
Sources/MarkdownAssetPolicy.swift:80                  (CSP)
Sources/MarkdownAssetPolicy.swift:85-93               (retargeted image root, never wider)
Sources/MarkdownAssetPolicy.swift:98-141              (scheme handler path and type policy)
Sources/MarkdownAssetPolicy.swift:152-214             (link and mailto validation)
Sources/MarkdownAssetPolicy.swift:235-345             (navigation scope, markdown-only, agentCLI exemption)
Sources/Panels/MarkdownWebRenderer.swift:552-689       (c11md message validation and dispatch)
Sources/Panels/MarkdownWebRenderer.swift:753-868       (link routing and peek reads)
Sources/Panels/MarkdownWebRenderer.swift:874-885       (navigation and new-window denial)
Sources/Panels/MarkdownWebRenderer.swift:5-25         (scheme handler; image root retargeted per document)
Sources/Panels/MarkdownWebRenderer.swift:965-985       (configuration)
Sources/MarkdownCorpusIndex.swift:99-117               (corpusNavigate validation)
Sources/MarkdownCorpusIndex.swift:177-196              (corpus bounds and skipped directories)
Sources/MarkdownCorpusIndex.swift:422-449              (git check-ignore on file events)
Sources/MarkdownCorpusIndex.swift:678-690              (git ls-files discovery)
Sources/MarkdownCorpusIndex.swift:839-891              (read-only .lattice ticket cards)
Sources/UntrustedRepositoryGit.swift:45-59             (git -c overrides)
Sources/UntrustedRepositoryGit.swift:86-123            (git environment; work-tree pin for .topLevel)
Sources/UntrustedRepositoryGit.swift:176-256           (filter.* scan and overrides for status)
Sources/WorkspaceBlueprintStore.swift:29-49            (reference normalization, path shape and safe default)
Sources/WorkspaceBlueprintStore.swift:187-196          (builtInEntry and reserved reference lookup)
Sources/WorkspaceBlueprintStore.swift:200-216          (resolveLayoutReference: saved URL and name precedence)
Sources/WorkspaceManager.swift:1922-1983               (workspace git probe, hardened status)
Sources/Metadata/GitContextResolver.swift:198-266      (ProcessGitRunner via UntrustedRepositoryGit)
Sources/SocketHandlers/MarkdownFeedbackHandlers.swift:295-315   (markdown socket methods)
Sources/SocketHandlers/MarkdownFeedbackHandlers.swift:460-517   (markdown.navigate, agentCLI origin)
Sources/SocketHandlers/MarkdownFeedbackHandlers.swift:859-900   (markdown.open_external)
Resources/markdown-viewer/viewer.js:28-33              (markdown-it config)
Resources/markdown-viewer/viewer.js:164-168            (DOMPurify config)
Resources/markdown-viewer/viewer.js:913-1060           (Mermaid config, math labels and SVG cleaning)
Resources/markdown-viewer/BRIDGE.md                    (renderer contract)
c11Tests/MarkdownAssetPolicyTests.swift               (positive and negative capabilities)
c11Tests/MarkdownCorpusIndexTests.swift               (corpus discovery and bounds; hostile repository config)
c11Tests/WorkspaceGitProbeHardeningTests.swift        (hostile fsmonitor and filters in a workspace repository)
c11Tests/MarkdownPresentationTests.swift              (field-local restore fallback)
```

---

## 5. AppleScript and Apple Events

c11 enables the AppleScript bridge:

- `NSAppleScriptEnabled = true` in `Info.plist`.
- Scripting dictionary at `Resources/c11.sdef`.
- Two NSServices entries (`openTab`, `openWindow`) that deliver
  filename pasteboard payloads to `AppDelegate.openTab` /
  `AppDelegate.openWindow`.

What this means in practice:

- Any process the operator has granted `automation.apple-events`
  permission to can invoke the verbs declared in `c11.sdef`. The
  operator's first-time AppleScript invocation triggers the macOS
  consent dialog.
- The Services menu sends folder paths (`NSFilenamesPboardType` /
  `public.plain-text`) to `openTab` / `openWindow`, which in turn
  call `externalOpenDirectories(from:)`.

The `c11.sdef` is the contract for what AppleScript can do; new verbs
require an entry there and must be reflected in this doc.

Evidence:

```
Resources/Info.plist:94-138                            (NSAppleScriptEnabled, OSAScriptingDefinition, NSServices)
Resources/c11.sdef                                     (scripting dictionary; 1.0 changes description text only)
Sources/AppDelegate.swift:7168                         (openWindow service entry)
Sources/AppDelegate.swift:7176                         (openTab service entry)
Sources/AppDelegate.swift:7189                         (openFromServicePasteboard)
```

---

## 6. Camera and microphone

c11 declares `NSCameraUsageDescription` and
`NSMicrophoneUsageDescription` in `Info.plist`. The camera and
microphone are consumed exclusively by web content — the WKWebView UI
delegate routes per-origin permission prompts through the OS dialog,
the operator approves per-origin, and the OS gates actual capture.

c11's first-party Swift code does **not** capture audio or video. If
that ever changes, the threat model section here needs to be rewritten
to describe the capture path, retention, and any storage location.

Evidence:

```
Resources/Info.plist:44-47                             (usage descriptions)
c11.entitlements                                       (device.camera, device.audio-input)
```

---

## 7. JIT, unsigned executable memory, disable-library-validation

These three entitlements are the most-commonly-flagged items by
hardened-runtime auditors. They are all required:

- **`allow-jit` + `allow-unsigned-executable-memory`** — WebKit's
  JavaScript JIT writes executable pages on the fly. Without these,
  every web surface degrades to interpreted JS and many sites break.
- **`disable-library-validation`** — Sparkle (the auto-update
  framework) loads its update-helper bundle and the user-installed
  appcast. WebKit and the Ghostty Zig dylib also load through paths
  that would otherwise fail validation.

Removing any of these breaks first-launch. They are not aspirational
exceptions — every release that ships needs them.

Evidence:

```
c11.entitlements                                       (the three exceptions)
Sources/Update/UpdateController.swift                  (Sparkle wiring; relevant when reviewing the update path)
Sources/Update/UpdateDriver.swift                      (Sparkle delegate / driver glue)
ghostty/                                               (Zig submodule loaded as dylib at runtime)
```

---

## 8. Socket control

The c11 socket is a Unix-domain socket at
`~/Library/Application Support/c11/c11.sock` (release) or
`/tmp/c11-debug*.sock` (debug; tagged builds use
`/tmp/c11-debug-<tag>.sock`). Control modes are defined by
`SocketControlMode`:

| Mode         | Who can connect                                  | Socket perms |
| ------------ | ------------------------------------------------ | ------------ |
| `off`        | Nobody — listener disabled.                       | n/a          |
| `c11Only`    | Processes whose ancestry includes the c11 app.    | `0o600`      |
| `automation` | Any local process with the same uid.              | `0o600`      |
| `password`   | Any local process that authenticates.             | `0o600`      |
| `allowAll`   | Anyone with filesystem access to the socket file. | `0o666`      |

Default mode on a fresh install: `c11Only`. The ancestry gate walks the
connecting process's parents (`TerminalController.parentPid(of:)`,
`TerminalController.swift:1102`) and rejects when c11 is not on the
chain. As of v0.58.0, command *dispatch* lives in per-domain handlers
under `Sources/SocketHandlers/`; the connection ACL and ancestry gate
remain in `TerminalController`. Also as of v0.58.0, panel-scoped
write commands reject empty or absent panel refs outright — a write
can no longer be silently routed to the operator-focused panel by a
malformed ref.

Password mode reads its secret from (in order):
1. `C11_SOCKET_PASSWORD` environment variable
   (`SocketControlSettings.swift:337`).
2. The file `~/Library/Application Support/c11/socket-control-password`.
3. The legacy Keychain item, read lazily at most once per process.

Login (`auth` / `auth.login`) lasts for one connection. The mode is read
per command, so switching to password mode also locks connections that
are already open, and the `markdown.visible --watch` stream checks the
login itself because it bypasses the ordinary dispatcher (1.1, C11-347).
`SocketPasswordModeTests` drive these paths against a stub password
source, never the machine's real one.

Both modes other than `allowAll` use `0o600` socket permissions; only
`allowAll` widens to `0o666`.

The focus-policy negative tests at
`c11Tests/TerminalControllerSocketSecurityTests.swift` exercise the
gate from the test side — they're the regression boundary for the
ancestor-PID and mode-check paths. New socket modes or changes to the
gate require updates to those tests as well as this doc.

Local persistent artifacts written by the socket/telemetry layer: the
panel-metadata snapshots, the mailbox tree, and (new in v0.58.0) the
events NDJSON log under `~/Library/Application Support/c11/` — an
append-only record of panel lifecycle, canonical-metadata changes,
liveness transitions, and mailbox deliveries. All are plaintext,
uid-scoped files in the same trust class: readable by any process
running as the operator. No transcript or scrollback content is
written to any of them.

Since 1.0 the events log is no longer content-free. Every successful
`send`, `send-key`, `paste` and mailbox send writes a `panel.input_sent`
event carrying the caller, the target and the sent text (the first
256 KiB), mailbox `accepted` events carry the message body, and a flag
answered through `c11 feed answer` records the answer on `flag.lowered`.
The text is plaintext, so the history is owner-only and bounded:

- **Modes.** Event files are created `0600` and the `events/` directory
  `0700`. 1.0 created its files `0644` (still inside the `0700`
  `~/Library`). Every retention checkpoint, starting at launch, removes
  group and other access from the history directory (at its target, if
  it is a symlink) and from every event file in it, whichever build wrote
  it. It skips symlinked files and files owned by another user, and never
  changes content.
- **Retention.** Each build label (production, nightly, each tag) keeps
  its history for 14 days by default and within 64 MiB across all its
  launches and numbered generations, deleting the oldest first.
  Settings → Data & Privacy → Keep history for selects 7, 14 or 30 days
  (`c11.activityHistory.retentionDays`). A generation is deleted at the
  first checkpoint after its last write passes the retention age.
  Checkpoints run at launch, on rotation, on policy changes, at clean
  shutdown, at every ten-minute health sample and at least daily,
  including while recording is off.
- **The live file.** The file a running c11 is writing is never deleted.
  It rolls into the numbered generations at 8 MiB and once it has been
  written for a day, so a long session's text ages out while the session
  runs. A launch that reuses a dead launch's pid rolls that launch's file
  aside instead of appending to it, so its age still counts.
- **Text off.** With Keep message and input text off, new records carry
  byte counts only. Existing history is not rewritten; it ages out.

Sent text (a pasted token, say) therefore stays on disk in plaintext,
readable by the operator's uid, until shortly after the retention age:
about a day later with usage analytics on (ten-minute checkpoints), up to
about three with it off (daily checkpoints). Three cases keep it longer:
nothing is pruned while no c11 runs or the Mac sleeps; with
recording off, a running c11 keeps its open file until it quits; and a
production or nightly build that is never launched again keeps its
history, because builds do not prune each other's production or nightly
history. Pruning is a plain unlink, not a secure erase.

Local activity history (1.1, C11-349) adds presence edges (app active,
screen lock, sleep and wake), workspace created, renamed and closed edges
with the workspace title and root directory, ten-minute process health
samples (RSS, CPU, threads) and coalesced terminal-title tails. Settings →
Data & Privacy → Local activity history controls it, separately from
anonymous telemetry:

- **Record usage analytics** (on by default) gates presence, workspace
  and health records.
- **Keep message and input text** (on by default) gates new input,
  mailbox-body and feed-answer text. With it off, those events keep byte
  counts and `text_recorded: false`. Existing history is not rewritten,
  and mail being delivered is not redacted: mailbox delivery files still
  hold the body.
- **Keep history for** selects 7, 14 or 30 days (default 14).

The full recording switch is a defaults key only
(`c11.activityHistory.enabled`). Any build also deletes another debug
or tag build's event files fourteen days after their last write. The
`.activity-history.lock` file is created `0600` like the event files.

`c11 usage` and `c11 report` (1.1, C11-349) are offline CLI commands. They
read the retained event logs plus `~/.claude/projects/**/*.jsonl` and
`~/.codex/sessions/**/*.jsonl` in the CLI process, with no socket, no
network and no writes, and print to stdout. Their output can contain
workspace titles and model IDs.

Other local artifacts added in 1.0, all owner-only:

- The lifecycle journal (`c11/journal/<bundle id>/`: SQLite database and
  an offline spool, directory `0700`, files `0600`). It stores lifecycle
  phases and attribution, never prompt, answer or transcript bodies.
- Staged launch prompts (`c11/runtime/launch-prompts/`, files `0600`,
  created `O_EXCL | O_NOFOLLOW`, removed when the panel closes).
- The messages page (section 4).

Changes to what reaches the socket and agents in 1.0:

- The `c11 ssh` remote command relay is gone: c11 no longer serves
  socket commands back to a remote host, and `c11` inside an ssh
  workspace reports itself unavailable. The SSH browser proxy remains.
- `c11 rpc <method> [json]` is a CLI convenience that sends one raw
  v2 request. It goes through the same connection gate and reaches no
  method the socket did not already expose.
- Mail bodies reach agents' context: a busy agent's hooks
  (`mailbox recv --drain --hook-format … --ack`) inject queued messages as
  `additionalContext` or a Stop-hook reason, and an idle agent receives
  mail as a typed turn. This is an agent-to-agent channel inside the
  semi-trusted tier (section 1): any socket client allowed by the
  current mode can put text in front of an agent. Pushes are withheld
  while the operator has a draft in the target panel.
- `c11 send` refuses to type into an operator draft or a Claude
  question or plan chooser unless `--allow-unguarded` is passed;
  `input-state` reports the prompt state and draft length, never draft
  text.
- Socket callers can no longer change the operator's selected workspace
  (`workspace_switch_blocked`), only explicit window-focus requests
  raise the app, a caller cannot close a workspace owned by another
  window, and near-miss routing keys (`surfaceId`) return
  `invalid_params` instead of falling back to the focused target.
- The socket listens before session restore and returns `not_ready` for
  graph requests until every initial window is installed.
- The bundled `codex` wrapper passes its hook definitions and trust
  hashes as per-process `-c` flags, and OpenCode skill install no
  longer writes persistent plugin files; c11 still makes no persistent
  writes to tenant config.
- `C11_SESSION_HISTORY_RESTORE_FILE` restores one archived session at
  startup and rejects any path, including a symlink, that resolves
  outside that snapshot's own `session-history/` directory.

Changes to what reaches the socket in 1.1:

- Ten markdown reader methods and a `markdown.visible --watch` stream
  (see "Markdown document renderer"). `markdown.navigate` and
  `markdown.open_external` let a caller show any readable file in a
  reader and hand a reader's file to Launch Services; both stay inside
  the socket tier, whose callers can already read and open those files.
- The markdown and feedback methods (`markdown.*`, `feedback.open`) join
  the destructive commands in rejecting an empty or stale target ref
  instead of falling back to the focused target.

The connection reader buffers a request until its newline with no size
cap, as it did before 1.0. A client already past the connection gate
can grow app memory by never sending a newline; that is a
denial-of-service by an already-trusted caller, not a privilege
boundary.

Evidence:

```
Sources/SocketControlSettings.swift:9                  (mode enum; .c11Only)
Sources/SocketControlSettings.swift:79-135             (password source order: env, file, legacy Keychain)
Sources/SocketControlSettings.swift:337                (C11_SOCKET_PASSWORD)
Sources/TerminalController.swift:358                   (accessMode = .c11Only default)
Sources/TerminalController.swift:1102                  (ancestry walk, parentPid(of:))
Sources/TerminalController.swift:1916                  (authResponseIfNeeded, per-connection login)
Sources/TerminalController.swift:2228                  (c11Only connection check)
Sources/TerminalController.swift:2267                  (serveClientCommandLines; watch-stream login check)
Sources/TerminalController.swift:2363                  (serveCommandLines, newline framing)
Sources/Events/EventEmitter.swift:5-21                 (activity history policy keys and defaults)
Sources/Events/EventEmitter.swift                      (panel.input_sent payload, 256 KiB text cap)
Sources/Events/EventLog.swift                          (per-instance log, 0600/0700 modes, age and byte retention)
CLI/ActivityAnalysisCommand.swift                      (offline usage and report reader)
Sources/Journal/JournalStorageLayout.swift             (journal location and permissions)
Sources/LaunchPromptStore.swift                        (staged launch prompts)
Sources/SocketHandlers/                                (per-domain command dispatch, v0.58.0)
c11Tests/TerminalControllerSocketSecurityTests.swift   (focus-policy negative tests)
c11Tests/SocketControlSafetyTests.swift                (SocketPasswordModeTests, C11-347)
```

---

## 9. Release checklist

This threat model is reviewed at release time. The release agent
running `skills/release/SKILL.md` is instructed (in the skill itself)
to grep the release diff for the signals below. When any signal fires,
the agent must:

1. Read this document end-to-end.
2. Update the relevant section if the signal reflects a behavior change.
3. Surface the change in the release notes so reviewers know the
   security posture moved.

Diff signals (single grep expression, callable from the release skill):

```
git diff <last-tag>..HEAD -- \
  Resources/Info.plist \
  c11.entitlements \
  Resources/c11.sdef \
  Sources/SocketControlSettings.swift \
  'Sources/SocketControl*' \
  Sources/AppDelegate.swift \
  Sources/Panels/BrowserPanel.swift \
  Sources/Panels/BrowserPanelView.swift \
  Sources/BrowserWindowPortal.swift \
  Sources/Panels/MarkdownWebRenderer.swift \
  Sources/UntrustedRepositoryGit.swift \
  Sources/MarkdownAssetPolicy.swift \
  Sources/MarkdownCorpusIndex.swift \
  Sources/SocketHandlers/MarkdownFeedbackHandlers.swift \
  Resources/markdown-viewer/ \
  Sources/Events/EventLog.swift \
  Sources/PanelLinkActivation.swift
```

`PanelLinkActivation.swift` owns the only link-driven workspace switch and
the second script handler. The markdown paths cover the second WebKit surface and its only script
bridge; `vendor/MANIFEST.json` moves when a sanitizer or renderer
library is upgraded. `EventLog.swift` owns the data-at-rest posture for
the activity history. `skills/release/SKILL.md` carries its own copy of
this list and must match it.

Within `AppDelegate.swift`, the area around `application(_:open:)`
(currently `Sources/AppDelegate.swift:2594`) is the URL-handler
choke point and warrants extra scrutiny when touched. Any new
`WKWebViewConfiguration` or `WKContentController` configuration is a
trigger because the JS-bridge surface is the chief untrusted-input
vector into the app.

This is a checklist trigger, not a CI gate. The audit's framing was
"release checklist item"; a CI gate adds friction for benign diffs
(NSUsageDescription string tweaks, version bumps) without preventing
the actual risk class — a behavior change a reviewer would still need
to evaluate manually.

---

## Out of scope

Items intentionally not covered here (yet):

- **Sparkle update path.** The auto-update mechanism has its own
  signing chain and trust model (EdDSA via `SUPublicEDKey`); a
  dedicated audit of the update path lives at the Sparkle layer. The
  threat-model doc cross-references Sparkle from section 7 but does
  not duplicate that audit.
- **Operator threat models.** c11 does not defend against the
  operator (see section 1). If the threat model needs to assume a
  hostile operator, it's a different document.
- **Hypothetical surfaces.** mTLS for the socket or sandboxed agent runtimes.
  None exist today. This doc describes only the current posture.
