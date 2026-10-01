import Foundation

// C11-248: wire vocabulary is workspace > area > tab. Canonical socket methods
// are `tab.*` / `area.*`, canonical refs are `tab:N` / `area:N`, canonical JSON
// keys are `tab_*` / `area_*`. Every older spelling (`surface.*` / `pane.*`
// methods, `surface:N` / `pane:N` refs, `surface_*` / `pane_*` / `panel_*` keys)
// keeps working as a hidden alias: this file is the one place that knows the
// old names.
//
// C11-248: legacy keys, remove after one release (the whole `legacyKeyPairs`
// table and the output/input completion that reads it).
enum LegacyWireAliases {
    // MARK: - Methods

    /// Maps an old socket method name to its canonical spelling. Canonical and
    /// unknown names pass through unchanged. Applied once at each request seam
    /// so every registry (handlers, off-main set, focus-intent set,
    /// capabilities) holds only canonical names.
    nonisolated static func canonicalMethod(_ method: String) -> String {
        if method.hasPrefix("surface.") {
            return "tab." + method.dropFirst("surface.".count)
        }
        if method.hasPrefix("pane.") {
            let rest = String(method.dropFirst("pane.".count))
            return "area." + (rest == "surfaces" ? "tabs" : rest)
        }
        if method == "notification.create_for_surface" {
            return "notification.create_for_tab"
        }
        return method
    }

    // MARK: - Handles

    /// `surface:N` -> `tab:N`, `pane:N` -> `area:N` (case-insensitive, trimmed).
    /// Anything else is returned unchanged.
    nonisolated static func canonicalHandle(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("surface:") { return "tab:" + trimmed.dropFirst("surface:".count) }
        if trimmed.hasPrefix("pane:") { return "area:" + trimmed.dropFirst("pane:".count) }
        if trimmed.hasPrefix("tab:") || trimmed.hasPrefix("area:") { return trimmed }
        return handle
    }

    /// `tab:N` -> `surface:N`, `area:N` -> `pane:N`: the old-format value that
    /// rides beside the new one in legacy keys.
    nonisolated static func legacyHandle(_ handle: String) -> String {
        if handle.hasPrefix("tab:") { return "surface:" + handle.dropFirst("tab:".count) }
        if handle.hasPrefix("area:") { return "pane:" + handle.dropFirst("area:".count) }
        return handle
    }

    // MARK: - Key table

    /// `new` is canonical. `old` is the primary legacy spelling: filled from
    /// `new` when absent, and `new` is filled from it when only `old` was set.
    /// `extraOld` spellings only ever fill `new` (the legacy `panel_*` /
    /// `focused_panel_*` family has one canonical successor).
    struct KeyPair {
        let new: String
        let old: String
        var extraOld: [String] = []
        /// Values are handles (`tab:N` / `area:N`) or arrays of them.
        var isRef: Bool = false
    }

    nonisolated static let legacyKeyPairs: [KeyPair] = [
        KeyPair(new: "tab_id", old: "surface_id", extraOld: ["panel_id"]),
        KeyPair(new: "tab_ref", old: "surface_ref", extraOld: ["panel_ref"], isRef: true),
        KeyPair(new: "tab_ids", old: "surface_ids"),
        KeyPair(new: "tab_refs", old: "surface_refs", isRef: true),
        KeyPair(new: "area_id", old: "pane_id"),
        KeyPair(new: "area_ref", old: "pane_ref", isRef: true),
        KeyPair(new: "target_area_id", old: "target_pane_id"),
        KeyPair(new: "target_area_ref", old: "target_pane_ref", isRef: true),
        KeyPair(new: "source_area_id", old: "source_pane_id"),
        KeyPair(new: "source_area_ref", old: "source_pane_ref", isRef: true),
        KeyPair(new: "source_tab_id", old: "source_surface_id"),
        KeyPair(new: "source_tab_ref", old: "source_surface_ref", isRef: true),
        KeyPair(new: "target_tab_id", old: "target_surface_id"),
        KeyPair(new: "target_tab_ref", old: "target_surface_ref", isRef: true),
        KeyPair(new: "before_tab_id", old: "before_surface_id"),
        KeyPair(new: "after_tab_id", old: "after_surface_id"),
        KeyPair(new: "created_tab_id", old: "created_surface_id"),
        KeyPair(new: "created_tab_ref", old: "created_surface_ref", isRef: true),
        KeyPair(new: "selected_tab_id", old: "selected_surface_id"),
        KeyPair(new: "selected_tab_ref", old: "selected_surface_ref", isRef: true),
        KeyPair(new: "focused_tab_id", old: "focused_surface_id", extraOld: ["focused_panel_id"]),
        KeyPair(new: "focused_tab_ref", old: "focused_surface_ref", extraOld: ["focused_panel_ref"], isRef: true),
        KeyPair(new: "caller_tab_id", old: "caller_surface_id"),
        KeyPair(new: "flag_caller_tab_id", old: "flag_caller_surface_id"),
        KeyPair(new: "affected_tab_ids", old: "affected_surface_ids"),
        KeyPair(new: "tab_type", old: "surface_type"),
        KeyPair(new: "tab_title", old: "surface_title"),
        KeyPair(new: "tab_index", old: "surface_index"),
        KeyPair(new: "tab_index_in_area", old: "surface_index_in_pane"),
        KeyPair(new: "tab_selected_in_area", old: "surface_selected_in_pane"),
        KeyPair(new: "index_in_area", old: "index_in_pane"),
        KeyPair(new: "selected_in_area", old: "selected_in_pane"),
        KeyPair(new: "area_index", old: "pane_index"),
        KeyPair(new: "is_browser_tab", old: "is_browser_surface"),
        KeyPair(new: "tab_pinned", old: "surface_pinned"),
        KeyPair(new: "tab_focused", old: "surface_focused"),
        KeyPair(new: "tab_created_at", old: "surface_created_at"),
        KeyPair(new: "tab_age_seconds", old: "surface_age_seconds"),
        KeyPair(new: "tab_context", old: "surface_context"),
        KeyPair(new: "tab_view_first_responder", old: "surface_view_first_responder"),
        KeyPair(new: "runtime_tab_ready", old: "runtime_surface_ready"),
        KeyPair(new: "runtime_tab_created_at", old: "runtime_surface_created_at"),
        KeyPair(new: "runtime_tab_age_seconds", old: "runtime_surface_age_seconds"),
        KeyPair(new: "tab_count", old: "surface_count"),
        KeyPair(new: "terminal_tabs", old: "terminal_panels"),
        // camelCase `workspace.apply` result keys.
        KeyPair(new: "tabRefs", old: "surfaceRefs", isRef: true),
        KeyPair(new: "areaRefs", old: "paneRefs", isRef: true),
    ]

    /// Extra spellings a caller may use for a param whose canonical name the
    /// handlers read: new name, `*_ref` variant, and old names all land on the
    /// key the handler reads (`target`). Applied only when `target` is absent.
    nonisolated static let paramSources: [(target: String, sources: [String])] = [
        ("surface_id", ["tab_id", "tab_ref", "surface_ref", "panel_id", "panel_ref"]),
        ("pane_id", ["area_id", "area_ref", "pane_ref"]),
        ("pane", ["area"]),
        ("target_pane_id", ["target_area_id", "target_area_ref", "target_pane_ref"]),
        ("source_pane_id", ["source_area_id", "source_area_ref", "source_pane_ref"]),
        ("target_surface_id", ["target_tab_id", "target_tab_ref", "target_surface_ref"]),
        ("source_surface_id", ["source_tab_id", "source_tab_ref", "source_surface_ref"]),
        ("before_surface_id", ["before_tab_id"]),
        ("after_surface_id", ["after_tab_id"]),
        ("caller_surface_id", ["caller_tab_id"]),
    ]

    /// Subtrees the output completion never enters: user/page-supplied data
    /// whose keys are not ours.
    nonisolated private static let opaqueKeys: Set<String> = ["value", "metadata", "metadata_sources"]

    // MARK: - Params (inbound)

    /// Returns `params` with every old and new spelling resolved onto the key
    /// the handlers read. Never overwrites a key the caller set.
    nonisolated static func canonicalParams(_ params: [String: Any]) -> [String: Any] {
        var out = params
        for (target, sources) in paramSources where out[target] == nil {
            for source in sources {
                if let value = params[source], !(value is NSNull) {
                    out[target] = value
                    break
                }
            }
        }
        return out
    }

    // MARK: - Results (outbound)

    /// Walks a JSON-shaped result: every `new`/`old` key pair is completed
    /// (never overwriting a key a handler set), the `new` spelling carrying
    /// `tab:N` / `area:N` values and the `old` spelling `surface:N` / `pane:N`.
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
            if let value = out[pair.new] {
                if pair.isRef { out[pair.new] = convertRef(value, using: canonicalHandle) }
                if out[pair.old] == nil {
                    out[pair.old] = pair.isRef ? convertRef(value, using: legacyHandle) : value
                } else if pair.isRef, let existing = out[pair.old] {
                    out[pair.old] = convertRef(existing, using: legacyHandle)
                }
                continue
            }
            if let value = out[pair.old] ?? pair.extraOld.lazy.compactMap({ out[$0] }).first {
                out[pair.new] = pair.isRef ? convertRef(value, using: canonicalHandle) : value
                if pair.isRef, let existing = out[pair.old] {
                    out[pair.old] = convertRef(existing, using: legacyHandle)
                }
            }
        }
        return out
    }

    nonisolated private static func convertRef(_ value: Any, using transform: (String) -> String) -> Any {
        if let string = value as? String { return transform(string) }
        if let array = value as? [Any] { return array.map { convertRef($0, using: transform) } }
        if let dict = value as? [String: Any] {
            // `surfaceRefs` style maps: plan id -> ref.
            return dict.mapValues { convertRef($0, using: transform) }
        }
        return value
    }
}
