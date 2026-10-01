# cmux Browser Automation Reference

Browser automation against cmux browser tabs — navigate, interact with DOM, inspect state, evaluate JS, manage sessions.

**Source:** https://cmux.com/docs/browser-automation

## Command Index

| Category | Subcommands |
|----------|-------------|
| Navigation | `identify`, `open`, `open-split`, `navigate`, `back`, `forward`, `reload`, `url`, `focus-webview`, `is-webview-focused` |
| Waiting | `wait` |
| DOM interaction | `click`, `dblclick`, `hover`, `focus`, `check`, `uncheck`, `scroll-into-view`, `type`, `fill`, `press`, `keydown`, `keyup`, `select`, `scroll` |
| Inspection | `snapshot`, `screenshot`, `get`, `is`, `find`, `highlight` |
| JS & injection | `eval`, `addinitscript`, `addscript`, `addstyle` |
| Frames & dialogs | `frame`, `dialog`, `download` |
| State & session | `cookies`, `storage`, `state` |
| Tabs & logs | `tab`, `console`, `errors` |

## Targeting

Most subcommands need a target tab. Pass positionally or with `--tab`:

```bash
cmux browser tab:2 url              # positional
cmux browser --tab tab:2 url    # flag — equivalent

cmux browser identify                           # focused browser metadata
cmux browser identify --tab tab:2       # specific tab
```

**Flag ordering:** `--tab` and `--workspace` go BEFORE the subcommand, not after.

## Navigation

```bash
cmux browser open https://example.com                # new browser split
cmux browser open-split https://news.ycombinator.com # alias

cmux browser tab:2 navigate https://example.org/docs --snapshot-after
cmux browser tab:2 back
cmux browser tab:2 forward
cmux browser tab:2 reload --snapshot-after
cmux browser tab:2 url

cmux browser tab:2 focus-webview          # give focus to the web content
cmux browser tab:2 is-webview-focused     # check if web content has focus
```

## Waiting

Block until a condition is satisfied:

```bash
cmux browser tab:2 wait --load-state complete --timeout-ms 15000
cmux browser tab:2 wait --selector "#checkout" --timeout-ms 10000
cmux browser tab:2 wait --text "Order confirmed"
cmux browser tab:2 wait --url-contains "/dashboard"
cmux browser tab:2 wait --function "window.__appReady === true"
```

## DOM Interaction

All mutating actions support `--snapshot-after` for inline verification.

### Click & Hover

```bash
cmux browser tab:2 click "button[type='submit']" --snapshot-after
cmux browser tab:2 dblclick ".item-row"
cmux browser tab:2 hover "#menu"
cmux browser tab:2 focus "#email"
cmux browser tab:2 scroll-into-view "#pricing"
```

### Checkboxes

```bash
cmux browser tab:2 check "#terms"
cmux browser tab:2 uncheck "#newsletter"
```

### Text Input

```bash
cmux browser tab:2 type "#search" "cmux"                     # keystroke-by-keystroke
cmux browser tab:2 fill "#email" --text "ops@example.com"    # set value directly
cmux browser tab:2 fill "#email" --text ""                   # clear field
```

### Keyboard

```bash
cmux browser tab:2 press Enter
cmux browser tab:2 keydown Shift
cmux browser tab:2 keyup Shift
```

### Select & Scroll

```bash
cmux browser tab:2 select "#region" "us-east"
cmux browser tab:2 scroll --dy 800 --snapshot-after
cmux browser tab:2 scroll --selector "#log-view" --dx 0 --dy 400
```

## Inspection

### Snapshots & Screenshots

```bash
cmux browser tab:2 snapshot --interactive --compact
cmux browser tab:2 snapshot --selector "main" --max-depth 5
cmux browser tab:2 screenshot --out /tmp/cmux-page.png
```

### Getters

```bash
cmux browser tab:2 get title
cmux browser tab:2 get url
cmux browser tab:2 get text "h1"
cmux browser tab:2 get html "main"
cmux browser tab:2 get value "#email"
cmux browser tab:2 get attr "a.primary" --attr href
cmux browser tab:2 get count ".row"
cmux browser tab:2 get box "#checkout"                    # bounding box
cmux browser tab:2 get styles "#total" --property color
```

### Boolean Checks

```bash
cmux browser tab:2 is visible "#checkout"
cmux browser tab:2 is enabled "button[type='submit']"
cmux browser tab:2 is checked "#terms"
```

### Locators (Playwright-style)

```bash
cmux browser tab:2 find role button --name "Continue"
cmux browser tab:2 find text "Order confirmed"
cmux browser tab:2 find label "Email"
cmux browser tab:2 find placeholder "Search"
cmux browser tab:2 find alt "Product image"
cmux browser tab:2 find title "Open settings"
cmux browser tab:2 find testid "save-btn"
cmux browser tab:2 find first ".row"
cmux browser tab:2 find last ".row"
cmux browser tab:2 find nth 2 ".row"
```

### Visual Debug

```bash
cmux browser tab:2 highlight "#checkout"    # visually highlight element
```

## JavaScript & Injection

```bash
cmux browser tab:2 eval "document.title"
cmux browser tab:2 eval --script "window.location.href"

cmux browser tab:2 addinitscript "window.__cmuxReady = true;"   # runs on every navigation
cmux browser tab:2 addscript "document.querySelector('#name')?.focus()"
cmux browser tab:2 addstyle "#debug-banner { display: none !important; }"
```

## Frames

```bash
cmux browser tab:2 frame "iframe[name='checkout']"   # enter iframe context
cmux browser tab:2 click "#pay-now"                   # interact inside frame
cmux browser tab:2 frame main                         # return to top-level
```

## Dialogs

```bash
cmux browser tab:2 dialog accept
cmux browser tab:2 dialog accept "Confirmed by automation"
cmux browser tab:2 dialog dismiss
```

## Downloads

```bash
cmux browser tab:2 click "a#download-report"
cmux browser tab:2 download --path /tmp/report.csv --timeout-ms 30000
```

## Cookies & Storage

```bash
# Cookies
cmux browser tab:2 cookies get
cmux browser tab:2 cookies get --name session_id
cmux browser tab:2 cookies set session_id abc123 --domain example.com --path /
cmux browser tab:2 cookies clear --name session_id
cmux browser tab:2 cookies clear --all

# Local storage
cmux browser tab:2 storage local set theme dark
cmux browser tab:2 storage local get theme
cmux browser tab:2 storage local clear

# Session storage
cmux browser tab:2 storage session set flow onboarding
cmux browser tab:2 storage session get flow
```

## Browser State (Save/Restore)

```bash
cmux browser tab:2 state save /tmp/session.json
cmux browser tab:2 state load /tmp/session.json
cmux browser tab:2 reload
```

## Tabs

```bash
cmux browser tab:2 tab list
cmux browser tab:2 tab new https://example.com/pricing
cmux browser tab:2 tab switch 1              # by index
cmux browser tab:2 tab switch tab:7      # by tab ref
cmux browser tab:2 tab close                 # current tab
cmux browser tab:2 tab close tab:7       # specific tab
```

## Console & Errors

```bash
cmux browser tab:2 console list
cmux browser tab:2 console clear
cmux browser tab:2 errors list
cmux browser tab:2 errors clear
```

## Common Patterns

### Navigate, Wait, Inspect

```bash
cmux browser open https://example.com/login
cmux browser tab:2 wait --load-state complete --timeout-ms 15000
cmux browser tab:2 snapshot --interactive --compact
cmux browser tab:2 get title
```

### Fill Form and Verify

```bash
cmux browser tab:2 fill "#email" --text "ops@example.com"
cmux browser tab:2 fill "#password" --text "$PASSWORD"
cmux browser tab:2 click "button[type='submit']" --snapshot-after
cmux browser tab:2 wait --text "Welcome"
cmux browser tab:2 is visible "#dashboard"
```

### Debug Artifacts on Failure

```bash
cmux browser tab:2 console list
cmux browser tab:2 errors list
cmux browser tab:2 screenshot --out /tmp/cmux-failure.png
cmux browser tab:2 snapshot --interactive --compact
```

### Persist and Restore Session

```bash
cmux browser tab:2 state save /tmp/session.json
# ...later...
cmux browser tab:2 state load /tmp/session.json
cmux browser tab:2 reload
```
