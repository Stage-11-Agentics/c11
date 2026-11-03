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
        let fragment = deepLinkFragment(
            panelID: panelID,
            nonce: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        MessagesPageWriter.shared.ensurePage { [weak workspace] result in
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
    #cw { position: fixed; inset: 0; display: grid; grid-template-rows: auto auto 1fr; background: var(--cw-surface);
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
    .cw-main { display: grid; grid-template-columns: 1fr 440px; min-height: 0; }
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
    .cw-cluster text { font-size: 10px; letter-spacing: .06em; text-transform: uppercase; fill: var(--cw-text-2); }
    .cw-cluster .cw-letter { fill: var(--cw-text); font-weight: 600; }
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
        <div class="cw-group"><span class="cw-label">Window</span>
          <div class="cw-seg cw-narrow" id="cw-window"><button type="button" class="cw-bk" data-v="1h">1H</button><button type="button" class="cw-bk" data-v="6h">6H</button><button type="button" class="cw-bk" data-v="24h">24H</button><button type="button" class="cw-bk" data-v="7d">7D</button><button type="button" class="cw-bk" data-v="all">All</button></div>
        </div>
        <div class="cw-group"><span class="cw-label">Closed panels</span>
          <div class="cw-seg cw-narrow" id="cw-closed"><button type="button" class="cw-bk" data-v="show" style="width:64px">Show</button><button type="button" class="cw-bk" data-v="hide" style="width:64px">Hide</button></div>
        </div>
      </div>
      <div class="cw-main">
        <div id="cw-stage">
          <svg id="cw-svg"><defs id="cw-defs"></defs><g id="cw-view"><g id="cw-clusters"></g><g id="cw-edges"></g><g id="cw-nodes"></g></g></svg>
          <div class="cw-empty-stage cw-label" id="cw-empty" hidden>No conversations in this scope and window</div>
          <div class="cw-legend cw-label">
            <svg viewBox="0 0 26 12"><rect x="9" y="2" width="8" height="8" fill="var(--cw-ink)"/></svg><span>Open panel</span>
            <svg viewBox="0 0 26 12"><rect x="9.5" y="2.5" width="7" height="7" fill="var(--cw-surface)" stroke="var(--cw-ink)"/></svg><span>Closed panel</span>
            <svg viewBox="0 0 26 12"><rect x="9" y="2" width="8" height="8" fill="var(--cw-accent)"/></svg><span>Traffic, last 15 min</span>
            <svg viewBox="0 0 26 12"><line x1="1" y1="6" x2="25" y2="6" stroke="var(--cw-ink)" stroke-width="1.5"/></svg><span>Mailbox</span>
            <svg viewBox="0 0 26 12"><line x1="1" y1="6" x2="25" y2="6" stroke="var(--cw-ink)" stroke-width="1.5" stroke-dasharray="4 3"/></svg><span>c11 send (typed)</span>
          </div>
          <div class="cw-hint cw-label">Click to inspect · double-click a panel to centre on it · drag to pan · scroll to zoom</div>
        </div>
        <aside id="cw-inspector"></aside>
      </div>
    </div>
    """#

    static let script = #"""
    (() => {
      "use strict";
      const raw = JSON.parse(document.getElementById("messages-data").textContent || "{}");
      const directory = raw.directory || {};
      const scheme = directory.link_scheme || "c11";
      const NOW = Date.now();
      const HOT_MS = 15 * 60 * 1000;
      const WINDOWS = { "1h": 3600e3, "6h": 6 * 3600e3, "24h": 86400e3, "7d": 7 * 86400e3, all: Infinity };
      const GENERIC = new Set(["Terminal", "Shell", "zsh", "bash", "Browser", "Markdown"]);
      const NO_WS = "__none__";
      const up = (v) => (typeof v === "string" ? v.toUpperCase() : null);
      const isUUID = (v) => typeof v === "string" && /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i.test(v);

      // ---------- model: panels, workspaces, messages with both ends resolved ----------
      const P = new Map();
      const W = new Map();
      const panel = (id) => {
        if (!P.has(id)) P.set(id, { id, title: null, workspace: null, live: false, type: null, agent: null, address: null, parent: null });
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
          agent: d.agent || null, address: d.address || null, parent: up(d.parent) });
        if (d.address && d.live) addressToPanel.set(d.address, p.id);
      });
      const rows = Array.isArray(raw.messages) ? raw.messages : [];
      rows.forEach((m) => {
        if (m.channel !== "mailbox" || !m.surface || !m.recipient || /^id:/i.test(m.recipient)) return;
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
          to = isUUID(m.surface) ? panel(up(m.surface)).id : resolveAddress(m.recipient);
          if (to && m.recipient && !/^id:/i.test(m.recipient)) P.get(to).address = P.get(to).address || m.recipient;
        }
        if (!from || !to) return;
        if (m.workspace && isUUID(m.workspace)) {
          workspace(up(m.workspace));
          const target = P.get(to);
          if (!target.workspace && target.type !== "address") target.workspace = up(m.workspace);
        }
        const ms = Date.parse(m.timestamp);
        if (!Number.isFinite(ms)) return;
        messages.push({ id: m.id, ch: m.channel, from, to, ms, status: m.status, topic: m.topic || null,
          body: m.text_recorded === false ? "" : (m.body || (m.body_ref ? "body_ref: " + m.body_ref : "")), cut: !!m.truncated });
      });
      messages.sort((a, b) => a.ms - b.ms);
      P.forEach((p) => {
        if (p.workspace) workspace(p.workspace);
        if (!p.title) p.title = p.address || ("panel " + p.id.slice(0, 8));
        if (GENERIC.has(p.title)) p.title = p.title + " " + p.id.slice(0, 4);
      });
      W.forEach((w) => { if (!w.title) w.title = "Workspace " + w.id.slice(0, 6); });
      W.set(NO_WS, { id: NO_WS, title: "Unresolved senders", live: false });
      const wsOf = (id) => (P.get(id) && P.get(id).workspace && W.has(P.get(id).workspace) ? P.get(id).workspace : NO_WS);
      const titleOf = (id) => (P.get(id) ? P.get(id).title : id);
      const isLive = (id) => !!(P.get(id) && P.get(id).live);
      const involved = new Set(messages.flatMap((m) => [m.from, m.to]));
      const wsTraffic = new Map();
      messages.forEach((m) => [m.from, m.to].forEach((id) => wsTraffic.set(wsOf(id), (wsTraffic.get(wsOf(id)) || 0) + 1)));
      const wsOrder = [...new Set([...involved].map(wsOf))].sort((a, b) => (b !== NO_WS) - (a !== NO_WS) || (wsTraffic.get(b) || 0) - (wsTraffic.get(a) || 0));
      const LETTER = new Map(wsOrder.map((id, i) => [id, i < 26 ? String.fromCharCode(65 + i) : String(i + 1)]));
      const letterOf = (id) => LETTER.get(id) || "?";

      // ---------- state, kept per browser panel across the page's live reloads ----------
      const STORE = "c11.messages.web.v1";
      const state = { scope: "instance", ws: null, panel: null, ch: ["mailbox", "send"], win: "all", closed: "show", sel: null };
      const VIEW = { k: 1, x: 0, y: 0 };
      let consumed = null, viewName = "web", fitted = false;
      try {
        const saved = JSON.parse(sessionStorage.getItem(STORE) || "null");
        if (saved) { Object.assign(state, saved.state || {}); Object.assign(VIEW, saved.view || {}); consumed = saved.consumed || null; viewName = saved.viewName || "web"; fitted = !!saved.view; }
      } catch (_) {}
      const save = () => { try { sessionStorage.setItem(STORE, JSON.stringify({ state, view: VIEW, consumed, viewName })); } catch (_) {} };
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

      // ---------- shaping ----------
      const filtered = () => {
        const span = WINDOWS[state.win] || Infinity;
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
      const pairKey = (a, b) => (a < b ? a + "|" + b : b + "|" + a);
      const aggregate = (ms) => {
        const nodes = new Map(), pairs = new Map();
        const node = (id) => { if (!nodes.has(id)) nodes.set(id, { id, sent: 0, recv: 0, last: 0 }); return nodes.get(id); };
        for (const m of ms) {
          const a = node(m.from), b = node(m.to);
          a.sent++; b.recv++; a.last = Math.max(a.last, m.ms); b.last = Math.max(b.last, m.ms);
          const k = pairKey(m.from, m.to);
          if (!pairs.has(k)) {
            const [x, y] = k.split("|");
            pairs.set(k, { key: k, a: x, b: y, dirs: { [x + ">" + y]: { mailbox: 0, send: 0, last: 0 }, [y + ">" + x]: { mailbox: 0, send: 0, last: 0 } }, count: 0, last: 0, msgs: [] });
          }
          const p = pairs.get(k), d = p.dirs[m.from + ">" + m.to];
          d[m.ch]++; d.last = Math.max(d.last, m.ms); p.count++; p.last = Math.max(p.last, m.ms); p.msgs.push(m);
        }
        nodes.forEach((n) => { n.total = n.sent + n.recv; n.hot = NOW - n.last < HOT_MS; });
        return { nodes, pairs };
      };

      // ---------- layout: workspaces as clusters, a small force simulation inside each ----------
      const hash32 = (s) => { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; };
      const rng = (seed) => () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
      const nodeSize = (n) => Math.round(8 + 3.2 * Math.log2(n.total + 1));
      const labelW = (id) => Math.min(titleOf(id).length, 30) * 6.4 + 8;
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
        const pos = new Map();
        agg.nodes.forEach((n) => {
          const c = centers.get(wsOf(n.id)), r = rng(hash32(n.id));
          pos.set(n.id, { x: c.x + (r() - 0.5) * 120, y: c.y + (r() - 0.5) * 120, vx: 0, vy: 0, g: wsOf(n.id), s: nodeSize(n) });
        });
        if (state.scope === "panel" && pos.has(state.panel)) Object.assign(pos.get(state.panel), { x: centers.get(home).x, y: centers.get(home).y, pinned: true });
        const springs = [];
        agg.pairs.forEach((p) => { if (wsOf(p.a) === wsOf(p.b)) springs.push([p.a, p.b, p.count]); });
        const ids = [...pos.keys()];
        const steps = ids.length > 400 ? 160 : 320;
        for (let it = 0; it < steps; it++) {
          const cool = 1 - it / steps;
          for (let i = 0; i < ids.length; i++) {
            const a = pos.get(ids[i]);
            for (let j = i + 1; j < ids.length; j++) {
              const b = pos.get(ids[j]);
              if (a.g !== b.g) continue;
              let dx = a.x - b.x, dy = a.y - b.y;
              const d2 = dx * dx + dy * dy + 0.01, d = Math.sqrt(d2);
              const f = 5200 / d2 + (d < 46 ? (46 - d) * 0.5 : 0);
              dx /= d; dy /= d;
              a.vx += dx * f; a.vy += dy * f * 1.6; b.vx -= dx * f; b.vy -= dy * f * 1.6;
            }
          }
          springs.forEach(([x, y, c]) => {
            const a = pos.get(x), b = pos.get(y);
            const dx = b.x - a.x, dy = b.y - a.y, d = Math.sqrt(dx * dx + dy * dy) + 0.01;
            const f = (d - 90) * 0.02 * Math.min(3, 1 + Math.log2(c) / 3);
            a.vx += dx / d * f; a.vy += dy / d * f; b.vx -= dx / d * f; b.vy -= dy / d * f;
          });
          pos.forEach((p) => {
            const c = centers.get(p.g);
            p.vx += (c.x - p.x) * 0.012; p.vy += (c.y - p.y) * 0.012;
            if (p.pinned) { p.vx = 0; p.vy = 0; return; }
            const v = Math.hypot(p.vx, p.vy), cap = 30 * cool + 1;
            if (v > cap) { p.vx *= cap / v; p.vy *= cap / v; }
            p.x += p.vx; p.y += p.vy; p.vx *= 0.6; p.vy *= 0.6;
          });
        }
        return { pos, groups, home };
      };

      // ---------- rendering ----------
      const $ = (id) => document.getElementById(id);
      // The SVG namespace, read from the page's own <svg> so the page carries no URL text.
      const NS = $("cw-svg").namespaceURI;
      const el = (tag, attrs, parent) => { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); if (parent) parent.appendChild(e); return e; };
      const svg = $("cw-svg"), view = $("cw-view"), gClusters = $("cw-clusters"), gEdges = $("cw-edges"), gNodes = $("cw-nodes");
      let current = null, pendingFit = false;
      [["ink", "var(--cw-ink)"], ["hot", "var(--cw-accent)"]].forEach(([id, c]) => {
        const m = el("marker", { id: "cw-arrow-" + id, viewBox: "0 0 8 8", refX: 7, refY: 4, markerWidth: 6, markerHeight: 6, orient: "auto", markerUnits: "userSpaceOnUse" }, $("cw-defs"));
        el("path", { d: "M0,0 L8,4 L0,8 Z", fill: c }, m);
      });
      const edgeLit = (p) => { const s = state.sel; if (!s) return true; return s.kind === "node" ? p.a === s.id || p.b === s.id : p.key === s.key; };
      const nodeLit = (id) => { const s = state.sel; if (!s) return true; return s.kind === "node" ? id === s.id || current.agg.pairs.has(pairKey(id, s.id)) : s.key.split("|").includes(id); };

      const drawEdges = () => {
        gEdges.textContent = "";
        const { agg, lay } = current;
        let max = 1;
        agg.pairs.forEach((p) => Object.values(p.dirs).forEach((d) => { max = Math.max(max, d.mailbox + d.send); }));
        agg.pairs.forEach((p) => {
          const lit = edgeLit(p);
          Object.entries(p.dirs).forEach(([dk, d]) => {
            const n = d.mailbox + d.send;
            if (!n) return;
            const [from, to] = dk.split(">");
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
            const g = el("g", {}, gEdges);
            const hit = el("path", { d: path, class: "cw-hit" }, g);
            el("path", { d: path, class: "cw-edge", stroke: hot ? "var(--cw-accent)" : "var(--cw-ink)",
              "stroke-width": (1 + 3 * Math.log2(1 + n) / Math.log2(1 + max)).toFixed(2),
              "stroke-dasharray": d.mailbox ? "" : "5 4", "stroke-opacity": lit ? (hot ? 1 : 0.55) : 0.08,
              "marker-end": `url(#cw-arrow-${hot ? "hot" : "ink"})` }, g);
            el("title", {}, hit).textContent = `${titleOf(from)} → ${titleOf(to)}: ${d.mailbox} mail, ${d.send} send · last ${when(d.last)}`;
            hit.addEventListener("click", (e) => { e.stopPropagation(); select({ kind: "pair", key: p.key }); });
          });
        });
      };

      const drawNodes = () => {
        gNodes.textContent = "";
        const { agg, lay } = current;
        agg.nodes.forEach((n) => {
          const p = lay.pos.get(n.id), s = p.s, live = isLive(n.id), info = P.get(n.id) || {};
          const selected = state.sel && state.sel.kind === "node" && state.sel.id === n.id;
          const g = el("g", { class: "cw-node" + (live ? "" : " closed"), transform: `translate(${p.x},${p.y})`, opacity: nodeLit(n.id) ? 1 : 0.22 }, gNodes);
          el("rect", { x: -s / 2, y: -s / 2, width: s, height: s,
            fill: n.hot ? "var(--cw-accent)" : live ? "var(--cw-ink)" : "var(--cw-surface)",
            stroke: n.hot ? "var(--cw-accent)" : "var(--cw-ink)", "stroke-width": live ? 0 : 1,
            "stroke-dasharray": info.type === "address" ? "2 2" : "" }, g);
          if (selected) el("rect", { x: -s / 2 - 4, y: -s / 2 - 4, width: s + 8, height: s + 8, fill: "none", stroke: "var(--cw-ink)", "stroke-width": 1.5 }, g);
          const o = s / 2 + (selected ? 8 : 5), l = 5;
          el("path", { class: "cw-bkt", fill: "none", stroke: "var(--cw-ink)", "stroke-width": 1.5,
            d: `M${-o},${-o + l}V${-o}H${-o + l} M${o - l},${-o}H${o}V${-o + l} M${o},${o - l}V${o}H${o - l} M${-o + l},${o}H${-o}V${o - l}` }, g);
          el("text", { class: "cw-lbl", x: s / 2 + 7, y: 4 }, g).textContent = trunc(titleOf(n.id), 30);
          el("title", {}, g).textContent = `${titleOf(n.id)}\n${W.get(wsOf(n.id)).title}\n${n.sent} sent · ${n.recv} received · last ${when(n.last)}`;
          g.addEventListener("mousedown", (e) => {
            e.stopPropagation();
            const down = { x: e.clientX, y: e.clientY, px: p.x, py: p.y, moved: false };
            const move = (ev) => {
              const dx = (ev.clientX - down.x) / VIEW.k, dy = (ev.clientY - down.y) / VIEW.k;
              if (Math.abs(dx) + Math.abs(dy) > 3) down.moved = true;
              if (down.moved) { p.x = down.px + dx; p.y = down.py + dy; g.setAttribute("transform", `translate(${p.x},${p.y})`); drawEdges(); drawClusters(); }
            };
            const release = () => { window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", release); if (!down.moved) select({ kind: "node", id: n.id }); };
            window.addEventListener("mousemove", move); window.addEventListener("mouseup", release);
          });
          g.addEventListener("dblclick", (e) => { e.stopPropagation(); focusPanel(n.id); });
        });
      };

      const drawClusters = () => {
        gClusters.textContent = "";
        const { lay } = current;
        lay.groups.forEach((members, gid) => {
          let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
          members.forEach((n) => { const p = lay.pos.get(n.id); x0 = Math.min(x0, p.x - p.s / 2); y0 = Math.min(y0, p.y - p.s / 2); x1 = Math.max(x1, p.x + p.s / 2 + labelW(n.id)); y1 = Math.max(y1, p.y + p.s / 2); });
          x0 -= 22; y0 -= 22; x1 += 14; y1 += 18;
          const w = W.get(gid);
          const g = el("g", { class: "cw-cluster" + (gid === lay.home ? " home" : "") }, gClusters);
          el("rect", { class: "cw-box", x: x0, y: y0, width: x1 - x0, height: y1 - y0 }, g);
          el("rect", { x: x0, y: y0 - 18, width: 16, height: 16, fill: "var(--cw-surface)", stroke: "var(--cw-edge)" }, g);
          el("text", { class: "cw-letter", x: x0 + 8, y: y0 - 6.5, "text-anchor": "middle" }, g).textContent = letterOf(gid);
          el("text", { x: x0 + 22, y: y0 - 6 }, g).textContent = `${trunc(w.title, 34)}  ·  ${members.length} panels${w.live || gid === NO_WS ? "" : "  ·  closed"}`;
        });
      };

      const fit = () => {
        const { lay } = current;
        const box = svg.getBoundingClientRect();
        let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        lay.pos.forEach((p, id) => { x0 = Math.min(x0, p.x - 40); y0 = Math.min(y0, p.y - 60); x1 = Math.max(x1, p.x + labelW(id) + 40); y1 = Math.max(y1, p.y + 40); });
        if (box.width === 0) { pendingFit = true; return; }
        pendingFit = false;
        if (!Number.isFinite(x0)) { Object.assign(VIEW, { k: 1, x: box.width / 2, y: box.height / 2 }); return; }
        const k = Math.min(1.6, (box.width - 40) / (x1 - x0), (box.height - 90) / (y1 - y0));
        Object.assign(VIEW, { k, x: (box.width - (x1 - x0) * k) / 2 - x0 * k, y: 20 + (box.height - 90 - (y1 - y0) * k) / 2 - y0 * k });
      };
      const applyView = () => view.setAttribute("transform", `translate(${VIEW.x},${VIEW.y}) scale(${VIEW.k})`);

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
      const row = (onClick, first, cells) => h("tr", { class: "cw-row cw-bk", on: onClick }, h("td", {}, first),
        cells.map(([value, cls]) => h("td", { class: cls }, value)));
      const pairTable = (pairs, perspective) => {
        if (!pairs.length) return h("div", { class: "cw-empty" }, "No traffic in this window.");
        return table([[perspective ? "Peer" : "Conversation"], [perspective ? "Out" : "→", "cw-num"], [perspective ? "In" : "←", "cw-num"], ["Last", "cw-when"]],
          pairs.map((p) => {
            const other = perspective ? (p.a === perspective ? p.b : p.a) : null;
            const out = perspective ? p.dirs[perspective + ">" + other] : p.dirs[p.a + ">" + p.b];
            const back = perspective ? p.dirs[other + ">" + perspective] : p.dirs[p.b + ">" + p.a];
            const on = perspective ? isLive(other) : isLive(p.a) && isLive(p.b);
            const name = perspective ? [titleOf(other)] : [titleOf(p.a), h("span", { class: "cw-sub" }, "⇄ " + titleOf(p.b))];
            return row(() => select({ kind: "pair", key: p.key }), [mark(NOW - p.last < HOT_MS, on), ...name],
              [[out.mailbox + out.send, "cw-num"], [back.mailbox + back.send, "cw-num"], [ago(p.last), "cw-when"]]);
          }));
      };
      const show = (...nodes) => { insp.replaceChildren(...nodes.flat().filter(Boolean)); };
      const inspectScope = () => {
        const { agg } = current;
        const pairs = [...agg.pairs.values()].sort((a, b) => b.last - a.last);
        const count = pairs.reduce((s, p) => s + p.count, 0);
        const title = state.scope === "instance" ? "Whole c11 instance" : state.scope === "workspace" ? W.get(state.ws).title : titleOf(state.panel);
        const busiest = [...agg.nodes.values()].sort((a, b) => b.total - a.total).slice(0, 8);
        show(zone("01", "Scope"), h("div", { class: "cw-title2" }, title),
          facts([["Messages", count], ["Panels", agg.nodes.size], ["Conversations", agg.pairs.size], ["Window", state.win === "all" ? "all recorded" : "last " + state.win]]),
          zone("02", "Conversations, most recent first"), pairTable(pairs, null), zone("03", "Busiest panels"),
          busiest.length
            ? table([["Panel"], ["Out", "cw-num"], ["In", "cw-num"], ["Last", "cw-when"]],
                busiest.map((n) => row(() => select({ kind: "node", id: n.id }), [mark(n.hot, isLive(n.id)), titleOf(n.id)],
                  [[n.sent, "cw-num"], [n.recv, "cw-num"], [ago(n.last), "cw-when"]])))
            : h("div", { class: "cw-empty" }, "No panels."));
      };
      const inspectNode = (n) => {
        const p = P.get(n.id) || {}, wid = wsOf(n.id);
        const pairs = [...current.agg.pairs.values()].filter((x) => x.a === n.id || x.b === n.id).sort((a, b) => b.last - a.last);
        const status = n.hot ? [mark(true), "ACTIVE"] : isLive(n.id) ? [mark(false, true), "OPEN"] : [mark(false, false), "CLOSED"];
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
        show(zone("01", p.type === "address" ? "Unresolved address" : "Panel"), h("div", { class: "cw-title2" }, titleOf(n.id)),
          facts(rows), actions, zone("02", "Conversations"), pairTable(pairs, n.id));
      };
      const inspectPair = (p) => {
        const ab = p.dirs[p.a + ">" + p.b], ba = p.dirs[p.b + ">" + p.a];
        const msgs = [...p.msgs].sort((x, y) => x.ms - y.ms), shown = msgs.slice(-200);
        const thread = shown.map((m) => {
          const body = h("div", { class: "cw-body" }, m.body ? m.body + (m.cut ? "\n…" : "") : h("span", { class: "cw-empty" }, "(text not recorded)"));
          body.addEventListener("click", () => body.classList.add("open"));
          return h("div", { class: "cw-msg" + (NOW - m.ms < HOT_MS ? " hot" : "") },
            h("div", { class: "cw-mhead" },
              h("span", { class: "cw-who" }, h("span", { class: "cw-tag" }, m.ch === "mailbox" ? "Mail" : "Send"),
                h("b", {}, trunc(titleOf(m.from), 22)), " → " + trunc(titleOf(m.to), 22) + (m.topic ? " · " + m.topic : "")),
              h("span", { class: "cw-t" }, when(m.ms))),
            body);
        });
        show(zone("01", "Conversation"), h("div", { class: "cw-title2" }, titleOf(p.a) + " ⇄ " + titleOf(p.b)),
          facts([[trunc(titleOf(p.a), 12) + " →", ab.mailbox + " mail · " + ab.send + " send"], [trunc(titleOf(p.b), 12) + " →", ba.mailbox + " mail · " + ba.send + " send"],
            ["Span", when(msgs[0].ms) + " – " + when(msgs[msgs.length - 1].ms)]]),
          h("div", { class: "cw-actions" }, button("Centre on " + trunc(titleOf(p.a), 14), () => focusPanel(p.a)),
            button("Centre on " + trunc(titleOf(p.b), 14), () => focusPanel(p.b)), button("Clear", () => select(null))),
          zone("02", "Thread" + (msgs.length > shown.length ? `, newest 200 of ${msgs.length}` : "")), thread);
        insp.scrollTop = insp.scrollHeight;
      };
      const inspect = () => {
        const s = state.sel, { agg } = current;
        if (s && s.kind === "node" && agg.nodes.has(s.id)) return inspectNode(agg.nodes.get(s.id));
        if (s && s.kind === "pair" && agg.pairs.has(s.key)) return inspectPair(agg.pairs.get(s.key));
        inspectScope();
      };

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
        pressed("#cw-window button", (v) => v === state.win);
        pressed("#cw-closed button", (v) => v === state.closed);
        const pick = $("cw-picker");
        if (state.scope === "workspace") {
          pick.disabled = false;
          pick.replaceChildren(...wsOrder.filter((id) => id !== NO_WS).map((id) => option(id, `${letterOf(id)} · ${W.get(id).title} (${wsTraffic.get(id) || 0})`, id === state.ws)));
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
        const agg = aggregate(scoped(filtered()));
        current = { agg, lay: layout(agg) };
        if (state.sel && state.sel.kind === "node" && !agg.nodes.has(state.sel.id)) state.sel = null;
        if (state.sel && state.sel.kind === "pair" && !agg.pairs.has(state.sel.key)) state.sel = null;
        $("cw-empty").hidden = agg.nodes.size > 0;
        if (refit) fit();
        applyView(); drawClusters(); drawEdges(); drawNodes(); inspect(); save();
      };
      const bindSeg = (id, fn) => document.querySelectorAll(`#${id} button`).forEach((b) => b.addEventListener("click", () => fn(b.dataset.v)));
      bindSeg("cw-scope", (v) => { state.scope = v; state.sel = null; render(true); });
      bindSeg("cw-channels", (v) => { state.ch = state.ch.includes(v) ? state.ch.filter((c) => c !== v) : [...state.ch, v]; if (!state.ch.length) state.ch = [v === "send" ? "mailbox" : "send"]; render(true); });
      bindSeg("cw-window", (v) => { state.win = v; render(true); });
      bindSeg("cw-closed", (v) => { state.closed = v; render(true); });
      $("cw-picker").addEventListener("change", (e) => {
        if (state.scope === "workspace") { state.ws = e.target.value; state.sel = null; }
        else { state.panel = e.target.value; state.sel = { kind: "node", id: state.panel }; }
        render(true);
      });

      let pan = null;
      svg.addEventListener("mousedown", (e) => { pan = { x: e.clientX, y: e.clientY, vx: VIEW.x, vy: VIEW.y, moved: false }; $("cw-stage").classList.add("cw-panning"); });
      window.addEventListener("mousemove", (e) => { if (!pan) return; const dx = e.clientX - pan.x, dy = e.clientY - pan.y; if (Math.abs(dx) + Math.abs(dy) > 3) pan.moved = true; VIEW.x = pan.vx + dx; VIEW.y = pan.vy + dy; applyView(); });
      window.addEventListener("mouseup", () => { if (pan && !pan.moved) select(null); if (pan) save(); pan = null; $("cw-stage").classList.remove("cw-panning"); });
      svg.addEventListener("wheel", (e) => {
        e.preventDefault();
        const r = svg.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
        const k = Math.min(4, Math.max(0.15, VIEW.k * Math.exp(-e.deltaY * 0.0015)));
        VIEW.x = mx - (mx - VIEW.x) * k / VIEW.k; VIEW.y = my - (my - VIEW.y) * k / VIEW.k; VIEW.k = k; applyView(); save();
      }, { passive: false });
      window.addEventListener("keydown", (e) => { if (e.key === "Escape" && viewName === "web") select(null); });
      window.addEventListener("resize", () => { if (viewName === "web" && current) { fit(); applyView(); save(); } });

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
        if (location.hash.startsWith("#web") && applyLink(location.hash)) { showView("web"); render(true); fitted = true; }
      });

      const gen = new Date(raw.generated_at || NOW);
      const live = [...involved].filter(isLive).length;
      $("cw-lede").textContent = `Who talks to whom, by mailbox and by c11 send. ${messages.length} messages between ${involved.size} panels (${live} open) in ${wsOrder.filter((id) => id !== NO_WS).length} workspaces.`;
      const zoneName = (Intl.DateTimeFormat().resolvedOptions().timeZone || "").split("/").pop().replace(/_/g, " ");
      $("cw-stamp").replaceChildren(...[["Built", gen.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) + " " + zoneName],
        ["Source", raw.bounded ? "newest " + rows.length : "all recorded"]].flatMap(([k, v]) => [h("div", {}, k), h("div", {}, v)]));

      showView(viewName);
      render(!fitted);
      fitted = true;
      save();
    })();
    """#
}
