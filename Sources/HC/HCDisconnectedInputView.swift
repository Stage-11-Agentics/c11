import SwiftUI

/// What the input bar shows, held apart from SwiftUI so it is testable without a
/// window (C11H-124). The bar has one fixed height in every state, so the
/// terminal under it never moves when a retry fails or a reason appears.
struct HCInputBarModel: Equatable {
    /// A paused panel takes no input until Retry; a refusal dropped one input.
    enum Role: Equatable { case paused, refused }

    static let height: CGFloat = 64

    let role: Role
    let message: String
    /// The retry line: progress, a refused retry's reason, or empty.
    let status: String
    let showsRetry: Bool
    let retryEnabled: Bool

    @MainActor
    init?(_ policy: HCDisconnectedInput) {
        guard let notice = policy.notice else { return nil }
        role = policy.isFaulted ? .paused : .refused
        message = notice.message
        showsRetry = policy.isFaulted
        retryEnabled = policy.isFaulted && !policy.isRetrying && !policy.isAwaitingRetry
        if !policy.isFaulted {
            status = ""
        } else if policy.isRetrying || policy.isAwaitingRetry {
            status = String(localized: "hc.input.retrying", defaultValue: "Retrying input…")
        } else if let failure = policy.retryFailure {
            status = failure.failureMessage
        } else {
            status = ""
        }
    }

    /// A strong warning fill with dark text, legible in light and dark mode.
    var fill: Color {
        switch role {
        case .paused: return Color(nsColor: .systemOrange)
        case .refused: return Color(nsColor: .systemYellow)
        }
    }
}

/// Mounted above GhosttyTerminalView in its VStack. A SwiftUI overlay can sit
/// behind the native terminal portal, hiding an otherwise correct refusal.
struct HCDisconnectedInputView: View {
    @ObservedObject var policy: HCDisconnectedInput

    var body: some View {
        if let model = HCInputBarModel(policy) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.message)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(model.message)
                        .accessibilityIdentifier("hc.input.notice")
                    Text(model.status)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(model.status)
                        .accessibilityIdentifier("hc.input.status")
                }
                Spacer(minLength: 0)
                if model.showsRetry {
                    Button(HCInputNotice.retryTitle) {
                        Task { _ = await policy.retryInputWaiting(seconds: 3) }
                    }
                    .disabled(!model.retryEnabled)
                    .accessibilityIdentifier("hc.input.retry")
                } else {
                    Button(String(localized: "hc.input.dismiss", defaultValue: "Dismiss")) {
                        policy.dismissRefusal()
                    }
                    .accessibilityIdentifier("hc.input.dismiss")
                }
            }
            .foregroundStyle(Color.black)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: HCInputBarModel.height, maxHeight: HCInputBarModel.height,
                   alignment: .leading)
            .background(model.fill)
            // Dark text on a bright fill in both appearances; the button keeps its
            // light rendering on that fill.
            .environment(\.colorScheme, .light)
            .accessibilityElement(children: .contain)
        }
    }
}
