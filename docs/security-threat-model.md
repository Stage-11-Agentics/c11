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
  inside a c11 surface — typically Claude Code, Codex, shell sessions.
  Treated as semi-trusted by default: the socket-control mode
  (`cmuxOnly`) limits commands to processes that are descendants of the
  c11 app, but those processes can run arbitrary code in the operator's
  environment. The trust delegation is "the operator put this agent
  here on purpose" — c11 doesn't sandbox agents beyond what macOS
  hardened runtime gives it.

- **Web content in WKWebView (untrusted).** Any page loaded into a c11
  browser surface. Cannot reach the c11 socket (no JS bridge from web
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
Sources/TerminalController.swift:1594-1596            (cmuxOnly ancestry check)
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
Sources/AppDelegate.swift:2301                         (application(_:open:))
Sources/AppDelegate.swift:5804                         (externalOpenDirectories)
```

---

## 4. WKWebView and web content

c11 hosts web content via WKWebView. The substrate is shared between
the embedded browser surface and any markdown / preview surface that
renders HTML. The relevant ATS posture:

- `NSAllowsArbitraryLoadsInWebContent = true` — required by the
  embedded browser to allow non-https sites the operator points at.
  This relaxation is scoped to web content; it does not relax the
  app's own networking.
- One `NSExceptionDomains` entry: `c11-loopback.localtest.me` allows
  `http://` for the loopback subdomain c11 uses to render local
  developer servers.

There is no explicit JS bridge from web content to the c11 socket. The
browser surface communicates with c11 via `WKContentController` script
message handlers configured per-panel; new handlers must be added to
this doc when introduced (the diff signal in section 9 catches this).

Evidence:

```
Resources/Info.plist:162-176                           (NSAppTransportSecurity)
Sources/Panels/BrowserPanel.swift                      (browser substrate)
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
Resources/Info.plist:74-138                            (NSAppleScriptEnabled, OSAScriptingDefinition, NSServices)
Resources/c11.sdef                                     (scripting dictionary)
Sources/AppDelegate.swift:5711-5717                    (openWindow service entry)
Sources/AppDelegate.swift:5719-5725                    (openTab service entry)
Sources/AppDelegate.swift:5732                         (openFromServicePasteboard)
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
`~/Library/Application Support/c11mux/c11.sock` (release) or
`/tmp/cmux-debug*.sock` (debug). Control modes are defined by
`SocketControlMode`:

| Mode         | Who can connect                                  | Socket perms |
| ------------ | ------------------------------------------------ | ------------ |
| `off`        | Nobody — listener disabled.                       | n/a          |
| `cmuxOnly`   | Processes whose ancestry includes the c11 app.    | `0o600`      |
| `automation` | Any local process with the same uid.              | `0o600`      |
| `password`   | Any local process that authenticates.             | `0o600`      |
| `allowAll`   | Anyone with filesystem access to the socket file. | `0o666`      |

Default mode on a fresh install: `cmuxOnly`. The ancestry check at
`TerminalController.swift:1594-1596` walks the connecting process's
parents and rejects when c11 is not on the chain.

Password mode reads its secret from (in order):
1. `CMUX_SOCKET_PASSWORD` environment variable.
2. The file `~/Library/Application Support/c11mux/socket-control-password`.

Both modes other than `allowAll` use `0o600` socket permissions; only
`allowAll` widens to `0o666`.

The focus-policy negative tests at
`c11Tests/TerminalControllerSocketSecurityTests.swift` exercise the
gate from the test side — they're the regression boundary for the
ancestor-PID and mode-check paths. New socket modes or changes to the
gate require updates to those tests as well as this doc.

Evidence:

```
Sources/SocketControlSettings.swift                    (mode enum + defaults)
Sources/TerminalController.swift:66                    (accessMode = .cmuxOnly default)
Sources/TerminalController.swift:1594-1596             (ancestry check)
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
(currently `Sources/AppDelegate.swift:2301`) is the URL-handler
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
