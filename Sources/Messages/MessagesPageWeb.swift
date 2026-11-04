import Foundation

/// The conversation web: the messages page's default view, drawing who talks
/// to whom as panels (nodes) and directed conversations (edges) at three
/// scopes: the whole c11 instance, one workspace, or one panel and its peers.
///
/// Everything here is static page text. The renderer splices it into the page
/// around the embedded `messages-data` JSON; the script reads that JSON and
/// never fetches anything. Deep links: `#web`, `#web:workspace=<uuid>`,
/// `#web:panel=<uuid>`, each with an optional `&n=<digits>` nonce so a repeat
/// request for the same target still re-centres a page that is already open.
enum MessagesPageWeb {
    static func deepLinkFragment(panelID: UUID, nonce: UInt64? = nil) -> String {
        "web:panel=\(panelID.uuidString)" + (nonce.map { "&n=\($0)" } ?? "")
    }

    static func deepLinkFragment(workspaceID: UUID, nonce: UInt64? = nil) -> String {
        "web:workspace=\(workspaceID.uuidString)" + (nonce.map { "&n=\($0)" } ?? "")
    }

    /// The page URL with a deep-link fragment.
    static func url(page: URL, fragment: String) -> URL {
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        components?.fragment = fragment
        return components?.url ?? page
    }

    /// Operator action from a panel's mailbox drawer: show the conversation
    /// web centred on that panel. Reuses a messages page already open in the
    /// workspace (navigating it to the new deep link), otherwise opens one in
    /// a split beside the panel. Focus moves to the page: the operator asked
    /// for it, inside the workspace they are looking at.
    @MainActor
    static func open(centredOn panelID: UUID, in workspace: Workspace) {
        MessagesPageWriter.shared.start()
        // The open panels' titles and addresses as they are now, from memory:
        // the session file can be one autosave behind a rename.
        let livePanels = (AppDelegate.shared?.mailboxAddressableSurfaces() ?? []).map { record in
            MessagesPageDirectory.Panel(
                id: record.surfaceId.uuidString,
                title: record.name.isEmpty ? nil : record.name,
                workspace: record.workspaceId.uuidString,
                live: true, type: nil, agent: nil,
                address: record.address.flatMap { $0.isEmpty ? nil : $0 },
                parent: nil
            )
        }
        let fragment = deepLinkFragment(
            panelID: panelID,
            nonce: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        MessagesPageWriter.shared.ensureFreshPage(livePanels: livePanels) { [weak workspace] result in
            guard case let .success(pageURL) = result else { return }
            DispatchQueue.main.async {
                guard let workspace else { return }
                present(url(page: pageURL, fragment: fragment), page: pageURL, centredOn: panelID, in: workspace)
            }
        }
    }

    @MainActor
    private static func present(_ target: URL, page: URL, centredOn panelID: UUID, in workspace: Workspace) {
        let pagePath = page.standardizedFileURL.path
        if let existing = workspace.panels.values
            .compactMap({ $0 as? BrowserPanel })
            .first(where: { $0.currentURL?.standardizedFileURL.path == pagePath }) {
            _ = existing.navigate(to: target)
            workspace.focusPanel(existing.id)
            return
        }
        _ = PanelLineage.shared.withCreator(panelID) {
            workspace.newBrowserSplit(from: panelID, orientation: .horizontal, url: target, focus: true)
        }
    }

    static let style = #"""
    body.view-web { padding: 0; height: 100vh; overflow: hidden; }
    body.view-web > main { display: none; }
    body.view-traffic #cw { display: none; }
    #cw-views { display: flex; gap: 0; border: 1px solid var(--cw-edge); width: max-content; margin: 0 0 16px; }
    body.view-web #cw-views { margin: 0; border-width: 0 1px 0 0; }
    #cw-views button { width: 92px; }
    .cw, #cw-views { --cw-accent: #FF4F1F; --cw-surface: #111214; --cw-chip: #1A1B1F; --cw-edge: #2C2E33;
      --cw-rule-soft: #1F2024; --cw-ink: #FFFFFF; --cw-text: rgba(255,255,255,.92); --cw-text-2: rgba(255,255,255,.58);
      --cw-text-dim: rgba(255,255,255,.46); --cw-inv-bg: #FFFFFF; --cw-inv-fg: #111214; --cw-halo: #111214;
      --cw-mono: "SF Mono", ui-monospace, Menlo, monospace; --cw-sans: -apple-system, "SF Pro Text", system-ui, sans-serif; }
    @media (prefers-color-scheme: light) {
      .cw, #cw-views { --cw-surface: #FFFFFF; --cw-chip: #F2F2F4; --cw-edge: #111214; --cw-rule-soft: #D3D4D8;
        --cw-ink: #111214; --cw-text: #111214; --cw-text-2: #111214; --cw-text-dim: rgba(17,18,20,.5);
        --cw-inv-bg: #111214; --cw-inv-fg: #FFFFFF; --cw-halo: #FFFFFF; }
    }
    body.view-web { background: var(--cw-surface-body, #111214); }
    @media (prefers-color-scheme: light) { body.view-web { background: #FFFFFF; } }
    .cw *, #cw-views * { box-sizing: border-box; border-radius: 0; }
    #cw { position: fixed; inset: 0; display: grid; grid-template-rows: auto auto 1fr; grid-template-columns: minmax(0, 1fr); overflow: hidden; background: var(--cw-surface);
      color: var(--cw-text); font: 13px/18px var(--cw-sans); font-variant-numeric: tabular-nums; }
    .cw-label { font: 500 10px/14px var(--cw-mono); letter-spacing: .06em; text-transform: uppercase; color: var(--cw-text-2); }
    .cw-head { display: grid; grid-template-columns: 1fr auto; gap: 2px 24px; padding: 14px 20px 10px; border-bottom: 1px solid var(--cw-edge); }
    .cw-head h1 { margin: 0; font: 600 22px/26px var(--cw-sans); }
    .cw-lede { color: var(--cw-text-2); }
    .cw-stamp { grid-row: 1 / span 3; grid-column: 2; display: grid; grid-template-columns: auto auto; border: 1px solid var(--cw-edge); align-self: start; }
    .cw-stamp div { padding: 3px 10px; border-bottom: 1px solid var(--cw-rule-soft); font: 500 10px/14px var(--cw-mono); letter-spacing: .06em; text-transform: uppercase; }
    .cw-stamp div:nth-child(odd) { color: var(--cw-text-2); border-right: 1px solid var(--cw-rule-soft); }
    .cw-stamp div:nth-last-child(-n+2) { border-bottom: 0; }
    .cw-controls { display: flex; flex-wrap: wrap; gap: 10px 22px; align-items: center; padding: 10px 20px; border-bottom: 1px solid var(--cw-edge); }
    .cw-group { display: flex; align-items: center; gap: 8px; }
    .cw-seg { display: flex; border: 1px solid var(--cw-edge); }
    .cw button, #cw-views button, .cw select { background: var(--cw-chip); color: var(--cw-text); border: 0; height: 26px; padding: 0 10px; margin: 0;
      font: 500 10.5px var(--cw-mono); letter-spacing: .06em; text-transform: uppercase; cursor: pointer; min-height: 0; }
    .cw-seg button { width: 92px; }
    .cw-seg.cw-narrow button { width: 56px; }
    .cw-seg button + button, #cw-views button + button { border-left: 1px solid var(--cw-edge); }
    .cw button[aria-pressed="true"], #cw-views button[aria-pressed="true"] { background: var(--cw-inv-bg); color: var(--cw-inv-fg); }
    .cw select { width: 300px; border: 1px solid var(--cw-edge); text-transform: none; letter-spacing: 0; }
    .cw select:disabled { color: var(--cw-text-dim); cursor: default; }
    .cw button:active, .cw-row:active { opacity: .55; }
    .cw-bk, #cw-views button { position: relative; }
    .cw-bk::after, #cw-views button::after { content: ""; position: absolute; inset: -5px; pointer-events: none; opacity: 0; transition: opacity 60ms linear;
      --l: 6px; --w: 1.5px; --c: var(--cw-ink);
      background:
        linear-gradient(var(--c),var(--c)) top left / var(--l) var(--w), linear-gradient(var(--c),var(--c)) top left / var(--w) var(--l),
        linear-gradient(var(--c),var(--c)) top right / var(--l) var(--w), linear-gradient(var(--c),var(--c)) top right / var(--w) var(--l),
        linear-gradient(var(--c),var(--c)) bottom left / var(--l) var(--w), linear-gradient(var(--c),var(--c)) bottom left / var(--w) var(--l),
        linear-gradient(var(--c),var(--c)) bottom right / var(--l) var(--w), linear-gradient(var(--c),var(--c)) bottom right / var(--w) var(--l);
      background-repeat: no-repeat; }
    .cw-bk:hover::after, #cw-views button:hover::after { opacity: .78; }
    .cw-main { display: grid; grid-template-columns: minmax(0, 1fr) 440px; min-height: 0; min-width: 0; }
    .cw-main > * { min-width: 0; }
    #cw-stage { position: relative; min-width: 0; min-height: 0; border-right: 1px solid var(--cw-edge); overflow: hidden;
      background-image: radial-gradient(var(--cw-rule-soft) 1px, transparent 1px); background-size: 16px 16px; cursor: grab; }
    #cw-stage.cw-panning { cursor: grabbing; }
    #cw-svg { width: 100%; height: 100%; display: block; user-select: none; -webkit-user-select: none; }
    .cw-legend { position: absolute; left: 14px; bottom: 12px; background: var(--cw-surface); border: 1px solid var(--cw-edge);
      padding: 8px 10px; display: grid; grid-template-columns: 26px auto; gap: 4px 8px; align-items: center; }
    .cw-legend svg { width: 26px; height: 12px; }
    .cw-hint { position: absolute; right: 14px; top: 10px; }
    @media (max-width: 1100px) { .cw-hint { display: none; } }
    .cw-empty-stage { position: absolute; inset: 0; display: grid; place-items: center; pointer-events: none; }
    .cw-empty-stage[hidden] { display: none; }
    #cw-inspector { overflow-y: auto; overflow-x: hidden; padding: 16px 20px 40px; min-width: 0; }
    .cw-zone { display: flex; align-items: center; gap: 8px; margin: 18px 0 8px; }
    .cw-zone:first-child { margin-top: 0; }
    .cw-zone .cw-sq { width: 18px; height: 16px; border: 1px solid var(--cw-edge); display: grid; place-items: center; font: 600 9.5px var(--cw-mono); }
    .cw-zone .cw-rule { flex: 1; height: 1px; background: var(--cw-edge); }
    .cw-title2 { font: 600 18px/22px var(--cw-sans); margin: 4px 0 6px; overflow-wrap: anywhere; }
    .cw-facts { display: grid; grid-template-columns: 110px 1fr; border-top: 1px solid var(--cw-rule-soft); }
    .cw-facts > div { padding: 5px 0; border-bottom: 1px solid var(--cw-rule-soft); min-width: 0; overflow-wrap: anywhere; }
    .cw-facts > div:nth-child(odd) { font: 500 10px/18px var(--cw-mono); letter-spacing: .06em; text-transform: uppercase; color: var(--cw-text-2); }
    .cw-facts > div:nth-child(even) { font: 12px/18px var(--cw-mono); }
    .cw-actions { display: flex; flex-wrap: wrap; gap: 12px; margin: 12px 0 0; }
    .cw-actions a { display: inline-flex; align-items: center; height: 26px; padding: 0 10px; background: var(--cw-chip); color: var(--cw-text);
      text-decoration: none; font: 500 10.5px var(--cw-mono); letter-spacing: .06em; text-transform: uppercase; }
    .cw table { width: 100%; border-collapse: collapse; table-layout: fixed; }
    .cw th { font: 500 10px var(--cw-mono); letter-spacing: .06em; text-transform: uppercase; color: var(--cw-text-2); text-align: left; padding: 4px 6px; border-bottom: 1px solid var(--cw-edge); }
    .cw td { padding: 5px 6px; border-bottom: 1px solid var(--cw-rule-soft); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font: 12px/18px var(--cw-mono); vertical-align: top; }
    .cw td.cw-num, .cw th.cw-num { text-align: right; width: 40px; }
    .cw td.cw-when, .cw th.cw-when { width: 72px; text-align: right; color: var(--cw-text-2); }
    .cw tr.cw-row { cursor: pointer; }
    .cw tr.cw-row td:first-child { font: 13px/18px var(--cw-sans); }
    .cw td .cw-sub { display: block; color: var(--cw-text-2); font-size: 12px; overflow: hidden; text-overflow: ellipsis; padding-left: 14px; }
    .cw-sqm { display: inline-block; width: 8px; height: 8px; margin-right: 6px; border: 1px solid var(--cw-ink); }
    .cw-sqm.on { background: var(--cw-ink); }
    .cw-sqm.hot { background: var(--cw-accent); border-color: var(--cw-accent); }
    .cw-empty { color: var(--cw-text-dim); padding: 12px 0; font: 12px var(--cw-mono); }
    .cw-msg { border-bottom: 1px solid var(--cw-rule-soft); padding: 8px 0; }
    .cw-msg .cw-mhead { display: grid; grid-template-columns: 1fr auto; gap: 8px; font: 500 10px/14px var(--cw-mono); letter-spacing: .06em; text-transform: uppercase; color: var(--cw-text-2); }
    .cw-msg .cw-who { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .cw-msg .cw-who b { color: var(--cw-text); font-weight: 600; }
    .cw-msg .cw-body { margin-top: 4px; white-space: pre-wrap; overflow-wrap: anywhere; font: 12px/17px var(--cw-mono); max-height: 102px; overflow: hidden; cursor: pointer; }
    .cw-msg .cw-body.open { max-height: none; cursor: auto; }
    .cw-msg.hot .cw-t { color: var(--cw-accent); }
    .cw-tag { display: inline-block; padding: 0 4px; border: 1px solid var(--cw-edge); margin-right: 6px; }
    #cw-svg text { font-family: var(--cw-mono); }
    .cw-node { cursor: pointer; }
    .cw-node .cw-lbl { font-size: 10.5px; fill: var(--cw-text); paint-order: stroke; stroke: var(--cw-halo); stroke-width: 3px; }
    .cw-node.closed .cw-lbl { fill: var(--cw-text-dim); }
    .cw-node .cw-bkt { opacity: 0; transition: opacity 60ms linear; }
    .cw-node:hover .cw-bkt { opacity: .78; }
    .cw-edge { fill: none; }
    .cw-hit { fill: none; stroke: transparent; stroke-width: 12px; cursor: pointer; }
    .cw-cluster rect.cw-box { fill: none; stroke: var(--cw-edge); stroke-dasharray: 2 3; }
    .cw-cluster.home rect.cw-box { stroke-dasharray: none; }
    .cw-cluster text { font-family: var(--cw-sans); font-weight: 600; letter-spacing: .01em; fill: var(--cw-text); paint-order: stroke; stroke: var(--cw-halo); }
    .cw-cluster .cw-wsmeta { font-family: var(--cw-mono); font-weight: 500; letter-spacing: .06em; text-transform: uppercase; fill: var(--cw-text-2); }
    .cw-cluster .cw-letter { font-family: var(--cw-mono); font-weight: 600; fill: var(--cw-text); stroke-width: 0; }
    .cw-scrub-box { position: relative; width: 320px; height: 36px; }
    .cw #cw-scrub { -webkit-appearance: none; appearance: none; display: block; width: 100%; height: 20px; min-height: 0; margin: 0; padding: 0;
      background: transparent; border: 0; border-radius: 0; box-shadow: none; outline: 0; cursor: pointer; }
    #cw-scrub::-webkit-slider-runnable-track { height: 2px; background: var(--cw-edge); }
    #cw-scrub::-webkit-slider-thumb { -webkit-appearance: none; width: 12px; height: 18px; margin-top: -8px; background: var(--cw-ink); border: 0; }
    .cw #cw-scrub:focus-visible { outline: 1px solid var(--cw-ink); outline-offset: 2px; }
    .cw-ticks { position: absolute; left: 6px; right: 6px; top: 18px; height: 18px; }
    .cw .cw-tick { position: absolute; transform: translateX(-50%); padding: 4px 3px 0; background: none; border: 0; height: auto; min-height: 0;
      font: 500 9.5px/12px var(--cw-mono); letter-spacing: .06em; color: var(--cw-text-2); cursor: pointer; }
    .cw-tick::before { content: ""; position: absolute; left: 50%; top: -4px; width: 1px; height: 6px; background: var(--cw-text-2); }
    .cw .cw-tick.on { color: var(--cw-ink); font-weight: 600; }
    .cw-scrub-val { display: inline-block; width: 124px; font: 600 12px/18px var(--cw-mono); white-space: nowrap; }
    .cw-card { position: absolute; z-index: 5; width: 320px; background: var(--cw-surface); border: 1px solid var(--cw-ink); padding: 9px 11px 8px; pointer-events: none; box-shadow: 0 8px 24px rgba(0,0,0,.35); }
    .cw-card[hidden] { display: none; }
    .cw-card .cw-ct { font: 600 14px/18px var(--cw-sans); overflow-wrap: anywhere; }
    .cw-card .cw-cd { margin-top: 4px; font: 12.5px/17px var(--cw-sans); color: var(--cw-text); white-space: pre-wrap; overflow-wrap: anywhere;
      display: -webkit-box; -webkit-line-clamp: 4; -webkit-box-orient: vertical; overflow: hidden; }
    .cw-card .cw-cd.none { color: var(--cw-text-dim); }
    .cw-card .cw-cm { margin-top: 6px; font: 500 10px/14px var(--cw-mono); letter-spacing: .06em; text-transform: uppercase; color: var(--cw-text-2); }
    .cw-desc { margin: 0 0 8px; font: 13px/18px var(--cw-sans); color: var(--cw-text); white-space: pre-wrap; overflow-wrap: anywhere; }
    .cw-desc.none { color: var(--cw-text-dim); }
    .cw-story { margin: 8px 0 12px; padding: 8px 10px; border-left: 2px solid var(--cw-accent); background: var(--cw-chip); font: 13px/19px var(--cw-sans); color: var(--cw-text); overflow-wrap: anywhere; }
    .cw-quote { display: block; margin-top: 6px; color: var(--cw-text-2); font: 12px/17px var(--cw-mono); overflow-wrap: anywhere; }
    .cw-note { display: grid; grid-template-columns: 84px 1fr; gap: 10px; padding: 5px 0; border-bottom: 1px solid var(--cw-rule-soft); font: 12.5px/17px var(--cw-sans); }
    .cw-note .cw-t { font: 11px/17px var(--cw-mono); color: var(--cw-text-2); text-align: right; white-space: nowrap; }
    .cw-note div:last-child { overflow-wrap: anywhere; white-space: pre-wrap; }
    .cw-node .cw-sqr { transition: transform 90ms ease-out; transform-box: fill-box; transform-origin: center; }
    .cw-node:hover .cw-sqr, .cw-node.near-self .cw-sqr { transform: scale(1.4); }
    .cw-node:hover .cw-lbl, .cw-node.near-self .cw-lbl { font-weight: 600; }
    #cw-svg .cw-node, #cw-svg .cw-edge-g { transition: opacity 80ms linear; }
    #cw-svg.cw-hovering .cw-node:not(.near) { opacity: .14; }
    #cw-svg.cw-hovering .cw-edge-g:not(.near) { opacity: .06; }
    #cw-svg.cw-hovering .cw-edge-g.near .cw-edge { stroke-opacity: 1; }
    @media (max-width: 900px) {
      .cw-main { grid-template-columns: minmax(0, 1fr); grid-template-rows: minmax(240px, 1fr) minmax(180px, 42%); }
      #cw-stage { border-right: 0; border-bottom: 1px solid var(--cw-edge); }
      #cw-inspector { padding: 12px 14px 24px; }
      .cw-head { grid-template-columns: 1fr; padding: 10px 14px 8px; }
      .cw-stamp, .cw-legend { display: none; }
      .cw-controls { padding: 8px 14px; gap: 8px 14px; }
      .cw select { width: 220px; }
    }
    @media (prefers-reduced-motion: reduce) { .cw *, #cw-views * { transition: none !important; } }
    """#

    static let markup = #"""
    <nav id="cw-views" aria-label="Messages views"><button type="button" data-view="web">Web</button><button type="button" data-view="traffic">Traffic</button></nav>
    <div id="cw" class="cw">
      <div class="cw-head">
        <div class="cw-label" id="cw-placard">c11 / conversation web</div>
        <h1>Conversation web</h1>
        <div class="cw-lede" id="cw-lede"></div>
        <div class="cw-stamp" id="cw-stamp"></div>
      </div>
      <div class="cw-controls">
        <div class="cw-group" id="cw-views-slot"></div>
        <div class="cw-group"><span class="cw-label">Scope</span>
          <div class="cw-seg" id="cw-scope"><button type="button" class="cw-bk" data-v="instance">Instance</button><button type="button" class="cw-bk" data-v="workspace">Workspace</button><button type="button" class="cw-bk" data-v="panel">Panel</button></div>
          <select id="cw-picker" class="cw-bk" aria-label="Scope target"></select>
        </div>
        <div class="cw-group"><span class="cw-label">Channel</span>
          <div class="cw-seg" id="cw-channels"><button type="button" class="cw-bk" data-v="mailbox" style="width:72px">Mail</button><button type="button" class="cw-bk" data-v="send" style="width:72px">Send</button></div>
        </div>
        <div class="cw-group"><span class="cw-label">Panels</span>
          <div class="cw-seg" id="cw-closed"><button type="button" class="cw-bk" data-v="hide" title="Every open panel, quiet ones included; conversations between open panels only">Open now</button><button type="button" class="cw-bk" data-v="show" title="Every panel that has talked, open or closed">History</button></div>
        </div>
        <div class="cw-group"><span class="cw-label">Since</span>
          <div class="cw-scrub-box"><input type="range" id="cw-scrub" min="0" max="1000" step="1" aria-label="How far back to show"><div class="cw-ticks" id="cw-ticks"></div></div>
          <span class="cw-scrub-val" id="cw-scrub-val"></span>
        </div>
        <div class="cw-group"><button type="button" class="cw-bk" id="cw-relayout" title="Forget where panels sit in this scope and lay them out again">Re-lay out</button></div>
      </div>
      <div class="cw-main">
        <div id="cw-stage">
          <svg id="cw-svg"><defs id="cw-defs"></defs><g id="cw-view"><g id="cw-clusters"></g><g id="cw-edges"></g><g id="cw-nodes"></g></g></svg>
          <div class="cw-empty-stage cw-label" id="cw-empty" hidden>No conversations in this scope and window</div>
          <div class="cw-card" id="cw-card" hidden></div>
          <div class="cw-legend cw-label">
            <svg viewBox="0 0 26 12"><rect x="9" y="2" width="8" height="8" fill="var(--cw-ink)"/></svg><span>Open panel</span>
            <svg viewBox="0 0 26 12"><rect x="10" y="3" width="6" height="6" fill="var(--cw-text-dim)"/></svg><span>Open, quiet in window</span>
            <svg viewBox="0 0 26 12"><rect x="9.5" y="2.5" width="7" height="7" fill="var(--cw-surface)" stroke="var(--cw-ink)"/></svg><span>Closed panel</span>
            <svg viewBox="0 0 26 12"><rect x="9" y="2" width="8" height="8" fill="var(--cw-accent)"/></svg><span>Traffic, last 15 min</span>
            <svg viewBox="0 0 26 12"><line x1="1" y1="6" x2="25" y2="6" stroke="var(--cw-ink)" stroke-width="1.5"/></svg><span>Mailbox</span>
            <svg viewBox="0 0 26 12"><line x1="1" y1="6" x2="25" y2="6" stroke="var(--cw-ink)" stroke-width="1.5" stroke-dasharray="4 3"/></svg><span>c11 send (typed)</span>
          </div>
          <div class="cw-hint cw-label">Hover to preview · click to inspect · double-click to centre · drag to pan · scroll to zoom</div>
        </div>
        <aside id="cw-inspector"></aside>
      </div>
    </div>
    """#

    static let script = #"""
    (() => {
      "use strict";
      // Set when the web could not be drawn; every later callback stands down.
      let broken = false;
      try {
      const raw = JSON.parse(document.getElementById("messages-data").textContent || "{}");
      const directory = raw.directory || {};
      const scheme = directory.link_scheme || "c11";
      let NOW = Date.now();
      const HOT_MS = 15 * 60 * 1000;
      const WINDOWS = { "1h": 3600e3, "6h": 6 * 3600e3, "24h": 86400e3, "7d": 7 * 86400e3, all: Infinity };
      const GENERIC = new Set(["Terminal", "Shell", "zsh", "bash", "Browser", "Markdown", "~"]);
      const AGENTS = { "claude-code": "Claude Code", claude: "Claude Code", codex: "Codex", opencode: "OpenCode", grok: "Grok", pi: "Pi", omp: "omp", kimi: "Kimi", copilot: "Copilot" };
      const clip = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
      // A subtitle's first line that says something: never its Lineage line.
      const noLineage = (l) => l.replace(/\s*Lineage:.*$/i, "").trim();
      const firstLine = (s) => (typeof s === "string" ? s.split("\n").map(noLineage).find(Boolean) || "" : "");
      const sayLines = (s) => (typeof s === "string" ? s.split("\n").map(noLineage).filter(Boolean).join("\n") : "");
      const NO_WS = "__none__";
      const up = (v) => (typeof v === "string" ? v.toUpperCase() : null);
      const isUUID = (v) => typeof v === "string" && /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i.test(v);

      // ---------- model: panels, workspaces, messages with both ends resolved ----------
      const P = new Map();
      const W = new Map();
      const panel = (id) => {
        if (!P.has(id)) P.set(id, { id, title: null, workspace: null, live: false, type: null, agent: null, address: null, parent: null, desc: null, notes: [], closedAt: null });
        return P.get(id);
      };
      const workspace = (id, title, live) => {
        if (!id) return;
        if (!W.has(id)) W.set(id, { id, title: null, live: false });
        const w = W.get(id);
        if (title && !w.title) w.title = title;
        if (live) w.live = true;
      };
      (directory.workspaces || []).forEach((w) => workspace(up(w.id), w.title, w.live));
      const addressToPanel = new Map();
      (directory.panels || []).forEach((d) => {
        const p = panel(up(d.id));
        Object.assign(p, { title: d.title || null, workspace: up(d.workspace), live: !!d.live, type: d.type || null,
          agent: d.agent || null, address: d.address || null, parent: up(d.parent), desc: typeof d.description === "string" ? d.description : null,
          notes: Array.isArray(d.notes) ? d.notes.filter((n) => n && typeof n.text === "string" && Number.isFinite(Date.parse(n.at))) : [],
          closedAt: Number.isFinite(Date.parse(d.closed)) ? Date.parse(d.closed) : null });
        if (d.address && d.live) addressToPanel.set(d.address, p.id);
      });
      const rows = Array.isArray(raw.messages) ? raw.messages : [];
      rows.forEach((m) => {
        if (m.channel !== "mailbox" || !m.surface || !m.recipient || /^id:/i.test(m.recipient)) return;
        // A role or broadcast address reaches several panels; it names none of them.
        if (Array.isArray(m.recipient_panel_ids) && m.recipient_panel_ids.length > 1) return;
        if (!addressToPanel.has(m.recipient)) addressToPanel.set(m.recipient, up(m.surface));
      });
      const resolveAddress = (address) => {
        if (!address) return null;
        if (/^id:/i.test(address) && isUUID(address.slice(3))) return panel(up(address.slice(3))).id;
        if (addressToPanel.has(address)) return panel(addressToPanel.get(address)).id;
        const p = panel("ADDR:" + address);
        p.title = p.title || address;
        p.address = address;
        p.type = "address";
        return p.id;
      };
      const messages = [];
      rows.forEach((m) => {
        let from = null, to = null;
        if (m.channel === "send") {
          from = isUUID(m.caller_panel_id || m.sender_id) ? panel(up(m.caller_panel_id || m.sender_id)).id : resolveAddress(m.caller_title || m.sender || "unknown sender");
          to = isUUID(m.surface) ? panel(up(m.surface)).id : null;
          if (from && m.caller_title) P.get(from).title = P.get(from).title || m.caller_title;
          if (to && m.target_title) P.get(to).title = P.get(to).title || m.target_title;
        } else if (m.channel === "mailbox") {
          from = isUUID(m.sender_id) ? panel(up(m.sender_id)).id : resolveAddress(m.sender || "unknown sender");
          const panels = (Array.isArray(m.recipient_panel_ids) ? m.recipient_panel_ids : []).filter(isUUID);
          if (panels.length) to = panels.map((id) => panel(up(id)).id);
          else to = isUUID(m.surface) ? panel(up(m.surface)).id : resolveAddress(m.recipient);
          if (Array.isArray(to) && to.length === 1) to = to[0];
          if (typeof to === "string" && m.recipient && !/^id:/i.test(m.recipient)) P.get(to).address = P.get(to).address || m.recipient;
        }
        if (!from || !to) return;
        const ms = Date.parse(m.timestamp);
        if (!Number.isFinite(ms)) return;
        (Array.isArray(to) ? to : [to]).forEach((target) => {
          if (m.workspace && isUUID(m.workspace) && !Array.isArray(to)) {
            workspace(up(m.workspace));
            const t = P.get(target);
            if (!t.workspace && t.type !== "address") t.workspace = up(m.workspace);
          }
          messages.push({ id: m.id, ch: m.channel, from, to: target, ms, status: m.status, topic: m.topic || null,
            body: m.text_recorded === false ? "" : (m.body || (m.body_ref ? "body_ref: " + m.body_ref : "")), cut: !!m.truncated });
        });
      });
      messages.sort((a, b) => a.ms - b.ms);
      // A panel is named by its title; a panel without a real one by its
      // mailbox address, then by what its subtitle says it is doing. A short
      // id is the last resort, kept only to tell two unnamed panels apart.
      P.forEach((p) => {
        if (p.workspace) workspace(p.workspace);
        if (p.title && !GENERIC.has(p.title)) return;
        const said = firstLine(p.desc);
        const kind = p.agent ? AGENTS[p.agent] || p.agent : p.title === "Browser" || p.title === "Markdown" ? p.title
          : p.title || p.type === "terminal" ? "Terminal" : "Unnamed panel";
        p.title = p.address || (said ? clip(said, 44) : kind + " " + p.id.slice(0, 4));
      });
      W.forEach((w) => { if (!w.title) w.title = "Workspace " + w.id.slice(0, 6); });
      W.set(NO_WS, { id: NO_WS, title: "Unplaced", live: false });
      const wsOf = (id) => (P.get(id) && P.get(id).workspace && W.has(P.get(id).workspace) ? P.get(id).workspace : NO_WS);
      const titleOf = (id) => (P.get(id) && P.get(id).title) || "Unnamed panel " + String(id).slice(0, 4);
      const isLive = (id) => !!(P.get(id) && P.get(id).live);
      const involved = new Set(messages.flatMap((m) => [m.from, m.to]));
      const wsTraffic = new Map();
      messages.forEach((m) => [m.from, m.to].forEach((id) => wsTraffic.set(wsOf(id), (wsTraffic.get(wsOf(id)) || 0) + 1)));
      const wsOrder = [...new Set([...involved].map(wsOf))].sort((a, b) => (b !== NO_WS) - (a !== NO_WS) || (wsTraffic.get(b) || 0) - (wsTraffic.get(a) || 0));
      // Letters are kept for the session, so a burst of traffic never relabels a cluster.
      const LETTER_STORE = "c11.messages.web.letters.v1";
      let storedLetters = {};
      try { const parsed = JSON.parse(sessionStorage.getItem(LETTER_STORE) || "{}"); if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) storedLetters = parsed; } catch (_) {}
      const labelFor = (i) => (i < 26 ? String.fromCharCode(65 + i) : String(i + 1));
      const LETTER = new Map();
      const usedLetters = new Set();
      wsOrder.forEach((id) => { if (typeof storedLetters[id] === "string") { LETTER.set(id, storedLetters[id]); usedLetters.add(storedLetters[id]); } });
      let nextLetter = 0;
      wsOrder.forEach((id) => {
        if (LETTER.has(id)) return;
        while (usedLetters.has(labelFor(nextLetter))) nextLetter++;
        LETTER.set(id, labelFor(nextLetter)); usedLetters.add(labelFor(nextLetter));
      });
      try { sessionStorage.setItem(LETTER_STORE, JSON.stringify(Object.assign({}, storedLetters, Object.fromEntries(LETTER)))); } catch (_) {}
      // A workspace drawn only for its quiet open panels gets the next free letter on first use.
      const letterOf = (id) => {
        if (!LETTER.has(id)) {
          while (usedLetters.has(labelFor(nextLetter))) nextLetter++;
          LETTER.set(id, labelFor(nextLetter)); usedLetters.add(labelFor(nextLetter));
          try { sessionStorage.setItem(LETTER_STORE, JSON.stringify(Object.assign({}, storedLetters, Object.fromEntries(LETTER)))); } catch (_) {}
        }
        return LETTER.get(id);
      };

      // ---------- state, kept per browser panel across the page's live reloads ----------
      const STORE = "c11.messages.web.v1";
      const state = { scope: "instance", ws: null, panel: null, ch: ["mailbox", "send"], win: "all", closed: "show", sel: null };
      // The window is a span in ms, or "all". Older pages saved "1h" and friends.
      const spanOf = () => (typeof state.win === "number" && state.win > 0 ? state.win : WINDOWS[state.win] || Infinity);
      const VIEW = { k: 1, x: 0, y: 0 };
      let consumed = null, viewName = "web", fitted = false, userMoved = false;
      try {
        const saved = JSON.parse(sessionStorage.getItem(STORE) || "null");
        if (saved) { Object.assign(state, saved.state || {}); Object.assign(VIEW, saved.view || {}); consumed = saved.consumed || null; viewName = saved.viewName || "web"; fitted = !!saved.view; userMoved = !!saved.userMoved; }
      } catch (_) {}
      const save = () => { try { sessionStorage.setItem(STORE, JSON.stringify({ state, view: VIEW, consumed, viewName, userMoved })); } catch (_) {} };
      const applyLink = (hash) => {
        const match = /^#web(?::(panel|workspace)=([0-9A-Fa-f-]{36}))?(?:&n=\d+)?$/.exec(hash || "");
        if (!match) return false;
        const id = match[2] ? up(match[2]) : null;
        if (match[1] === "panel") { state.scope = "panel"; state.panel = id; state.sel = { kind: "node", id }; }
        else if (match[1] === "workspace") { state.scope = "workspace"; state.ws = id; state.sel = null; }
        else { state.scope = "instance"; state.sel = null; }
        consumed = hash; viewName = "web"; fitted = false;
        return true;
      };
      if (location.hash.startsWith("#web") && location.hash !== consumed) applyLink(location.hash);

      // ---------- formatting ----------
      const when = (ms) => {
        const d = new Date(ms), today = new Date(NOW);
        const time = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
        return d.toDateString() === today.toDateString() ? time : d.toLocaleDateString([], { month: "short", day: "numeric" }) + " " + time;
      };
      const ago = (ms) => {
        const s = Math.max(0, (NOW - ms) / 1000);
        if (s < 60) return "now";
        if (s < 3600) return Math.floor(s / 60) + "m ago";
        if (s < 86400) return Math.floor(s / 3600) + "h ago";
        return Math.floor(s / 86400) + "d ago";
      };
      const trunc = (s, n) => (s.length > n ? s.slice(0, n - 1) + "…" : s);
      const spanText = (ms) => {
        if (!Number.isFinite(ms)) return "All recorded";
        const m = Math.round(ms / 60e3);
        if (m < 60) return `Last ${m} min`;
        const hr = Math.floor(m / 60), mm = m % 60;
        if (m <= 1440) { if (mm && hr < 10) return `Last ${hr}h ${mm}m`; const n = Math.round(m / 60); return n === 1 ? "Last hour" : `Last ${n} hours`; }
        const d = Math.floor(m / 1440), dh = Math.round((m - d * 1440) / 60);
        if (dh && d < 7) return `Last ${d}d ${dh}h`;
        const n = Math.round(m / 1440);
        return n === 1 ? "Last day" : `Last ${n} days`;
      };

      // ---------- shaping ----------
      const filtered = () => {
        const span = spanOf();
        return messages.filter((m) => state.ch.includes(m.ch) && NOW - m.ms <= span && (state.closed === "show" || (isLive(m.from) && isLive(m.to))));
      };
      const scoped = (ms) => {
        if (state.scope === "workspace" && state.ws) return ms.filter((m) => wsOf(m.from) === state.ws || wsOf(m.to) === state.ws);
        if (state.scope === "panel" && state.panel) {
          const direct = ms.filter((m) => m.from === state.panel || m.to === state.panel);
          const peers = new Set(direct.flatMap((m) => [m.from, m.to]));
          return ms.filter((m) => peers.has(m.from) && peers.has(m.to));
        }
        return ms;
      };
      // Endpoints are kept as fields; ids can hold any character an address can.
      const pairKey = (a, b) => JSON.stringify(a < b ? [a, b] : [b, a]);
      const dirOf = (p, from) => (from === p.a ? p.ab : p.ba);
      const aggregate = (ms, quiet) => {
        const nodes = new Map(), pairs = new Map();
        const node = (id) => { if (!nodes.has(id)) nodes.set(id, { id, sent: 0, recv: 0, last: 0 }); return nodes.get(id); };
        (quiet || []).forEach(node);
        for (const m of ms) {
          const a = node(m.from), b = node(m.to);
          a.sent++; b.recv++; a.last = Math.max(a.last, m.ms); b.last = Math.max(b.last, m.ms);
          const k = pairKey(m.from, m.to);
          if (!pairs.has(k)) {
            const [x, y] = m.from < m.to ? [m.from, m.to] : [m.to, m.from];
            pairs.set(k, { key: k, a: x, b: y, ab: { mailbox: 0, send: 0, last: 0 }, ba: { mailbox: 0, send: 0, last: 0 }, count: 0, last: 0, msgs: [] });
          }
          const p = pairs.get(k), d = dirOf(p, m.from);
          d[m.ch]++; d.last = Math.max(d.last, m.ms); p.count++; p.last = Math.max(p.last, m.ms); p.msgs.push(m);
        }
        nodes.forEach((n) => { n.total = n.sent + n.recv; n.hot = n.total > 0 && NOW - n.last < HOT_MS; n.quiet = n.total === 0; });
        return { nodes, pairs };
      };

      // ---------- layout: workspaces as clusters, a small force simulation inside each ----------
      const hash32 = (s) => { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; };
      const rng = (seed) => () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
      const nodeSize = (n) => Math.round(8 + 3.2 * Math.log2(n.total + 1));
      const labelW = (id) => Math.min(titleOf(id).length, 30) * 6.4 + 8;
      // "Open now" draws every open terminal in scope, quiet ones included.
      const openTerminal = (p) => p.live && p.type !== "browser" && p.type !== "markdown" && p.type !== "address" && isUUID(p.id);
      const quietOpen = () => {
        if (state.closed !== "hide" || state.scope === "panel") return [];
        return [...P.values()].filter((p) => openTerminal(p) && (state.scope !== "workspace" || wsOf(p.id) === state.ws)).map((p) => p.id);
      };
      // ---------- position memory: what is drawn stays where it is ----------
      // c11 rewrites and reloads this page on every burst of traffic. Each
      // panel's place is remembered per scope, so a reload moves nothing that
      // is already drawn; only new panels are placed.
      const POS_STORE = "c11.messages.web.positions.v1";
      let positionMemory = {};
      try { positionMemory = JSON.parse(sessionStorage.getItem(POS_STORE) || "{}"); } catch (_) { positionMemory = {}; }
      if (!positionMemory || typeof positionMemory !== "object" || Array.isArray(positionMemory)) positionMemory = {};
      const MAX_REMEMBERED = 3000;
      const writePositions = () => {
        try { sessionStorage.setItem(POS_STORE, JSON.stringify(positionMemory)); return; } catch (_) {}
        // Full: keep only the current scope, then try once more.
        const key = scopeKey();
        positionMemory = { [key]: positionMemory[key] || {} };
        try { sessionStorage.setItem(POS_STORE, JSON.stringify(positionMemory)); }
        catch (error) { console.warn("conversation web: panel positions not saved", error); }
      };
      const scopeKey = () => state.scope + ":" + (state.scope === "workspace" ? state.ws : state.scope === "panel" ? state.panel : "");
      // Merged, not replaced: a panel hidden by a filter or aged out of the
      // time window keeps its place for when it comes back.
      const rememberPositions = () => {
        if (!current || current.lay.pos.size === 0) return;
        const key = scopeKey();
        const entry = Object.assign({}, positionMemory[key] || {});
        const seen = Date.now();
        current.lay.pos.forEach((p, id) => { entry[id] = [p.x, p.y, p.g, seen]; });
        const ids = Object.keys(entry);
        if (ids.length > MAX_REMEMBERED) {
          ids.sort((a, b) => (entry[a][3] || 0) - (entry[b][3] || 0))
            .slice(0, ids.length - MAX_REMEMBERED).forEach((id) => delete entry[id]);
        }
        delete positionMemory[key];
        positionMemory[key] = entry;
        const keys = Object.keys(positionMemory);
        keys.slice(0, Math.max(0, keys.length - 8)).forEach((k) => delete positionMemory[k]);
        writePositions();
      };
      const forgetPositions = () => { delete positionMemory[scopeKey()]; writePositions(); };

      const layout = (agg) => {
        const home = state.scope === "workspace" ? state.ws : state.scope === "panel" ? wsOf(state.panel) : null;
        const groups = new Map();
        agg.nodes.forEach((n) => { const g = wsOf(n.id); if (!groups.has(g)) groups.set(g, []); groups.get(g).push(n); });
        const radius = (g) => 50 + 46 * Math.sqrt(groups.get(g).length);
        const order = [...groups.keys()].sort((a, b) => (a === home ? -1 : b === home ? 1 : groups.get(b).length - groups.get(a).length));
        const centers = new Map();
        if (home && groups.has(home)) {
          centers.set(home, { x: 0, y: 0 });
          const others = order.filter((g) => g !== home);
          const ring = radius(home) + (others.length ? Math.max(...others.map(radius)) : 0) + 120;
          others.forEach((g, i) => { const a = -Math.PI / 2 + (2 * Math.PI * i) / others.length; centers.set(g, { x: Math.cos(a) * ring * 1.35, y: Math.sin(a) * ring }); });
        } else {
          const total = order.reduce((s, g) => s + (2 * radius(g) + 140) ** 2, 0);
          const rowW = Math.max(900, Math.sqrt(total) * 1.5);
          let x = 0, y = 0, rowH = 0;
          order.forEach((g) => {
            const d = 2 * radius(g) + 140;
            if (x > 0 && x + d > rowW) { x = 0; y += rowH; rowH = 0; }
            centers.set(g, { x: x + d / 2, y: y + d / 2 }); x += d; rowH = Math.max(rowH, d);
          });
        }
        // Remembered panels keep their place. A workspace with remembered
        // panels is centred where they are; a workspace that is new to this
        // scope goes in a row below everything already drawn.
        const remembered = positionMemory[scopeKey()] || {};
        const fixedByGroup = new Map();
        agg.nodes.forEach((n) => {
          const r = remembered[n.id], g = wsOf(n.id);
          if (!r || r[2] !== g || !Number.isFinite(r[0]) || !Number.isFinite(r[1])) return;
          if (!fixedByGroup.has(g)) fixedByGroup.set(g, []);
          fixedByGroup.get(g).push([r[0], r[1]]);
        });
        if (fixedByGroup.size) {
          let minX = Infinity, maxY = -Infinity;
          fixedByGroup.forEach((points, g) => {
            const cx = points.reduce((s, q) => s + q[0], 0) / points.length, cy = points.reduce((s, q) => s + q[1], 0) / points.length;
            centers.set(g, { x: cx, y: cy });
            points.forEach((q) => { minX = Math.min(minX, q[0]); maxY = Math.max(maxY, q[1]); });
          });
          let maxX = -Infinity;
          fixedByGroup.forEach((points) => points.forEach((q) => { maxX = Math.max(maxX, q[0]); }));
          const rowW = Math.max(900, maxX - minX);
          let x = minX, y = maxY + 160, rowH = 0;
          order.filter((g) => !fixedByGroup.has(g)).forEach((g) => {
            const d = 2 * radius(g) + 140;
            if (x > minX && x + d > minX + rowW) { x = minX; y += rowH; rowH = 0; }
            centers.set(g, { x: x + d / 2, y: y + d / 2 }); x += d; rowH = Math.max(rowH, d);
          });
        }
        const pos = new Map();
        agg.nodes.forEach((n) => {
          const g = wsOf(n.id), c = centers.get(g), r = rng(hash32(n.id)), m = remembered[n.id];
          const keep = m && m[2] === g && Number.isFinite(m[0]) && Number.isFinite(m[1]);
          pos.set(n.id, keep
            ? { x: m[0], y: m[1], vx: 0, vy: 0, g, s: nodeSize(n), fixed: true }
            : { x: c.x + (r() - 0.5) * 120, y: c.y + (r() - 0.5) * 120, vx: 0, vy: 0, g, s: nodeSize(n) });
        });
        if (state.scope === "panel" && pos.has(state.panel) && !fixedByGroup.size) Object.assign(pos.get(state.panel), { x: centers.get(home).x, y: centers.get(home).y, pinned: true });
        const springs = [];
        agg.pairs.forEach((p) => { if (wsOf(p.a) === wsOf(p.b)) springs.push([p.a, p.b, p.count]); });
        const ids = [...pos.keys()];
        // Nothing new to place: draw exactly what was drawn before.
        const steps = ids.every((id) => pos.get(id).fixed) ? 0 : ids.length > 400 ? 160 : 320;
        // Only panels that can move are simulated: each against the others in
        // its workspace. Remembered panels push but are never pushed.
        const byGroup = new Map();
        ids.forEach((id) => { const g = pos.get(id).g; if (!byGroup.has(g)) byGroup.set(g, []); byGroup.get(g).push(id); });
        const movable = ids.filter((id) => !pos.get(id).fixed && !pos.get(id).pinned);
        const liveSprings = springs.filter(([x, y]) => !pos.get(x).fixed || !pos.get(y).fixed);
        for (let it = 0; it < steps; it++) {
          const cool = 1 - it / steps;
          for (const ia of movable) {
            const a = pos.get(ia);
            for (const ib of byGroup.get(a.g)) {
              if (ib === ia) continue;
              const b = pos.get(ib);
              let dx = a.x - b.x, dy = a.y - b.y;
              const d2 = dx * dx + dy * dy + 0.01, d = Math.sqrt(d2);
              const f = 5200 / d2 + (d < 46 ? (46 - d) * 0.5 : 0);
              a.vx += dx / d * f; a.vy += dy / d * f * 1.6;
            }
          }
          liveSprings.forEach(([x, y, c]) => {
            const a = pos.get(x), b = pos.get(y);
            const dx = b.x - a.x, dy = b.y - a.y, d = Math.sqrt(dx * dx + dy * dy) + 0.01;
            const f = (d - 90) * 0.02 * Math.min(3, 1 + Math.log2(c) / 3);
            a.vx += dx / d * f; a.vy += dy / d * f; b.vx -= dx / d * f; b.vy -= dy / d * f;
          });
          pos.forEach((p) => {
            const c = centers.get(p.g);
            p.vx += (c.x - p.x) * 0.012; p.vy += (c.y - p.y) * 0.012;
            if (p.pinned || p.fixed) { p.vx = 0; p.vy = 0; return; }
            const v = Math.hypot(p.vx, p.vy), cap = 30 * cool + 1;
            if (v > cap) { p.vx *= cap / v; p.vy *= cap / v; }
            p.x += p.vx; p.y += p.vy; p.vx *= 0.6; p.vy *= 0.6;
          });
        }
        // Positions are kept to a tenth of a point, the precision they are
        // remembered at, so a reload draws exactly what was drawn.
        pos.forEach((p) => { p.x = Math.round(p.x * 10) / 10; p.y = Math.round(p.y * 10) / 10; });
        return { pos, groups, home };
      };

      // ---------- rendering ----------
      const $ = (id) => document.getElementById(id);
      // The SVG namespace, read from the page's own <svg> so the page carries no URL text.
      const NS = $("cw-svg").namespaceURI;
      const el = (tag, attrs, parent) => { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); if (parent) parent.appendChild(e); return e; };
      const svg = $("cw-svg"), view = $("cw-view"), gClusters = $("cw-clusters"), gEdges = $("cw-edges"), gNodes = $("cw-nodes");
      let current = null, pendingFit = false, dragging = false;
      [["ink", "var(--cw-ink)"], ["hot", "var(--cw-accent)"]].forEach(([id, c]) => {
        const m = el("marker", { id: "cw-arrow-" + id, viewBox: "0 0 8 8", refX: 7, refY: 4, markerWidth: 6, markerHeight: 6, orient: "auto", markerUnits: "userSpaceOnUse" }, $("cw-defs"));
        el("path", { d: "M0,0 L8,4 L0,8 Z", fill: c }, m);
      });
      const edgeLit = (p) => { const s = state.sel; if (!s) return true; return s.kind === "node" ? p.a === s.id || p.b === s.id : p.key === s.key; };
      const nodeLit = (id) => {
        const s = state.sel; if (!s) return true;
        if (s.kind === "node") return id === s.id || current.agg.pairs.has(pairKey(id, s.id));
        const p = current.agg.pairs.get(s.key); return !!p && (p.a === id || p.b === id);
      };

      const drawEdges = () => {
        gEdges.textContent = "";
        const { agg, lay } = current;
        let max = 1;
        agg.pairs.forEach((p) => [p.ab, p.ba].forEach((d) => { max = Math.max(max, d.mailbox + d.send); }));
        agg.pairs.forEach((p) => {
          const lit = edgeLit(p);
          [[p.a, p.b, p.ab], [p.b, p.a, p.ba]].forEach(([from, to, d]) => {
            const n = d.mailbox + d.send;
            if (!n) return;
            const a = lay.pos.get(from), b = lay.pos.get(to);
            if (!a || !b || from === to) return;
            const dx = b.x - a.x, dy = b.y - a.y, len = Math.hypot(dx, dy) || 1;
            const ux = dx / len, uy = dy / len, bend = Math.min(40, 14 + len * 0.08);
            const cx = (a.x + b.x) / 2 - uy * bend, cy = (a.y + b.y) / 2 + ux * bend;
            const t1 = Math.hypot(cx - a.x, cy - a.y) || 1, t2 = Math.hypot(b.x - cx, b.y - cy) || 1;
            const sx = a.x + (cx - a.x) / t1 * (a.s / 2 + 3), sy = a.y + (cy - a.y) / t1 * (a.s / 2 + 3);
            const ex = b.x - (b.x - cx) / t2 * (b.s / 2 + 5), ey = b.y - (b.y - cy) / t2 * (b.s / 2 + 5);
            const path = `M${sx},${sy} Q${cx},${cy} ${ex},${ey}`;
            const hot = NOW - d.last < HOT_MS;
            const g = el("g", { class: "cw-edge-g", "data-a": from, "data-b": to }, gEdges);
            const hit = el("path", { d: path, class: "cw-hit" }, g);
            el("path", { d: path, class: "cw-edge", stroke: hot ? "var(--cw-accent)" : "var(--cw-ink)",
              "stroke-width": (1 + 3 * Math.log2(1 + n) / Math.log2(1 + max)).toFixed(2),
              "stroke-dasharray": d.mailbox ? "" : "5 4", "stroke-opacity": lit ? (hot ? 1 : 0.55) : 0.08,
              "marker-end": `url(#cw-arrow-${hot ? "hot" : "ink"})` }, g);
            hit.setAttribute("aria-label", `${titleOf(from)} to ${titleOf(to)}: ${d.mailbox} mail, ${d.send} send`);
            hit.addEventListener("click", (e) => { e.stopPropagation(); select({ kind: "pair", key: p.key }); });
            hit.addEventListener("mouseenter", (e) => { if (!busy()) { hoverEdge(from, to); edgeCard(p, from, to, d, e); } });
            hit.addEventListener("mousemove", (e) => { if (!card.hidden) placeCard(e.clientX, e.clientY); });
            hit.addEventListener("mouseleave", unhover);
          });
        });
      };

      const drawNodes = () => {
        gNodes.textContent = "";
        const { agg, lay } = current;
        agg.nodes.forEach((n) => {
          const p = lay.pos.get(n.id), s = p.s, live = isLive(n.id), info = P.get(n.id) || {};
          const selected = state.sel && state.sel.kind === "node" && state.sel.id === n.id;
          const g = el("g", { class: "cw-node" + (live ? "" : " closed"), "data-id": n.id, transform: `translate(${p.x},${p.y})`, opacity: nodeLit(n.id) ? 1 : 0.22 }, gNodes);
          el("rect", { class: "cw-sqr", x: -s / 2, y: -s / 2, width: s, height: s,
            fill: n.hot ? "var(--cw-accent)" : n.quiet ? "var(--cw-text-dim)" : live ? "var(--cw-ink)" : "var(--cw-surface)",
            stroke: n.hot ? "var(--cw-accent)" : "var(--cw-ink)", "stroke-width": live ? 0 : 1,
            "stroke-dasharray": info.type === "address" ? "2 2" : "" }, g);
          if (selected) el("rect", { x: -s / 2 - 4, y: -s / 2 - 4, width: s + 8, height: s + 8, fill: "none", stroke: "var(--cw-ink)", "stroke-width": 1.5 }, g);
          const o = s / 2 + (selected ? 8 : 5), l = 5;
          el("path", { class: "cw-bkt", fill: "none", stroke: "var(--cw-ink)", "stroke-width": 1.5,
            d: `M${-o},${-o + l}V${-o}H${-o + l} M${o - l},${-o}H${o}V${-o + l} M${o},${o - l}V${o}H${o - l} M${-o + l},${o}H${-o}V${o - l}` }, g);
          el("text", { class: "cw-lbl", x: s / 2 + 7, y: 4 }, g).textContent = trunc(titleOf(n.id), 30);
          g.setAttribute("aria-label", titleOf(n.id));
          g.addEventListener("mouseenter", (e) => { if (!busy()) { hoverNode(n.id); nodeCard(n, e); } });
          g.addEventListener("mousemove", (e) => { if (!card.hidden) placeCard(e.clientX, e.clientY); });
          g.addEventListener("mouseleave", unhover);
          g.addEventListener("mousedown", (e) => {
            e.stopPropagation();
            unhover();
            const down = { x: e.clientX, y: e.clientY, px: p.x, py: p.y, moved: false };
            dragging = true;
            const move = (ev) => {
              const dx = (ev.clientX - down.x) / VIEW.k, dy = (ev.clientY - down.y) / VIEW.k;
              if (Math.abs(dx) + Math.abs(dy) > 3) down.moved = true;
              if (down.moved) { p.x = down.px + dx; p.y = down.py + dy; g.setAttribute("transform", `translate(${p.x},${p.y})`); drawEdges(); drawClusters(); }
            };
            const release = () => {
              dragging = false;
              window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", release);
              if (down.moved) {
                p.x = Math.round(p.x * 10) / 10; p.y = Math.round(p.y * 10) / 10;
                g.setAttribute("transform", `translate(${p.x},${p.y})`);
                userMoved = true;
                rememberPositions(); save();
              } else select({ kind: "node", id: n.id });
            };
            window.addEventListener("mousemove", move); window.addEventListener("mouseup", release);
          });
          g.addEventListener("dblclick", (e) => { e.stopPropagation(); focusPanel(n.id); });
        });
      };

      const drawClusters = () => {
        gClusters.textContent = "";
        clustersAtK = VIEW.k;
        const { lay } = current;
        lay.groups.forEach((members, gid) => {
          let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
          members.forEach((n) => { const p = lay.pos.get(n.id); x0 = Math.min(x0, p.x - p.s / 2); y0 = Math.min(y0, p.y - p.s / 2); x1 = Math.max(x1, p.x + p.s / 2 + labelW(n.id)); y1 = Math.max(y1, p.y + p.s / 2); });
          x0 -= 22; y0 -= 22; x1 += 14; y1 += 18;
          const w = W.get(gid);
          const g = el("g", { class: "cw-cluster" + (gid === lay.home ? " home" : "") }, gClusters);
          el("rect", { class: "cw-box", x: x0, y: y0, width: x1 - x0, height: y1 - y0 }, g);
          // Workspace names are read at one on-screen size whatever the zoom.
          const z = Math.max(0.5, Math.min(5, 1 / VIEW.k));
          el("rect", { x: x0, y: y0 - 26 * z, width: 22 * z, height: 22 * z, fill: "var(--cw-surface)", stroke: "var(--cw-ink)", "stroke-width": 1.25 * z }, g);
          el("text", { class: "cw-letter", x: x0 + 11 * z, y: y0 - 10.5 * z, "text-anchor": "middle", "font-size": 13 * z }, g).textContent = letterOf(gid);
          // A label never runs past its own box: the name is cut to the box's
          // on-screen width (mono, about 9.7px a character at 16px), and the
          // panel count shows only where it fits beside the name.
          const fullRoom = Math.floor((x1 - x0 - 30 * z) / (9.7 * z));
          const nameText = trunc(w.title, Math.min(40, Math.max(4, fullRoom)));
          const meta = `${members.length} ${members.length === 1 ? "panel" : "panels"}${w.live || gid === NO_WS ? "" : " · closed"}`;
          const name = el("text", { x: x0 + 30 * z, y: y0 - 10 * z, "font-size": 16 * z, "stroke-width": 4 * z }, g);
          name.textContent = nameText;
          if (nameText.length + 1 + meta.length * 0.7 <= fullRoom) el("tspan", { class: "cw-wsmeta", dx: 10 * z, "font-size": 11 * z }, name).textContent = meta;
          el("title", {}, g).textContent = `${w.title} · ${meta}`;
        });
      };

      const fit = () => {
        const { lay } = current;
        const box = svg.getBoundingClientRect();
        let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        lay.pos.forEach((p, id) => { x0 = Math.min(x0, p.x - 40); y0 = Math.min(y0, p.y - 70); x1 = Math.max(x1, p.x + labelW(id) + 40); y1 = Math.max(y1, p.y + 40); });
        if (box.width === 0) { pendingFit = true; return; }
        pendingFit = false;
        if (!Number.isFinite(x0)) { Object.assign(VIEW, { k: 1, x: box.width / 2, y: box.height / 2 }); return; }
        const k = Math.max(0.15, Math.min(1.6, (box.width - 40) / (x1 - x0), (box.height - 90) / (y1 - y0)));
        Object.assign(VIEW, { k, x: (box.width - (x1 - x0) * k) / 2 - x0 * k, y: 20 + (box.height - 90 - (y1 - y0) * k) / 2 - y0 * k });
      };
      let clustersAtK = null;
      const applyView = () => {
        view.setAttribute("transform", `translate(${VIEW.x},${VIEW.y}) scale(${VIEW.k})`);
        if (current && clustersAtK !== VIEW.k) drawClusters();
      };

      // ---------- inspector (DOM nodes and textContent only: agent text is never parsed as HTML) ----------
      const insp = $("cw-inspector");
      const h = (tag, attrs, ...kids) => {
        const e = document.createElement(tag);
        for (const k in attrs || {}) {
          if (k === "class") e.className = attrs[k];
          else if (k === "on") e.addEventListener("click", attrs[k]);
          else e.setAttribute(k, attrs[k]);
        }
        kids.flat().forEach((c) => { if (c == null || c === false) return; e.appendChild(typeof c === "object" ? c : document.createTextNode(String(c))); });
        return e;
      };
      const zone = (n, name) => h("div", { class: "cw-zone" }, h("span", { class: "cw-sq" }, n), h("span", { class: "cw-label" }, name), h("span", { class: "cw-rule" }));
      const mark = (hot, on) => h("span", { class: "cw-sqm" + (hot ? " hot" : on ? " on" : "") });
      const facts = (pairs) => h("div", { class: "cw-facts" }, pairs.flatMap(([k, v]) => [h("div", {}, k), h("div", {}, v)]));
      const button = (label, on) => h("button", { type: "button", class: "cw-bk", on }, label);
      const table = (heads, rows) => h("table", {},
        h("thead", {}, h("tr", {}, heads.map(([label, cls]) => h("th", cls ? { class: cls } : {}, label)))),
        h("tbody", {}, rows));
      const row = (onClick, first, cells, preview) => {
        const tr = h("tr", { class: "cw-row cw-bk", on: onClick }, h("td", {}, first), cells.map(([value, cls]) => h("td", { class: cls }, value)));
        if (preview) { tr.addEventListener("mouseenter", () => { if (!busy()) preview(); }); tr.addEventListener("mouseleave", unhover); }
        return tr;
      };
      const subOf = (id) => { const said = firstLine((P.get(id) || {}).desc); return said ? h("span", { class: "cw-sub" }, said) : null; };

      // ---------- hover: a panel or a conversation lights up its neighbourhood ----------
      const card = $("cw-card");
      const busy = () => dragging || !!pan;
      const light = (ids, self, edgeTest) => {
        svg.classList.add("cw-hovering");
        gNodes.querySelectorAll(".cw-node").forEach((g) => { g.classList.toggle("near", ids.has(g.dataset.id)); g.classList.toggle("near-self", g.dataset.id === self); });
        gEdges.querySelectorAll(".cw-edge-g").forEach((g) => g.classList.toggle("near", edgeTest(g.dataset.a, g.dataset.b)));
      };
      const hoverNode = (id) => {
        if (!current) return;
        const ids = new Set([id]);
        current.agg.pairs.forEach((x) => { if (x.a === id) ids.add(x.b); if (x.b === id) ids.add(x.a); });
        light(ids, id, (a, b) => a === id || b === id);
      };
      const hoverEdge = (from, to) => light(new Set([from, to]), null, (a, b) => a === from && b === to);
      const hoverPair = (key) => { const x = current && current.agg.pairs.get(key); if (x) light(new Set([x.a, x.b]), null, (a, b) => (a === x.a && b === x.b) || (a === x.b && b === x.a)); };
      const unhover = () => {
        svg.classList.remove("cw-hovering");
        gNodes.querySelectorAll(".near, .near-self").forEach((g) => g.classList.remove("near", "near-self"));
        gEdges.querySelectorAll(".near").forEach((g) => g.classList.remove("near"));
        card.hidden = true;
      };
      const placeCard = (cx, cy) => {
        const r = $("cw-stage").getBoundingClientRect(), w = card.offsetWidth || 320, hgt = card.offsetHeight || 120;
        let x = cx - r.left + 18, y = cy - r.top + 16;
        if (x + w > r.width - 8) x = cx - r.left - 18 - w;
        if (y + hgt > r.height - 8) y = r.height - 8 - hgt;
        card.style.left = Math.max(8, x) + "px"; card.style.top = Math.max(8, y) + "px";
      };
      const stateWord = (n) => (n.hot ? "active now" : n.quiet ? "open, quiet" : isLive(n.id) ? "open" : "closed");
      const nodeCard = (n, e) => {
        const p = P.get(n.id) || {}, said = sayLines(p.desc), wid = wsOf(n.id);
        const peers = [...current.agg.pairs.values()].filter((x) => x.a === n.id || x.b === n.id).sort((a, b) => b.count - a.count);
        card.replaceChildren(
          h("div", { class: "cw-ct" }, titleOf(n.id)),
          h("div", { class: "cw-cd" + (said ? "" : " none") }, said || "No subtitle set"),
          h("div", { class: "cw-cm" }, `${letterOf(wid)} · ${W.get(wid).title} · ${stateWord(n)}`),
          h("div", { class: "cw-cm" }, n.total ? `${n.sent} sent · ${n.recv} received · last ${ago(n.last)}` : "No messages in this window"),
          peers.length ? h("div", { class: "cw-cm" }, "Talks with " + peers.slice(0, 3).map((x) => clip(titleOf(x.a === n.id ? x.b : x.a), 24)).join(", ") + (peers.length > 3 ? ` +${peers.length - 3}` : "")) : null);
        card.hidden = false; placeCard(e.clientX, e.clientY);
      };
      const edgeCard = (p, from, to, d, e) => {
        const last = [...p.msgs].reverse().find((m) => m.from === from);
        const text = last && last.body ? clip(firstLine(last.body) || last.body, 220) : "";
        card.replaceChildren(
          h("div", { class: "cw-ct" }, `${titleOf(from)} → ${titleOf(to)}`),
          h("div", { class: "cw-cm" }, `${d.mailbox} mail · ${d.send} send · last ${ago(d.last)}`),
          text ? h("div", { class: "cw-cd" }, text) : null);
        card.hidden = false; placeCard(e.clientX, e.clientY);
      };

      // ---------- plain-English summaries ----------
      const plural = (n, one, many) => `${n} ${n === 1 ? one : many || one + "s"}`;
      const tally = (items) => { const m = new Map(); items.forEach((k) => m.set(k, (m.get(k) || 0) + 1)); return [...m.entries()].sort((a, b) => b[1] - a[1]); };
      const names = (entries, max) => {
        const shown = entries.slice(0, max).map(([id, c]) => `${titleOf(id)} (${c})`), rest = entries.length - shown.length;
        return shown.join(", ") + (rest > 0 ? ` and ${plural(rest, "other")}` : "");
      };
      const kindOf = (id) => {
        const p = P.get(id) || {};
        if (p.type === "address") return "mailbox address no open panel holds";
        const what = p.agent ? (AGENTS[p.agent] || p.agent) + " agent" : p.type === "browser" ? "browser panel" : p.type === "markdown" ? "markdown panel" : "terminal";
        return (isLive(id) ? "open " : "closed ") + what;
      };
      const article = (word) => (/^[aeiou]/i.test(word) ? "An " : "A ");
      const windowWords = () => (Number.isFinite(spanOf()) ? spanText(spanOf()).replace(/^Last/, "in the last") : "across everything recorded");
      const nodeStory = (n) => {
        const mine = [];
        current.agg.pairs.forEach((x) => { if (x.a === n.id || x.b === n.id) mine.push(...x.msgs); });
        const kind = kindOf(n.id);
        const parts = [`${article(kind)}${kind} in ${W.get(wsOf(n.id)).title}.`];
        if (!n.total) parts.push(`No messages ${windowWords()}.`);
        if (n.sent) parts.push(`Sent ${plural(n.sent, "message")} to ${names(tally(mine.filter((m) => m.from === n.id).map((m) => m.to)), 3)}.`);
        if (n.recv) parts.push(`Received ${plural(n.recv, "message")} from ${names(tally(mine.filter((m) => m.to === n.id).map((m) => m.from)), 3)}.`);
        if (mine.length) parts.push(`Talking from ${when(Math.min(...mine.map((m) => m.ms)))} to ${when(n.last)}.`);
        const topics = tally(mine.map((m) => m.topic).filter(Boolean));
        if (topics.length) parts.push(`Topics: ${topics.slice(0, 4).map(([t]) => t).join(", ")}.`);
        const p = P.get(n.id) || {};
        if (p.closedAt) parts.push(`Closed ${when(p.closedAt)}.`);
        return parts.join(" ");
      };
      const scopeStory = (agg, count) => {
        const talkers = [...agg.nodes.values()].filter((n) => n.total), quiet = agg.nodes.size - talkers.length;
        const ws = new Set(talkers.map((n) => wsOf(n.id))); ws.delete(NO_WS);
        const open = talkers.filter((n) => isLive(n.id)).length;
        const lead = windowWords().replace(/^./, (c) => c.toUpperCase());
        if (!count) return `${lead}, no messages here. ${quiet ? plural(quiet, "open panel") + " shown, all quiet." : ""}`.trim();
        const parts = [`${lead}, ${plural(talkers.length, "panel")} exchanged ${plural(count, "message")} in ${plural(ws.size || 1, "workspace")}; ${open} of them still open.`];
        if (quiet) parts.push(`${plural(quiet, "more open panel")} said nothing.`);
        const top = [...agg.pairs.values()].sort((a, b) => b.count - a.count)[0];
        if (top) parts.push(`The busiest conversation is ${titleOf(top.a)} ⇄ ${titleOf(top.b)} (${top.count}).`);
        const busiest = [...agg.nodes.values()].sort((a, b) => b.total - a.total)[0];
        if (busiest && busiest.total) parts.push(`${titleOf(busiest.id)} talked the most: ${busiest.sent} sent, ${busiest.recv} received.`);
        const hot = [...agg.nodes.values()].filter((n) => n.hot).length;
        if (hot) parts.push(`${plural(hot, "panel")} talked in the last 15 minutes.`);
        return parts.join(" ");
      };
      const pairStory = (p, msgs) => {
        const nab = p.ab.mailbox + p.ab.send, nba = p.ba.mailbox + p.ba.send;
        const parts = [`${titleOf(p.a)} sent ${titleOf(p.b)} ${plural(nab, "message")}` + (nba ? `, and ${titleOf(p.b)} sent ${nba} back.` : `; ${titleOf(p.b)} never wrote back here.`)];
        parts.push(msgs.length > 1 ? `From ${when(msgs[0].ms)} to ${when(msgs[msgs.length - 1].ms)}.` : `On ${when(msgs[0].ms)}.`);
        const topics = tally(msgs.map((m) => m.topic).filter(Boolean));
        if (topics.length) parts.push(`Topics: ${topics.slice(0, 4).map(([t]) => t).join(", ")}.`);
        return parts.join(" ");
      };
      const quote = (label, m) => (m && m.body ? h("span", { class: "cw-quote" }, `${label} (${clip(titleOf(m.from), 22)}): ${clip(firstLine(m.body) || m.body, 180)}`) : null);
      const pairTable = (pairs, perspective) => {
        if (!pairs.length) return h("div", { class: "cw-empty" }, "No traffic in this window.");
        return table([[perspective ? "Peer" : "Conversation"], [perspective ? "Out" : "→", "cw-num"], [perspective ? "In" : "←", "cw-num"], ["Last", "cw-when"]],
          pairs.map((p) => {
            const other = perspective ? (p.a === perspective ? p.b : p.a) : null;
            const out = perspective ? dirOf(p, perspective) : p.ab;
            const back = perspective ? dirOf(p, other) : p.ba;
            const on = perspective ? isLive(other) : isLive(p.a) && isLive(p.b);
            const name = perspective ? [titleOf(other), subOf(other)] : [titleOf(p.a), h("span", { class: "cw-sub" }, "⇄ " + titleOf(p.b))];
            return row(() => select({ kind: "pair", key: p.key }), [mark(NOW - p.last < HOT_MS, on), ...name],
              [[out.mailbox + out.send, "cw-num"], [back.mailbox + back.send, "cw-num"], [ago(p.last), "cw-when"]], () => hoverPair(p.key));
          }));
      };
      const show = (...nodes) => { insp.replaceChildren(...nodes.flat().filter(Boolean)); };
      const isOpen = (id) => Array.isArray(state.open) && state.open.includes(id);
      const markOpen = (id) => {
        state.open = (Array.isArray(state.open) ? state.open : []).filter((x) => x !== id).concat(id).slice(-300);
        save();
      };
      const inspectScope = () => {
        const { agg } = current;
        const pairs = [...agg.pairs.values()].sort((a, b) => b.last - a.last);
        const count = new Set(pairs.flatMap((p) => p.msgs.map((m) => m.id))).size;
        const title = state.scope === "instance" ? "Whole c11 instance"
          : state.scope === "workspace" ? (W.has(state.ws) ? W.get(state.ws).title : "No workspace has messages yet")
          : state.panel ? titleOf(state.panel) : "No panel has messages yet";
        const busiest = [...agg.nodes.values()].sort((a, b) => b.total - a.total).slice(0, 8);
        const busiestTalkers = busiest.filter((n) => n.total);
        show(zone("01", "Scope"), h("div", { class: "cw-title2" }, title), h("div", { class: "cw-story" }, scopeStory(agg, count)),
          facts([["Messages", count], ["Panels", agg.nodes.size], ["Conversations", agg.pairs.size], ["Window", spanText(spanOf())]]),
          zone("02", "Conversations, most recent first"), pairTable(pairs, null), zone("03", "Busiest panels"),
          busiestTalkers.length
            ? table([["Panel"], ["Out", "cw-num"], ["In", "cw-num"], ["Last", "cw-when"]],
                busiestTalkers.map((n) => row(() => select({ kind: "node", id: n.id }), [mark(n.hot, isLive(n.id)), titleOf(n.id), subOf(n.id)],
                  [[n.sent, "cw-num"], [n.recv, "cw-num"], [ago(n.last), "cw-when"]], () => hoverNode(n.id))))
            : h("div", { class: "cw-empty" }, "No panels talked in this window."));
      };
      const inspectNode = (n) => {
        const p = P.get(n.id) || {}, wid = wsOf(n.id);
        const pairs = [...current.agg.pairs.values()].filter((x) => x.a === n.id || x.b === n.id).sort((a, b) => b.last - a.last);
        const status = n.hot ? [mark(true), "ACTIVE"] : isLive(n.id) ? [mark(false, true), n.quiet ? "OPEN · QUIET" : "OPEN"] : [mark(false, false), "CLOSED"];
        const rows = [["State", status], ["Workspace", letterOf(wid) + " · " + W.get(wid).title]];
        if (p.address) rows.push(["Address", p.address]);
        if (p.agent) rows.push(["Agent", p.agent]);
        if (p.parent) rows.push(["Child of", titleOf(p.parent)]);
        rows.push(["Sent", n.sent], ["Received", n.recv], ["Last", when(n.last)]);
        const actions = h("div", { class: "cw-actions" },
          state.scope === "panel" && state.panel === n.id ? null : button("Centre on panel", () => focusPanel(n.id)),
          wid !== NO_WS && !(state.scope === "workspace" && state.ws === wid) ? button("Its workspace", () => { state.scope = "workspace"; state.ws = wid; state.sel = null; render(true); }) : null,
          isLive(n.id) && isUUID(n.id) ? h("a", { class: "cw-bk", href: scheme + "://panel/" + n.id.toLowerCase() }, "Open panel") : null,
          button("Clear", () => select(null)));
        const said = sayLines(p.desc);
        const notes = (p.notes || []).slice().reverse();
        show(zone("01", p.type === "address" ? "Unresolved address" : "Panel"), h("div", { class: "cw-title2" }, titleOf(n.id)),
          h("div", { class: "cw-desc" + (said ? "" : " none") }, said || "No subtitle set"),
          h("div", { class: "cw-story" }, nodeStory(n)),
          facts(rows), actions, zone("02", "Conversations"), pairTable(pairs, n.id),
          notes.length > 1 || (notes.length === 1 && sayLines(notes[0].text) !== said) ? [zone("03", "What it said it was doing"),
            notes.map((x) => h("div", { class: "cw-note" }, h("span", { class: "cw-t" }, when(Date.parse(x.at))), h("div", {}, sayLines(x.text) || x.text)))] : null);
      };
      const inspectPair = (p) => {
        const ab = p.ab, ba = p.ba;
        const msgs = [...p.msgs].sort((x, y) => x.ms - y.ms), shown = msgs.slice(-200);
        const thread = shown.map((m) => {
          const body = h("div", { class: "cw-body" + (isOpen(m.id) ? " open" : "") }, m.body ? m.body + (m.cut ? "\n…" : "") : h("span", { class: "cw-empty" }, "(text not recorded)"));
          body.addEventListener("click", () => { body.classList.add("open"); markOpen(m.id); });
          return h("div", { class: "cw-msg" + (NOW - m.ms < HOT_MS ? " hot" : "") },
            h("div", { class: "cw-mhead" },
              h("span", { class: "cw-who" }, h("span", { class: "cw-tag" }, m.ch === "mailbox" ? "Mail" : "Send"),
                h("b", {}, trunc(titleOf(m.from), 22)), " → " + trunc(titleOf(m.to), 22) + (m.topic ? " · " + m.topic : "")),
              h("span", { class: "cw-t" }, when(m.ms))),
            body);
        });
        show(zone("01", "Conversation"), h("div", { class: "cw-title2" }, titleOf(p.a) + " ⇄ " + titleOf(p.b)),
          h("div", { class: "cw-story" }, pairStory(p, msgs), quote("Opened with", msgs[0]), msgs.length > 1 ? quote("Latest", msgs[msgs.length - 1]) : null),
          facts([[trunc(titleOf(p.a), 12) + " →", ab.mailbox + " mail · " + ab.send + " send"], [trunc(titleOf(p.b), 12) + " →", ba.mailbox + " mail · " + ba.send + " send"],
            ["Span", when(msgs[0].ms) + " – " + when(msgs[msgs.length - 1].ms)]]),
          h("div", { class: "cw-actions" }, button("Centre on " + trunc(titleOf(p.a), 14), () => focusPanel(p.a)),
            button("Centre on " + trunc(titleOf(p.b), 14), () => focusPanel(p.b)), button("Clear", () => select(null))),
          zone("02", "Thread" + (msgs.length > shown.length ? `, newest 200 of ${msgs.length}` : "")), thread);
      };
      // Re-drawing the same thing (a reload, a filter, the minute tick) keeps
      // the reader's scroll; something new opens at its start, a thread at its end.
      const inspect = () => {
        const s = state.sel, { agg } = current;
        let shown = "scope:" + scopeKey(), pair = false;
        if (s && s.kind === "node" && agg.nodes.has(s.id)) { inspectNode(agg.nodes.get(s.id)); shown = "node:" + s.id; }
        else if (s && s.kind === "pair" && agg.pairs.has(s.key)) { inspectPair(agg.pairs.get(s.key)); shown = "pair:" + s.key; pair = true; }
        else inspectScope();
        if (state.insKey === shown && state.insAtEnd) insp.scrollTop = insp.scrollHeight;
        else if (state.insKey === shown && Number.isFinite(state.insScroll)) insp.scrollTop = state.insScroll;
        else { insp.scrollTop = pair ? insp.scrollHeight : 0; state.insKey = shown; state.insScroll = insp.scrollTop; state.insAtEnd = pair; }
      };
      let scrollSaveQueued = false;
      insp.addEventListener("scroll", () => {
        state.insScroll = insp.scrollTop;
        state.insAtEnd = insp.scrollHeight - insp.scrollTop - insp.clientHeight < 4;
        if (scrollSaveQueued) return;
        scrollSaveQueued = true;
        requestAnimationFrame(() => { scrollSaveQueued = false; save(); });
      }, { passive: true });

      // ---------- controls ----------
      const select = (sel) => { state.sel = sel; drawEdges(); drawNodes(); inspect(); save(); };
      const focusPanel = (id) => { state.scope = "panel"; state.panel = id; state.sel = { kind: "node", id }; render(true); };
      const counts = new Map();
      messages.forEach((m) => [m.from, m.to].forEach((id) => counts.set(id, (counts.get(id) || 0) + 1)));
      const option = (value, label, selected) => { const o = document.createElement("option"); o.value = value; o.textContent = label; o.selected = selected; return o; };
      const syncControls = () => {
        const pressed = (sel, test) => document.querySelectorAll(sel).forEach((b) => b.setAttribute("aria-pressed", String(test(b.dataset.v))));
        pressed("#cw-scope button", (v) => v === state.scope);
        pressed("#cw-channels button", (v) => state.ch.includes(v));
        pressed("#cw-closed button", (v) => v === state.closed);
        syncScrub();
        const pick = $("cw-picker");
        if (state.scope === "workspace") {
          pick.disabled = false;
          const wsIds = wsOrder.filter((id) => id !== NO_WS);
          W.forEach((w, id) => { if (w.live && id !== NO_WS && !wsIds.includes(id)) wsIds.push(id); });
          if (state.ws && W.has(state.ws) && !wsIds.includes(state.ws)) wsIds.unshift(state.ws);
          pick.replaceChildren(...wsIds.map((id) => option(id, `${letterOf(id)} · ${W.get(id).title} (${wsTraffic.get(id) || 0})`, id === state.ws)));
        } else if (state.scope === "panel") {
          pick.disabled = false;
          const ids = [...involved].sort((a, b) => (counts.get(b) || 0) - (counts.get(a) || 0));
          if (state.panel && !involved.has(state.panel)) ids.unshift(state.panel);
          pick.replaceChildren(...ids.map((id) => option(id, `${trunc(titleOf(id), 34)} · ${letterOf(wsOf(id))} (${counts.get(id) || 0})`, id === state.panel)));
        } else {
          pick.disabled = true;
          pick.replaceChildren(option("", "Every workspace and panel", true));
        }
      };
      const render = (refit) => {
        if (state.scope === "workspace" && !W.has(state.ws)) state.ws = wsOrder[0] || null;
        if (state.scope === "panel" && !state.panel) state.panel = [...involved][0] || null;
        if (state.scope === "panel" && state.panel) panel(state.panel);
        syncControls();
        const agg = aggregate(scoped(filtered()), quietOpen());
        current = { agg, lay: layout(agg) };
        if (state.sel && state.sel.kind === "node" && !agg.nodes.has(state.sel.id)) state.sel = null;
        if (state.sel && state.sel.kind === "pair" && !agg.pairs.has(state.sel.key)) state.sel = null;
        $("cw-empty").hidden = agg.nodes.size > 0;
        rememberPositions();
        if (refit) { fit(); userMoved = false; }
        applyView(); drawClusters(); drawEdges(); drawNodes(); inspect(); save();
      };
      // ---------- the time scrubber: how far back, on a log scale, with detents ----------
      // 0..900 runs from 10 minutes to 30 days; the far end is everything recorded.
      const SCRUB = { min: 10 * 60e3, max: 30 * 86400e3, end: 900, all: 1000, pull: 22 };
      const DETENTS = [["1H", 3600e3], ["6H", 6 * 3600e3], ["24H", 86400e3], ["7D", 7 * 86400e3], ["ALL", Infinity]];
      const toSpan = (v) => (v > (SCRUB.end + SCRUB.all) / 2 ? Infinity : SCRUB.min * Math.pow(SCRUB.max / SCRUB.min, Math.min(v, SCRUB.end) / SCRUB.end));
      const toPos = (span) => (!Number.isFinite(span) ? SCRUB.all : Math.max(0, Math.min(SCRUB.end, Math.round(SCRUB.end * Math.log(span / SCRUB.min) / Math.log(SCRUB.max / SCRUB.min)))));
      const snapPos = (v) => { for (const [, span] of DETENTS) { const at = toPos(span); if (Math.abs(v - at) <= SCRUB.pull) return at; } return v; };
      // A detent stands for its exact span, not the nearest the scale can draw.
      const spanAt = (v) => { const d = DETENTS.find(([, span]) => toPos(span) === v); return d ? d[1] : toSpan(v); };
      const scrub = $("cw-scrub"), scrubVal = $("cw-scrub-val"), ticks = $("cw-ticks");
      DETENTS.forEach(([label, span]) => {
        const b = h("button", { type: "button", class: "cw-tick", "data-span": String(span), "aria-label": label === "ALL" ? "Everything recorded" : "Last " + label, style: `left: ${toPos(span) / 10}%` }, label);
        b.addEventListener("click", () => { setSpan(span); finishScrub(); });
        ticks.appendChild(b);
      });
      const syncScrub = () => {
        const span = spanOf();
        scrub.value = String(toPos(span));
        scrubVal.textContent = spanText(span);
        ticks.querySelectorAll(".cw-tick").forEach((b) => b.classList.toggle("on", Number(b.dataset.span) === span));
      };
      const setSpan = (span) => { state.win = Number.isFinite(span) ? Math.round(span) : "all"; };
      let scrubQueued = false;
      scrub.addEventListener("input", () => {
        const v = snapPos(Number(scrub.value));
        if (String(v) !== scrub.value) scrub.value = String(v);
        setSpan(spanAt(v));
        scrubVal.textContent = spanText(spanOf());
        if (scrubQueued) return;
        scrubQueued = true;
        requestAnimationFrame(() => { scrubQueued = false; if (!broken) render(false); });
      });
      // Let go: show what the new window brought in, unless the operator has framed the view themselves.
      const finishScrub = () => { render(false); if (!userMoved && current && current.agg.nodes.size) { fit(); applyView(); } save(); };
      scrub.addEventListener("change", finishScrub);
      const bindSeg = (id, fn) => document.querySelectorAll(`#${id} button`).forEach((b) => b.addEventListener("click", () => fn(b.dataset.v)));
      bindSeg("cw-scope", (v) => { state.scope = v; state.sel = null; render(true); });
      bindSeg("cw-channels", (v) => { state.ch = state.ch.includes(v) ? state.ch.filter((c) => c !== v) : [...state.ch, v]; if (!state.ch.length) state.ch = [v === "send" ? "mailbox" : "send"]; render(true); });
      bindSeg("cw-closed", (v) => { state.closed = v; render(true); });
      $("cw-relayout").addEventListener("click", () => { forgetPositions(); render(true); });
      $("cw-picker").addEventListener("change", (e) => {
        if (state.scope === "workspace") { state.ws = e.target.value; state.sel = null; }
        else { state.panel = e.target.value; state.sel = { kind: "node", id: state.panel }; }
        render(true);
      });

      let pan = null;
      svg.addEventListener("mousedown", (e) => { unhover(); pan = { x: e.clientX, y: e.clientY, vx: VIEW.x, vy: VIEW.y, moved: false }; $("cw-stage").classList.add("cw-panning"); });
      window.addEventListener("mousemove", (e) => { if (!pan) return; const dx = e.clientX - pan.x, dy = e.clientY - pan.y; if (Math.abs(dx) + Math.abs(dy) > 3) { pan.moved = true; userMoved = true; } VIEW.x = pan.vx + dx; VIEW.y = pan.vy + dy; applyView(); });
      window.addEventListener("mouseup", () => { if (pan && !pan.moved) select(null); if (pan) save(); pan = null; $("cw-stage").classList.remove("cw-panning"); });
      svg.addEventListener("wheel", (e) => {
        e.preventDefault();
        if (!card.hidden) unhover();
        const r = svg.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
        const k = Math.min(4, Math.max(0.15, VIEW.k * Math.exp(-e.deltaY * 0.0015)));
        VIEW.x = mx - (mx - VIEW.x) * k / VIEW.k; VIEW.y = my - (my - VIEW.y) * k / VIEW.k; VIEW.k = k; userMoved = true; applyView(); save();
      }, { passive: false });
      window.addEventListener("keydown", (e) => { if (!broken && e.key === "Escape" && viewName === "web") select(null); });
      // The stage's own size, not the window's: a browser panel is often
      // created at one size and laid out at another, with no window resize.
      // A resize re-fits only a view the operator has not panned or zoomed.
      // Only panels placed by this load count: a remembered panel that sits
      // outside the view was already there.
      const newOutOfView = () => {
        const s = $("cw-stage").getBoundingClientRect();
        return [...gNodes.querySelectorAll(".cw-node")].some((g) => {
          const p = current.lay.pos.get(g.dataset.id);
          if (!p || p.fixed) return false;
          const b = g.querySelector("rect").getBoundingClientRect();
          return b.width > 0 && (b.left < s.left || b.right > s.right || b.top < s.top || b.bottom > s.bottom);
        });
      };
      const refitOnResize = () => {
        if (broken || viewName !== "web" || !current) return;
        const box = $("cw-stage").getBoundingClientRect();
        const changed = !state.stage || Math.abs(state.stage[0] - box.width) > 1 || Math.abs(state.stage[1] - box.height) > 1;
        state.stage = [Math.round(box.width), Math.round(box.height)];
        // A reload at the same size keeps the operator's view unless a new
        // panel landed outside it; a real resize re-fits an unmoved view.
        // At the zoom floor a re-fit cannot show more; it would only move the view.
        if (pendingFit || (!userMoved && (changed || (VIEW.k > 0.151 && newOutOfView())))) { fit(); applyView(); }
        save();
      };
      if (window.ResizeObserver) new ResizeObserver(refitOnResize).observe($("cw-stage"));
      else window.addEventListener("resize", refitOnResize);
      // The page reloads only on new traffic, so "last 15 min" and "ago" advance on a clock.
      // Only the marks move; the inspector is left alone so a thread being read does not jump.
      setInterval(() => {
        NOW = Date.now();
        if (broken || dragging || viewName !== "web" || !current) return;
        current.agg.nodes.forEach((n) => { n.hot = NOW - n.last < HOT_MS; });
        drawEdges(); drawNodes();
      }, 60000);

      // ---------- Web | Traffic ----------
      const views = $("cw-views");
      const showView = (name) => {
        viewName = name === "traffic" ? "traffic" : "web";
        document.body.classList.toggle("view-web", viewName === "web");
        document.body.classList.toggle("view-traffic", viewName === "traffic");
        if (viewName === "web") $("cw-views-slot").appendChild(views); else document.body.insertBefore(views, document.body.firstChild);
        views.querySelectorAll("button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.view === viewName)));
        save();
      };
      views.querySelectorAll("button").forEach((b) => b.addEventListener("click", () => {
        const wasTraffic = viewName === "traffic";
        showView(b.dataset.view);
        if (viewName === "web" && wasTraffic) render(pendingFit);
      }));
      window.addEventListener("hashchange", () => {
        if (broken || !location.hash.startsWith("#web") || !applyLink(location.hash)) return;
        showView("web"); render(true); fitted = true;
        // c11 rewrote the page just before this link; reload so it shows that
        // rebuild even if the fragment navigation pre-empted c11's own reload.
        setTimeout(() => location.reload(), 0);
      });

      const gen = new Date(raw.generated_at || NOW);
      const live = [...involved].filter(isLive).length;
      $("cw-lede").textContent = `Who talks to whom, by mailbox and by c11 send. ${new Set(messages.map((m) => m.id)).size} messages between ${involved.size} panels (${live} open) in ${wsOrder.filter((id) => id !== NO_WS).length} workspaces.`;
      // The zone's own name ("Pacific Time"), never the city in its IANA id:
      // America/Los_Angeles says nothing about where the operator is.
      const zoneName = (() => {
        for (const style of ["longGeneric", "long", "short"]) {
          try {
            const part = new Intl.DateTimeFormat([], { timeZoneName: style }).formatToParts(gen).find((p) => p.type === "timeZoneName");
            if (part && part.value) return part.value;
          } catch (_) {}
        }
        return "";
      })();
      $("cw-stamp").replaceChildren(...[["Built", gen.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) + " " + zoneName],
        ["Source", raw.bounded ? "newest " + rows.length : "all recorded"]].flatMap(([k, v]) => [h("div", {}, k), h("div", {}, v)]));

      showView(viewName);
      render(!fitted);
      fitted = true;
      save();
      } catch (error) {
        broken = true;
        // The Traffic view never depends on this script: show it, and say why the Web view is missing.
        document.body.classList.remove("view-web");
        document.body.classList.add("view-traffic");
        const views = document.getElementById("cw-views");
        if (views) {
          document.body.insertBefore(views, document.body.firstChild);
          views.querySelectorAll("button").forEach((b) => { b.disabled = b.dataset.view === "web"; b.setAttribute("aria-pressed", String(b.dataset.view === "traffic")); });
          views.title = "The conversation web could not be drawn: " + String(error && error.message || error);
        }
        console.error("conversation web failed", error);
      }
    })();
    """#
}
