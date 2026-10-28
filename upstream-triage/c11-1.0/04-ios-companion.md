# 04 · A c11 iOS companion app

**Needs you:**

1. **Do you want phone reach at all, or only push?** If push alone is enough, rung 1 below is a 10-minute settings change you can make today, and nothing goes into 1.0. If you want to *read and reply* from the phone, the answer is rung 3 (a tailnet web view), and the open question becomes whether it lives in c11 or in Overwatch (question 2).
2. **Where should a phone-facing fleet view live: c11 or Overwatch?** In c11 it needs a new primitive: a network listener, the first one c11 would have. In Overwatch it is a page on a service that already exists to watch the fleet, and c11 stays a Unix-socket-only host. My gut says Overwatch.
3. **Should the fix to the flag notification path be in 1.0?** It is small. Today a flag never reaches the menu bar extra (contrary to the skill), and the Notification Command hook gets no workspace or tab IDs. Both are cheap to fix and make every rung below better. Yes means one small ticket; no means the skill text gets corrected instead.

**Recommendation in one line:** don't build a native iOS app, not in 1.0 and probably never. Climb the ladder instead: push through the ntfy server Stage 11 already runs (now), then a tailnet-only web view of the fleet (later, ideally in Overwatch).

---

## What cmux built

cmux's iOS app is a full second product, not a companion widget. Everything below was read from `upstream/main` at `920ff39ff7` (2026-10-01) and from the installed cmux 0.64.25 bundle.

### What it does

The app is a SwiftUI iOS and iPadOS shell over a shared mobile core (`ios/README.md`). The screens are listed in its changelog (`ios/CHANGELOG.md`, versions 1.0.2 to 1.0.6):

| Screen | What it does | Source |
|---|---|---|
| Sign-in | Stack Auth: Apple, Google or an email code. Required. | `ios/README.md` |
| Your Computers | One row per paired Mac, with online and last-seen state; tap to reconnect | `ios/CHANGELOG.md` 1.0.3 |
| Workspace list and detail | Mirrors the Mac's workspaces and terminals | `ios/README.md`; `Packages/iOS/CmuxMobileWorkspace` |
| Terminal | Live terminal rendering, plus an iMessage-style composer that keeps a draft per terminal, and "View as Text" | `ios/CHANGELOG.md` 1.0.3 (#5876, #5875); `Packages/iOS/CmuxMobileTerminal` |
| Feed | Agent questions and approvals, with replies and full-text reading | #10218 (merged 2026-09-30) |
| Task Composer | Starts a new agent task on the Mac: picks a model and effort, picks a directory, attaches files | Feature flag `mobileTaskComposer` ("Enables the iOS New Task composer, including task model discovery, directory picking, and attachment staging", strings in the cmux binary); `Mobile­Task­*` types in the Mac binary; #15797 |
| Browser | Streams a browser pane from the Mac | #14301; `Packages/iOS/CmuxMobileBrowserStream` |
| Also | Changes (diffs), SSH, Cloud VMs, iOS Simulator streaming | `Packages/iOS/CmuxMobileChanges`, `CmuxMobileSSH`, `CmuxMobileCloud`; `docs/ios-simulator-streaming-v2.md` |

### How it connects to the Mac

- **Transport.** The transport is Iroh, a peer-to-peer QUIC library from n0, linked into the Mac app. The Mac binary contains Iroh's relay, hole-punching and pkarr (`dns.iroh.link`) code paths, plus an mDNS service type `_cmux-iroh._udp` for local discovery (from `strings` on `/Applications/cmux.app/Contents/MacOS/cmux`). There is also a Tailscale route: the iOS transport has a `TailscaleStatusMonitor` and a `CmxSystemTailscaleRouteAuthority`, and it refuses raw Tailscale TCP without an authorization context (`Packages/iOS/CmuxMobileTransport/Sources/CmuxMobileTransport/CmxNetworkByteTransport.swift:13-46`).
- **More than one transport.** Three generations coexist: legacy Tailscale TCP, Iroh v1 (`docs/iroh-app-transport-architecture.md`) and a rebuilt "IRX" stack (`docs/irx-transport-design.md`). The IRX design doc says the earlier stack's failure modes were structural. To get there, cmux carries forks of Iroh, its QUIC library and `iroh-ffi`.
- **Relays.** Relays are cmux's own: seven at `*.relay.cmux.dev` across the US, EU and APAC (`config/iroh/managed-relay-catalog.json`), run under an Iroh Services project. Relay access is tied to the account. A separate Vercel service, `services/iroh-relay-minter`, is the only holder of the Iroh Services credential. It mints endpoint-scoped `relay:use` tokens (`services/iroh-relay-minter/README.md`), and the app gets short-lived relay tokens from `POST /api/relay/token`.
- **Pairing.** Pairing works through the account. First, turn on Settings > Mobile > Enable iOS pairing on each Mac; it is off by default (`ios/CHANGELOG.md` 1.0.4). Then sign in to the same cmux account on the phone and the Mac shows up. Pair grants are signed by the backend. QR is a secondary path. Even offline LAN pairing needs two endpoint attestations from the backend: "Possession of the QR payload is never sufficient" (`docs/iroh-offline-pairing-v1.md`).
- **Where the Mac side runs.** It runs inside the cmux app (`Sources/Mobile/MobileHostService.swift`, about 2,700 lines), not in a separate daemon.
- **Hosted services.** Besides the relay fleet, the app depends on these cmux-run services:
  - Stack Auth (`api.stack-auth.com`) for accounts.
  - Two Cloudflare Workers, each backed by Durable Objects: `workers/iroh-v2`, which owns device registration, challenges, permissions and endpoint ownership (the ownership map is in a shared PlanetScale Postgres database), and `workers/presence`, which handles presence heartbeats, a 15-second heartbeat with a 45-second offline timeout, and a WebSocket for connectivity invalidation (`workers/iroh-v2/README.md`, `workers/presence/README.md`).
  - The cmux.com Next.js API, for device tokens and push (`web/app/api/device-tokens/route.ts`, `web/app/api/notifications/push/route.ts`).

### Push notifications

The path is Mac → `cmux.com/api/notifications/push` → APNs, signed with cmux's own `.p8` key (`CMUX_APNS_KEY_P8`, in `web/app/api/notifications/push/route.ts`, `web/services/apns/`).

- **Encryption.** Since #12384 (2026-09-17), pushes and replies are end-to-end encrypted. The phone decrypts them in a Notification Service Extension (`ios/NotificationService`). Getting decryption to work on release builds took four fixes in one week: #14039, #14110, #14267 and #14292.
- **Reply from the notification.** Pushes carry a `replyShape`, a workspace ID and a surface ID. Replies wait encrypted in the presence worker until the Mac decrypts and injects them.
- **When the phone buzzes.** A Mac setting picks "always" (the default, `Sources/Cloud/PhoneForwardingMode.swift:11`) or "only when away" (locked, asleep or idle). There is also a "hide content" option.

### What the phone can do to the Mac

The phone has a lot of power over the Mac:

- type into and paste into any terminal;
- approve agent permission prompts;
- read files and diffs;
- drive browser and simulator panes;
- create workspaces with an arbitrary `initial_command` and environment. This is how the Task Composer works (#7670, +18k lines).

In effect, anyone holding the phone's account and grant has remote code execution on the Mac. Authorization has two layers: an Iroh EndpointID authenticated over TLS, and a signed pair grant bound to both endpoints. The Mac rechecks with the broker at least every 30 seconds (`Sources/Mobile/MobileHostService+TicketAuthorization.swift`). There are MDM policies that turn remote control off.

### The `cmux-terminal-client` xcframework

It does not belong to the Mac pairing path. It is a Rust crate, `cmux-tui/crates/cmux-terminal-client`: a static C ABI over `cmux-remote`, with `ghostty-vt` and in-process WireGuard. CI builds it as a 116 to 194 MB xcframework, and it shipped five prereleases between 2026-09-30 and 2026-10-01. It feeds the iOS **Cloud VM** client (`Packages/iOS/CmuxMobileCloudUI`). In other words, it is cmux's account-backed platform reaching onto the phone, not a companion to a Mac. It has nothing for c11 to reuse.

### Distribution

The app ships through TestFlight. Version 1.0.6 is the current beta (2026-09-23). External builds go to the "Founder's Edition" and "Pro" tester groups, which are paid tiers (`ios/README.md`, TestFlight section). An App Store archive lane exists (#16486, fastlane screenshot automation in `ios/fastlane`, `ios/AppStoreReview`), but I found no evidence of a public App Store release. iOS builds are version-locked to Mac builds: 1.0.6 requires Mac 0.64.25 or later (`ios/CHANGELOG.md` 1.0.6).

### What it costs them

Counted with `git log 53910919..upstream/main` over `ios`, `Packages/iOS`, `Packages/Shared/{CmuxIrohTransport,CMUXMobileCore}`, `Packages/macOS/CmuxMobileHost`, `workers/{iroh-v2,presence}`, `services/iroh-relay-minter` and `web/services/iroh`:

| Measure | Value |
|---|---|
| Commits since the first prototype (2026-05-11, "Add Swift iOS mobile prototype") | 1,800 |
| September alone | 694, about 10% of all cmux commits that month |
| Distinct authors | 15. One author wrote about 60% of the iOS commits, which is a bus-factor risk. |
| Share of all merged PRs since May | about 12 to 14% (about 800 PRs, counted from `(#N)` suffixes via `gh`) |
| Code (Swift, Rust, TypeScript, tests included) | about 530,000 lines. `Packages/iOS` alone is about 359,000. |
| Mac-side `Sources/` files with "mobile" in the path | 89 |
| Hosted services to run | Stack Auth, two Cloudflare Workers, Vercel minter, PlanetScale, APNs sender, Iroh Services |

Four bug classes keep recurring:

- **Pairing and startup.** On 2026-09-28 four pairing performance changes landed and were reverted the same day.
- **Push decryption.** Four fixes in one week (#14039, #14110, #14267, #14292).
- **Reconnects through background suspension and network changes.** `docs/ios-network-reliability.md`, `docs/ios-connectivity-soak.md`.
- **Mac and iOS version skew.**

A full Iroh v2 security audit also lives in `docs/iroh-v2/SECURITY-AUDIT.md`.

**In short:** to give a phone remote control of terminals, cmux built a whole platform:

- an account system;
- a device registry;
- a presence service;
- a relay fleet with a token broker;
- a push broker;
- three generations of transport.

It needs a team to maintain. Most of it exists because cmux serves strangers across arbitrary networks. Atin's tailnet already solves that problem.

## What c11 has today

Cited from c11 `main` (read only).

- **No network listener.** The control socket is Unix-domain only (`Sources/TerminalController.swift:1034-1058`). Its modes are `off`, `c11Only` (the default), `automation`, `password` and `allowAll` (`Sources/SocketControlSettings.swift:7-13`). The only TCP listeners belong to `c11 ssh` remote workspaces, and they are pinned to `127.0.0.1` (`Sources/Workspace.swift:2699-2710, 3420-3426`). The `WorkspaceRemoteCLIRelayServer` checks a token, then forwards loopback TCP to the Unix socket (`Sources/Workspace.swift:2950-3110`). It is the closest existing pattern for an authenticated bridge.
- **The attention model** is `flag`, `flag_caller_surface_id` and `suppressed`, stored as reserved metadata (`Sources/SurfaceMetadataStore.swift:21-23`). It is mutated through `AttentionModel.swift:384` and emits `flag.raised`, `flag.lowered`, `flag.suppressed` and `flag.unsuppressed` (`Sources/AttentionModel.swift:401-449`). `flag.list` returns refs, reason, `raised_at` and caller (`Sources/SocketHandlers/AttentionHandlers.swift:166-186`).
- **Flags do not reach the menu bar extra.** The menu bar extra builds its badge and items only from `notificationStore.notifications` (`Sources/AppDelegate.swift:13450-13493`). Flag delivery deliberately skips that list (`Sources/TerminalNotificationStore.swift:1029-1031`), so a flag escalates as a macOS banner, not in the menu bar. **The skill says otherwise** (`skills/c11/SKILL.md:60`).
- **Notifications.** c11 posts macOS banners with only a "Show" action and no reply (`Sources/AppDelegate.swift:12631-12649`). A flag notifies even when the tab is suppressed (`Sources/TerminalNotificationStore.swift:1032-1112`).
- **There is already an external delivery hook.** Settings > Notification Command runs `/bin/sh -c <cmd>` with `CMUX_NOTIFICATION_TITLE`, `CMUX_NOTIFICATION_SUBTITLE` and `CMUX_NOTIFICATION_BODY` in the environment (`Sources/TerminalNotificationStore.swift:510-531`; the settings UI is at `Sources/c11App.swift:6105-6114`). It fires for flags too, but only after the macOS banner posts successfully, and it gets no workspace or tab IDs. The variables still use the `CMUX_` prefix.
- **Events.** There is one NDJSON file per instance at `~/Library/Application Support/c11/events/events-<instance>.ndjson` (`Sources/Events/EventLogLayout.swift:32-39`). The envelope carries `seq, ts, type, workspace, surface, payload` (`Sources/Events/EventEnvelope.swift:28-36`). It is documented as the contract, readable even with the app closed (`skills/c11/references/events.md`). `c11 events tail -f --filter type=flag.raised` is a complete source for a forwarder.
- **Read, reply and launch** all exist and run off-main without stealing focus: `read-screen`, `send` (it requires an explicit surface), and `launch-agent` with `--flag` and `--suppressed` (`CLI/c11.swift:2238, 2765-2832`; `Sources/SocketHandlers/SocketDispatch.swift:63-72`). One catch: only a real keystroke auto-lowers a flag (`Sources/GhosttyTerminalView.swift:5620-5626`), so a remote `send` would also need to call `lower-flag`.
- **Fleet data.** `tree --json` lacks agent fields. Type, model, lifecycle and description are per-surface metadata (`Sources/SurfaceMetadataStore.swift:12-23`), and `tree --report` already joins them in (`CLI/c11.swift:13383-13480`).
- **Prior design.** `docs/c11v-design.md` puts phone and web viewers in step 6, as clients of the same `c11d` protocol that c11 uses ("Steer the fleet from a phone"). Its prerequisite is a `c11d` on every host (steps 1 and 2). `ROADMAP.md:9` lists "Remote and cloud fleets". No Lattice ticket mentions iOS or mobile.
- **Stage 11 already runs a push server.** `ntfy.stage11.ai` on pine (`code/platform/infrastructure-summary.md:35`; config in `code/pine-server/pine.py:1322-1331`). Gatus already alerts through it. The server config sets no `upstream-base-url` (see the rung 1 caveat).

## The gap

| Capability | cmux iOS | c11 today | What closing it needs |
|---|---|---|---|
| Phone knows an agent needs you | Push via own APNs broker, "only when away" mode | macOS banner only; Notification Command hook with no IDs | A forwarder to ntfy (exists) |
| Phone shows the fleet | Workspace list, presence | Nothing off the Mac | Something that serves `tree --report` and `flag.list` over the tailnet |
| Read a tab | Live terminal stream | `read-screen` over the local socket only | Same server, read-only text |
| Reply or approve | Composer, Feed, reply from push | `send` over the local socket only | An authenticated write path, plus `lower-flag` |
| Launch a task | Task Composer | `launch-agent` over the local socket only | Same write path, constrained |
| Works when the Mac is asleep | No (presence shows offline) | No | Agents on Atlas (topic 02), not a phone app |

The real gap is not the iOS app. It is that **c11 has no authenticated way in from off the Mac.** Topic 02 (agents on SSH hosts) and the `c11d` design both hit the same wall. Whatever answers it there also answers the phone.

## Proposed c11 1.0 shape

### Atin's world changes the problem

- **Tailscale removes most of what cmux built.** Every machine, the iPhone included, is on one tailnet. Identity, NAT traversal, encryption and device ACLs come free, so there is no need for accounts, relays, a device registry or presence. cmux even added a Tailscale route itself (`CmxNetworkByteTransport.swift`).
- **One user.** No teams or account ownership, which removes most of `workers/iroh-v2`.
- **Atlas is always on and Hyperion roams.** The phone matters most for agents on Atlas while Atin is away from both Macs. A sleeping Hyperion is unreachable from any phone design, so agent placement (topic 02) matters more than the client.
- **Push already exists.** `ntfy.stage11.ai` is running.
- **c11 is a public product.** Anything that ships *in c11* must work for other users too. Those users don't have Atin's tailnet or ntfy, and c11 cannot hold an APNs key for them without running a push broker, which is exactly cmux's platform turn.

### The ladder (cheapest first)

| Rung | What | Cost | Value | Stops being enough when |
|---|---|---|---|---|
| **1. Notification Command → ntfy** | Paste one `curl` into Settings > Notification Command, then subscribe in the ntfy iOS app | 10 minutes, zero code | Phone buzzes on every c11 notification, flags included | You want only flags, a deep link, or IDs in the message. You want to *act* without walking to a Mac. |
| **2. Event forwarder → ntfy** | A ~100-line script (or an Overwatch job) that runs `c11 events tail -f --filter type=flag.raised` on each Mac, adds names from `get-metadata`, and posts to ntfy with priority, tags and a click URL. Optionally gate on `last_seen_at` / screen lock for "only when away" | S. Lives outside c11. | Flag-only, named, prioritized pushes from Atlas and Hyperion. ntfy action buttons can call an HTTP endpoint (for rung 3). | You want to read the screen or reply |
| **3. Tailnet web view** | A small HTTP service on each Mac, bound to the tailnet with `tailscale serve`. It shells out to `c11 tree --report`, `flag.list`, `read-screen`, `send` and `lower-flag`, and serves one mobile page. Add to Home Screen as a PWA. | M | Read and reply from the phone. Covers about 80% of cmux's app for one operator. | You need live terminal streaming, background push without ntfy, or Live Activities |
| **3b. Shortcuts** | iOS Shortcuts that call rung 3's endpoints ("Get contents of URL"): "What's flagged?" through Siri, "Reply to flagged" with dictation | S on top of 3 | Voice: fits how Atin already works | Needs rung 3 underneath. A home-screen *widget* needs either an app or a third-party widget host (Scriptable-style). **Not verified.** |
| **4. Native iOS app** | SwiftUI client against rung 3's API, with its own APNs push, widgets and Live Activities | L to XL | Polish, lock-screen glanceability, reliable background push | Never, for one operator |

Two side notes:

- **Claude sessions may already be covered.** Claude Code's own Remote Control lets the Claude app drive a running Claude Code session. That partly covers reply for Claude sessions, but not for Codex, Grok or Kimi, and not with c11's flags. It is worth a look before building rung 3. **Not verified here** for Atin's setup.
- **The rung 1 and 2 caveat: background push.** From ntfy's docs, not verified here: the ntfy iOS app gets instant background delivery from a self-hosted server only if the server sets `upstream-base-url: https://ntfy.sh`. With it, ntfy.sh receives a poll request carrying only a message ID and wakes the phone through APNs; the phone then fetches the content from `ntfy.stage11.ai` over the tailnet. Without it, iOS delivery is delayed. pine's config has no such line (`pine-server/pine.py:1325-1329`). Adding it is a one-line change, and the message content stays on pine. The phone also needs Tailscale connected to reach `ntfy.stage11.ai`, because that name resolves only through split DNS.

### If it ever became an app: the sketch

Atin asked what it would look like, so here are the five screens. Each one is a view of an existing c11 primitive.

**1. Fleet at a glance** (`tree --report` across Atlas and Hyperion)

```
┌──────────────────────────────┐
│ c11              ● Atlas     │
│                  ○ Hyperion  │  ← Hyperion asleep, last seen 14m
├──────────────────────────────┤
│ ⚑ 2 flagged   ◐ 5 waiting    │
│ ● 9 working   ○ 3 idle       │
├──────────────────────────────┤
│ Atlas · Lattice Hosted       │
│  ⚑ Merge Captain   Opus  6m  │
│  ● C11-241 Impl    Sonnet 2m │
│  ◐ Reviewer        Codex 11m │
│ Atlas · Overtone             │
│  ● Eval sweep      Sonnet 1m │
└──────────────────────────────┘
```

**2. Flagged and waiting** (`flag.list`, waiting tabs; flags first, then oldest waiting)

```
┌──────────────────────────────┐
│ Needs you                  2 │
├──────────────────────────────┤
│ ⚑ Merge Captain · 6m         │
│   "Need a call on squash vs  │
│    rebase for #461"          │
│   [Read]  [Reply]  [Dismiss] │
├──────────────────────────────┤
│ ⚑ C11-238 Delegator · 22m    │
│   "Screen locked; tagged     │
│    build can't open a tab"   │
│   [Read]  [Reply]  [Dismiss] │
├──────────────────────────────┤
│ ◐ Reviewer · waiting 11m     │
└──────────────────────────────┘
```

**3. Read a tab** (`read-screen --lines 60`, refreshed on pull; text, not a terminal emulator)

```
┌──────────────────────────────┐
│ ‹ Merge Captain   Opus · ⚑   │
│ Reviewing #461 for merge;    │  ← live description
│ next, pick merge strategy.   │
├──────────────────────────────┤
│ … PR #461 has 14 commits.    │
│ Squash loses the bisect      │
│ trail; rebase keeps it but   │
│ needs a force-push.          │
│                              │
│ Which do you want?           │
│  1. Squash                   │
│  2. Rebase and merge         │
│ ❯                            │
├──────────────────────────────┤
│ [ 1 ] [ 2 ]  [ Esc ]  [ ⏎ ]  │  ← quick keys parsed from screen
│ ┌──────────────────────┐ 🎙  │
│ │ Reply…               │  ➤  │
│ └──────────────────────┘     │
└──────────────────────────────┘
```

**4. Reply / approve** (`send` plus `lower-flag --by operator`, with a confirmation step for anything that isn't a plain answer)

**5. Launch a task** (`launch-agent` from saved `c11 config` presets only)

```
┌──────────────────────────────┐
│ New task on  [Atlas ▾]       │
│ Workspace    [Overtone ▾]    │
│ Agent        [Opus planner▾] │  ← saved c11 config presets only
│ ┌──────────────────────────┐ │
│ │ Re-run the eval sweep on │ │
│ │ the September corpus…    │ │
│ └──────────────────────────┘ │
│ ☐ Flag this mission          │
│             [ Launch ]       │
└──────────────────────────────┘
```

### What it must never do

1. **Never write tenant config.** No hooks into `~/.claude`, `~/.codex` and so on. Everything it shows comes from c11's own socket, metadata and screen reads.
2. **Never be a terminal.** No raw keystroke streaming, no arbitrary shell, no `send` to a plain shell tab. Replies go only to tabs that carry agent metadata, and only as text-plus-Enter or a parsed quick key.
3. **Never launch arbitrary commands.** Launch is limited to saved `c11 config` presets, on a workspace that already exists.
4. **Never listen beyond the tailnet,** and never require an account. Identity comes from Tailscale (`tailscale serve` passes `Tailscale-User-Login`), with an allowlist of one.
5. **Never steal focus or wake a Mac's screen.** Socket rules already guarantee the first (`Sources/TerminalController.swift:241-266`).
6. **Never put content on a third party in clear text.** That rules out Pushover-style relays of terminal text; ntfy's upstream poll carries only an ID.

### Fit to doctrine

Rungs 1 to 3 add **no new primitive to c11**. They compose `events tail`, `tree --report`, `flag.list`, `read-screen`, `send` and `launch-agent`, which is "primitives before policy" (`PHILOSOPHY.md`). They observe from outside and touch no agent config.

The doctrine pressure point is rung 3 living *inside* c11, because that would make c11 a network service. There are three ways to place it:

| Option | Pros | Cons |
|---|---|---|
| **A. In Overwatch** (recommended) | Overwatch is already the fleet view, a Lattice extension shown as a browser tab (memory: Overwatch = Lattice substrate). It already spans Atlas and boxes, so it can show Atlas and Hyperion side by side. c11 stays socket-only. | Ties phone reach to Stage 11's stack, so public c11 users get nothing |
| **B. A separate script in the c11 repo** (`scripts/` or `tools/`) | Ships with c11, so other users can run it. No in-app listener. | Unowned tooling rots. Each user has to set up their own tailnet or proxy. |
| **C. In-app listener** (`c11 serve --tailnet`, built on the token relay at `Workspace.swift:2950`) | Best for public users; one switch in Settings | c11's first network-reachable surface, with a real security review and a new attack surface. Overlaps the `c11d` P1 work and should wait for it. |

## Effort and risk

| Item | Size | What could go wrong |
|---|---|---|
| Rung 1 (settings) | XS | It fires for every notification, not only flags, so it gets noisy. It also needs macOS notification permission (`TerminalNotificationStore.swift:1320-1333`). |
| Fix flag notification path (question 3) | S | Pass `C11_NOTIFICATION_WORKSPACE_ID` / `TAB_ID` / `KIND` to the Notification Command (keeping the `CMUX_` names as aliases), and have the menu bar extra observe `SurfaceAttentionIndex`. Low risk, but `TerminalNotificationStore` is on a busy path. |
| Rung 2 forwarder | S | A rotated or new event file per instance needs a re-open, so use `events tail`, not raw `tail`. ntfy delivery latency without `upstream-base-url`. |
| Rung 3 web view | M | Security is the whole risk: a write path to agent PTYs reachable from any tailnet device. Mitigations: `tailscale serve` only, user-login allowlist, and agent tabs only. `send` doesn't lower flags, so the bridge must do it. `read-screen` on never-shown background workspaces may fail (cmux #14673, landscape bug 9). |
| Rung 4 native app | L to XL | App Store review, APNs credentials and a push sender, version skew with the Mac, and background reconnects. cmux's 1,800 commits are the evidence. It also needs an Apple Developer team. The current one, `JS6GYLT553`, is set up for macOS signing only (`code/platform/apple.md`). |

## Recommendation

- **Not in 1.0.** A native app does not belong in this release or on the roadmap. cmux needed accounts, five hosted services and about half a million lines to do it. Tailscale plus ntfy gives one operator most of the value for almost nothing.
- **Now, outside 1.0:** rung 1 today (you can do it yourself; the command is below), plus `upstream-base-url` on pine's ntfy.
- **In 1.0, optional:** the small flag-notification fix (question 3), because it makes every later rung better and corrects the skill.
- **Later:** rung 2, then rung 3 in Overwatch, once topic 02 decides where agents live. A phone view is most useful for Atlas-hosted agents.
- **Never:** rung 4, unless c11 decides to become an account-backed platform. That would be a different product.

Rung 1, ready to paste into Settings > Notification Command (topic name is a suggestion):

```sh
curl -s -H "Title: $CMUX_NOTIFICATION_TITLE" -H "Tags: c11" -d "$CMUX_NOTIFICATION_SUBTITLE $CMUX_NOTIFICATION_BODY" https://ntfy.stage11.ai/c11-hyperion
```

## Open questions

1. Push only, or read and reply? (Needs-you 1.)
2. Overwatch or c11 for the web view? (Needs-you 2.)
3. Flag notification fix in 1.0? (Needs-you 3.)
4. Is Tailscale always connected on Hoplight 17? Every rung except a public relay assumes it is. If it is on-demand only, rung 1 needs ntfy reachable through Cloudflare Access instead.
5. Does Claude Code Remote Control already cover your Claude sessions well enough that the reply rung only matters for Codex, Grok and Kimi? If so, rung 3's priority drops.
6. Should "only when away" use c11's `last_seen_at` and screen-lock state? That is the one cmux push feature worth copying, and c11 already has the signal (`last_seen_at` per tab, skill `SKILL.md` cross-cutting rules). Whether it is exposed to an external forwarder is **not verified**.
