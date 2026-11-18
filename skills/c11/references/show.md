# Show the operator what you made

Print this page with `c11 guide show`. `c11 show` in full: viewers, assets, reload, close, limits and point-and-say. A link to `<page>.md` names another page: `c11 guide <page>`.

`c11 show <path>` shows a file to the operator from any machine; `c11 show <url>` for anything you host yourself. Anything you show, assume the operator sees. `show` answers whether it loaded; fix a nonzero before you tell the operator it is ready. Keep prototype UI state in the URL hash so it survives live reload.

- The viewer opens beside your panel. `.md` opens in the markdown viewer; other files open in a browser viewer.
- `--dir <folder>` lets the page fetch assets from that folder (js, css, json, fonts, images); svg is not served. A nonzero `assets refused` warning means pass `--dir`.
- While the viewer is visible it reloads when the file changes. Showing the same file again refreshes its viewer.
- `c11 show close [<path|url>]` closes what you showed: that one, or all of yours.
- Display only: browser commands on a viewer are refused (`show_viewer_display_only`). Test with `c11 browser` or your own tools, then `show` the result.
- Files over 8 MB are refused: host them and `show <url>`.
- **From a linked machine a viewer is fenced** so the page cannot reach the operator's Mac, apart from requests whose answer it never reads (`c11 guide trust`). A file or `--dir` page runs its script, but loads and fetches only from what you showed: no CDN, no outside fetch, no frames, forms or WebRTC. A URL you show from there, and any page the viewer goes on to, runs no script, and the viewer never navigates to the operator's Mac. A closed viewer does not reopen or duplicate, and a viewer from a linked machine has no Open in Default Browser; show it again. To show an interactive app from a linked machine, show its built files with `--dir`. A show from the operator's Mac has no fence, and its Open in Default Browser opens the shown file itself when it is HTML, text (not a script), an image or PDF (or the page it navigated to).
- Point and say: the operator can Option-click an element in a shown page and type a line. It arrives as mail (topic `show.point`) with the element's selector, its text, a cropped screenshot path and the page it was on (`page:`, with a `note:` line when that is another page of your source, not the one you showed). The operator sees your panel's title and machine while typing, and whether the note reached you. Only your own pages offer it; once your panel closes or its terminal ends, the viewer says its agent is gone and sends nothing until you (or a resumed you) show again.

Flags, result fields and error codes: [API reference](api.md#show).
