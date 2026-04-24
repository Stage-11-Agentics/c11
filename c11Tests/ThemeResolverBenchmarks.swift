import AppKit
import XCTest
@testable import c11

final class ThemeResolverBenchmarks: XCTestCase {
    func testResolverP95PerformanceBudget() throws {
        let snapshot = ResolvedThemeSnapshot(theme: .fallbackStage11)
        let contexts = benchmarkContexts()
        let roles: [ThemeRole] = [
            .sidebar_activeTabFill,
            .sidebar_activeTabRail,
            .sidebar_badgeFill,
            .titleBar_background,
            .titleBar_borderBottom,
            .dividers_color,
            .windowFrame_color,
            .tabBar_activeIndicator,
            .browserChrome_omnibarFill,
            .markdownChrome_background,
        ]

        let iterations = 10_000
        let trials = 20

        // Warm-up so the trial loop reflects steady-state memoized lookup cost.
        for context in contexts {
            for role in roles {
                _ = snapshot.resolveColor(role: role, context: context)
            }
        }

        var totalsMS: [Double] = []
        totalsMS.reserveCapacity(trials)

        for _ in 0..<trials {
            let start = CFAbsoluteTimeGetCurrent()
            for index in 0..<iterations {
                let role = roles[index % roles.count]
                let context = contexts[index % contexts.count]
                _ = snapshot.resolveColor(role: role, context: context)
            }
            let elapsedMS = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            totalsMS.append(elapsedMS)
        }

        let p95MS = percentile(totalsMS, 0.95)
        let p95PerLookupUS = (p95MS * 1000.0) / Double(iterations)

        XCTAssertLessThan(
            p95MS,
            10.0,
            "expected p95 < 10ms for 10,000 lookups; observed \(p95MS)ms"
        )
        XCTAssertLessThan(
            p95PerLookupUS,
            1.0,
            "expected amortized p95 lookup < 1µs; observed \(p95PerLookupUS)µs"
        )
    }

    private func benchmarkContexts() -> [ThemeContext] {
        let colors = ["#C0392B", "#1565C0", "#196F3D"]
        let schemes: [ThemeContext.ColorScheme] = [.light, .dark]
        var contexts: [ThemeContext] = []

        for color in colors {
            for scheme in schemes {
                contexts.append(
                    ThemeContext(
                        workspaceColor: color,
                        colorScheme: scheme,
                        forceBright: false,
                        ghosttyBackgroundGeneration: 0,
                        isWindowFocused: true,
                        workspaceState: nil
                    )
                )
            }
        }

        return contexts
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        precondition(!values.isEmpty)
        let sorted = values.sorted()
        let rank = Int((Double(sorted.count - 1) * p).rounded(.up))
        return sorted[min(rank, sorted.count - 1)]
    }
}
