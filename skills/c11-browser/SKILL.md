---
name: c11-browser
version: 1
description: Browser automation for c11 browser panels (formerly tabs) (WKWebView-backed). Use to open sites, interact with pages, wait for state changes, extract data, save/load auth state, and validate UI changes without leaving c11. Prefer this over Chrome MCP whenever c11 is running.
---

# c11 Browser Automation

Use this skill for browser tasks inside c11 webviews. Browser panels are a native panel type, scriptable alongside terminals and markdown viewers from the same `c11` CLI. Prefer this over Chrome MCP whenever c11 is running: lighter, integrated, no stray Chrome windows.

## Core Workflow

1. Open or target a browser panel.
2. Verify navigation with `get url` before waiting or snapshotting.
3. Snapshot (`--interactive`) to get fresh element refs.
4. Act with refs (`click`, `fill`, `type`, `select`, `press`).
5. Wait for state changes.
6. Re-snapshot after DOM/navigation changes.

```bash
c11 --json browser open https://example.com
# use returned panel ref, for example: panel:7

c11 browser panel:7 get url
c11 browser panel:7 wait --load-state complete --timeout-ms 15000
c11 browser panel:7 snapshot --interactive
c11 browser panel:7 fill e1 "hello"
c11 --json browser panel:7 click e2 --snapshot-after
c11 browser panel:7 snapshot --interactive
```

## Panel Targeting

```bash
# identify current context
c11 identify --json

# open routed to a specific topology target
c11 browser open https://example.com --workspace workspace:2 --window window:1 --json
```

Notes:
- CLI output defaults to short refs (`panel:N`, `area:N`, `workspace:N`, `window:N`).
- UUIDs are still accepted on input; only request UUID output when needed (`--id-format uuids|both`).
- Keep using one `panel:N` per task within the current c11 process unless you intentionally switch. Short refs (`panel:N`, `area:N`, `workspace:N`, `window:N`) start over after a restart; store the panel UUID from `c11 --id-format both tree --json` to find that same browser panel afterward.
**Place browsers by anchor, never by focus.** `browser open`, `open-split`, and `new` anchor on the caller (`$C11_PANEL_ID`) unless `--panel` or `--area` is given. The first open splits beside the anchor when space permits; later opens join its browser area. A cross-workspace `--workspace` open adds a panel to an existing area without splitting. `--area <ref>` adds there without splitting. `open --panel <browser>` still navigates that browser in place; `--panel <terminal>` places beside it.

## Browser Profiles

Profiles isolate WebKit cookies, storage, and history. The built-in `Default`
profile is always present and cannot be renamed, cleared, or deleted.

```bash
c11 browser profiles list --json
c11 browser profiles add smoke-b3 --json
c11 browser profiles rename smoke-b3 smoke-b3-renamed --json
c11 browser open https://example.com --profile smoke-b3-renamed --json
c11 browser profiles clear smoke-b3-renamed --yes --json
c11 browser profiles delete smoke-b3-renamed --yes --json
```

`--profile` is one-shot: it selects the profile for the panel being created and
does not change the profile used by a later unscoped `browser open`, `new-panel`,
or `new-area`. Profile names resolve case-insensitively when unique; UUIDs are
accepted as well. `clear` and `delete` never show a dialog: both require
`--yes`, refuse the built-in profile, and refuse profiles attached to any live
browser panel. Close those panels before retrying.

## Plain `http://` Navigation

c11 guards plain-HTTP navigation, and socket-driven navigation is the path most likely to hit it.

- **Loopback is allowed by default** — `localhost`, `127.0.0.1`, `::1`, `0.0.0.0`, `*.localtest.me`. The usual `python3 -m http.server` validation loop needs nothing extra.
- **Any other plain-HTTP host needs consent.** That includes LAN addresses (`192.168.x.x`, `10.x.x.x`), tailnet hostnames, and public `http://` sites. Two outcomes, both now reported:
  - a window is available (even if the app is not frontmost): a prompt is sheeted onto it and the call returns with `insecure_http: {"status": "prompted", ...}` — nothing loads until a human answers;
  - no window can host it (app hidden, window miniaturized, all windows closed): the call fails with `insecure_http_blocked` and names the host and the remedy.
- **Consent on your own authority with `--allow-insecure-http`**, on `open`/`open-split`/`new` and on `goto`/`navigate`:

```bash
c11 --json browser open http://192.168.1.5:8000 --allow-insecure-http
c11 browser panel:7 goto http://192.168.1.5:8000 --allow-insecure-http
```

The consent covers **one navigation to one host, including that navigation's HTTP redirects to the same host** (a 302 from `/` to `/login` works). A page that redirects itself after loading — JS or `<meta http-equiv="refresh">` — starts a new navigation and needs consent again. It is not persisted and is released once the navigation settles. A redirect to plain HTTP on a *different* host prompts or blocks again — if an opted-in page comes up blank after a redirect, check `c11 browser <panel> get url --json`, which reports the outcome in `insecure_http`, and re-issue with the flag against the redirect target. To allow a host permanently, add it in Settings → Browser → insecure HTTP allowlist.

`c11 new-panel --type browser --url <url>` and `c11 new-area --type browser --url <url>` do **not** take the flag and do not report the outcome, so for a non-loopback plain-HTTP page create the panel without a URL and then `goto <url> --allow-insecure-http`.

Both `open` and `goto` report the outcome rather than failing silently. `browser open` always keeps its promise that a panel exists, so it returns success with `insecure_http: {"status": "blocked"|"prompted", ...}` in the payload (and says so on the text line) — you keep the panel ref to retry or close. `browser goto`/`navigate` promises the navigation itself, so an unpromptable one fails with the `insecure_http_blocked` error.

## Links That Open Another App

A URL whose scheme is not a web scheme (`vnc:`, `smb:`, `ssh:`, `zoommtg:`, `x-apple.systempreferences:`, any custom app scheme) is handed to macOS, which opens the app that owns it.

- **You name the URL: it opens as before.** `browser open`, `goto`/`navigate` and the omnibar open an app link directly, with no prompt.
- **The page asks: the operator decides.** A page that navigates, opens a window or a popup to an app link gets a sheet on its panel's window: `Open "<App>"?`, naming the page's site, the app, and the URL, with **Open**, **Cancel** and an **Always allow <site> to open <scheme>: links** checkbox. Return does not press Open; Escape cancels. This covers your own `browser click` on a page's link too, because the page chose where the link goes. Nothing opens until a human answers, so don't wait on it: if the app must open, navigate to the URL yourself.
- **Only one prompt per panel.** While one is showing, more requests from that page and its popups are dropped, as is any request in the 2 seconds after it closes. After Cancel, the page's scripts cannot ask again for that scheme until it loads a new page; a click on the link can.
- **A panel the operator can't see never prompts.** A page in a hidden workspace or background panel is refused without a sheet.
- **Every dropped request is explainable.** A request refused because the panel was hidden, a prompt was showing, the cooldown was running, or the operator had cancelled leaves a warning line with source `browser` in the workspace log (`c11 list-log`), at most one per reason, site and scheme every 30 seconds.
- **`mailto:` opens without asking**, as in Safari and Chrome: it only drafts a message.
- **No app for the scheme:** a short notice appears in the panel instead of a prompt.
- **Always allow** stores the site and scheme (`https://zoom.us zoommtg`) in Settings → Browser → Sites Allowed to Open Apps. Delete the line to make that site ask again. Local `file:` pages always ask.
- `c11://` links keep their own rules (Links to panels and workspaces, in the c11 skill).

## Wait Support

c11 supports wait patterns similar to agent-browser:

```bash
c11 browser <panel> wait --selector "#ready" --timeout-ms 10000
c11 browser <panel> wait --text "Success" --timeout-ms 10000
c11 browser <panel> wait --url-contains "/dashboard" --timeout-ms 10000
c11 browser <panel> wait --load-state complete --timeout-ms 15000
c11 browser <panel> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

## Keep a Background Tab Running

A browser panel in a hidden workspace is hidden to WebKit: `document.hidden` is true, timers and media are throttled, and the page may not render. To prove a poller, timer, video or rAF feature without showing the workspace, turn keep-live on for that panel:

```bash
c11 browser <panel> keep-live on      # page reports visibilityState "visible"; timers, media and snapshots keep working
c11 browser <panel> keep-live status  # on | off
c11 browser <panel> keep-live off     # normal throttling returns
```

Socket: `browser.keep_live` with `panel_id` and optional `enabled` (omit to read). It never selects a workspace, moves focus or reorders windows. Keep-live is off by default, is not saved across a c11 restart, and costs the CPU and memory of a visible tab, so turn it off when the check is done. It works while the c11 window itself is on screen; a minimized or fully covered window throttles every page, kept live or not. Verify with `c11 browser <panel> eval "document.visibilityState"`.

## Common Flows

### Form Submit

```bash
c11 --json browser open https://example.com/signup
c11 browser panel:7 get url
c11 browser panel:7 wait --load-state complete --timeout-ms 15000
c11 browser panel:7 snapshot --interactive
c11 browser panel:7 fill e1 "Jane Doe"
c11 browser panel:7 fill e2 "jane@example.com"
c11 --json browser panel:7 click e3 --snapshot-after
c11 browser panel:7 wait --url-contains "/welcome" --timeout-ms 15000
c11 browser panel:7 snapshot --interactive
```

### Clear an Input

```bash
c11 browser panel:7 fill e11 --text "" --snapshot-after --json
c11 browser panel:7 get value e11 --json
```

### Stable Agent Loop (Recommended)

```bash
# navigate -> verify -> wait -> snapshot -> action -> snapshot
c11 browser panel:7 get url
c11 browser panel:7 wait --load-state complete --timeout-ms 15000
c11 browser panel:7 snapshot --interactive
c11 --json browser panel:7 click e5 --snapshot-after
c11 browser panel:7 snapshot --interactive
```

If `get url` is empty or `about:blank`, navigate first instead of waiting on load state.

A browser panel that has never been navigated cannot run JavaScript at all — there is no web
process to run it in — so every JS command against one fails immediately rather than
waiting out its timeout. `eval`, `wait`, `snapshot`, and the element actions (`click`,
`fill`, `type`, `press`, …) return code `no_document` with `current_url` and
`lifecycle_state` in the error data; the remaining JS paths report the same message under
`js_error`. Either way, treat it as "navigate first", not as a transient failure to retry.
If the message says navigation was *requested* but no load has been issued, the load is
being withheld rather than missing: check for a pending insecure-HTTP confirmation, a
remote-workspace proxy that has not resolved, or a hibernated panel.

`timeout-ms` on `wait` and `download wait` is capped at 120000. A larger value is clamped,
and the error payload reports both `timeout_ms` and your `requested_timeout_ms`.

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/commands.md](references/commands.md) | Full browser command mapping and quick syntax |
| [references/snapshot-refs.md](references/snapshot-refs.md) | Ref lifecycle and stale-ref troubleshooting |
| [references/authentication.md](references/authentication.md) | Login/OAuth/2FA patterns and state save/load |
| [references/authentication.md#saving-authentication-state](references/authentication.md#saving-authentication-state) | Save authenticated state right after login |
| [references/session-management.md](references/session-management.md) | Multi-panel isolation and state persistence patterns |
| [references/video-recording.md](references/video-recording.md) | Current recording status and practical alternatives |
| [references/proxy-support.md](references/proxy-support.md) | Proxy behavior in WKWebView and workarounds |

## Ready-to-Use Templates

| Template | Description |
|----------|-------------|
| [templates/form-automation.sh](templates/form-automation.sh) | Snapshot/ref form fill loop |
| [templates/authenticated-session.sh](templates/authenticated-session.sh) | Login once, save/load state |
| [templates/capture-workflow.sh](templates/capture-workflow.sh) | Navigate + capture snapshots/screenshots |

## Limits (WKWebView)

These commands currently return `not_supported` because they rely on Chrome/CDP-only APIs not exposed by WKWebView:
- viewport emulation
- offline emulation
- trace/screencast recording
- network route interception/mocking
- low-level raw input injection

Use supported high-level commands (`click`, `fill`, `press`, `scroll`, `wait`, `snapshot`) instead.

**`file://` pages see only their own folder.** A local HTML page opened in a c11 browser panel can load files from its own directory and below; `../vendor/x.js` or `../shots/y.png` fail silently (broken images, undefined libraries) while the same page passes in Chrome and headless Playwright. Keep every asset of a local HTML deliverable inside the page's folder or inlined, and before calling it done load it in a c11 browser panel and check `document.images` for `naturalWidth === 0`.

## Troubleshooting

### `js_error` on `snapshot --interactive` or `eval`

Some complex pages can reject or break the JavaScript used for rich snapshots and ad-hoc evaluation.

**Prefer `get text body` / `get html body` for reading page content; reserve `eval` for interaction and computed checks.** `eval` and `snapshot --interactive` run injected JavaScript that strict-CSP or framebusting sites (Hacker News is a known case) reject with `js_error` — even for something as trivial as `eval "1+1"` — whereas `get text`/`get html` read the already-rendered DOM and keep working. Reach for `eval` when you genuinely need to run script on the page, not as the default way to extract content.

Recovery steps:

```bash
c11 browser panel:7 get url
c11 browser panel:7 get text body
c11 browser panel:7 get html body
```

- Use `get url` first so you know whether the page actually navigated.
- Fall back to `get text body` or `get html body` when `snapshot --interactive` or `eval` returns `js_error`.
- If the page is still failing, navigate to a simpler intermediate page, then retry the task from there.
