import XCTest
import AppKit

#if canImport(c11_DEV)
@testable import c11_DEV
#elseif canImport(c11)
@testable import c11
#endif

final class SidebarSnapshotTests: XCTestCase {
    private struct SidebarFixture: Codable {
        enum IndicatorStyle: String, Codable {
            case solidFill
            case leftRail
        }

        enum SelectionState: String, Codable {
            case active
            case inactive
            case multiSelected
        }

        let colorScheme: String
        let indicatorStyle: IndicatorStyle
        let selectionState: SelectionState
        let hasCustomColor: Bool
        let expectedBackgroundHex: String?
        let expectedRailHex: String?
    }

    func testSidebarM1bSnapshotsMatchFixtures() throws {
        let fixtures = try loadFixtures(directoryName: "sidebar-m1b")
        XCTAssertEqual(fixtures.count, 24)

        let snapshot = ResolvedThemeSnapshot(theme: .fallbackStage11)

        for (url, fixture) in fixtures {
            let actual = resolveSidebarColors(snapshot: snapshot, fixture: fixture)
            XCTAssertEqual(actual.backgroundHex, fixture.expectedBackgroundHex, "Background mismatch for \(url.lastPathComponent)")
            XCTAssertEqual(actual.railHex, fixture.expectedRailHex, "Rail mismatch for \(url.lastPathComponent)")
        }
    }

    private func resolveSidebarColors(
        snapshot: ResolvedThemeSnapshot,
        fixture: SidebarFixture
    ) -> (backgroundHex: String?, railHex: String?) {
        let context = ThemeContext(
            workspaceColor: fixture.hasCustomColor ? "#FFFFFF" : nil,
            colorScheme: fixture.colorScheme == "dark" ? .dark : .light,
            forceBright: fixture.indicatorStyle == .leftRail,
            ghosttyBackgroundGeneration: 0
        )

        let isActive = fixture.selectionState == .active
        let isMultiSelected = fixture.selectionState == .multiSelected

        switch fixture.indicatorStyle {
        case .leftRail:
            guard isActive else {
                return (nil, nil)
            }

            let role: ThemeRole = fixture.hasCustomColor ? .sidebar_activeTabRail : .sidebar_activeTabRailFallback
            guard let base = snapshot.resolveColor(role: role, context: context) else {
                return (nil, nil)
            }
            let opacity = snapshot.resolveNumber(role: .sidebar_activeTabRailOpacity, context: context) ?? 0.95
            return (nil, base.withAlphaComponent(CGFloat(opacity)).hexString(includeAlpha: true))

        case .solidFill:
            if isActive {
                let role: ThemeRole = fixture.hasCustomColor ? .sidebar_activeTabFill : .sidebar_activeTabFillFallback
                let color = snapshot.resolveColor(role: role, context: context)
                return (color?.hexString(includeAlpha: true), nil)
            }

            guard fixture.hasCustomColor,
                  let base = snapshot.resolveColor(role: .sidebar_activeTabFill, context: context)
            else {
                return (nil, nil)
            }

            let opacityRole: ThemeRole = isMultiSelected
                ? .sidebar_inactiveTabMultiSelectOpacity
                : .sidebar_inactiveTabCustomOpacity
            let opacity = snapshot.resolveNumber(role: opacityRole, context: context)
                ?? (isMultiSelected ? 0.35 : 0.70)
            return (base.withAlphaComponent(CGFloat(opacity)).hexString(includeAlpha: true), nil)
        }
    }

    private func loadFixtures(directoryName: String) throws -> [(URL, SidebarFixture)] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Snapshots")
            .appendingPathComponent(directoryName)

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        return try urls.map { url in
            let data = try Data(contentsOf: url)
            return (url, try decoder.decode(SidebarFixture.self, from: data))
        }
    }
}
