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
Sources/TerminalController.swift:2220-2222            (c11Only ancestry check)
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

c11 declares itself a `Default` handler for the `http` and `https`
schemes in `Resources/Info.plist`. There is no bespoke `c11://` or
`cmux://` scheme; URL-as-action is constrained to whatever
`AppDelegate.application(_:open:)` does with the incoming URL list.

The handler converts incoming URLs to *folders* via
`externalOpenDirectories(from:)` and opens those folders as new c11
workspaces. Non-folder URLs are not opened by the application
delegate; web URLs hit the system handler chain like any other app.
Only `file://` URLs are considered, and since 1.0 a URL that resolves
(through symlinks) into c11's own app bundle is dropped, so Launch
Services handing c11 itself to c11 no longer suppresses session
restore.

So the URL-handler attack surface is:

- Whatever folder paths an attacker can convince LaunchServices to
  hand to c11 via an `open <url>` call. macOS already constrains this
  to file:// URLs and folders the calling user has read access to;
  c11 does not loosen this.
- Whatever the operator's drag-and-drop / Services menu sends through
  the `openTab` / `openWindow` Apple Events (see section 5).

Evidence:

```
Resources/Info.plist:76-91                             (CFBundleURLTypes)
Sources/AppDelegate.swift:2594                         (application(_:open:))
Sources/AppDelegate.swift:7237                         (externalOpenDirectories)
Sources/AppDelegate.swift:~580-615                     (FinderServicePathResolver.orderedUniqueDirectories)
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

There is no explicit JS bridge from web content to the c11 socket. The
browser panel communicates with c11 via `WKContentController` script
message handlers configured per panel; new handlers must be added to
this doc when introduced (the diff signal in section 9 catches this).

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
`browser state load` writes cookies for the target URL only, and writes
local and session storage only after navigation settles on the expected
origin; a wrong-origin redirect returns `navigation_failed`.

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
Sources/SocketHandlers/BrowserHandlers.swift           (cookies, state load, profiles)
Sources/SocketHandlers/BrowserQueryHandlers.swift      (init scripts and styles, off-main JS)
Sources/Messages/MessagesPage.swift                    (messages page renderer, CSP, JSON escaping)
Sources/Panels/BrowserPanelView.swift                  (panel host)
Sources/BrowserWindowPortal.swift                      (popout / portal layer)
Sources/BrowserSnapshotStore.swift                     (snapshot capture)
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
Sources/AppDelegate.swift:7172                         (openWindow service entry)
Sources/AppDelegate.swift:7180                         (openTab service entry)
Sources/AppDelegate.swift:7193                         (openFromServicePasteboard)
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
`TerminalController.swift:1096`) and rejects when c11 is not on the
chain. As of v0.58.0, command *dispatch* lives in per-domain handlers
under `Sources/SocketHandlers/`; the connection ACL and ancestry gate
remain in `TerminalController`. Also as of v0.58.0, panel-scoped
write commands reject empty or absent panel refs outright — a write
can no longer be silently routed to the operator-focused panel by a
malformed ref.

Password mode reads its secret from (in order):
1. `C11_SOCKET_PASSWORD` environment variable
   (`SocketControlSettings.swift:297`).
2. The file `~/Library/Application Support/c11/socket-control-password`.

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
The log files are created with default permissions (`0644`) inside the
`0700` `~/Library`, so they stay private to the operator's uid, but each
launch writes a new per-instance file and old instance files are never
pruned. Anything an agent types into another panel through c11 (a
pasted token, say) therefore persists in plaintext until the operator
deletes it.

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
  (`mailbox recv --drain --hook-format …`) inject queued messages as
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

The connection reader buffers a request until its newline with no size
cap, as it did before 1.0. A client already past the connection gate
can grow app memory by never sending a newline; that is a
denial-of-service by an already-trusted caller, not a privilege
boundary.

Evidence:

```
Sources/SocketControlSettings.swift:9                  (mode enum; .c11Only)
Sources/SocketControlSettings.swift:297                (C11_SOCKET_PASSWORD)
Sources/TerminalController.swift:358                   (accessMode = .c11Only default)
Sources/TerminalController.swift:1096                  (ancestry walk, parentPid(of:))
Sources/TerminalController.swift:2222                  (c11Only connection check)
Sources/TerminalController.swift:2300                  (serveCommandLines, newline framing)
Sources/Events/EventEmitter.swift                      (panel.input_sent payload, 256 KiB text cap)
Sources/Events/EventLog.swift                          (per-instance log, one rolled generation)
Sources/Journal/JournalStorageLayout.swift             (journal location and permissions)
Sources/LaunchPromptStore.swift                        (staged launch prompts)
Sources/SocketHandlers/                                (per-domain command dispatch, v0.58.0)
c11Tests/TerminalControllerSocketSecurityTests.swift   (focus-policy negative tests)
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
  Sources/BrowserWindowPortal.swift
```

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
- **Hypothetical surfaces.** A `c11://` URL scheme, mTLS for the
  socket, or sandboxed agent runtimes — none exist today. This doc
  describes only the current posture.
