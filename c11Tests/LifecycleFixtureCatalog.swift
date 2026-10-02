import Foundation
import XCTest

/// One sanitized lifecycle edge from a C11-271 capture.
struct LifecycleReplayStep: Equatable {
    let seq: Int
    let source: String
    let name: String
    let toolName: String?
}

/// A corpus case plus the two attention readings a replay must keep apart:
/// what production c11 did, and what the journal should project.
struct LifecycleFixtureCase: Equatable {
    let id: String
    let origin: String
    let provider: String
    let incident: String
    let steps: [LifecycleReplayStep]
    let currentMark: String
    let intendedMark: String
    let currentNotes: String
    let intendedNotes: String
}

enum LifecycleFixtureCatalog {
    private static let allowedOrigins: Set<String> = ["observed", "derived-reorder", "gap"]

    static func directory(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/lifecycle", isDirectory: true)
    }

    static func load(from directory: URL) throws -> [LifecycleFixtureCase] {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        try assertPublic(manifestText, label: "manifest.json")
        let manifest = try jsonObject(manifestText, label: "manifest.json")
        guard let cases = manifest["cases"] as? [[String: Any]], !cases.isEmpty else {
            throw CatalogError.malformed("manifest.json has no cases")
        }
        return try cases.map { entry in
            try loadCase(entry, directory: directory)
        }
    }

    private static func loadCase(_ entry: [String: Any], directory: URL) throws -> LifecycleFixtureCase {
        let id = try string(entry, "id")
        let origin = try string(entry, "origin")
        guard allowedOrigins.contains(origin) else {
            throw CatalogError.malformed("\(id) origin \(origin)")
        }
        let captureName = try string(entry, "capture_file")
        let normalizedName = try string(entry, "normalized_file")
        let captureURL = directory.appendingPathComponent(captureName)
        let normalizedURL = directory.appendingPathComponent(normalizedName)
        let captureText = try String(contentsOf: captureURL, encoding: .utf8)
        let normalizedText = try String(contentsOf: normalizedURL, encoding: .utf8)
        try assertPublic(captureText, label: captureName)
        try assertPublic(normalizedText, label: normalizedName)
        let capture = try jsonObject(captureText, label: captureName)
        let normalized = try jsonObject(normalizedText, label: normalizedName)
        guard capture["id"] as? String == id, normalized["id"] as? String == id else {
            throw CatalogError.malformed("\(id) file id does not match the manifest")
        }
        guard normalized["origin"] as? String == origin else {
            throw CatalogError.malformed("\(id) normalized origin does not match the manifest")
        }
        let events = normalized["events"] as? [[String: Any]] ?? []
        let steps = try events.enumerated().map { index, event -> LifecycleReplayStep in
            let seq = try int(event, "seq", label: id)
            if seq != index + 1 {
                throw CatalogError.malformed("\(id) seq \(seq) is not \(index + 1)")
            }
            return LifecycleReplayStep(
                seq: seq,
                source: try string(event, "source"),
                name: (event["name"] as? String) ?? "",
                toolName: event["tool_name"] as? String
            )
        }
        let current = try object(normalized, "current", label: id)
        let intended = try object(normalized, "intended", label: id)
        return LifecycleFixtureCase(
            id: id,
            origin: origin,
            provider: try string(entry, "provider"),
            incident: try string(entry, "incident"),
            steps: steps,
            currentMark: try string(current, "mark"),
            intendedMark: try string(intended, "mark"),
            currentNotes: try string(current, "notes"),
            intendedNotes: try string(intended, "notes")
        )
    }

    private static func jsonObject(_ text: String, label: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.malformed("\(label) is not a JSON object")
        }
        return object
    }

    private static func object(_ source: [String: Any], _ key: String, label: String) throws -> [String: Any] {
        guard let value = source[key] as? [String: Any] else {
            throw CatalogError.malformed("\(label) missing \(key)")
        }
        return value
    }

    private static func string(_ source: [String: Any], _ key: String) throws -> String {
        guard let value = source[key] as? String, !value.isEmpty else {
            throw CatalogError.malformed("missing \(key)")
        }
        return value
    }

    private static func int(_ source: [String: Any], _ key: String, label: String) throws -> Int {
        if let value = source[key] as? Int { return value }
        if let value = source[key] as? NSNumber { return value.intValue }
        throw CatalogError.malformed("\(label) missing \(key)")
    }

    private static func assertPublic(_ text: String, label: String) throws {
        if text.contains("/Users/") || text.contains("/private/var/") || text.contains("toolu_") {
            throw CatalogError.privateToken(label)
        }
        if text.range(of: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#, options: .regularExpression) != nil {
            throw CatalogError.privateToken(label)
        }
        if text.range(
            of: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
            options: .regularExpression
        ) != nil {
            throw CatalogError.privateToken(label)
        }
    }

    enum CatalogError: Error, Equatable {
        case malformed(String)
        case privateToken(String)
    }
}

final class LifecycleFixtureCatalogTests: XCTestCase {
    func testCorpusReplaysCurrentAndIntendedMarks() throws {
        let cases = try LifecycleFixtureCatalog.load(from: LifecycleFixtureCatalog.directory())
        let ids = Set(cases.map(\.id))
        XCTAssertEqual(cases.count, ids.count, "case ids must be unique")
        for item in cases {
            XCTAssertFalse(item.currentMark.isEmpty)
            XCTAssertFalse(item.intendedMark.isEmpty)
            XCTAssertFalse(item.currentNotes.isEmpty)
            XCTAssertFalse(item.intendedNotes.isEmpty)
            if item.origin == "derived-reorder" {
                XCTAssertFalse(item.steps.isEmpty, "\(item.id) derived reorder has no steps")
                let names = item.steps.map(\.name)
                guard let stop = names.firstIndex(of: "Stop"), let pre = names.firstIndex(of: "PreToolUse") else {
                    XCTFail("\(item.id) is missing Stop or PreToolUse")
                    continue
                }
                XCTAssertLessThan(stop, pre, "\(item.id) keeps PreToolUse after Stop")
            }
            if item.origin == "gap" {
                XCTAssertTrue(item.steps.isEmpty, "\(item.id) gap case invented events")
            }
        }
    }
}
