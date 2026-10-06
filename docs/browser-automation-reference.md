# cmux Browser Automation Reference

Browser automation against cmux browser panels — navigate, interact with DOM, inspect state, evaluate JS, manage sessions.

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
| Panels & logs | `panel`, `console`, `errors` |

## Targeting

Most subcommands need a target panel. Pass positionally or with `--panel`:

```bash
cmux browser panel:2 url              # positional
cmux browser --panel panel:2 url    # flag — equivalent

cmux browser identify                           # focused browser metadata
cmux browser identify --panel panel:2       # specific panel
```

**Flag ordering:** `--panel` and `--workspace` go BEFORE the subcommand, not after.

## Navigation

```bash
cmux browser open https://example.com                # new browser split
cmux browser open-split https://news.ycombinator.com # alias

cmux browser panel:2 navigate https://example.org/docs --snapshot-after
cmux browser panel:2 back
cmux browser panel:2 forward
cmux browser panel:2 reload --snapshot-after
cmux browser panel:2 url

cmux browser panel:2 focus-webview          # give focus to the web content
cmux browser panel:2 is-webview-focused     # check if web content has focus
```

## Waiting

Block until a condition is satisfied:

```bash
cmux browser panel:2 wait --load-state complete --timeout-ms 15000
cmux browser panel:2 wait --selector "#checkout" --timeout-ms 10000
cmux browser panel:2 wait --text "Order confirmed"
cmux browser panel:2 wait --url-contains "/dashboard"
cmux browser panel:2 wait --function "window.__appReady === true"
```

## DOM Interaction

All mutating actions support `--snapshot-after` for inline verification.

### Click & Hover

```bash
cmux browser panel:2 click "button[type='submit']" --snapshot-after
cmux browser panel:2 dblclick ".item-row"
cmux browser panel:2 hover "#menu"
cmux browser panel:2 focus "#email"
cmux browser panel:2 scroll-into-view "#pricing"
```

### Checkboxes

```bash
cmux browser panel:2 check "#terms"
cmux browser panel:2 uncheck "#newsletter"
```

### Text Input

```bash
cmux browser panel:2 type "#search" "cmux"                     # keystroke-by-keystroke
cmux browser panel:2 fill "#email" --text "ops@example.com"    # set value directly
cmux browser panel:2 fill "#email" --text ""                   # clear field
```

### Keyboard

```bash
cmux browser panel:2 press Enter
cmux browser panel:2 keydown Shift
cmux browser panel:2 keyup Shift
```

### Select & Scroll

```bash
cmux browser panel:2 select "#region" "us-east"
cmux browser panel:2 scroll --dy 800 --snapshot-after
cmux browser panel:2 scroll --selector "#log-view" --dx 0 --dy 400
```

## Inspection

### Snapshots & Screenshots

```bash
cmux browser panel:2 snapshot --interactive --compact
cmux browser panel:2 snapshot --selector "main" --max-depth 5
cmux browser panel:2 screenshot --out /tmp/cmux-page.png
```

### Getters

```bash
cmux browser panel:2 get title
cmux browser panel:2 get url
cmux browser panel:2 get text "h1"
cmux browser panel:2 get html "main"
cmux browser panel:2 get value "#email"
cmux browser panel:2 get attr "a.primary" --attr href
cmux browser panel:2 get count ".row"
cmux browser panel:2 get box "#checkout"                    # bounding box
cmux browser panel:2 get styles "#total" --property color
```

### Boolean Checks

```bash
cmux browser panel:2 is visible "#checkout"
cmux browser panel:2 is enabled "button[type='submit']"
cmux browser panel:2 is checked "#terms"
```

### Locators (Playwright-style)

```bash
cmux browser panel:2 find role button --name "Continue"
cmux browser panel:2 find text "Order confirmed"
cmux browser panel:2 find label "Email"
cmux browser panel:2 find placeholder "Search"
cmux browser panel:2 find alt "Product image"
cmux browser panel:2 find title "Open settings"
cmux browser panel:2 find testid "save-btn"
cmux browser panel:2 find first ".row"
cmux browser panel:2 find last ".row"
cmux browser panel:2 find nth 2 ".row"
```

### Visual Debug

```bash
cmux browser panel:2 highlight "#checkout"    # visually highlight element
```

## JavaScript & Injection

```bash
cmux browser panel:2 eval "document.title"
cmux browser panel:2 eval --script "window.location.href"

cmux browser panel:2 addinitscript "window.__cmuxReady = true;"   # runs on every navigation
cmux browser panel:2 addscript "document.querySelector('#name')?.focus()"
cmux browser panel:2 addstyle "#debug-banner { display: none !important; }"
```

## Frames

```bash
cmux browser panel:2 frame "iframe[name='checkout']"   # enter iframe context
cmux browser panel:2 click "#pay-now"                   # interact inside frame
cmux browser panel:2 frame main                         # return to top-level
```

## Dialogs

```bash
cmux browser panel:2 dialog accept
cmux browser panel:2 dialog accept "Confirmed by automation"
cmux browser panel:2 dialog dismiss
```

## Downloads

```bash
cmux browser panel:2 click "a#download-report"
cmux browser panel:2 download --path /tmp/report.csv --timeout-ms 30000
```

## Cookies & Storage

```bash
# Cookies
cmux browser panel:2 cookies get
cmux browser panel:2 cookies get --name session_id
cmux browser panel:2 cookies set session_id abc123 --domain example.com --path /
cmux browser panel:2 cookies clear --name session_id
cmux browser panel:2 cookies clear --all

# Local storage
cmux browser panel:2 storage local set theme dark
cmux browser panel:2 storage local get theme
cmux browser panel:2 storage local clear

# Session storage
cmux browser panel:2 storage session set flow onboarding
cmux browser panel:2 storage session get flow
```

## Browser State (Save/Restore)

```bash
cmux browser panel:2 state save /tmp/session.json
cmux browser panel:2 state load /tmp/session.json
cmux browser panel:2 reload
```

## Panels

```bash
cmux browser panel:2 panel list
cmux browser panel:2 panel new https://example.com/pricing
cmux browser panel:2 panel switch 1              # by index
cmux browser panel:2 panel switch panel:7      # by panel ref
cmux browser panel:2 panel close                 # current panel
cmux browser panel:2 panel close panel:7       # specific panel
```

## Console & Errors

```bash
cmux browser panel:2 console list
cmux browser panel:2 console clear
cmux browser panel:2 errors list
cmux browser panel:2 errors clear
```

## Common Patterns

### Navigate, Wait, Inspect

```bash
cmux browser open https://example.com/login
cmux browser panel:2 wait --load-state complete --timeout-ms 15000
cmux browser panel:2 snapshot --interactive --compact
cmux browser panel:2 get title
```

### Fill Form and Verify

```bash
cmux browser panel:2 fill "#email" --text "ops@example.com"
cmux browser panel:2 fill "#password" --text "$PASSWORD"
cmux browser panel:2 click "button[type='submit']" --snapshot-after
cmux browser panel:2 wait --text "Welcome"
cmux browser panel:2 is visible "#dashboard"
```

### Debug Artifacts on Failure

```bash
cmux browser panel:2 console list
cmux browser panel:2 errors list
cmux browser panel:2 screenshot --out /tmp/cmux-failure.png
cmux browser panel:2 snapshot --interactive --compact
```

### Persist and Restore Session

```bash
cmux browser panel:2 state save /tmp/session.json
# ...later...
cmux browser panel:2 state load /tmp/session.json
cmux browser panel:2 reload
```
