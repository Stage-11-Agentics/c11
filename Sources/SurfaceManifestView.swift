import AppKit
import SwiftUI

enum SurfaceManifestKind: String {
    case terminal
    case browser
    case markdown

    var localizedLabel: String {
        switch self {
        case .terminal:
            return String(localized: "surfaceManifest.kind.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "surfaceManifest.kind.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "surfaceManifest.kind.markdown", defaultValue: "Markdown")
        }
    }
}

/// Friendly handle refs (and a few human-relevant fields) for a surface,
/// resolved by `TerminalController.surfaceHandleInfo(workspaceId:surfaceId:)`.
/// This is the data the operator opens Surface Details to find — chiefly the
/// `surface:N` / `tab:N` numbers, which are otherwise only reachable via the
/// CLI.
struct SurfaceHandleInfo {
    let surfaceRef: String
    let tabRef: String
    let paneRef: String?
    let workspaceRef: String
    let windowRef: String?
    let terminalType: String?
    let tty: String?
    let workingDirectory: String?
    let url: String?
    let filePath: String?
}

struct SurfaceManifestSnapshot {
    let metadata: [String: Any]
    let sources: [String: [String: Any]]
    let capturedAt: Date

    static func capture(workspaceId: UUID, surfaceId: UUID) -> SurfaceManifestSnapshot {
        let result = SurfaceMetadataStore.shared.getMetadata(workspaceId: workspaceId, surfaceId: surfaceId)
        return SurfaceManifestSnapshot(metadata: result.metadata, sources: result.sources, capturedAt: Date())
    }

    var prettyJSON: String {
        guard !metadata.isEmpty else { return "" }
        let opts: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: opts),
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }
}

struct SurfaceManifestView: View {
    let workspaceId: UUID
    let surfaceId: UUID
    let kind: SurfaceManifestKind
    let handle: SurfaceHandleInfo

    @State private var snapshot: SurfaceManifestSnapshot
    // Which field's Copy button most recently fired — flips that one button to
    // "Copied" briefly. Only one row shows the confirmation at a time.
    @State private var copiedField: String?
    @State private var copyResetWorkItem: DispatchWorkItem?

    init(workspaceId: UUID, surfaceId: UUID, kind: SurfaceManifestKind, handle: SurfaceHandleInfo) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.kind = kind
        self.handle = handle
        _snapshot = State(initialValue: SurfaceManifestSnapshot.capture(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailsSection
                    jsonSection
                    sourcesDisclosure
                    advancedDisclosure
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 520, minHeight: 400)
    }

    // The handle refs are the headline — always-visible, each copyable, with
    // surface:N rendered extra-large since it's the number the operator most
    // often wants.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            refRow(
                label: String(localized: "surfaceManifest.ref.surface", defaultValue: "Surface"),
                value: handle.surfaceRef,
                field: "surface",
                size: .extraLarge
            )
            refRow(
                label: String(localized: "surfaceManifest.ref.tab", defaultValue: "Tab"),
                value: handle.tabRef,
                field: "tab",
                size: .prominent
            )
            if let pane = handle.paneRef {
                refRow(
                    label: String(localized: "surfaceManifest.ref.pane", defaultValue: "Pane"),
                    value: pane,
                    field: "pane",
                    size: .normal
                )
            }
            refRow(
                label: String(localized: "surfaceManifest.ref.workspace", defaultValue: "Workspace"),
                value: handle.workspaceRef,
                field: "workspace",
                size: .normal
            )
            if let window = handle.windowRef {
                refRow(
                    label: String(localized: "surfaceManifest.ref.window", defaultValue: "Window"),
                    value: window,
                    field: "window",
                    size: .normal
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum RefSize {
        case normal, prominent, extraLarge

        var fontSize: CGFloat {
            switch self {
            case .normal: return 11
            case .prominent: return 13
            case .extraLarge: return 22
            }
        }

        var weight: Font.Weight {
            switch self {
            case .normal: return .regular
            case .prominent: return .semibold
            case .extraLarge: return .bold
            }
        }
    }

    private func refRow(label: String, value: String, field: String, size: RefSize) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: size.fontSize, weight: size.weight, design: .monospaced))
                .textSelection(.enabled)
            Spacer(minLength: 8)
            copyButton(field: field, value: value)
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(
                label: String(localized: "surfaceManifest.detail.type", defaultValue: "Type"),
                value: kind.localizedLabel
            )
            if let terminalType = handle.terminalType, !terminalType.isEmpty {
                row(
                    label: String(localized: "surfaceManifest.detail.terminalType", defaultValue: "Terminal type"),
                    value: terminalType
                )
            }
            if let tty = handle.tty, !tty.isEmpty {
                row(
                    label: String(localized: "surfaceManifest.detail.tty", defaultValue: "TTY"),
                    value: tty
                )
            }
            if let cwd = handle.workingDirectory, !cwd.isEmpty {
                row(
                    label: String(localized: "surfaceManifest.detail.directory", defaultValue: "Directory"),
                    value: cwd
                )
            }
            if let url = handle.url, !url.isEmpty {
                row(
                    label: String(localized: "surfaceManifest.detail.url", defaultValue: "URL"),
                    value: url
                )
            }
            if let file = handle.filePath, !file.isEmpty {
                row(
                    label: String(localized: "surfaceManifest.detail.file", defaultValue: "File"),
                    value: file
                )
            }
            row(
                label: String(localized: "surfaceManifest.header.capturedAt", defaultValue: "Captured"),
                value: Self.timestampFormatter.string(from: snapshot.capturedAt)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func copyButton(field: String, value: String) -> some View {
        Button {
            copyValue(value, field: field)
        } label: {
            Text(copiedField == field
                 ? String(localized: "surfaceManifest.copiedButton", defaultValue: "Copied")
                 : String(localized: "surfaceManifest.copyButton.short", defaultValue: "Copy"))
                .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.borderless)
        .foregroundColor(copiedField == field ? .secondary : .accentColor)
    }

    private var jsonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "surfaceManifest.json.title", defaultValue: "Metadata (JSON)"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !snapshot.metadata.isEmpty {
                    copyButton(field: "json", value: snapshot.prettyJSON)
                }
            }
            bodyJSON
        }
    }

    @ViewBuilder
    private var bodyJSON: some View {
        if snapshot.metadata.isEmpty {
            Text(String(localized: "surfaceManifest.empty", defaultValue: "No metadata set on this surface."))
                .foregroundColor(.secondary)
                .font(.system(size: 12))
        } else {
            Text(snapshot.prettyJSON)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // Identifiers are advanced-only — collapsed by default, with a note
    // steering toward the surface integer (surface:N) rather than the UUID.
    private var advancedDisclosure: some View {
        DisclosureGroup(String(localized: "surfaceManifest.advanced.disclosure", defaultValue: "Advanced — identifiers")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(
                    localized: "surfaceManifest.advanced.note",
                    defaultValue: "Tip: copy the surface integer above (e.g. surface:75), not the UUID below."
                ))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                row(
                    label: String(localized: "surfaceManifest.ids.surfaceUUID", defaultValue: "Surface UUID"),
                    value: surfaceId.uuidString
                )
                row(
                    label: String(localized: "surfaceManifest.ids.workspaceUUID", defaultValue: "Workspace UUID"),
                    value: workspaceId.uuidString
                )
            }
            .padding(.top, 6)
        }
        .font(.system(size: 12))
    }

    private var sourcesDisclosure: some View {
        DisclosureGroup(String(localized: "surfaceManifest.sources.disclosure", defaultValue: "Show sources")) {
            sourcesTable
                .padding(.top, 6)
        }
        .font(.system(size: 12))
    }

    @ViewBuilder
    private var sourcesTable: some View {
        let rows = sourceRows
        if rows.isEmpty {
            Text(String(localized: "surfaceManifest.sources.empty", defaultValue: "No source records."))
                .foregroundColor(.secondary)
                .font(.system(size: 11))
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    Text(String(localized: "surfaceManifest.sources.column.key", defaultValue: "Key"))
                        .frame(width: 140, alignment: .leading)
                    Text(String(localized: "surfaceManifest.sources.column.source", defaultValue: "Source"))
                        .frame(width: 90, alignment: .leading)
                    Text(String(localized: "surfaceManifest.sources.column.timestamp", defaultValue: "Set at"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                Divider()
                ForEach(rows, id: \.key) { row in
                    HStack(spacing: 12) {
                        Text(row.key)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 140, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.source)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 90, alignment: .leading)
                        Text(row.timestamp)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private struct SourceRow {
        let key: String
        let source: String
        let timestamp: String
    }

    private var sourceRows: [SourceRow] {
        snapshot.sources.keys.sorted().map { key in
            let entry = snapshot.sources[key] ?? [:]
            let source = (entry["source"] as? String) ?? "—"
            let ts: String
            if let epoch = entry["ts"] as? Double {
                ts = Self.timestampFormatter.string(from: Date(timeIntervalSince1970: epoch))
            } else {
                ts = "—"
            }
            return SourceRow(key: key, source: source, timestamp: ts)
        }
    }

    private var footer: some View {
        HStack {
            Button(action: refresh) {
                Text(String(localized: "surfaceManifest.refreshButton", defaultValue: "Refresh"))
            }
            Spacer()
        }
    }

    private func copyValue(_ value: String, field: String) {
        guard !value.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copiedField = field
        copyResetWorkItem?.cancel()
        let work = DispatchWorkItem { copiedField = nil }
        copyResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func refresh() {
        snapshot = SurfaceManifestSnapshot.capture(workspaceId: workspaceId, surfaceId: surfaceId)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
