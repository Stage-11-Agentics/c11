import AppKit
import SwiftUI

/// Shared SwiftUI rendering for a pane-scoped interaction. Used by every mount layer —
/// AppKit-hosted for terminals and WebView-backed browsers (via NSHostingView), and
/// as a raw SwiftUI ZStack overlay for markdown and empty-browser panels.
///
/// Scrim covers only the panel's bounds. The card grabs first responder via an internal
/// `@FocusState` anchor so Return/Escape/Tab/Cmd+D route through `onKeyPress`.
struct PaneInteractionCardView: View {
    let panelId: UUID
    let interaction: PaneInteraction
    @ObservedObject var runtime: PaneInteractionRuntime

    var body: some View {
        ZStack {
            // Scrim — click does NOT dismiss (plan §2: prevents accidental cancel).
            Color.black.opacity(0.55)
                .contentShape(Rectangle())
                .allowsHitTesting(true)
                .onTapGesture { /* intentional no-op */ }
                .accessibilityHidden(true)

            card
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    @ViewBuilder
    private var card: some View {
        switch interaction {
        case .confirm(let content):
            ConfirmCard(panelId: panelId, content: content, runtime: runtime)
        case .textInput(let content):
            TextInputCard(panelId: panelId, content: content, runtime: runtime)
        }
    }
}

// MARK: - Confirm variant

private struct ConfirmCard: View {
    let panelId: UUID
    let content: ConfirmContent
    @ObservedObject var runtime: PaneInteractionRuntime

    private enum Field: Hashable { case cancel, confirm }
    @FocusState private var focused: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(content.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)

            if let message = content.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.85))
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button(action: cancel) {
                    Text(content.cancelLabel)
                        .foregroundColor(BrandColors.whiteSwiftUI)
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .focused($focused, equals: .cancel)
                .focusRing(isActive: focused == .cancel)

                Button(role: content.role == .destructive ? .destructive : nil,
                       action: confirm) {
                    DefaultActionLabel(text: content.confirmLabel)
                }
                .buttonStyle(.borderedProminent)
                // Destructive red softened to 85% — the brand aesthetic is
                // monochrome + gold (no second accent), so the red is already
                // a compromise. Full-saturation red on a dark card was reading
                // too aggressive; at 0.85 the destructive signal survives
                // without shouting.
                .tint(content.role == .destructive
                      ? Color.red.opacity(0.85)
                      : BrandColors.goldSwiftUI)
                .keyboardShortcut(.defaultAction)
                .focused($focused, equals: .confirm)
                .focusRing(isActive: focused == .confirm)
            }
        }
        .padding(24)
        .frame(minWidth: 260, maxWidth: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BrandColors.surfaceSwiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(BrandColors.ruleSwiftUI, lineWidth: 1)
                )
        )
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("PaneInteraction.confirm.card")
        .onAppear { focused = .confirm }
        .onKeyPress(.escape) {
            cancel()
            return .handled
        }
    }

    private func confirm() {
        runtime.resolveConfirm(
            panelId: panelId,
            result: .confirmed,
            ifInteractionId: content.id
        )
    }
    private func cancel() {
        runtime.resolveConfirm(
            panelId: panelId,
            result: .cancelled,
            ifInteractionId: content.id
        )
    }
}

// MARK: - TextInput variant

private struct TextInputCard: View {
    let panelId: UUID
    let content: TextInputContent
    @ObservedObject var runtime: PaneInteractionRuntime

    @State private var value: String = ""
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(content.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(BrandColors.whiteSwiftUI)

            if let message = content.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(BrandColors.whiteSwiftUI.opacity(0.85))
            }

            IMESafeTextField(
                text: $value,
                placeholder: content.placeholder,
                onSubmit: submit,
                onCancel: cancel
            )
            .frame(minHeight: 22)

            if let errorText, !errorText.isEmpty {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red)
                    .accessibilityIdentifier("PaneInteraction.textInput.error")
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button(action: cancel) {
                    Text(content.cancelLabel)
                        .foregroundColor(BrandColors.whiteSwiftUI)
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(action: submit) {
                    DefaultActionLabel(text: content.confirmLabel)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColors.goldSwiftUI)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 320, maxWidth: 480, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BrandColors.surfaceSwiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(BrandColors.ruleSwiftUI, lineWidth: 1)
                )
        )
        .environment(\.colorScheme, .dark)
        .accessibilityIdentifier("PaneInteraction.textInput.card")
        .onAppear {
            value = content.defaultValue
            // Seed the bridge so Cmd+D immediately after present() submits the
            // default value instead of nil — matches the original contract
            // when the user hasn't started typing yet.
            runtime.updatePendingTextInputValue(interactionId: content.id, value: content.defaultValue)
        }
        .onChange(of: value) { _, newValue in
            // Bridge live text back to the runtime so Cmd+D accept submits
            // what the user typed, not the default value.
            runtime.updatePendingTextInputValue(interactionId: content.id, value: newValue)
        }
        .onKeyPress(.escape) {
            cancel()
            return .handled
        }
    }

    private func submit() {
        if let error = content.validate(value) {
            errorText = error
            return
        }
        runtime.resolveTextInput(
            panelId: panelId,
            result: .submitted(value),
            ifInteractionId: content.id
        )
    }

    private func cancel() {
        runtime.resolveTextInput(
            panelId: panelId,
            result: .cancelled,
            ifInteractionId: content.id
        )
    }
}

/// NSTextField-backed text input that respects IME composition. Needed because
/// SwiftUI's `TextField` routes key events in a way that swallows marked-text
/// composition state for CJK input methods — typing Japanese (Kotoeri) or
/// Pinyin into the rename-tab overlay would otherwise lose the composition.
///
/// Pattern mirrors m9's `TextBoxInput.InputTextView` IME guard: skip binding
/// sync and binding writes whenever `currentEditor()?.hasMarkedText()` is true.
private struct IMESafeTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String?
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.placeholderString = placeholder ?? ""
        tf.delegate = context.coordinator
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.isEditable = true
        tf.isSelectable = true
        tf.usesSingleLineMode = true
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.sendsActionOnEndEditing = false
        tf.focusRingType = .default
        // Grab first responder on next runloop so the hosting window has
        // settled its responder chain (the AppKit overlay host has already
        // become first responder just before this view appears).
        DispatchQueue.main.async { [weak tf] in
            guard let tf, let window = tf.window else { return }
            window.makeFirstResponder(tf)
            if let editor = tf.currentEditor() {
                editor.selectedRange = NSRange(location: 0, length: (tf.stringValue as NSString).length)
            }
        }
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        nsView.placeholderString = placeholder ?? ""
        // Skip committed-text sync during IME composition — the field editor
        // holds uncommitted marked text that stringValue doesn't reflect.
        // Overwriting stringValue here cancels the active composition.
        if let editor = nsView.currentEditor() as? NSTextView, editor.hasMarkedText() {
            return
        }
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: IMESafeTextField
        init(_ parent: IMESafeTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            if let editor = tf.currentEditor() as? NSTextView, editor.hasMarkedText() {
                // Don't push uncommitted composition through to the binding.
                return
            }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() {
                    // Let the IME commit the composition first; NSTextField
                    // will re-send insertNewline on the next commit.
                    return false
                }
                // Flush the field's committed value to the binding before
                // invoking submit — resignFirstResponder otherwise lags.
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Helpers

/// Label for the default button on a pane-dialog card: the text the caller
/// supplied, plus a small trailing Return glyph to telegraph "Enter fires
/// this." The glyph is the persistent default-action affordance; it stays
/// put regardless of which button currently holds keyboard focus. The focus
/// ring and this glyph are deliberately independent signals — focus can
/// move (Tab), but the default action does not.
private struct DefaultActionLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            Image(systemName: "return")
                .font(.system(size: 10, weight: .medium))
                .opacity(0.75)
                .accessibilityHidden(true)
        }
        .frame(minWidth: 64)
    }
}

private extension View {
    @ViewBuilder
    func focusRing(isActive: Bool) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(BrandColors.goldSwiftUI, lineWidth: isActive ? 2 : 0)
                .padding(-2)
                .animation(.easeInOut(duration: 0.12), value: isActive)
        )
    }
}

