# c11 markdown bridge v1

The host loads `index.html` from a private custom scheme rooted at this folder
(or `file:` in the hermetic harness). All bundle assets are relative. No document
content is a script, stylesheet or page URL. No renderer request uses the network.
The native host owns file access, navigation policy, persistence and toolbar controls.
The page owns layout, scroll anchoring, content interactions and engine queries.

## Native → page

Call `window.c11md` only after `ready`. Arguments/results are JSON values. `load`
and `setSettings` return Promises; await them with `callAsyncJavaScript` when a
result is needed. Other methods return synchronously. Queries never mutate focus.

- `load({markdown, documentPath, baseURL, revision})`: markdown and documentPath
  are strings; baseURL is an optional absolute URL for resolving document links
  (normally the document's file URL); revision is an opaque string or number,
  echoed in state/rendered. Returns `visible()` after fonts/diagrams/layout settle.
  First load/new document starts at top; same-document reload keeps the reader's
  anchor and reconciles only changed blocks. A newer load supersedes an older one.
- `setSettings({theme, typeface, scale, outlineOpen, osAppearance, strings})`:
  omitted fields keep their value. theme: `system|light|dark`; typeface:
  `theme|serif|sans|mono`; scale: number 0.5–3.0 (native controls step by 0.1);
  outlineOpen: `true|false|"auto"`; osAppearance: `light|dark` (optional host
  override; otherwise follows matchMedia). Invalid values restore the default for
  that field (`system`, `theme`, `1`, `auto`). Returns settled `visible()`.
  `strings` is an optional localized string map, merged over English defaults:
  `copy`, `copied`, `copyLink`, `expand`, `close`, `diagram`, `diagramError`,
  `imageBlocked`, `notes`, `back`, `source`, `frontmatter`. Native localizes these
  when constructing settings; content is never used as localization markup.
- `scrollToHeading(textOrSlug)`: exact slug, exact case-insensitive text, then
  prefix/substring text match. Returns `{ok:boolean, heading:Heading|null}`.
  Switches to read mode and briefly highlights the target; no window focus.
- `scrollToLine(line, offset = 0)`: 1-based source line, clamped to the document;
  offset is a signed CSS-pixel distance from that line's origin to the viewport
  top (positive means the viewport has moved down into the line). Zero aligns the
  line origin with the viewport top. Returns state; the original one-argument call
  is unchanged.
- `visible()`: returns State below, including bounded selection (max 120 chars).
- `outline()`: returns nested `Heading[]`; `progress()`: returns
  `{progress, minutesLeft}`. Both are read-only.
- `find(query)`: literal case-insensitive text search in the current mode; marks
  matches, selects the first and returns `{query,matches,current}`. `current` is
  1-based, or 0 with no hits. `findNext()` / `findPrevious()` wrap and return the
  same shape. `findClose()` removes marks and returns the empty find state.
- `setSourceMode(boolean)`: read-only source mode, preserving source position;
  returns State. `expandDiagram(number)` opens a 1-based diagram in an in-pane
  pan/zoom overlay and returns boolean; `closeDiagram()` closes it.
- `themes()`: returns `[{id,label,scheme,defaultTypeface}]` (including system).
  `typefaces()`: returns `[{id,label,family,measure,leading}]` (including theme).

Effective layout width is the pane's CSS width **divided by scale**. The page
applies text scale itself; native must keep WKWebView pageZoom at 1. Breakpoints,
table stacking, footnotes and outline docking all use that effective width.

`Heading = {level:1..6, text, slug, line, tasks, done, children:Heading[]}`.
Task counts include the heading's section (until a same/higher-level heading).

`State = {file, revision, mode:"read"|"source", pane:{width,effectiveWidth,size},
heading_path:string[], heading:Heading|null, lines:{first,last,total,offset},
progress:number, minutes_left:number, find:{query,matches,current}|null,
outline:{open,docked,choice:true|false|"auto",tree:Heading[]},
theme:{choice,resolved}, typeface:{choice,resolved}, font_scale:number,
diagram_open:number|null, selection:string|null}`.
`lines.offset` is the signed CSS-pixel distance from the first visible line's
origin to the viewport top. Widths/offsets are CSS pixels; progress is a clamped
fraction 0..1, minutes are nonnegative whole minutes, source lines are 1-based
inclusive. `size` is
`narrow|medium|wide` at effective widths <620 / <1000 / >=1000.

## Page → native

The page calls `window.webkit.messageHandlers.c11md.postMessage(message)` when
available. Absence is normal for file/harness use. Every message is a JSON object
with `type` and the following fields (no JSON string wrapping):

- `{type:"ready", version:1}`: API installed, initial fonts ready. Send load/settings.
- `{type:"state", state:State}`: after load/settings/mode/find/outline/diagram
  changes, and coalesced at most once per animation frame while scrolling.
- `{type:"rendered", revision, blocks:number, changedBlocks:number}`: the current
  load settled, including Mermaid and fonts. Superseded loads emit no rendered.
- `{type:"link", href, resolvedURL:string|null,
  kind:"anchor"|"local"|"external"|"blocked",
  modifiers:{meta,ctrl,shift,alt:boolean}}`: every document link click is prevented
  before posting. Anchor clicks additionally scroll locally (and offer a return
  pill). Local/external links never navigate the page. Native independently
  validates paths/schemes before opening anything. `javascript:`, `data:`, unknown
  schemes and malformed URLs are blocked. No link creates a window or loads a URL.
- `{type:"copy", text, kind:"code"|"heading"}`: user pressed a copy button;
  native writes text to the pasteboard. The page does not require Clipboard API.
- `{type:"error", code, message, revision}`: recoverable renderer error. Codes
  include `render_failed`, `diagram_failed`, `invalid_argument`. A malformed
  Mermaid diagram shows escaped source inline and does not fail the document.

## Anchoring and security

The JS page owns scroll holding, including live reload, theme/typeface/scale,
outline layout, source toggles, font loading, resize and asynchronous Mermaid.
Native must not restore a second scroll offset after an ordinary reload/settings
change. New-document navigation and explicit scroll commands may move the reader.

Raw HTML is disabled. Remote and unauthorized images are inert alt-text placeholders. Mermaid runs
with strict security, no document-supplied initialization/config directives,
and sanitized SVG; hyperlinks inside diagrams are inert. CSP disallows network,
frames, objects, forms and base tags. The host must additionally reject arbitrary
navigation/new windows and grant the custom scheme only bundled assets. The
bridge exposes no eval, file read, socket, external-open or arbitrary native call.

## Local images (accepted amendment)

Relative and `file:` image URLs inside the document directory tree render through
`c11md-asset://doc/<URL-encoded path relative to the document directory>`. Encode
each path component; keep `/` separators. Reject any decoded `..` component
(including encoded traversal), remote/data/unknown schemes, and absolute paths
outside that tree. The native asset handler independently validates decoded paths,
symlinks and file types before serving bytes. The renderer never loads a raw file
or remote image URL. The disk harness proves URL rewriting and rejection policy without loading raw
image URLs. C11-359 proves native byte serving and realpath/symlink/type validation.
