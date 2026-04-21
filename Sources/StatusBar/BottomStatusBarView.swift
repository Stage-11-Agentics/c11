import SwiftUI

/// Persistent window-scoped footer chrome. A multi-slot container (leading,
/// center, trailing) whose only job is to lay out tenant views. Tenants
/// themselves own their own observation graphs — the container never reads
/// app state, so mounting it does not subscribe the parent view to any
/// observable.
struct BottomStatusBarView<Leading: View, Center: View, Trailing: View>: View {
    // `static let` is disallowed on generic types; the `static var { 32 }`
    // form returns the literal every call but inlines to a constant.
    private static var barHeight: CGFloat { 32 }

    private let leading: Leading
    private let center: Center
    private let trailing: Trailing

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder center: () -> Center = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.leading = leading()
        self.center = center()
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.6)
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 8)
                center
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: Self.barHeight)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("window.bottomStatusBar")
    }
}
