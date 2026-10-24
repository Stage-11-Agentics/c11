// C11-317: split out of CLI/c11.swift by scripts/split-cli.py.
import Foundation
import CryptoKit
import Darwin
import SQLite3
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif

/// Version-skew fallback: a fresh CLI talking to an older app. The tier is probed once per
/// client via `system.capabilities` (see `SocketClient.serverVocabularyTier`). Requests are
/// written in canonical panel vocabulary and downgraded here; results map forward so CLI
/// code only ever reads `panel_*` / `area_*` keys, `panels` / `areas` arrays and
/// `panel:N` / `area:N` refs.
///
/// Tier 2 (`.tab`, v0.67.0 and pre-panel nightlies) is removed at 1.1. Tier 3 (`.surface`,
/// pre-0.67 apps) stays.
enum CLIVersionSkew {
    enum Tier: Equatable {
        /// Advertises `vocabulary.workspace_area_panel` (or the probe failed): send as-is.
        case panel
        /// Advertises `tab.list` but not the panel vocabulary: `tab.*` / `tab_*` / `tab:N`.
        case tab
        /// Neither: `surface.*` / `pane.*`, `surface_*` / `pane_*`, `surface:N` / `pane:N`.
        case surface
    }

    /// The capability that marks a panel-vocabulary app.
    static let panelVocabularyFeature = "vocabulary.workspace_area_panel"

    /// Tier from a `system.capabilities` result; nil (probe failed) means `.panel`.
    static func tier(fromCapabilities caps: [String: Any]?) -> Tier {
        guard let caps else { return .panel }
        let features = (caps["features"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        if features.contains(panelVocabularyFeature) { return .panel }
        let methods = caps["methods"] as? [String] ?? []
        if methods.isEmpty { return .panel }
        return methods.contains("tab.list") ? .tab : .surface
    }

    /// One panel-family key in each vocabulary: canonical, tab era, surface era.
    struct PanelKey {
        let panel: String
        let tab: String
        let surface: String
        /// Values are handles (`panel:N`) or arrays/maps of them.
        var isRef: Bool = false
    }

    /// One area-family key: canonical and surface-era (`pane_*`). Tab-era apps already spoke `area_*`.
    struct AreaKey {
        let area: String
        let pane: String
        var isRef: Bool = false
    }

    /// Mirrors the app's key table (`LegacyWireAliases`): 37 panel triples.
    static let panelKeys: [PanelKey] = [
        PanelKey(panel: "panel_id", tab: "tab_id", surface: "surface_id"),
        PanelKey(panel: "panel_ref", tab: "tab_ref", surface: "surface_ref", isRef: true),
        PanelKey(panel: "panel_ids", tab: "tab_ids", surface: "surface_ids"),
        PanelKey(panel: "panel_refs", tab: "tab_refs", surface: "surface_refs", isRef: true),
        PanelKey(panel: "source_panel_id", tab: "source_tab_id", surface: "source_surface_id"),
        PanelKey(panel: "source_panel_ref", tab: "source_tab_ref", surface: "source_surface_ref", isRef: true),
        PanelKey(panel: "target_panel_id", tab: "target_tab_id", surface: "target_surface_id"),
        PanelKey(panel: "target_panel_ref", tab: "target_tab_ref", surface: "target_surface_ref", isRef: true),
        PanelKey(panel: "before_panel_id", tab: "before_tab_id", surface: "before_surface_id"),
        PanelKey(panel: "after_panel_id", tab: "after_tab_id", surface: "after_surface_id"),
        PanelKey(panel: "created_panel_id", tab: "created_tab_id", surface: "created_surface_id"),
        PanelKey(panel: "created_panel_ref", tab: "created_tab_ref", surface: "created_surface_ref", isRef: true),
        PanelKey(panel: "selected_panel_id", tab: "selected_tab_id", surface: "selected_surface_id"),
        PanelKey(panel: "selected_panel_ref", tab: "selected_tab_ref", surface: "selected_surface_ref", isRef: true),
        PanelKey(panel: "focused_panel_id", tab: "focused_tab_id", surface: "focused_surface_id"),
        PanelKey(panel: "focused_panel_ref", tab: "focused_tab_ref", surface: "focused_surface_ref", isRef: true),
        PanelKey(panel: "caller_panel_id", tab: "caller_tab_id", surface: "caller_surface_id"),
        PanelKey(panel: "flag_caller_panel_id", tab: "flag_caller_tab_id", surface: "flag_caller_surface_id"),
        PanelKey(panel: "affected_panel_ids", tab: "affected_tab_ids", surface: "affected_surface_ids"),
        PanelKey(panel: "panel_type", tab: "tab_type", surface: "surface_type"),
        PanelKey(panel: "panel_title", tab: "tab_title", surface: "surface_title"),
        PanelKey(panel: "panel_index", tab: "tab_index", surface: "surface_index"),
        PanelKey(panel: "panel_index_in_area", tab: "tab_index_in_area", surface: "surface_index_in_pane"),
        PanelKey(panel: "panel_selected_in_area", tab: "tab_selected_in_area", surface: "surface_selected_in_pane"),
        PanelKey(panel: "is_browser_panel", tab: "is_browser_tab", surface: "is_browser_surface"),
        PanelKey(panel: "panel_pinned", tab: "tab_pinned", surface: "surface_pinned"),
        PanelKey(panel: "panel_focused", tab: "tab_focused", surface: "surface_focused"),
        PanelKey(panel: "panel_created_at", tab: "tab_created_at", surface: "surface_created_at"),
        PanelKey(panel: "panel_age_seconds", tab: "tab_age_seconds", surface: "surface_age_seconds"),
        PanelKey(panel: "panel_context", tab: "tab_context", surface: "surface_context"),
        PanelKey(panel: "panel_view_first_responder", tab: "tab_view_first_responder", surface: "surface_view_first_responder"),
        PanelKey(panel: "runtime_panel_ready", tab: "runtime_tab_ready", surface: "runtime_surface_ready"),
        PanelKey(panel: "runtime_panel_created_at", tab: "runtime_tab_created_at", surface: "runtime_surface_created_at"),
        PanelKey(panel: "runtime_panel_age_seconds", tab: "runtime_tab_age_seconds", surface: "runtime_surface_age_seconds"),
        PanelKey(panel: "panel_count", tab: "tab_count", surface: "surface_count"),
        // Pre-0.67 apps already said `terminal_panels`; tab-era apps said `terminal_tabs`.
        PanelKey(panel: "terminal_panels", tab: "terminal_tabs", surface: "terminal_panels"),
        PanelKey(panel: "panelRefs", tab: "tabRefs", surface: "surfaceRefs", isRef: true),
    ]

    /// Mirrors the app's key table: 10 area pairs.
    static let areaKeys: [AreaKey] = [
        AreaKey(area: "area_id", pane: "pane_id"),
        AreaKey(area: "area_ref", pane: "pane_ref", isRef: true),
        AreaKey(area: "target_area_id", pane: "target_pane_id"),
        AreaKey(area: "target_area_ref", pane: "target_pane_ref", isRef: true),
        AreaKey(area: "source_area_id", pane: "source_pane_id"),
        AreaKey(area: "source_area_ref", pane: "source_pane_ref", isRef: true),
        AreaKey(area: "index_in_area", pane: "index_in_pane"),
        AreaKey(area: "selected_in_area", pane: "selected_in_pane"),
        AreaKey(area: "area_index", pane: "pane_index"),
        AreaKey(area: "areaRefs", pane: "paneRefs", isRef: true),
    ]

    private static let panelKeyByPanel: [String: PanelKey] =
        Dictionary(panelKeys.map { ($0.panel, $0) }, uniquingKeysWith: { first, _ in first })
    private static let panelKeyByTab: [String: PanelKey] =
        Dictionary(panelKeys.map { ($0.tab, $0) }, uniquingKeysWith: { first, _ in first })
    private static let areaKeyByArea: [String: AreaKey] =
        Dictionary(areaKeys.map { ($0.area, $0) }, uniquingKeysWith: { first, _ in first })

    /// Debug method names whose tab-era spelling differs. `debug.panel_snapshot` is
    /// accepted by every app, so it is not here.
    private static let tabEraDebugMethods: [String: String] = [
        "debug.command_palette.rename_panel.open": "debug.command_palette.rename_tab.open",
        "debug.panel_rail.open": "debug.tab_rail.open",
        "debug.panel_strip.scroll": "debug.tab_strip.scroll",
    ]

    /// `panel.action` action values in their tab-era spelling (also accepted by surface-era apps).
    private static let tabEraActions: [String: String] = [
        "reload_panel": "reload_tab",
        "duplicate_panel": "duplicate_tab",
        "new_terminal_panel_to_right": "new_terminal_tab_to_right",
        "new_browser_panel_to_right": "new_browser_tab_to_right",
        "close_other_panels": "close_other_tabs",
    ]

    /// The method name an older app understands, or nil when it is unchanged.
    static func legacyMethod(for method: String, tier: Tier) -> String? {
        switch tier {
        case .panel:
            return nil
        case .tab:
            if method.hasPrefix("panel.") { return "tab." + method.dropFirst("panel.".count) }
            if method == "area.panels" { return "area.tabs" }
            if method == "notification.create_for_panel" { return "notification.create_for_tab" }
            if method.hasPrefix("browser.panel.") { return "browser.tab." + method.dropFirst("browser.panel.".count) }
            return legacyDebugMethod(method)
        case .surface:
            if method == "panel.action" { return "tab.action" }
            if method.hasPrefix("panel.") { return "surface." + method.dropFirst("panel.".count) }
            if method == "area.panels" { return "pane.surfaces" }
            if method.hasPrefix("area.") { return "pane." + method.dropFirst("area.".count) }
            if method == "notification.create_for_panel" { return "notification.create_for_surface" }
            if method.hasPrefix("browser.panel.") { return "browser.tab." + method.dropFirst("browser.panel.".count) }
            return legacyDebugMethod(method)
        }
    }

    private static func legacyDebugMethod(_ method: String) -> String? {
        if let mapped = tabEraDebugMethods[method] { return mapped }
        if method.hasPrefix("debug.panel_sheet.") { return "debug.tab_sheet." + method.dropFirst("debug.panel_sheet.".count) }
        return nil
    }

    /// Param keys whose values are user data: never rewritten.
    private static let opaqueParamKeys: Set<String> = ["metadata", "value", "payload", "env", "text", "body", "title", "prompt"]

    /// `panel:N` -> `tab:N` (tab era) or `surface:N` (surface era); `area:N` -> `pane:N` (surface era).
    private static func legacyHandle(_ value: String, tier: Tier) -> String {
        let prefixes: [(String, String)]
        switch tier {
        case .panel: return value
        case .tab: prefixes = [("panel:", "tab:"), ("tab:", "tab:"), ("surface:", "surface:")]
        case .surface: prefixes = [("panel:", "surface:"), ("tab:", "surface:"), ("surface:", "surface:"), ("area:", "pane:"), ("pane:", "pane:")]
        }
        // Prefixes match in any case (`Panel:3`, `TAB:3`); the ordinal must be numeric.
        let lowered = value.lowercased()
        for (modern, legacy) in prefixes where lowered.hasPrefix(modern) {
            let rest = value.dropFirst(modern.count)
            if !rest.isEmpty, rest.allSatisfy(\.isNumber) { return legacy + rest }
        }
        return value
    }

    private static func legacyKey(_ key: String, tier: Tier) -> String {
        switch tier {
        case .panel:
            return key
        case .tab:
            return panelKeyByPanel[key]?.tab ?? key
        case .surface:
            if let row = panelKeyByPanel[key] ?? panelKeyByTab[key] { return row.surface }
            return areaKeyByArea[key]?.pane ?? key
        }
    }

    /// Params for an older app: its keys at every depth (never inside user-data values),
    /// its ref values, and for `panel.action` its action spelling.
    static func legacyParams(_ params: [String: Any], method: String, tier: Tier) -> [String: Any] {
        guard tier != .panel else { return params }
        var out = legacyParamValue(params, tier: tier) as? [String: Any] ?? params
        if method == "panel.action", let action = out["action"] as? String, let legacy = tabEraActions[action] {
            out["action"] = legacy
        }
        return out
    }

    private static func legacyParamValue(_ value: Any, tier: Tier) -> Any {
        if let string = value as? String { return legacyHandle(string, tier: tier) }
        if let array = value as? [Any] { return array.map { legacyParamValue($0, tier: tier) } }
        guard let dict = value as? [String: Any] else { return value }
        var out: [String: Any] = [:]
        for (key, child) in dict {
            out[legacyKey(key, tier: tier)] = opaqueParamKeys.contains(key) ? child : legacyParamValue(child, tier: tier)
        }
        return out
    }

    /// `tab:N` / `surface:N` -> `panel:N`, `pane:N` -> `area:N`.
    static func modernHandle(_ value: String) -> String {
        for (legacy, modern) in [("tab:", "panel:"), ("surface:", "panel:"), ("pane:", "area:")] where value.hasPrefix(legacy) {
            return modern + value.dropFirst(legacy.count)
        }
        return value
    }

    private static func modernRef(_ value: Any) -> Any {
        if let string = value as? String { return modernHandle(string) }
        if let array = value as? [Any] { return array.map(modernRef) }
        if let dict = value as? [String: Any] { return dict.mapValues(modernRef) }
        return value
    }

    /// Subtrees that carry user or page data, never ours (matches the app's completion).
    private static let opaqueResultKeys: Set<String> = [
        "value", "metadata", "metadata_sources", "payload", "headers", "request_headers",
        "response_headers", "cookies", "storage", "entries", "plan",
        "configs", "config", "recent", "removed", "pinned",
    ]

    /// Result from an older app with canonical keys, arrays and refs filled in beside the old ones.
    static func modernResult(_ value: [String: Any]) -> [String: Any] {
        modernValue(value) as? [String: Any] ?? value
    }

    private static func modernValue(_ value: Any) -> Any {
        if let array = value as? [Any] { return array.map(modernValue) }
        guard var dict = value as? [String: Any] else { return value }
        for (key, child) in dict where !opaqueResultKeys.contains(key) { dict[key] = modernValue(child) }
        for row in panelKeys {
            if let current = dict[row.panel] {
                if row.isRef { dict[row.panel] = modernRef(current) }
                continue
            }
            guard let old = dict[row.tab] ?? dict[row.surface] else { continue }
            dict[row.panel] = row.isRef ? modernRef(old) : old
        }
        for row in areaKeys {
            if let current = dict[row.area] {
                if row.isRef { dict[row.area] = modernRef(current) }
                continue
            }
            guard let old = dict[row.pane] else { continue }
            dict[row.area] = row.isRef ? modernRef(old) : old
        }
        if dict["panels"] == nil, let items = dict["tabs"] ?? dict["surfaces"] { dict["panels"] = items }
        if dict["areas"] == nil, let items = dict["panes"] { dict["areas"] = items }
        // Items carry a generic `ref`; give it the canonical prefix too.
        if let ref = dict["ref"] as? String { dict["ref"] = modernHandle(ref) }
        return dict
    }
}

/// Returns true when a `CLIError` represents "c11 app isn't reachable on its
/// control socket" — used by advisory pathways (like the claude-hook dispatch)
/// that should no-op rather than surface an error when nothing is listening.
///
/// c11 is single-user: the claude-hook writer treats "another uid owns the
/// socket", "an orphaned socket file exists but no listener accepts", and
/// "permission denied on the socket directory" all as "no live c11 app on
/// this machine for me" — advisory, not failure. If multi-user support ever
/// lands, revisit and split `failed` from advisory.
///
/// The string-based predicate lives in `Sources/CLIAdvisoryConnectivity.swift`
/// so it can be unit-tested in the app test target without dragging `CLIError`
/// (CLI-local) into the c11 module.
func isAdvisoryHookConnectivityError(_ error: CLIError) -> Bool {
    CLIAdvisoryConnectivity.isAdvisoryHookConnectivity(message: error.message)
}
