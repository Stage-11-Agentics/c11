# c11 Browser Automation Reference

Browser automation against c11 browser panels — navigate, interact with DOM, inspect state, evaluate JS, manage sessions.

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
c11 browser panel:2 url              # positional
c11 browser --panel panel:2 url    # flag — equivalent

c11 browser identify                           # focused browser metadata
c11 browser identify --panel panel:2       # specific panel
```

**Flag ordering:** `--panel` goes BEFORE the subcommand. `--workspace` and `--window` apply only to `open`, `open-split` and `new`, after the subcommand.

## Navigation

```bash
c11 browser open https://example.com                # new browser split
c11 browser open-split https://news.ycombinator.com # alias

c11 browser panel:2 navigate https://example.org/docs --snapshot-after
c11 browser panel:2 back
c11 browser panel:2 forward
c11 browser panel:2 reload --snapshot-after
c11 browser panel:2 url

c11 browser panel:2 focus-webview          # give focus to the web content
c11 browser panel:2 is-webview-focused     # check if web content has focus
```

## Waiting

Block until a condition is satisfied:

```bash
c11 browser panel:2 wait --load-state complete --timeout-ms 15000
c11 browser panel:2 wait --selector "#checkout" --timeout-ms 10000
c11 browser panel:2 wait --text "Order confirmed"
c11 browser panel:2 wait --url-contains "/dashboard"
c11 browser panel:2 wait --function "window.__appReady === true"
```

## DOM Interaction

All mutating actions support `--snapshot-after` for inline verification.

### Click & Hover

```bash
c11 browser panel:2 click "button[type='submit']" --snapshot-after
c11 browser panel:2 dblclick ".item-row"
c11 browser panel:2 hover "#menu"
c11 browser panel:2 focus "#email"
c11 browser panel:2 scroll-into-view "#pricing"
```

### Checkboxes

```bash
c11 browser panel:2 check "#terms"
c11 browser panel:2 uncheck "#newsletter"
```

### Text Input

```bash
c11 browser panel:2 type "#search" "c11"                     # keystroke-by-keystroke
c11 browser panel:2 fill "#email" --text "ops@example.com"    # set value directly
c11 browser panel:2 fill "#email" --text ""                   # clear field
```

### Keyboard

```bash
c11 browser panel:2 press Enter
c11 browser panel:2 keydown Shift
c11 browser panel:2 keyup Shift
```

### Select & Scroll

```bash
c11 browser panel:2 select "#region" "us-east"
c11 browser panel:2 scroll --dy 800 --snapshot-after
c11 browser panel:2 scroll --selector "#log-view" --dx 0 --dy 400
```

## Inspection

### Snapshots & Screenshots

```bash
c11 browser panel:2 snapshot --interactive --compact
c11 browser panel:2 snapshot --selector "main" --max-depth 5
c11 browser panel:2 screenshot --out /tmp/c11-page.png
```

### Getters

```bash
c11 browser panel:2 get title
c11 browser panel:2 get url
c11 browser panel:2 get text "h1"
c11 browser panel:2 get html "main"
c11 browser panel:2 get value "#email"
c11 browser panel:2 get attr "a.primary" --attr href
c11 browser panel:2 get count ".row"
c11 browser panel:2 get box "#checkout"                    # bounding box
c11 browser panel:2 get styles "#total" --property color
```

### Boolean Checks

```bash
c11 browser panel:2 is visible "#checkout"
c11 browser panel:2 is enabled "button[type='submit']"
c11 browser panel:2 is checked "#terms"
```

### Locators (Playwright-style)

```bash
c11 browser panel:2 find role button --name "Continue"
c11 browser panel:2 find text "Order confirmed"
c11 browser panel:2 find label "Email"
c11 browser panel:2 find placeholder "Search"
c11 browser panel:2 find alt "Product image"
c11 browser panel:2 find title "Open settings"
c11 browser panel:2 find testid "save-btn"
c11 browser panel:2 find first ".row"
c11 browser panel:2 find last ".row"
c11 browser panel:2 find nth 2 ".row"
```

### Visual Debug

```bash
c11 browser panel:2 highlight "#checkout"    # visually highlight element
```

## JavaScript & Injection

```bash
c11 browser panel:2 eval "document.title"
c11 browser panel:2 eval --script "window.location.href"

c11 browser panel:2 addinitscript "window.__c11Ready = true;"   # runs on every navigation
c11 browser panel:2 addscript "document.querySelector('#name')?.focus()"
c11 browser panel:2 addstyle "#debug-banner { display: none !important; }"
```

## Frames

```bash
c11 browser panel:2 frame "iframe[name='checkout']"   # enter iframe context
c11 browser panel:2 click "#pay-now"                   # interact inside frame
c11 browser panel:2 frame main                         # return to top-level
```

## Dialogs

```bash
c11 browser panel:2 dialog accept
c11 browser panel:2 dialog accept "Confirmed by automation"
c11 browser panel:2 dialog dismiss
```

## Downloads

```bash
c11 browser panel:2 click "a#download-report"
c11 browser panel:2 download --path /tmp/report.csv --timeout-ms 30000
```

## Cookies & Storage

```bash
# Cookies
c11 browser panel:2 cookies get
c11 browser panel:2 cookies get --name session_id
c11 browser panel:2 cookies set session_id abc123 --domain example.com --path /
c11 browser panel:2 cookies clear --name session_id
c11 browser panel:2 cookies clear --all

# Local storage
c11 browser panel:2 storage local set theme dark
c11 browser panel:2 storage local get theme
c11 browser panel:2 storage local clear

# Session storage
c11 browser panel:2 storage session set flow onboarding
c11 browser panel:2 storage session get flow
```

## Browser State (Save/Restore)

```bash
c11 browser panel:2 state save /tmp/session.json
c11 browser panel:2 state load /tmp/session.json
c11 browser panel:2 reload
```

## Panels

```bash
c11 browser panel:2 panel list
c11 browser panel:2 panel new https://example.com/pricing
c11 browser panel:2 panel switch 1              # by index
c11 browser panel:2 panel switch panel:7      # by panel ref
c11 browser panel:2 panel close                 # current panel
c11 browser panel:2 panel close panel:7       # specific panel
```

## Console & Errors

```bash
c11 browser panel:2 console list
c11 browser panel:2 console clear
c11 browser panel:2 errors list
c11 browser panel:2 errors clear
```

## Common Patterns

### Navigate, Wait, Inspect

```bash
c11 browser open https://example.com/login
c11 browser panel:2 wait --load-state complete --timeout-ms 15000
c11 browser panel:2 snapshot --interactive --compact
c11 browser panel:2 get title
```

### Fill Form and Verify

```bash
c11 browser panel:2 fill "#email" --text "ops@example.com"
c11 browser panel:2 fill "#password" --text "$PASSWORD"
c11 browser panel:2 click "button[type='submit']" --snapshot-after
c11 browser panel:2 wait --text "Welcome"
c11 browser panel:2 is visible "#dashboard"
```

### Debug Artifacts on Failure

```bash
c11 browser panel:2 console list
c11 browser panel:2 errors list
c11 browser panel:2 screenshot --out /tmp/c11-failure.png
c11 browser panel:2 snapshot --interactive --compact
```

### Persist and Restore Session

```bash
c11 browser panel:2 state save /tmp/session.json
# ...later...
c11 browser panel:2 state load /tmp/session.json
c11 browser panel:2 reload
```
