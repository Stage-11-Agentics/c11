import Foundation

/// Pure parser + writer for the Markdown blueprint format introduced by
/// CMUX-37 workstream 1. The on-disk shape is YAML frontmatter, optional
/// prose, and a fenced YAML codeblock under `## Layout` — Obsidian-friendly
/// and hand-editable. Both directions compile to / from the existing
/// `WorkspaceBlueprintFile` envelope; no AppKit, no SwiftUI; tests inject
/// a Foundation-only world.
///
/// The schema (operator-approved):
///
/// ```markdown
/// ---
/// title: Agent Room
/// description: Three-pane orchestration layout
/// custom_color: "#9D8048"
/// ---
///
/// # Agent Room
///
/// Free-form prose body. Renders nicely in Obsidian. Parser ignores it.
///
/// ## Layout
///
/// ```yaml
/// layout:
///   - direction: horizontal
///     split: 50/50
///     children:
///       - type: terminal
///         title: Main terminal
///         cwd: ~/Projects/Stage11/code/c11
///       - direction: vertical
///         split: 60/40
///         children:
///           - type: browser
///             title: Lattice
///             url: http://localhost:8799/
///           - type: markdown
///             title: Notes
///             file: ~/notes/today.md
/// ```
/// ```
///
/// Round-trip rules:
/// - `frontmatter.title` ↔ `WorkspaceBlueprintFile.name`. When the embedded
///   `WorkspaceSpec.title` differs from the file name we additionally write
///   a `workspace_title:` frontmatter key; absent → falls back to `title`.
/// - `frontmatter.description` ↔ `WorkspaceBlueprintFile.description`.
/// - `frontmatter.custom_color` ↔ `WorkspaceSpec.customColor`.
/// - The layout tree is encoded under `## Layout` in a fenced YAML block.
///   `WorkspaceSpec.workingDirectory` and `WorkspaceSpec.metadata`,
///   `SurfaceSpec.description`, `SurfaceSpec.metadata`, and
///   `SurfaceSpec.paneMetadata` are silently dropped on serialise; their
///   round-trip lives on the JSON path. The markdown form is meant for
///   hand-authoring and legible exports — not lossless capture.
enum WorkspaceBlueprintMarkdown {

    // MARK: - Errors

    enum ParseError: Error, CustomStringConvertible, Equatable {
        case missingLayoutSection
        case missingLayoutCodeblock
        case yamlParseFailed(String)
        case unknownNodeType(String)
        case malformedSplitRatio(String)
        case missingChildren
        case wrongChildCount(Int)
        case missingType
        case unsupportedSurfaceKind(String)

        var description: String {
            switch self {
            case .missingLayoutSection:
                return String(
                    localized: "blueprint.markdown.error.missingLayoutSection",
                    defaultValue: "blueprint markdown: missing `## Layout` section"
                )
            case .missingLayoutCodeblock:
                return String(
                    localized: "blueprint.markdown.error.missingLayoutCodeblock",
                    defaultValue: "blueprint markdown: `## Layout` section has no fenced YAML codeblock"
                )
            case .yamlParseFailed(let detail):
                return String(
                    localized: "blueprint.markdown.error.yamlParseFailed",
                    defaultValue: "blueprint markdown: layout YAML parse failed: \(detail)"
                )
            case .unknownNodeType(let raw):
                return String(
                    localized: "blueprint.markdown.error.unknownNodeType",
                    defaultValue: "blueprint markdown: unknown layout node type '\(raw)'"
                )
            case .malformedSplitRatio(let raw):
                return String(
                    localized: "blueprint.markdown.error.malformedSplitRatio",
                    defaultValue: "blueprint markdown: malformed split ratio '\(raw)' (expected `N/M` or `0.<digits>`)"
                )
            case .missingChildren:
                return String(
                    localized: "blueprint.markdown.error.missingChildren",
                    defaultValue: "blueprint markdown: split node missing `children:` list"
                )
            case .wrongChildCount(let got):
                return String(
                    localized: "blueprint.markdown.error.wrongChildCount",
                    defaultValue: "blueprint markdown: split must have exactly two children (got \(got))"
                )
            case .missingType:
                return String(
                    localized: "blueprint.markdown.error.missingType",
                    defaultValue: "blueprint markdown: leaf node missing `type:` (expected terminal/browser/markdown)"
                )
            case .unsupportedSurfaceKind(let raw):
                return String(
                    localized: "blueprint.markdown.error.unsupportedSurfaceKind",
                    defaultValue: "blueprint markdown: unsupported surface kind '\(raw)' (expected terminal/browser/markdown)"
                )
            }
        }
    }

    // MARK: - Public API

    static func parse(_ data: Data) throws -> WorkspaceBlueprintFile {
        let text = String(data: data, encoding: .utf8) ?? ""
        let (frontmatter, body) = splitFrontmatter(text)
        let frontKV = parseSimpleMapping(frontmatter ?? "")
        let layoutBlock = try extractLayoutCodeblock(body)
        let yamlRoot = try YAML.parse(layoutBlock)

        // Build plan from the YAML root.
        let layoutList = yamlRoot.lookup("layout")?.asList ?? []
        guard let rootNode = layoutList.first else {
            throw ParseError.yamlParseFailed("`layout:` is missing or empty")
        }
        var idGen = SurfaceIDGenerator()
        var surfaces: [SurfaceSpec] = []
        let layout = try buildLayoutTree(from: rootNode, surfaces: &surfaces, idGen: &idGen)

        let workspaceTitle = frontKV["workspace_title"] ?? frontKV["title"]
        let customColor = frontKV["custom_color"]
        let spec = WorkspaceSpec(
            title: workspaceTitle?.isEmpty == true ? nil : workspaceTitle,
            customColor: customColor?.isEmpty == true ? nil : customColor,
            workingDirectory: nil,
            metadata: nil
        )
        let plan = WorkspaceApplyPlan(
            version: 1,
            workspace: spec,
            layout: layout,
            surfaces: surfaces
        )
        let name = frontKV["title"] ?? ""
        let description = frontKV["description"]
        return WorkspaceBlueprintFile(
            version: 1,
            name: name,
            description: description?.isEmpty == true ? nil : description,
            plan: plan
        )
    }

    static func serialize(_ file: WorkspaceBlueprintFile) throws -> Data {
        var out = ""
        // Frontmatter.
        out += "---\n"
        out += "title: \(quoteIfNeeded(file.name))\n"
        if let workspaceTitle = file.plan.workspace.title,
           workspaceTitle != file.name {
            out += "workspace_title: \(quoteIfNeeded(workspaceTitle))\n"
        }
        if let desc = file.description, !desc.isEmpty {
            out += "description: \(quoteIfNeeded(desc))\n"
        }
        if let color = file.plan.workspace.customColor, !color.isEmpty {
            out += "custom_color: \(quoteIfNeeded(color))\n"
        }
        out += "---\n\n"
        // Heading.
        out += "# \(file.name)\n\n"
        if let desc = file.description, !desc.isEmpty {
            out += "\(desc)\n\n"
        }
        // Layout.
        out += "## Layout\n\n"
        out += "```yaml\n"
        out += "layout:\n"
        // C11-35: emit list items at indent 4 so the leading dash sits at
        // column 2 (under `layout:` at column 0). Previously emitted at
        // indent 2, putting the dash at column 0 — valid compact YAML, but
        // the in-tree `YAML` subset parser only accepts list items strictly
        // deeper than their parent key, which collapsed `layout:` to an
        // empty scalar and failed every `.md` round-trip.
        out += emitLayoutNode(file.plan.layout, surfaces: file.plan.surfaces, indent: 4, listItem: true)
        out += "```\n"
        return out.data(using: .utf8) ?? Data()
    }

    // MARK: - Frontmatter splitting

    /// Split a Markdown source into (frontmatter, body). When the source
    /// does not lead with `---` on its own line, the frontmatter is `nil`
    /// and the entire input is the body.
    private static func splitFrontmatter(_ source: String) -> (frontmatter: String?, body: String) {
        let lines = source.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, source)
        }
        var idx = 1
        var fm: [String] = []
        var found = false
        while idx < lines.count {
            let line = lines[idx]
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                found = true
                idx += 1
                break
            }
            fm.append(line)
            idx += 1
        }
        guard found else { return (nil, source) }
        let bodyLines = Array(lines[idx...])
        return (fm.joined(separator: "\n"), bodyLines.joined(separator: "\n"))
    }

    /// Parse a flat YAML-ish frontmatter (`key: value` lines, optional
    /// quoting). Nested structures and lists are not supported here — the
    /// frontmatter is intentionally a tiny subset.
    private static func parseSimpleMapping(_ source: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in source.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colonRange = YAML.findKeyColonRange(in: line) else { continue }
            let key = String(line[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            out[key] = YAML.unquote(value)
        }
        return out
    }

    /// Find the fenced YAML codeblock under `## Layout` and return the
    /// inner text (without fences).
    private static func extractLayoutCodeblock(_ body: String) throws -> String {
        let lines = body.components(separatedBy: "\n")
        // Find `## Layout` header (allow trailing whitespace).
        var i = 0
        var found = false
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "## Layout" || trimmed.hasPrefix("## Layout ") {
                found = true
                i += 1
                break
            }
            i += 1
        }
        guard found else { throw ParseError.missingLayoutSection }
        // Walk forward to a fence opening: ```yaml or ```yml or ``` (assume yaml).
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let fenceClose = "```"
                i += 1
                var inner: [String] = []
                while i < lines.count {
                    let inLine = lines[i]
                    if inLine.trimmingCharacters(in: .whitespaces) == fenceClose {
                        return inner.joined(separator: "\n")
                    }
                    inner.append(inLine)
                    i += 1
                }
                throw ParseError.missingLayoutCodeblock
            }
            // Stop if we hit another `## ` heading before the fence.
            if trimmed.hasPrefix("## ") { break }
            i += 1
        }
        throw ParseError.missingLayoutCodeblock
    }

    // MARK: - Layout tree conversion (YAML → LayoutTreeSpec)

    private struct SurfaceIDGenerator {
        var counter: Int = 1
        mutating func mint() -> String {
            defer { counter += 1 }
            return "s\(counter)"
        }
    }

    private static func buildLayoutTree(
        from node: YAML.Value,
        surfaces: inout [SurfaceSpec],
        idGen: inout SurfaceIDGenerator
    ) throws -> LayoutTreeSpec {
        let mapping = node.asMapping ?? []
        let keys = Set(mapping.map { $0.0 })

        // Split node: has `direction`, `split`, `children`.
        if keys.contains("direction") || keys.contains("children") {
            let direction = (node.lookup("direction")?.asScalar ?? "horizontal").lowercased()
            let orientation: LayoutTreeSpec.SplitSpec.Orientation =
                (direction == "vertical") ? .vertical : .horizontal
            let splitRaw = node.lookup("split")?.asScalar ?? "50/50"
            let dividerPosition = try parseSplitRatio(splitRaw)
            guard let childrenList = node.lookup("children")?.asList, !childrenList.isEmpty else {
                throw ParseError.missingChildren
            }
            guard childrenList.count == 2 else {
                throw ParseError.wrongChildCount(childrenList.count)
            }
            let first = try buildLayoutTree(from: childrenList[0], surfaces: &surfaces, idGen: &idGen)
            let second = try buildLayoutTree(from: childrenList[1], surfaces: &surfaces, idGen: &idGen)
            return .split(LayoutTreeSpec.SplitSpec(
                orientation: orientation,
                dividerPosition: dividerPosition,
                first: first,
                second: second
            ))
        }

        // Multi-tab pane: has `tabs:` list.
        if keys.contains("tabs") {
            let tabs = node.lookup("tabs")?.asList ?? []
            var ids: [String] = []
            for tab in tabs {
                let id = idGen.mint()
                ids.append(id)
                surfaces.append(try buildSurfaceSpec(id: id, from: tab))
            }
            let selectedIndex: Int? = node.lookup("selected")?.asScalar.flatMap { Int($0) }
            return .pane(LayoutTreeSpec.PaneSpec(
                surfaceIds: ids,
                selectedIndex: selectedIndex
            ))
        }

        // Single-tab leaf: has `type:` directly.
        let id = idGen.mint()
        surfaces.append(try buildSurfaceSpec(id: id, from: node))
        return .pane(LayoutTreeSpec.PaneSpec(surfaceIds: [id], selectedIndex: nil))
    }

    private static func buildSurfaceSpec(id: String, from node: YAML.Value) throws -> SurfaceSpec {
        guard let typeRaw = node.lookup("type")?.asScalar, !typeRaw.isEmpty else {
            throw ParseError.missingType
        }
        guard let kind = SurfaceSpecKind(rawValue: typeRaw.lowercased()) else {
            throw ParseError.unsupportedSurfaceKind(typeRaw)
        }
        let title = node.lookup("title")?.asScalar
        let cwd = node.lookup("cwd")?.asScalar
        let url = node.lookup("url")?.asScalar
        let file = node.lookup("file")?.asScalar
        let command = node.lookup("command")?.asScalar
        return SurfaceSpec(
            id: id,
            kind: kind,
            title: nullIfEmpty(title),
            description: nil,
            workingDirectory: nullIfEmpty(cwd),
            command: nullIfEmpty(command),
            url: nullIfEmpty(url),
            filePath: nullIfEmpty(file),
            metadata: nil,
            paneMetadata: nil
        )
    }

    private static func parseSplitRatio(_ raw: String) throws -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let lhs = Double(parts[0]),
                  let rhs = Double(parts[1]),
                  (lhs + rhs) > 0 else {
                throw ParseError.malformedSplitRatio(raw)
            }
            return lhs / (lhs + rhs)
        }
        guard let v = Double(trimmed), v > 0, v < 1 else {
            throw ParseError.malformedSplitRatio(raw)
        }
        return v
    }

    private static func nullIfEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Layout tree emission (LayoutTreeSpec → YAML text)

    /// Emit a layout node at `indent` spaces. When `listItem` is true the
    /// first emitted line begins with `- ` at column `indent - 2` and
    /// subsequent keys live at column `indent`.
    private static func emitLayoutNode(
        _ tree: LayoutTreeSpec,
        surfaces: [SurfaceSpec],
        indent: Int,
        listItem: Bool
    ) -> String {
        switch tree {
        case .split(let split):
            return emitSplitNode(split, surfaces: surfaces, indent: indent, listItem: listItem)
        case .pane(let pane):
            return emitPaneNode(pane, surfaces: surfaces, indent: indent, listItem: listItem)
        }
    }

    private static func emitSplitNode(
        _ split: LayoutTreeSpec.SplitSpec,
        surfaces: [SurfaceSpec],
        indent: Int,
        listItem: Bool
    ) -> String {
        let pad = String(repeating: " ", count: indent)
        let firstLinePad = listItem ? String(repeating: " ", count: indent - 2) + "- " : pad
        var out = ""
        out += "\(firstLinePad)direction: \(split.orientation.rawValue)\n"
        out += "\(pad)split: \(formatSplitRatio(split.dividerPosition))\n"
        out += "\(pad)children:\n"
        out += emitLayoutNode(split.first, surfaces: surfaces, indent: indent + 4, listItem: true)
        out += emitLayoutNode(split.second, surfaces: surfaces, indent: indent + 4, listItem: true)
        return out
    }

    private static func emitPaneNode(
        _ pane: LayoutTreeSpec.PaneSpec,
        surfaces: [SurfaceSpec],
        indent: Int,
        listItem: Bool
    ) -> String {
        let pad = String(repeating: " ", count: indent)
        let firstLinePad = listItem ? String(repeating: " ", count: indent - 2) + "- " : pad
        let resolved = pane.surfaceIds.compactMap { id in surfaces.first(where: { $0.id == id }) }
        if resolved.count == 1 {
            return emitSurfaceFields(resolved[0], firstLinePad: firstLinePad, restPad: pad)
        }
        // Multi-tab pane.
        var out = ""
        out += "\(firstLinePad)tabs:\n"
        for surface in resolved {
            out += emitSurfaceFields(
                surface,
                firstLinePad: pad + "  - ",
                restPad: pad + "    "
            )
        }
        if let sel = pane.selectedIndex, sel != 0 {
            out += "\(pad)selected: \(sel)\n"
        }
        return out
    }

    private static func emitSurfaceFields(
        _ surface: SurfaceSpec,
        firstLinePad: String,
        restPad: String
    ) -> String {
        var out = ""
        out += "\(firstLinePad)type: \(surface.kind.rawValue)\n"
        if let title = surface.title {
            out += "\(restPad)title: \(quoteIfNeeded(title))\n"
        }
        if let cwd = surface.workingDirectory {
            out += "\(restPad)cwd: \(quoteIfNeeded(cwd))\n"
        }
        if let url = surface.url {
            out += "\(restPad)url: \(quoteIfNeeded(url))\n"
        }
        if let file = surface.filePath {
            out += "\(restPad)file: \(quoteIfNeeded(file))\n"
        }
        if let command = surface.command {
            out += "\(restPad)command: \(quoteIfNeeded(command))\n"
        }
        return out
    }

    /// Convert a 0..1 divider position to the `N/M` integer-ratio form when
    /// the result rounds cleanly; fall back to a four-digit decimal when the
    /// integer form would lose precision.
    private static func formatSplitRatio(_ p: Double) -> String {
        let scaled = p * 100.0
        let rounded = (scaled).rounded()
        if abs(scaled - rounded) < 0.001 {
            let first = Int(rounded)
            let second = 100 - first
            return "\(first)/\(second)"
        }
        return String(format: "%.4f", p)
    }

    /// Quote a scalar with `"..."` when it contains characters that would
    /// confuse the parser (colon-space, leading/trailing whitespace,
    /// reserved YAML indicators). Plain ASCII titles, URLs, and POSIX
    /// paths emit unquoted for readability.
    private static func quoteIfNeeded(_ raw: String) -> String {
        if raw.isEmpty { return "\"\"" }
        // Reserved YAML indicators at start: -, ?, :, ,, [, ], {, }, #, &, *, !, |, >, ', ", %, @, `, tab/space.
        let firstChar = raw.first!
        let reservedFirst: Set<Character> = ["-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*", "!", "|", ">", "'", "\"", "%", "@", "`"]
        if reservedFirst.contains(firstChar)
            || firstChar.isWhitespace {
            return quoted(raw)
        }
        // Trailing whitespace, embedded `: ` (colon-space), backslashes, or
        // double-quotes anywhere → quote.
        if raw.last!.isWhitespace
            || raw.contains(": ")
            || raw.hasSuffix(":")
            || raw.contains("\"")
            || raw.contains("\\")
            || raw.contains("\n")
            || raw.contains("\t")
            || raw.contains("\r")
            || raw.contains("#") {
            return quoted(raw)
        }
        return raw
    }

    private static func quoted(_ raw: String) -> String {
        var inner = ""
        for ch in raw {
            switch ch {
            case "\\": inner.append("\\\\")
            case "\"": inner.append("\\\"")
            case "\n": inner.append("\\n")
            case "\t": inner.append("\\t")
            case "\r": inner.append("\\r")
            default: inner.append(ch)
            }
        }
        return "\"\(inner)\""
    }
}

// MARK: - YAML subset

/// Tiny Foundation-only YAML subset used by the markdown blueprint format.
/// Handles indented mappings, dash-prefixed lists with mapping or scalar
/// items, double- and single-quoted scalars, and `# comment` lines.
/// Multi-document streams, tags, anchors, flow-style structures, and block
/// scalars are NOT supported — anything beyond what `Sources/Blueprints/`
/// emits will hit `parseFailed`.
enum YAML {
    indirect enum Value: Equatable {
        case scalar(String)
        case list([Value])
        case mapping([(String, Value)])

        var asScalar: String? {
            if case .scalar(let s) = self { return s }
            return nil
        }
        var asList: [Value]? {
            if case .list(let l) = self { return l }
            return nil
        }
        var asMapping: [(String, Value)]? {
            if case .mapping(let m) = self { return m }
            return nil
        }

        func lookup(_ key: String) -> Value? {
            guard case .mapping(let m) = self else { return nil }
            return m.first(where: { $0.0 == key })?.1
        }

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.scalar(let l), .scalar(let r)): return l == r
            case (.list(let l), .list(let r)): return l == r
            case (.mapping(let l), .mapping(let r)):
                guard l.count == r.count else { return false }
                for (a, b) in zip(l, r) where a.0 != b.0 || a.1 != b.1 {
                    return false
                }
                return true
            default: return false
            }
        }
    }

    struct Line {
        let indent: Int
        let content: String  // trimmed of leading whitespace; trailing whitespace preserved
    }

    static func parse(_ source: String) throws -> Value {
        let lines = tokenize(source)
        var index = 0
        return parseValue(lines: lines, index: &index, indent: 0)
    }

    /// Strip blank and comment-only lines; keep indent + trimmed content.
    private static func tokenize(_ source: String) -> [Line] {
        var result: [Line] = []
        for raw in source.components(separatedBy: "\n") {
            // Determine indent (count leading spaces; tabs are counted as one
            // per Foundation but discouraged — the writer never emits them).
            var indent = 0
            for ch in raw {
                if ch == " " { indent += 1 } else { break }
            }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") { continue }
            result.append(Line(indent: indent, content: trimmed))
        }
        return result
    }

    /// Parse a value at the given indent level. Decides between mapping,
    /// list, and scalar based on the first line at that indent.
    private static func parseValue(lines: [Line], index: inout Int, indent: Int) -> Value {
        guard index < lines.count else { return .scalar("") }
        let line = lines[index]
        if line.indent < indent { return .scalar("") }
        if line.content.hasPrefix("- ") || line.content == "-" {
            return parseList(lines: lines, index: &index, indent: line.indent)
        }
        return parseMapping(lines: lines, index: &index, indent: line.indent)
    }

    /// Parse mapping entries at exactly `indent`.
    private static func parseMapping(lines: [Line], index: inout Int, indent: Int) -> Value {
        var entries: [(String, Value)] = []
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent { break }
            if line.indent > indent { break }
            if line.content.hasPrefix("- ") || line.content == "-" { break }
            guard let colonRange = findKeyColonRange(in: line.content) else { break }
            let key = String(line.content[..<colonRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let after = String(line.content[colonRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            index += 1
            if !after.isEmpty {
                entries.append((key, .scalar(unquote(after))))
            } else if index < lines.count && lines[index].indent > indent {
                let inner = parseValue(lines: lines, index: &index, indent: lines[index].indent)
                entries.append((key, inner))
            } else {
                entries.append((key, .scalar("")))
            }
        }
        return .mapping(entries)
    }

    /// Parse list entries at exactly `indent` (the `-` sits at column `indent`).
    private static func parseList(lines: [Line], index: inout Int, indent: Int) -> Value {
        var items: [Value] = []
        while index < lines.count {
            let line = lines[index]
            if line.indent < indent { break }
            if line.indent > indent { break }
            if !(line.content.hasPrefix("- ") || line.content == "-") { break }
            // The content following "- " starts at column indent + 2.
            let payload = (line.content == "-")
                ? ""
                : String(line.content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            index += 1
            if payload.isEmpty {
                if index < lines.count && lines[index].indent > indent {
                    items.append(parseValue(lines: lines, index: &index, indent: lines[index].indent))
                } else {
                    items.append(.scalar(""))
                }
            } else if let colonRange = findKeyColonRange(in: payload) {
                // `- key: value` (or `- key:`) — start of an inline mapping
                // whose subsequent keys live at column indent + 2.
                let mapIndent = indent + 2
                var entries: [(String, Value)] = []
                let key = String(payload[..<colonRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let after = String(payload[colonRange.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !after.isEmpty {
                    entries.append((key, .scalar(unquote(after))))
                } else if index < lines.count && lines[index].indent > mapIndent {
                    let inner = parseValue(lines: lines, index: &index, indent: lines[index].indent)
                    entries.append((key, inner))
                } else {
                    entries.append((key, .scalar("")))
                }
                while index < lines.count {
                    let next = lines[index]
                    if next.indent != mapIndent { break }
                    if next.content.hasPrefix("- ") || next.content == "-" { break }
                    guard let cr = findKeyColonRange(in: next.content) else { break }
                    let k = String(next.content[..<cr.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                    let v = String(next.content[cr.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    index += 1
                    if !v.isEmpty {
                        entries.append((k, .scalar(unquote(v))))
                    } else if index < lines.count && lines[index].indent > mapIndent {
                        let inner = parseValue(lines: lines, index: &index, indent: lines[index].indent)
                        entries.append((k, inner))
                    } else {
                        entries.append((k, .scalar("")))
                    }
                }
                items.append(.mapping(entries))
            } else {
                items.append(.scalar(unquote(payload)))
            }
        }
        return .list(items)
    }

    /// Locate the `:` that separates a YAML key from its value, ignoring
    /// `:` characters inside quoted strings and `:` characters not followed
    /// by whitespace or end-of-string (e.g. `http://example`).
    static func findKeyColonRange(in s: String) -> Range<String.Index>? {
        var i = s.startIndex
        var inDouble = false
        var inSingle = false
        while i < s.endIndex {
            let c = s[i]
            if inDouble {
                if c == "\\" {
                    let next = s.index(after: i)
                    if next < s.endIndex { i = next }
                } else if c == "\"" {
                    inDouble = false
                }
            } else if inSingle {
                if c == "'" { inSingle = false }
            } else if c == "\"" {
                inDouble = true
            } else if c == "'" {
                inSingle = true
            } else if c == ":" {
                let next = s.index(after: i)
                if next == s.endIndex { return i..<next }
                let nc = s[next]
                if nc == " " || nc == "\t" {
                    return i..<next
                }
            }
            i = s.index(after: i)
        }
        return nil
    }

    /// Unquote a scalar: strip surrounding `"..."` (with `\"`/`\\`/`\n`/
    /// `\t`/`\r` escapes) or `'...'` (with `''` → `'`). Bare scalars are
    /// returned as-is (already trimmed of surrounding whitespace).
    static func unquote(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if first == "\"" && last == "\"" {
            let inner = String(s.dropFirst().dropLast())
            var out = ""
            out.reserveCapacity(inner.count)
            var i = inner.startIndex
            while i < inner.endIndex {
                let c = inner[i]
                if c == "\\" {
                    let next = inner.index(after: i)
                    if next < inner.endIndex {
                        switch inner[next] {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "r": out.append("\r")
                        case "\\": out.append("\\")
                        case "\"": out.append("\"")
                        default: out.append(inner[next])
                        }
                        i = inner.index(after: next)
                        continue
                    }
                }
                out.append(c)
                i = inner.index(after: i)
            }
            return out
        }
        if first == "'" && last == "'" {
            let inner = String(s.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        return s
    }
}
