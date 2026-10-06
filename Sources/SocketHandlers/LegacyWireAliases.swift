import Foundation

// C11-337: wire vocabulary is workspace > area > panel. Canonical socket
// methods are `panel.*` / `area.*`, canonical refs are `panel:N` / `area:N`,
// canonical JSON keys are `panel_*` / `area_*`. Every older spelling keeps
// working as a hidden alias on input: `tab.*` / `surface.*` / `pane.*`
// methods, `tab:N` / `surface:N` / `pane:N` refs, `tab_*` / `surface_*` /
// `pane_*` keys. This file is the one place that knows the old names.
//
// Output: results carry `panel_*` beside the v0.67 `tab_*` spelling (whose ref
// values say `tab:N`), and `area_*` alone. `surface_*` / `pane_*` are no longer
// emitted; they had their one release.
//
// C11-337: stop emitting `tab_*` at 1.1 (set `emitOld: false` on the panel
// family); input aliases stay forever.
enum LegacyWireAliases {
    // MARK: - Methods

    /// Maps an old socket method name to its canonical spelling. Canonical and
    /// unknown names pass through unchanged. Applied once at each request seam
    /// so every registry (handlers, off-main set, focus-intent set,
    /// capabilities) holds only canonical names.
    nonisolated static func canonicalMethod(_ method: String) -> String {
        if method.hasPrefix("tab.") {
            return "panel." + method.dropFirst("tab.".count)
        }
        if method.hasPrefix("surface.") {
            return "panel." + method.dropFirst("surface.".count)
        }
        if method == "area.tabs" || method == "pane.surfaces" {
            return "area.panels"
        }
        if method.hasPrefix("pane.") {
            return "area." + method.dropFirst("pane.".count)
        }
        if method.hasPrefix("browser.tab.") {
            return "browser.panel." + method.dropFirst("browser.tab.".count)
        }
        if method == "notification.create_for_tab" || method == "notification.create_for_surface" {
            return "notification.create_for_panel"
        }
        if method.hasPrefix("debug.") {
            if let canonical = legacyDebugMethods[method] {
                return canonical
            }
            for (old, new) in legacyDebugPrefixes where method.hasPrefix(old) {
                return new + method.dropFirst(old.count)
            }
        }
        return method
    }

    /// Old debug-only method names. `empty_panel` counts the Empty Area view, so
    /// it maps to `empty_area` (there "panel" never meant the c11 leaf).
    nonisolated private static let legacyDebugMethods: [String: String] = [
        "debug.empty_panel.count": "debug.empty_area.count",
        "debug.empty_panel.reset": "debug.empty_area.reset",
        "debug.tab_snapshot": "debug.panel_snapshot",
        "debug.tab_snapshot.reset": "debug.panel_snapshot.reset",
        "debug.command_palette.rename_tab.open": "debug.command_palette.rename_panel.open",
    ]

    /// Old debug chrome method families (panel sheet, rail and strip).
    nonisolated private static let legacyDebugPrefixes: [(old: String, new: String)] = [
        ("debug.tab_sheet.", "debug.panel_sheet."),
        ("debug.tab_rail.", "debug.panel_rail."),
        ("debug.tab_strip.", "debug.panel_strip."),
    ]

    /// The canonical spelling of a handler-side param key, for error text
    /// (`surface_id`/`tab_id` -> `panel_id`, `pane_id` -> `area_id`).
    nonisolated static func displayKey(_ key: String) -> String {
        switch key {
        case "surface_id", "tab_id": return "panel_id"
        case "pane_id": return "area_id"
        default: return key
        }
    }

    // MARK: - Handles

    /// `tab:N` / `surface:N` -> `panel:N`, `pane:N` -> `area:N`
    /// (case-insensitive prefix, trimmed). Anything else is returned unchanged.
    nonisolated static func canonicalHandle(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the prefix is case-folded; the remainder (an ordinal, or a fallback UUID) is kept verbatim.
        guard let colon = trimmed.firstIndex(of: ":") else { return handle }
        let prefix = trimmed[..<colon].lowercased()
        let rest = trimmed[trimmed.index(after: colon)...]
        switch prefix {
        case "panel", "tab", "surface": return "panel:" + rest
        case "area", "pane": return "area:" + rest
        default: return handle
        }
    }

    /// `panel:N` (or any spelling of it) -> `tab:N`: the v0.67 value that rides
    /// beside the canonical one in `tab_*` keys. Area refs keep `area:N`.
    nonisolated static func legacyHandle(_ handle: String) -> String {
        let canonical = canonicalHandle(handle)
        if canonical.hasPrefix("panel:") { return "tab:" + canonical.dropFirst("panel:".count) }
        return canonical
    }

    /// The ref spelling an old client expects back, from the method name it
    /// sent: `tab.*` (v0.67) -> `tab:`, `surface.*` (older) -> `surface:`.
    /// `system.tree` / `system.identify` kept their names, so there the old
    /// client shows in its `caller` block: `tab_id` (or `surface_id`) without
    /// `panel_id`. Canonical requests return nil.
    nonisolated static func legacyRefPrefix(forRawMethod method: String, params: [String: Any] = [:]) -> String? {
        if method.hasPrefix("tab.") || method == "area.tabs" || method.hasPrefix("browser.tab.") {
            return "tab:"
        }
        if method.hasPrefix("surface.") || method == "pane.surfaces" {
            return "surface:"
        }
        if method == "system.tree" || method == "system.identify",
           let caller = params["caller"] as? [String: Any], caller["panel_id"] == nil {
            if caller["tab_id"] != nil { return "tab:" }
            if caller["surface_id"] != nil { return "surface:" }
        }
        return nil
    }

    /// Old CLIs resolve `--tab tab:N` client-side by matching the generic `ref`
    /// of `tab.list` items, so a response to an old-spelling request carries its
    /// generic `ref` values (`panel:N`) in that spelling. Paired keys already
    /// carry `tab:N` in `tab_*`. Only old clients pay for the re-encode.
    nonisolated static func echoLegacyRefs(_ response: String, prefix: String) -> String {
        guard response.contains("\"panel:"),
              let data = response.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = object["result"] else { return response }
        object["result"] = echoGenericRefs(result, prefix: prefix)
        guard JSONSerialization.isValidJSONObject(object),
              let encoded = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: encoded, encoding: .utf8) else { return response }
        return text
    }

    nonisolated private static func echoGenericRefs(_ value: Any, prefix: String) -> Any {
        if let array = value as? [Any] {
            return array.map { echoGenericRefs($0, prefix: prefix) }
        }
        guard var dict = value as? [String: Any] else { return value }
        for (key, child) in dict where !opaqueKeys.contains(key) {
            if key == "ref", let ref = child as? String, ref.hasPrefix("panel:") {
                dict[key] = prefix + ref.dropFirst("panel:".count)
            } else {
                dict[key] = echoGenericRefs(child, prefix: prefix)
            }
        }
        return dict
    }

    // MARK: - Key table

    /// `new` is canonical and always emitted. `old` is the previous spelling:
    /// when `emitOld`, it is filled from `new` (and `new` from it); otherwise
    /// it is accepted on input and dropped from output. `extraOld` spellings
    /// are input-only: they fill `new` and are dropped from output.
    struct KeyPair {
        let new: String
        let old: String
        var extraOld: [String] = []
        /// Values are handles (`panel:N` / `area:N`) or arrays of them.
        var isRef: Bool = false
        var emitOld: Bool = true
    }

    /// The panel family: `panel_*` canonical, `tab_*` emitted beside it,
    /// `surface_*` input-only.
    nonisolated private static func panel(
        _ new: String, _ old: String, _ surface: String? = nil, ref: Bool = false
    ) -> KeyPair {
        KeyPair(new: new, old: old, extraOld: surface.map { [$0] } ?? [], isRef: ref)
    }

    /// The area family: `area_*` canonical and alone on output, `pane_*` input-only.
    nonisolated private static func area(_ new: String, _ old: String, ref: Bool = false) -> KeyPair {
        KeyPair(new: new, old: old, isRef: ref, emitOld: false)
    }

    nonisolated static let legacyKeyPairs: [KeyPair] = [
        panel("panel_id", "tab_id", "surface_id"),
        panel("panel_ref", "tab_ref", "surface_ref", ref: true),
        panel("panel_ids", "tab_ids", "surface_ids"),
        panel("panel_refs", "tab_refs", "surface_refs", ref: true),
        area("area_id", "pane_id"),
        area("area_ref", "pane_ref", ref: true),
        area("target_area_id", "target_pane_id"),
        area("target_area_ref", "target_pane_ref", ref: true),
        area("source_area_id", "source_pane_id"),
        area("source_area_ref", "source_pane_ref", ref: true),
        panel("source_panel_id", "source_tab_id", "source_surface_id"),
        panel("source_panel_ref", "source_tab_ref", "source_surface_ref", ref: true),
        panel("target_panel_id", "target_tab_id", "target_surface_id"),
        panel("target_panel_ref", "target_tab_ref", "target_surface_ref", ref: true),
        panel("before_panel_id", "before_tab_id", "before_surface_id"),
        panel("after_panel_id", "after_tab_id", "after_surface_id"),
        panel("created_panel_id", "created_tab_id", "created_surface_id"),
        panel("created_panel_ref", "created_tab_ref", "created_surface_ref", ref: true),
        panel("selected_panel_id", "selected_tab_id", "selected_surface_id"),
        panel("selected_panel_ref", "selected_tab_ref", "selected_surface_ref", ref: true),
        panel("focused_panel_id", "focused_tab_id", "focused_surface_id"),
        panel("focused_panel_ref", "focused_tab_ref", "focused_surface_ref", ref: true),
        panel("caller_panel_id", "caller_tab_id", "caller_surface_id"),
        panel("flag_caller_panel_id", "flag_caller_tab_id", "flag_caller_surface_id"),
        panel("affected_panel_ids", "affected_tab_ids", "affected_surface_ids"),
        panel("panel_type", "tab_type", "surface_type"),
        panel("panel_title", "tab_title", "surface_title"),
        panel("panel_index", "tab_index", "surface_index"),
        panel("panel_index_in_area", "tab_index_in_area", "surface_index_in_pane"),
        panel("panel_selected_in_area", "tab_selected_in_area", "surface_selected_in_pane"),
        area("index_in_area", "index_in_pane"),
        area("selected_in_area", "selected_in_pane"),
        area("area_index", "pane_index"),
        panel("is_browser_panel", "is_browser_tab", "is_browser_surface"),
        panel("panel_pinned", "tab_pinned", "surface_pinned"),
        panel("panel_focused", "tab_focused", "surface_focused"),
        panel("panel_created_at", "tab_created_at", "surface_created_at"),
        panel("panel_age_seconds", "tab_age_seconds", "surface_age_seconds"),
        panel("panel_context", "tab_context", "surface_context"),
        panel("panel_view_first_responder", "tab_view_first_responder", "surface_view_first_responder"),
        panel("runtime_panel_ready", "runtime_tab_ready", "runtime_surface_ready"),
        panel("runtime_panel_created_at", "runtime_tab_created_at", "runtime_surface_created_at"),
        panel("runtime_panel_age_seconds", "runtime_tab_age_seconds", "runtime_surface_age_seconds"),
        panel("panel_count", "tab_count", "surface_count"),
        panel("terminal_panels", "terminal_tabs"),
        // camelCase `workspace.apply` result keys.
        panel("panelRefs", "tabRefs", "surfaceRefs", ref: true),
        area("areaRefs", "paneRefs", ref: true),
    ]

    /// Extra spellings a caller may use for a param whose canonical name the
    /// handlers read: new name, `*_ref` variant, and old names all land on the
    /// key the handler reads (`target`). Applied only when `target` is absent.
    nonisolated static let paramSources: [(target: String, sources: [String])] = [
        ("surface_id", ["panel_id", "panel_ref", "tab_id", "tab_ref", "surface_ref"]),
        ("pane_id", ["area_id", "area_ref", "pane_ref"]),
        ("pane", ["area"]),
        ("target_pane_id", ["target_area_id", "target_area_ref", "target_pane_ref"]),
        ("source_pane_id", ["source_area_id", "source_area_ref", "source_pane_ref"]),
        ("target_surface_id", [
            "target_panel_id", "target_panel_ref", "target_tab_id", "target_tab_ref", "target_surface_ref",
        ]),
        ("source_surface_id", [
            "source_panel_id", "source_panel_ref", "source_tab_id", "source_tab_ref", "source_surface_ref",
        ]),
        ("before_surface_id", ["before_panel_id", "before_tab_id"]),
        ("after_surface_id", ["after_panel_id", "after_tab_id"]),
        ("caller_surface_id", ["caller_panel_id", "caller_tab_id"]),
    ]

    /// Subtrees the output completion never enters: user/page-supplied data
    /// whose keys are not ours.
    /// (page values, metadata blobs, conversation payloads, network headers and cookies, config
    /// and plan blobs.)
    nonisolated private static let opaqueKeys: Set<String> = [
        "value", "metadata", "metadata_sources", "payload", "headers", "request_headers",
        "response_headers", "cookies", "storage", "entries", "plan",
        "configs", "config", "recent", "removed", "pinned",
    ]

    // MARK: - Params (inbound)

    /// Returns `params` with every old and new spelling resolved onto the key
    /// the handlers read. Never overwrites a key the caller set.
    nonisolated static func canonicalParams(_ params: [String: Any]) -> [String: Any] {
        var out = params
        for (target, sources) in paramSources where out[target] == nil {
            for source in sources {
                if let value = params[source] {
                    out[target] = value
                    break
                }
            }
        }
        return out
    }

    struct RoutingKeyRejection {
        let key: String
        let canonical: String
        var code: String { "invalid_params" }
        var message: String {
            String(format: String(
                localized: "socket.error.unsupported_routing_key",
                defaultValue: "Unsupported parameter '%1$@'; use '%2$@'."
            ), key, canonical)
        }
    }

    /// The existing alias tables define the exact spellings we accept. Cache
    /// their normalized selector forms once, rather than rebuilding per request.
    private struct RoutingKeys {
        var allowed: Set<String> = []
        var canonicalByNormalized: [String: String] = [:]

        mutating func add(_ key: String, canonical: String) {
            allowed.insert(key)
            let normalized = LegacyWireAliases.normalizedRoutingKey(key)
            // Snake-case pairs precede the camelCase result-map pairs. Keep
            // their public spelling when both normalize to the same selector.
            if canonicalByNormalized[normalized] == nil {
                canonicalByNormalized[normalized] = canonical
            }
        }
    }

    nonisolated private static func normalizedRoutingKey(_ key: String) -> String {
        key.replacingOccurrences(of: "_", with: "").lowercased()
    }

    nonisolated private static let routingKeys: RoutingKeys = {
        var keys = RoutingKeys()
        for pair in legacyKeyPairs {
            let selector = ["_id", "_ids", "_ref", "_refs"].contains { pair.new.hasSuffix($0) }
                || pair.isRef
            guard selector else { continue }
            for key in [pair.new, pair.old] + pair.extraOld {
                keys.add(key, canonical: pair.new)
            }
        }
        for (target, sources) in paramSources {
            let canonical = target == "pane" ? "area"
                : keys.canonicalByNormalized[normalizedRoutingKey(target)] ?? displayKey(target)
            for key in [target] + sources {
                keys.add(key, canonical: canonical)
            }
        }
        for key in ["window_id", "workspace_id"] {
            keys.add(key, canonical: key)
        }
        return keys
    }()

    /// Inspect top-level names only. Case/underscore variants of selectors are
    /// rejected; unrelated keys and character typos such as surfce_id remain
    /// outside this bounded check. Alias copying is intentionally unchanged.
    nonisolated static func unsupportedRoutingKey(_ params: [String: Any]) -> RoutingKeyRejection? {
        for key in params.keys where !routingKeys.allowed.contains(key) {
            if let canonical = routingKeys.canonicalByNormalized[normalizedRoutingKey(key)] {
                return RoutingKeyRejection(key: key, canonical: canonical)
            }
        }
        return nil
    }

    // MARK: - Results (outbound)

    /// Walks a JSON-shaped result and completes every key pair (never
    /// overwriting a canonical key a handler set): `new` always, carrying
    /// `panel:N` / `area:N` values; `old` beside it when `emitOld`, carrying
    /// `tab:N`; input-only spellings (`extraOld`, and `old` when not emitted)
    /// are removed.
    nonisolated static func completeResult(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return completeDict(dict)
        }
        if let array = value as? [Any] {
            return array.map { completeResult($0) }
        }
        return value
    }

    nonisolated private static func completeDict(_ input: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        out.reserveCapacity(input.count + 4)
        for (key, child) in input {
            out[key] = opaqueKeys.contains(key) ? child : completeResult(child)
        }
        for pair in legacyKeyPairs {
            var found: Any? = out[pair.new]
            if found == nil { found = out[pair.old] }
            for key in pair.extraOld {
                if found == nil { found = out[key] }
                out.removeValue(forKey: key)
            }
            guard let value = found else { continue }
            out[pair.new] = pair.isRef ? convertRef(value, using: canonicalHandle) : value
            if pair.emitOld {
                let old = out[pair.old] ?? value
                out[pair.old] = pair.isRef ? convertRef(old, using: legacyHandle) : old
            } else {
                out.removeValue(forKey: pair.old)
            }
        }
        return out
    }

    nonisolated private static func convertRef(_ value: Any, using transform: (String) -> String) -> Any {
        if let string = value as? String { return transform(string) }
        if let array = value as? [Any] { return array.map { convertRef($0, using: transform) } }
        if let dict = value as? [String: Any] {
            // `panelRefs` style maps: plan id -> ref.
            return dict.mapValues { convertRef($0, using: transform) }
        }
        return value
    }
}
