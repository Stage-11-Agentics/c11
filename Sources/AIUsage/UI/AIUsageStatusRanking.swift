import Foundation

enum AIUsageStatusRanking {
    private static let severities: [String: Int] = [
        "none": 0,
        "maintenance": 1,
        "minor": 2,
        "major": 3,
        "critical": 4,
    ]

    static func severity(for impact: String) -> Int {
        severities[impact.lowercased()] ?? 0
    }

    static func worstImpactSeverity(in incidents: [AIUsageIncident]) -> Int {
        guard !incidents.isEmpty else { return 0 }
        let nonMaintenance = incidents.filter { severity(for: $0.impact) > 1 }
        if let max = nonMaintenance.map({ severity(for: $0.impact) }).max() {
            return max
        }
        return incidents.map { severity(for: $0.impact) }.max() ?? 0
    }

    static func worstIncident(in incidents: [AIUsageIncident]) -> AIUsageIncident? {
        let target = worstImpactSeverity(in: incidents)
        return incidents.first(where: { severity(for: $0.impact) == target })
    }

    static func statusText(for incidents: [AIUsageIncident]) -> String {
        guard !incidents.isEmpty else {
            return String(
                localized: "aiusage.status.allOk",
                defaultValue: "All systems operational"
            )
        }
        switch worstImpactSeverity(in: incidents) {
        case 4:
            return String(localized: "aiusage.status.critical", defaultValue: "Critical incident")
        case 3:
            return String(localized: "aiusage.status.major", defaultValue: "Major incident")
        case 2:
            return String(localized: "aiusage.status.minor", defaultValue: "Minor incident")
        case 1:
            return String(localized: "aiusage.status.maintenance", defaultValue: "Maintenance")
        default:
            return String(localized: "aiusage.status.allOk", defaultValue: "All systems operational")
        }
    }
}
