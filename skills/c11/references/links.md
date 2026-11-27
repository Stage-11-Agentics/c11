# Links to panels and workspaces

Print this page with `c11 guide links`. How to mention a panel or workspace to the operator as a link, and where those links work. A link to `<page>.md` names another page: `c11 guide <page>`.

## Links to panels and workspaces

Before emitting these links, pages and agents should check the connected server's `features` in `c11 capabilities --json` for `links.panel` version 1, which covers the browser and Markdown navigation described here.
`links.terminal` version 1 covers terminal Cmd-click, true-destination hover previews,
and `c11 link` generation. Check that capability before relying on terminal links.

**Mention panels and workspaces in operator reports only as titled links.** Use
`c11 link --panel <ref> --format markdown` or `c11 link --workspace <ref> --format markdown`
to resolve the live target and its title. Keep short refs in commands, not in prose
that asks the operator to find a destination. Never put a short ref inside a URL.

Terminal output, local pages in c11 browser panels, and local markdown panels offer operator navigation:

```html
<a href="c11://panel/01234567-89AB-CDEF-0123-456789ABCDEF">Open the agent</a>
<a href="c11://workspace/01234567-89AB-CDEF-0123-456789ABCDEF">Open the workspace</a>
```

Markdown uses `[Open the agent](c11://panel/<uuid>)`. `c11 link` also prints a raw
URL (the default), `--format osc8`, or all forms with `--json`. It requires an
explicit live panel or workspace and refuses unknown targets, including stale UUIDs.
Copy Link in a panel's tab menu or a workspace's sidebar menu copies the UUID URL.
Get real UUIDs from
`c11 --id-format both tree --json`, `$C11_PANEL_ID`, or `$C11_WORKSPACE_ID`.
Short refs such as `panel:10` are process-local and are refused in links.
UUID case does not matter; surrounding whitespace is trimmed. Query strings, fragments
and extra path segments are refused. Text such as `c11: notes` is not a panel link and
follows ordinary browser search handling.

In terminals, **click** an OSC 8 titled `c11:` link, or **Cmd-click** it or a bare URL.
With mouse reporting off, a plain click navigates one double-click interval
(Ghostty's `click-repeat-interval`) after release, so a double or triple click
still selects instead; a drag or Shift-click selects as usual, and typing or
clicking elsewhere before it lands cancels it. Links of other schemes and bare
URL text keep Cmd-click. Cmd-hover shows the true destination's live panel title
and workspace name, even when a program's OSC 8 label says something else. Claude
Code renders the Markdown form as OSC 8; Codex currently displays the title followed
by the URL in parentheses, which is also clickable. A closed or malformed `c11:`
target shows a notice and never opens another app or browser.
Bare `c11://` URLs are detected by Ghostty's `link-url` setting (on by default); OSC 8 links work regardless.
When the program in the terminal holds the mouse (Claude Code's fullscreen view, most
full-screen TUIs), a plain click or Cmd-click on an OSC 8 `c11:` link navigates, and
Cmd-hover shows the true destination: c11 takes that click and the program never sees it.
A press that drags away goes to the program, so its selection still starts there. Every
other click, links of other schemes included, still goes to the program. A bare `c11://`
URL there needs Shift+Cmd-click.

In browser and markdown panels, a plain left click or Return on the focused link selects the owning workspace/window,
reveals the panel's area, and pulses the panel after it becomes visible. A workspace
link keeps that workspace's focused panel. The pulse follows the flash setting and
is suppressed with Reduce Motion. Visiting a link does not lower flags or answer asks;
unread notifications follow the same rules as a sidebar visit. Closed or invalid targets
show a small notice in the source panel.

Mail bodies in the mailbox drawer show `[Title](c11://panel/<uuid>)` as "Title", and
bare `c11://panel/<uuid>` and `c11://workspace/<uuid>` URLs are links too. A plain click
lands exactly as a markdown-panel link does, then closes the drawer; a closed or
malformed target shows the notice over the drawer. `http` and `https` links open in
the default browser. Every other scheme stays plain text, and nothing else in a body
is styled.

Browser links work only from a main-frame `file://` page or
HTTP(S) on `localhost`, `127.0.0.1` or `::1` (any port). Other origins show a notice.
The link itself must be in the top document: links inside iframes are refused,
even when the outer page is local. A committed page can use links while resources load.
Scripts, redirects, forms, subframes, popups and browser automation cannot navigate
these links. In web content, Cmd/middle/modified clicks and `target="_blank"` are refused. Opening a
`c11://` URL through the CLI is also refused; socket focus still cannot switch the
operator's workspace. Only the production Release app registers the macOS `c11://` scheme; c11 never
claims c11's `c11://`, though `c11://` links still open inside c11. Outside links show a
floating, nonactivating confirmation naming the live panel/workspace and UUID
URL; only a fresh click on Confirm after its short arming delay navigates.
From another app, Return or Escape cancels it and focus returns to that app;
with c11 frontmost the prompt is click-only and typing stays in the terminal.
Keyboard users and VoiceOver AXPress cannot confirm because the gate requires
a fresh mouse-down/up sequence. Switching to c11's Space cancels the prompt;
click the outside link again to request a new confirmation.
Cancel is the safe default. Closed or malformed
targets show a notice. There is one pending prompt, no queue, a two-second
cooldown after dismissal and a 60-second expiry; bursts are dropped. Cold
startup holds one link until the session is ready, within its original expiry.
If c11 was not running and the Resume picker shows (On Launch set to Ask, or Option held), answer it within a minute or click the link again. In-app
clicks keep the rules above. Debug, nightly and staging copies do not register the scheme.
`open c11://…` from a panel asks the operator; it is not a way to switch their
workspace.
Browser navigation and creation commands return `operator_activation_required` for these URLs.
Local-origin eligibility grants navigation only; it grants no page-to-agent messages,
structure reads, or other capabilities.
