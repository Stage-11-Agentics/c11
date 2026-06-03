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

    @State private var snapshot: SurfaceManifestSnapshot
    @State private var copiedFlash: Bool = false
    @State private var copyResetWorkItem: DispatchWorkItem?

    init(workspaceId: UUID, surfaceId: UUID, kind: SurfaceManifestKind) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.kind = kind
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
                    bodyJSON
                    sourcesDisclosure
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(
                label: String(localized: "surfaceManifest.header.workspace", defaultValue: "Workspace"),
                value: workspaceId.uuidString
            )
            row(
                label: String(localized: "surfaceManifest.header.surface", defaultValue: "Surface"),
                value: surfaceId.uuidString
            )
            row(
                label: String(localized: "surfaceManifest.header.kind", defaultValue: "Kind"),
                value: kind.localizedLabel
            )
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
            Button(action: copyJSON) {
                Text(copiedFlash
                     ? String(localized: "surfaceManifest.copiedButton", defaultValue: "Copied")
                     : String(localized: "surfaceManifest.copyButton", defaultValue: "Copy JSON"))
            }
            .disabled(snapshot.metadata.isEmpty)
            Button(action: refresh) {
                Text(String(localized: "surfaceManifest.refreshButton", defaultValue: "Refresh"))
            }
            Spacer()
        }
    }

    private func copyJSON() {
        let payload = snapshot.prettyJSON
        guard !payload.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        copiedFlash = true
        copyResetWorkItem?.cancel()
        let work = DispatchWorkItem { copiedFlash = false }
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
