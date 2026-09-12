# C11-207 validation — PASS

Tagged build `c11-207` from this worktree at the review-fix tree (commit below), driven
through the tagged socket `/tmp/c11-debug-c11-207.sock` exactly as an agent would, with
the tagged app's own CLI:

```
./scripts/reload.sh --tag c11-207          # (behind a pgrep guard; one xcodebuild at a time)
CLI="…/c11 DEV c11-207.app/Contents/Resources/bin/c11"
export C11_SOCKET_PATH=/tmp/c11-debug-c11-207.sock
```

Dev server: `python3` on `0.0.0.0:8777` serving `/` (page), `/login.html` (page) and
`/redirect` (302 → `/login.html`), reachable as loopback `127.0.0.1:8777` and as LAN
`192.168.1.141:8777`. The LAN address is the realistic non-allowlisted plain-HTTP case;
loopback is the already-allowed one.

## A — loopback needs nothing (window visible)

```
$ "$CLI" browser surface:3 goto http://127.0.0.1:8777/
OK
$ "$CLI" browser surface:3 get title
C11-207 LAN dev server
$ "$CLI" browser surface:3 get text body
C11-207 validation page
served over plain http from a LAN address
```

## B — LAN host, window visible → the prompt is reported, not hidden behind a bare OK

A merely backgrounded/unfocused window still hosts the sheet, so this is `.prompting`,
not `.blocked` (the plan review's R2 correction).

```
$ "$CLI" browser surface:3 goto http://192.168.1.141:8777/
OK (insecure-http prompt pending for 192.168.1.141; a human must answer it, or retry with --allow-insecure-http)
exit=0

$ "$CLI" --json browser surface:3 get url
{ "insecure_http" : { "status" : "prompted", "host" : "192.168.1.141",
                      "hint" : "Pass --allow-insecure-http …" },
  "url" : "http://127.0.0.1:8777/" }          ← still the old page; nothing loaded
```

## B2 — the human declines → the surface stops claiming a human still has to act

Escape sent to the sheet via System Events (this is the MAJOR code-review finding's fix,
proven live rather than only in a unit test):

```
$ "$CLI" --json browser surface:3 get url
{ "insecure_http" : { "status" : "blocked", "reason" : "declined_by_operator",
                      "host" : "192.168.1.141", "hint" : "…" },
  "url" : "http://127.0.0.1:8777/" }
```

## C — no window to prompt on → the structured error the ticket asked for

App hidden (`System Events` → `set visible … to false`): the app is alive and the socket
is fully responsive, but no window can host a sheet.

```
$ "$CLI" browser surface:3 goto http://192.168.1.141:8777/
Error: insecure_http_blocked: insecure HTTP navigation to 192.168.1.141 blocked: no window
available to prompt. Pass --allow-insecure-http (socket: allow_insecure_http: true) to consent
to this one navigation, or add the host to Settings > Browser > insecure HTTP allowlist to
allow it permanently. Loopback hosts (localhost, 127.0.0.1, ::1) are allowed by default.
exit=1
```

Before this PR the same command printed `OK`, exited 0, and left a page that never loaded,
with only an NSLog line in the app's stderr.

## D — the opt-in, same conditions

```
$ "$CLI" browser surface:3 goto http://192.168.1.141:8777/login.html --allow-insecure-http
OK
exit=0
$ "$CLI" browser surface:3 get title
C11-207 redirect target
$ "$CLI" browser surface:3 get url
http://192.168.1.141:8777/login.html
```

Also with the window visible (D earlier in the run): title `C11-207 LAN dev server`, body
`served over plain http from a LAN address`, no sheet raised.

## E — one consent covers the navigation's same-host 302

The S1 fix. Before it, the delegate consumed the grant on the first policy check and
cancelled the redirect hop.

```
$ "$CLI" browser surface:3 goto http://192.168.1.141:8777/redirect --allow-insecure-http
OK
$ "$CLI" browser surface:3 get title
C11-207 redirect target
$ "$CLI" browser surface:3 get url
http://192.168.1.141:8777/login.html
$ "$CLI" --json browser surface:3 get url
{ … "url" : "http://192.168.1.141:8777/login.html" }     ← no insecure_http fragment: proceeded
```

## F — `browser open` keeps its surface, and the caller can recover it

The S2 shape: the verb's promise ("a surface exists") is kept, the refusal rides in the
payload, and the refs stay reachable.

```
$ "$CLI" browser open http://192.168.1.141:8777/ --workspace workspace:1      # app hidden
OK surface=surface:6 pane=pane:4 placement=reuse (insecure-http navigation to 192.168.1.141
was blocked: no window available to prompt; retry with --allow-insecure-http)
exit=0

$ "$CLI" browser surface:6 goto http://192.168.1.141:8777/ --allow-insecure-http
OK
$ "$CLI" browser surface:6 get title
C11-207 LAN dev server                       ← the blocked surface was recoverable

$ "$CLI" --json browser open http://192.168.1.141:8777/login.html --workspace workspace:1 --allow-insecure-http
surface: surface:7
insecure_http: absent (navigation proceeded)
$ "$CLI" browser surface:7 get title
C11-207 redirect target
```

## G — loopback is unaffected by all of this, app still hidden

```
$ "$CLI" browser surface:7 goto http://127.0.0.1:8777/
OK
$ "$CLI" browser surface:7 get url
http://127.0.0.1:8777/
```

## Workspace state after the run

`c11 tree --no-layout` on the tagged build shows every pane at a readable size
(230×404 minimum, four panes across two columns); nothing was left too small to read.
App visibility restored, tagged app and dev server cleaned up afterwards.

## Test gate

CI `build` job (which runs `c11Tests` + `c11LogicTests`) passed on `709bef43e`; the
review-fix commit re-runs it. Local `xcodebuild test` was not run, per the repo's delegator
policy and the operator's one-build-at-a-time instruction during this session.