import Foundation

enum ProviderUsageResetLabel: Equatable {
    case awaitingRefresh
    case sessionNotStarted
    case weekResetUnknown
    case resetsAt(Date)
}

func providerUsageResetLabel(window: AIUsageWindow,
                             isSession: Bool,
                             now: Date) -> ProviderUsageResetLabel {
    if let resets = window.resetsAt, resets > now {
        return .resetsAt(resets)
    }

    if isSession {
        if window.utilization == 0 && window.resetsAt == nil {
            return .sessionNotStarted
        }
    } else {
        if window.utilization == 0 && window.resetsAt == nil {
            return .weekResetUnknown
        }
    }
    return .awaitingRefresh
}
